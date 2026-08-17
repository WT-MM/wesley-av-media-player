// layerproto.mm -- STANDALONE macOS prototype comparing video presentation routes.
//
// Phase A prototype for the WAM media-player design pivot. Nothing here is
// wired into the WAM app; this binary exists only to measure and to answer the
// display-proof question for AVSampleBufferDisplayLayer.
//
// Modes:
//   asbdl-decoded      AVAssetReader -> decoded CVPixelBuffer CMSampleBuffers
//                      -> AVSampleBufferDisplayLayer.sampleBufferRenderer
//   asbdl-compressed   same, but nil output settings (layer decodes internally)
//   metal-blit         decoded CVPixelBuffer -> CVMetalTextureCache -> one
//                      render pass into a CAMetalLayer, presentDrawable
//   iosurface-contents decoded CVPixelBuffer -> CVPixelBufferGetIOSurface ->
//                      layer.contents inside a CATransaction
//   idle-window        control: window open, nothing rendering
//
// Build: ./build.sh
//
// Host clock convention: every *_ns value in this program is
// CACurrentMediaTime() * 1e9, i.e. mach_absolute_time converted to
// nanoseconds. MTLDrawable.presentedTime uses the same base, so Metal
// presentation timestamps are directly comparable to everything else here.

#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurface.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <vector>
#include <string>
#include <algorithm>
#include <map>
#include <objc/runtime.h>

// --------------------------------------------------------------- utilities

static inline uint64_t now_ns(void) {
  return (uint64_t)(CACurrentMediaTime() * 1.0e9);
}

static inline uint64_t sec_to_ns(double s) { return (uint64_t)(s * 1.0e9); }

// --------------------------------------------------------------- records

struct FrameRec {
  int index;
  double pts;             // seconds, on the synchronizer/timebase timeline
  uint64_t enqueue_ns;    // host time we handed the frame to the presenter
  uint64_t proof_ns;      // host time the mode's strongest proof fired (0 = none)
  uint64_t proof2_ns;     // ASBDL: the SECOND BufferConsumed firing for this sample
  uint64_t inferred_ns;   // host time inferred from vsync/timebase correlation
  uint32_t surface_id;    // IOSurfaceID of the decoded frame (0 if none)
  double dur;             // frame duration in media seconds
};

// copyDisplayedPixelBuffer paused-attestation probe (macOS 14.4+).
struct PausedProbe {
  double pause_timeline_s;   // synchronizer currentTime when we set rate 0
  double nonnull_after_ms;   // how long until the call returned a buffer (-1 = never)
  int polls;
  uint32_t surface_id;       // IOSurfaceID of the buffer it handed back
  int matched_index;         // frame index we identified (-1 = none)
  double matched_pts;
  double matched_dur;
  int candidates;            // how many enqueued frames shared that IOSurfaceID
  int expected_index;        // frame that frameCoversPosition() says is on screen
  double expected_pts;
  double expected_dur;
  uint32_t expected_surface_id;
  bool covers;               // returned surface == expected frame's surface
  bool nonnull_while_playing; // did it (wrongly) return a buffer at rate 1.0?
};

struct VsyncRec {
  uint64_t host_ns;
  double link_ts;       // CADisplayLink.timestamp
  double link_target;   // CADisplayLink.targetTimestamp
  double timeline_s;    // synchronizer currentTime / elapsed media time
};

struct MetricsRec {
  uint64_t host_ns;
  double elapsed_s;
  long total;
  long dropped;
  long corrupted;
  long optimized;
  double accumulated_delay;
};

struct EventRec {
  uint64_t host_ns;
  std::string what;
};

// --------------------------------------------------------------- globals

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static std::vector<FrameRec> g_frames;
static std::vector<VsyncRec> g_vsyncs;
static std::vector<MetricsRec> g_metrics;
static std::vector<EventRec> g_events;
static std::vector<PausedProbe> g_pausedProbes;
static std::map<std::string, long> g_notifiers;  // notifyingObject class -> count
static double g_overlayAt = -1.0;      // raise a translucent chrome layer at T
static double g_overlayAtElapsed = -1.0;
static int g_surfaceProbe = 0;         // retain last N buffers to read use counts
static std::vector<long> g_useCountSamples;
static std::vector<CVPixelBufferRef> g_heldBuffers;
static int g_probeCount = 6;

static std::string g_mode;
static std::string g_clip;
static std::string g_outPath;
static std::string g_proofLogPath;
static double g_duration = 20.0;
static long g_enqueueLimit = 0;   // 0 = unlimited; >0 = decisive counter sub-test
static double g_holdAfter = 0.0;  // extra seconds to sit still after the limit
static std::string g_feed = "greedy";  // greedy | jit
static double g_jitLeadS = 0.20;       // how far ahead of the timeline jit feeds
static double g_occludeAfter = -1.0;   // seconds; raise a self-owned cover window
static double g_occludeFor = 0.0;
static double g_flushAt = -1.0;        // seconds; call flush to test invalidation

static uint64_t g_t0_ns = 0;
static uint64_t g_playStart_ns = 0;
static long g_framesRead = 0;
static long g_framesEnqueued = 0;
static long g_proofCount = 0;
static long g_readerRestarts = 0;
static int g_occludedSamples = 0;
static int g_occludedAfterGrace = 0;
static int g_occlusionSamples = 0;
static long g_notReadyTransitions = 0;
static long g_requiresFlushEvents = 0;
static long g_failedToDecodeEvents = 0;
static long g_droppedNoDrawable = 0;
static bool g_readyForDisplaySeen = false;
static uint64_t g_readyForDisplay_ns = 0;
static std::string g_layerStatusFinal = "unknown";
static std::string g_layerErrorFinal = "";
static std::string g_timingMechanism = "";
static std::string g_pixelFormatUsed = "";
static std::string g_iosurfaceNote = "";
static bool g_contentsEverSet = false;

// ---- enqueue-depth / acknowledgment-semantics instrumentation ----
// in-flight depth = enqueued - consumed. Each enqueued decoded sample holds a
// CVPixelBuffer, so this is directly the surface-budget question.
static long g_consumedCount = 0;      // total BufferConsumed notifications
static long g_consumedDistinct = 0;   // distinct frame indices acknowledged
static long g_consumedDuplicates = 0; // repeat acknowledgments of a frame
static long g_consumedBeyondTwo = 0;  // any frame acknowledged 3+ times
static long g_firstFillCount = -1;      // frames accepted before !isReadyForMoreMediaData
static long g_inflightMax = 0;
static long g_lastConsumedIndex = -1;
static long g_outOfOrderConsumed = 0;   // notification order violations
static long g_payloadMismatches = 0;    // identifier round-trip failures
static std::vector<long> g_inflightSamples;
// occlusion experiment
static long g_consumedWhileOccluded = 0;
static long g_enqueuedWhileOccluded = 0;
static bool g_occlusionTestRan = false;
static volatile bool g_isOccluded = false;
// flush experiment
static bool g_flushRan = false;
static long g_inflightAtFlush = 0;
static long g_consumedAfterFlush = 0;
static uint64_t g_flush_ns = 0;

static void log_event(const char *what) {
  pthread_mutex_lock(&g_lock);
  g_events.push_back({now_ns(), std::string(what)});
  pthread_mutex_unlock(&g_lock);
}

// --------------------------------------------------------------- app object

@interface ProtoApp : NSObject
@property(strong) NSWindow *window;
@property(strong) NSView *hostView;

// ASBDL
@property(strong) AVSampleBufferDisplayLayer *sbLayer;
@property(strong) AVSampleBufferRenderSynchronizer *sync;
@property(strong) AVSampleBufferVideoRenderer *renderer;

// Metal
@property(strong) CAMetalLayer *metalLayer;
@property(strong) id<MTLDevice> device;
@property(strong) id<MTLCommandQueue> queue;
@property(strong) id<MTLRenderPipelineState> pipeline;

// IOSurface
@property(strong) CALayer *plainLayer;

@property(strong) CADisplayLink *link;
@property(strong) NSTimer *occlusionTimer;
@property(strong) NSTimer *metricsTimer;
@property(strong) dispatch_queue_t feedQueue;
@end

// ---- reader wrapper: loops the clip so trial length is clip-independent ----

@interface LoopingReader : NSObject
@property(strong) AVAsset *asset;
@property(strong) AVAssetTrack *track;
@property(strong) NSDictionary *settings;   // nil == compressed passthrough
@property(strong) AVAssetReader *reader;
@property(strong) AVAssetReaderTrackOutput *output;
@property(assign) CMTime ptsOffset;
@property(assign) CMTime lastEnd;
@property(assign) CMTime frameDur;
@end

@implementation LoopingReader

- (BOOL)openWithClip:(NSString *)path settings:(NSDictionary *)settings error:(NSError **)err {
  self.settings = settings;
  self.asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
  NSArray<AVAssetTrack *> *tracks = [self.asset tracksWithMediaType:AVMediaTypeVideo];
  if (tracks.count == 0) {
    if (err) *err = [NSError errorWithDomain:@"layerproto" code:1
                                    userInfo:@{NSLocalizedDescriptionKey: @"no video track"}];
    return NO;
  }
  self.track = tracks[0];
  float fps = self.track.nominalFrameRate > 0 ? self.track.nominalFrameRate : 30.0f;
  self.frameDur = CMTimeMakeWithSeconds(1.0 / fps, 90000);
  self.ptsOffset = kCMTimeZero;
  self.lastEnd = kCMTimeZero;
  return [self startReader:err];
}

- (BOOL)startReader:(NSError **)err {
  NSError *e = nil;
  self.reader = [AVAssetReader assetReaderWithAsset:self.asset error:&e];
  if (!self.reader) { if (err) *err = e; return NO; }
  self.output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:self.track
                                                          outputSettings:self.settings];
  self.output.alwaysCopiesSampleData = NO;
  if (![self.reader canAddOutput:self.output]) {
    if (err) *err = [NSError errorWithDomain:@"layerproto" code:2
                                    userInfo:@{NSLocalizedDescriptionKey: @"canAddOutput NO"}];
    return NO;
  }
  [self.reader addOutput:self.output];
  if (![self.reader startReading]) { if (err) *err = self.reader.error; return NO; }
  return YES;
}

// Returns a retained CMSampleBufferRef with PTS/DTS shifted onto a continuous
// timeline, or NULL on unrecoverable failure. Caller must CFRelease.
- (CMSampleBufferRef)copyNext {
  for (int attempt = 0; attempt < 2; attempt++) {
    CMSampleBufferRef sb = [self.output copyNextSampleBuffer];
    if (sb) {
      if (CMTimeCompare(self.ptsOffset, kCMTimeZero) == 0) {
        CMTime end = CMSampleBufferGetPresentationTimeStamp(sb);
        CMTime dur = CMSampleBufferGetDuration(sb);
        if (CMTIME_IS_NUMERIC(dur) && CMTimeCompare(dur, kCMTimeZero) > 0)
          end = CMTimeAdd(end, dur);
        else
          end = CMTimeAdd(end, self.frameDur);
        self.lastEnd = end;
        return sb;
      }
      // Retime onto the looped timeline.
      CMItemCount count = 0;
      CMSampleBufferGetSampleTimingInfoArray(sb, 0, NULL, &count);
      std::vector<CMSampleTimingInfo> timing(count > 0 ? count : 1);
      if (count > 0)
        CMSampleBufferGetSampleTimingInfoArray(sb, count, timing.data(), &count);
      for (CMItemCount i = 0; i < count; i++) {
        if (CMTIME_IS_NUMERIC(timing[i].presentationTimeStamp))
          timing[i].presentationTimeStamp =
              CMTimeAdd(timing[i].presentationTimeStamp, self.ptsOffset);
        if (CMTIME_IS_NUMERIC(timing[i].decodeTimeStamp))
          timing[i].decodeTimeStamp =
              CMTimeAdd(timing[i].decodeTimeStamp, self.ptsOffset);
      }
      CMSampleBufferRef out = NULL;
      OSStatus st = CMSampleBufferCreateCopyWithNewTiming(
          kCFAllocatorDefault, sb, count, count > 0 ? timing.data() : NULL, &out);
      CFRelease(sb);
      if (st != noErr || !out) return NULL;
      CMTime end = CMSampleBufferGetPresentationTimeStamp(out);
      CMTime dur = CMSampleBufferGetDuration(out);
      end = CMTimeAdd(end, (CMTIME_IS_NUMERIC(dur) && CMTimeCompare(dur, kCMTimeZero) > 0)
                               ? dur : self.frameDur);
      self.lastEnd = end;
      return out;
    }
    // EOF -> loop.
    if (self.reader.status == AVAssetReaderStatusCompleted) {
      self.ptsOffset = self.lastEnd;
      g_readerRestarts++;
      log_event("reader-loop-restart");
      NSError *e = nil;
      if (![self startReader:&e]) return NULL;
      continue;
    }
    return NULL;
  }
  return NULL;
}
@end

// --------------------------------------------------------------- shaders

static NSString *const kShaderSrc = @R"METAL(
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut v_main(uint vid [[vertex_id]]) {
  // Full-screen triangle.
  float2 p = float2((vid == 2) ? 3.0 : -1.0, (vid == 1) ? 3.0 : -1.0);
  VOut o;
  o.pos = float4(p, 0.0, 1.0);
  o.uv = float2((p.x + 1.0) * 0.5, 1.0 - (p.y + 1.0) * 0.5);
  return o;
}

fragment float4 f_main(VOut in [[stage_in]],
                       texture2d<float> yTex [[texture(0)]],
                       texture2d<float> cbcrTex [[texture(1)]]) {
  constexpr sampler s(filter::linear, address::clamp_to_edge);
  float y = yTex.sample(s, in.uv).r;
  float2 cbcr = cbcrTex.sample(s, in.uv).rg;
  // BT.709 video-range NV12 -> RGB
  y = (y - 16.0/255.0) * (255.0/219.0);
  float u = cbcr.x - 0.5;
  float v = cbcr.y - 0.5;
  float3 rgb;
  rgb.r = y + 1.5748 * v;
  rgb.g = y - 0.1873 * u - 0.4681 * v;
  rgb.b = y + 1.8556 * u;
  return float4(saturate(rgb), 1.0);
}
)METAL";

// --------------------------------------------------------------- state for
// the pull-based (metal / iosurface) modes

struct PendingFrame {
  CVPixelBufferRef pb;
  double pts;
  int index;
};

static std::vector<PendingFrame> g_pending;   // bounded ring, guarded by g_lock
static dispatch_semaphore_t g_slots = nil;    // bounds the ring
static bool g_readerDone = false;
static CVMetalTextureCacheRef g_texCache = NULL;

// --------------------------------------------------------------- ProtoApp

@implementation ProtoApp {
  LoopingReader *_reader;
  BOOL _finished;
  BOOL _started;
  dispatch_source_t _pump;
  NSWindow *_coverWindow;
}

// ---- window ----

- (void)buildWindow {
  NSScreen *screen = [NSScreen mainScreen];
  const CGFloat W = 640, H = 360;
  // Park top-left of the window at (40,40) measured from the top-left of the
  // screen, matching benchmarks/macos/player_resource_trial.py PARK_POS.
  NSRect sf = screen.frame;
  NSRect frame = NSMakeRect(sf.origin.x + 40,
                            NSMaxY(sf) - 40 - H,
                            W, H);
  NSWindow *w = [[NSWindow alloc] initWithContentRect:frame
                                           styleMask:(NSWindowStyleMaskTitled |
                                                      NSWindowStyleMaskClosable)
                                             backing:NSBackingStoreBuffered
                                               defer:NO];
  w.title = [NSString stringWithFormat:@"layerproto %s", g_mode.c_str()];
  w.releasedWhenClosed = NO;
  // Floating level so the 640x360 park rect is guaranteed unoccluded (the
  // terminal that launches the trial would otherwise sit on top of it). This
  // keeps the window visible WITHOUT activating the app or taking key status,
  // which is what would actually disturb the user.
  w.level = NSFloatingWindowLevel;
  NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, W, H)];
  v.wantsLayer = YES;
  v.layer.backgroundColor = CGColorCreateGenericRGB(0, 0, 0, 1);
  w.contentView = v;
  self.window = w;
  self.hostView = v;
  // orderFront:, NOT makeKeyAndOrderFront: / activateIgnoringOtherApps: --
  // the window must become visible without stealing the user's focus.
  [w orderFront:nil];
}

- (void)startOcclusionSampling {
  self.occlusionTimer =
      [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        (void)t;
        g_occlusionSamples++;
        BOOL visible =
            (self.window.occlusionState & NSWindowOcclusionStateVisible) != 0;
        g_isOccluded = !visible;
        if (!visible) {
          g_occludedSamples++;
          // The first ~2 s cover window creation/mapping, during which AppKit
          // legitimately reports not-visible. Occlusion during that grace
          // window is not a counterfeit-result risk; occlusion after it is.
          if (g_occlusionSamples > 2) {
            g_occludedAfterGrace++;
            log_event("window-occluded");
          } else {
            log_event("window-not-yet-mapped");
          }
        }
        pthread_mutex_lock(&g_lock);
        // IOSurfaceGetUseCount on buffers we still hold: a count above our own
        // reference means the renderer is holding OUR surface rather than
        // having copied out of it.
        for (CVPixelBufferRef pb : g_heldBuffers) {
          IOSurfaceRef s = CVPixelBufferGetIOSurface(pb);
          if (s) g_useCountSamples.push_back((long)IOSurfaceGetUseCount(s));
        }
        long inflight = g_framesEnqueued - g_consumedDistinct;
        g_inflightSamples.push_back(inflight);
        if (inflight > g_inflightMax) g_inflightMax = inflight;
        pthread_mutex_unlock(&g_lock);
      }];
}

// (D) Self-occlusion experiment. Raises an opaque window owned by THIS process
// directly over the prototype window -- it never touches or covers anything of
// the user's beyond the 640x360 park rect the prototype already occupies.
- (void)scheduleOcclusionExperiment {
  if (g_occludeAfter < 0) return;
  [NSTimer scheduledTimerWithTimeInterval:g_occludeAfter repeats:NO block:^(NSTimer *t) {
    (void)t;
    NSRect f = self.window.frame;
    _coverWindow = [[NSWindow alloc] initWithContentRect:f
                                               styleMask:NSWindowStyleMaskBorderless
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
    _coverWindow.backgroundColor = [NSColor blackColor];
    _coverWindow.opaque = YES;
    _coverWindow.level = NSFloatingWindowLevel;
    _coverWindow.releasedWhenClosed = NO;
    [_coverWindow orderFront:nil];
    g_occlusionTestRan = true;
    log_event("cover-window-raised");
    [NSTimer scheduledTimerWithTimeInterval:g_occludeFor repeats:NO block:^(NSTimer *t2) {
      (void)t2;
      [_coverWindow orderOut:nil];
      _coverWindow = nil;
      log_event("cover-window-lowered");
    }];
  }];
}

// ---- copyDisplayedPixelBuffer paused-attestation experiment (macOS 14.4+) ----
//
// The header says this returns NULL when the rate is non-zero. WAM's
// commit-seek path is always PAUSED when it needs its proof, so if this call
// yields the on-screen frame while paused AND we can identify WHICH frame it
// is, it is a strictly stronger commit-seek proof than the GL path's
// post-draw/pre-swap fence.
- (void)runPausedProbeCycle:(int)k {
  if (@available(macOS 14.4, *)) {
    // (a) control: does it return non-NULL while PLAYING (rate 1.0)?
    CVPixelBufferRef whilePlaying = [self.renderer copyDisplayedPixelBuffer];
    BOOL nonNullPlaying = (whilePlaying != NULL);
    if (whilePlaying) CVPixelBufferRelease(whilePlaying);

    // Freeze the timebase FIRST, then read it. Sampling currentTime before the
    // rate change leaves a race: the timebase keeps advancing across the
    // setter, so the position can land one frame away from what is on screen
    // and produce a spurious mismatch.
    uint64_t pause_ns = now_ns();
    self.sync.rate = 0.0;
    double pauseTimeline = CMTimeGetSeconds([self.sync currentTime]);
    log_event("paused-probe-rate-0");

    __block int polls = 0;
    __block NSTimer *poll = nil;
    poll = [NSTimer scheduledTimerWithTimeInterval:0.005 repeats:YES
                                             block:^(NSTimer *t) {
      polls++;
      CVPixelBufferRef pb = [self.renderer copyDisplayedPixelBuffer];
      BOOL done = NO;
      PausedProbe pr = {};
      pr.pause_timeline_s = pauseTimeline;
      pr.polls = polls;
      pr.matched_index = -1;
      pr.expected_index = -1;
      pr.nonnull_while_playing = nonNullPlaying;
      if (pb) {
        pr.nonnull_after_ms = (double)(now_ns() - pause_ns) / 1e6;
        IOSurfaceRef s = CVPixelBufferGetIOSurface(pb);
        pr.surface_id = s ? IOSurfaceGetID(s) : 0;
        // NON-CIRCULAR identification: independently compute which frame
        // SHOULD be on screen using WAM's own predicate
        //   frameCoversPosition(f, pos) := pos >= f.pts && pos - f.pts < f.dur
        // against the paused timebase position, then ask whether the
        // IOSurface we were handed is that frame's surface. We do NOT search
        // for a surface that happens to cover the position.
        pthread_mutex_lock(&g_lock);
        for (auto &f : g_frames) {
          if (f.surface_id && f.surface_id == pr.surface_id) pr.candidates++;
          if ((pauseTimeline >= f.pts) && (pauseTimeline - f.pts < f.dur)) {
            pr.expected_index = f.index;
            pr.expected_pts = f.pts;
            pr.expected_dur = f.dur;
            pr.expected_surface_id = f.surface_id;
          }
        }
        pthread_mutex_unlock(&g_lock);
        pr.matched_index = pr.expected_index;
        pr.matched_pts = pr.expected_pts;
        pr.matched_dur = pr.expected_dur;
        pr.covers = (pr.expected_index >= 0 &&
                     pr.expected_surface_id == pr.surface_id);
        CVPixelBufferRelease(pb);
        done = YES;
      } else if (polls * 5 >= 1000) {
        pr.nonnull_after_ms = -1.0;
        done = YES;
      }
      if (!done) return;
      [t invalidate];
      pthread_mutex_lock(&g_lock);
      g_pausedProbes.push_back(pr);
      pthread_mutex_unlock(&g_lock);
      // resume
      self.sync.rate = 1.0;
      log_event("paused-probe-resumed");
    }];
    (void)poll;
    (void)k;
  }
}

- (void)schedulePausedProbes {
  if (g_mode != "asbdl-pausedproof") return;
  for (int k = 0; k < g_probeCount; k++) {
    // Deliberately NOT a multiple of the 1/30 s frame period. A 2.0 s spacing
    // would land every probe at the same phase within a frame interval and
    // would never exercise a frame boundary.
    double at = 3.0 + k * 1.37;
    [NSTimer scheduledTimerWithTimeInterval:at repeats:NO block:^(NSTimer *t) {
      (void)t;
      [self runPausedProbeCycle:k];
    }];
  }
}

// ---- optimized-compositing perturbation ----
//
// Apple documents no rule for what disqualifies a frame from
// numberOfFramesDisplayedUsingOptimizedCompositing. WAM's chrome would sit
// above the video, so raise a translucent sublayer over the video layer
// mid-run and watch whether the counter stops advancing. If it does, chrome
// must live in a separate window rather than a layer above the video.
- (void)scheduleOverlayExperiment {
  if (g_overlayAt < 0) return;
  [NSTimer scheduledTimerWithTimeInterval:g_overlayAt repeats:NO block:^(NSTimer *t) {
    (void)t;
    CALayer *chrome = [CALayer layer];
    chrome.frame = CGRectMake(20, 20, 240, 60);
    chrome.backgroundColor = CGColorCreateGenericRGB(1, 1, 1, 1);
    chrome.opacity = 0.35f;   // non-integral opacity == real compositing work
    CALayer *host = self.sbLayer ? self.sbLayer : self.hostView.layer;
    [host addSublayer:chrome];
    g_overlayAtElapsed = g_playStart_ns ? (now_ns() - g_playStart_ns) / 1.0e9 : 0.0;
    log_event("translucent-overlay-raised");
  }];
}

// Flush / generation-invalidation experiment.
- (void)scheduleFlushExperiment {
  if (g_flushAt < 0 || !self.renderer) return;
  [NSTimer scheduledTimerWithTimeInterval:g_flushAt repeats:NO block:^(NSTimer *t) {
    (void)t;
    pthread_mutex_lock(&g_lock);
    g_inflightAtFlush = g_framesEnqueued - g_consumedDistinct;
    g_flushRan = true;
    g_flush_ns = now_ns();
    pthread_mutex_unlock(&g_lock);
    log_event("flush-issued");
    [self.renderer flushWithRemovalOfDisplayedImage:NO completionHandler:^{
      log_event("flush-completed");
    }];
  }];
}

// ---- ASBDL ----

- (BOOL)setupASBDL:(BOOL)decoded error:(NSError **)err {
  AVSampleBufferDisplayLayer *layer = [[AVSampleBufferDisplayLayer alloc] init];
  layer.frame = self.hostView.bounds;
  layer.videoGravity = AVLayerVideoGravityResizeAspect;
  layer.backgroundColor = CGColorCreateGenericRGB(0, 0, 0, 1);
  [self.hostView.layer addSublayer:layer];
  self.sbLayer = layer;

  // macOS 14+: enqueue through sampleBufferRenderer, not the (deprecated)
  // layer-level AVQueuedSampleBufferRendering methods.
  self.renderer = layer.sampleBufferRenderer;
  self.sync = [[AVSampleBufferRenderSynchronizer alloc] init];
  [self.sync addRenderer:self.renderer];
  g_timingMechanism =
      "AVSampleBufferRenderSynchronizer + layer.sampleBufferRenderer (macOS 14+); "
      "frames displayed at PTS on the synchronizer timebase; "
      "kCMSampleBufferAttachmentKey_DisplayImmediately NOT used";

  NSDictionary *settings = nil;
  if (decoded) {
    settings = @{
      (id)kCVPixelBufferPixelFormatTypeKey:
          @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
      (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    g_pixelFormatUsed = "420YpCbCr8BiPlanarVideoRange (decoded CVPixelBuffer)";
  } else {
    g_pixelFormatUsed = "compressed CMSampleBuffer passthrough (nil outputSettings)";
  }

  _reader = [[LoopingReader alloc] init];
  if (![_reader openWithClip:@(g_clip.c_str()) settings:settings error:err]) return NO;

  [self installASBDLObservers];

  self.feedQueue = dispatch_queue_create("layerproto.feed", DISPATCH_QUEUE_SERIAL);
  __weak ProtoApp *weakSelf = self;
  if (g_feed == "jit") {
    // JIT feeding cannot use requestMediaDataWhenReadyOnQueue: alone -- that
    // block is only re-invoked on a NO->YES readiness edge, and a JIT feeder
    // returns while readiness is still YES. Pump on a 5 ms timer instead.
    _pump = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.feedQueue);
    dispatch_source_set_timer(_pump, dispatch_time(DISPATCH_TIME_NOW, 0),
                              5 * NSEC_PER_MSEC, 1 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_pump, ^{ [weakSelf feedASBDL]; });
    dispatch_resume(_pump);
  } else {
    [self.renderer requestMediaDataWhenReadyOnQueue:self.feedQueue usingBlock:^{
      [weakSelf feedASBDL];
    }];
  }
  return YES;
}

- (void)installASBDLObservers {
  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

  // (2) PostNotificationWhenConsumed -> BufferConsumed
  [nc addObserverForName:(__bridge NSString *)kCMSampleBufferConsumerNotification_BufferConsumed
                  object:nil
                   queue:nil
              usingBlock:^(NSNotification *note) {
                uint64_t t = now_ns();
                NSDictionary *ui = note.userInfo;
                NSNumber *idx = ui[@"layerproto_index"];
                if (!idx) return;
                // Who posted it? The two acks per sample could be one
                // consumer posting twice, or two different consumers.
                const char *cls = note.object ? object_getClassName(note.object)
                                              : "(nil)";
                pthread_mutex_lock(&g_lock);
                if (g_notifiers.find(cls) == g_notifiers.end()) g_notifiers[cls] = 0;
                g_notifiers[cls]++;
                pthread_mutex_unlock(&g_lock);
                int i = idx.intValue;
                // Identifier round-trip check: can we carry arbitrary
                // per-frame identity (the WAM Stamp/generation/exact CMTime)
                // through this attachment and get it back intact?
                BOOL ok = [ui[@"magic"] isEqual:@"WAM-layerproto"] &&
                          [ui[@"pts_value"] isKindOfClass:NSNumber.class] &&
                          [ui[@"pts_scale"] isKindOfClass:NSNumber.class] &&
                          [ui[@"dur_value"] isKindOfClass:NSNumber.class] &&
                          [ui[@"generation"] isKindOfClass:NSNumber.class];
                pthread_mutex_lock(&g_lock);
                if (!ok) g_payloadMismatches++;
                g_consumedCount++;
                if (g_isOccluded) g_consumedWhileOccluded++;
                if (g_flushRan) g_consumedAfterFlush++;
                if (i >= 0 && i < (int)g_frames.size()) {
                  FrameRec &f = g_frames[i];
                  if (f.proof_ns == 0) {
                    // FIRST acknowledgment of this sample.
                    if (i <= (int)g_lastConsumedIndex) g_outOfOrderConsumed++;
                    g_lastConsumedIndex = i;
                    f.proof_ns = t;
                    g_consumedDistinct++;
                    g_proofCount++;
                  } else if (f.proof2_ns == 0) {
                    f.proof2_ns = t;
                    g_consumedDuplicates++;
                  } else {
                    g_consumedBeyondTwo++;
                  }
                }
                pthread_mutex_unlock(&g_lock);
              }];

  [nc addObserverForName:AVSampleBufferVideoRendererDidFailToDecodeNotification
                  object:nil queue:nil
              usingBlock:^(NSNotification *note) {
                g_failedToDecodeEvents++;
                NSError *e = note.userInfo[AVSampleBufferVideoRendererDidFailToDecodeNotificationErrorKey];
                log_event([[NSString stringWithFormat:@"did-fail-to-decode: %@",
                                                      e.localizedDescription] UTF8String]);
              }];

  [nc addObserverForName:AVSampleBufferVideoRendererRequiresFlushToResumeDecodingDidChangeNotification
                  object:nil queue:nil
              usingBlock:^(NSNotification *note) {
                (void)note;
                g_requiresFlushEvents++;
                log_event("requiresFlushToResumeDecoding-changed");
              }];

  if (@available(macOS 14.4, *)) {
    [nc addObserverForName:AVSampleBufferDisplayLayerReadyForDisplayDidChangeNotification
                    object:nil queue:nil
                usingBlock:^(NSNotification *note) {
                  (void)note;
                  if (!g_readyForDisplaySeen && self.sbLayer.isReadyForDisplay) {
                    g_readyForDisplaySeen = true;
                    g_readyForDisplay_ns = now_ns();
                    log_event("readyForDisplay=YES");
                  }
                }];
  }
}

- (void)feedASBDL {
  while (self.renderer.isReadyForMoreMediaData) {
    if (_finished) { [self.renderer stopRequestingMediaData]; return; }
    if (g_enqueueLimit > 0 && g_framesEnqueued >= g_enqueueLimit) {
      [self.renderer stopRequestingMediaData];
      log_event("enqueue-limit-reached");
      return;
    }
    // Just-in-time feeding: only push a frame when its PTS is within
    // g_jitLeadS of the synchronizer timeline. This is the feeding discipline
    // WAM would need under its 10-IOSurface / 64 MiB process budget.
    if (g_feed == "jit" && _started) {
      double tl = CMTimeGetSeconds([self.sync currentTime]);
      double nextPts = CMTimeGetSeconds(_reader.lastEnd);
      if (nextPts > tl + g_jitLeadS) return;  // re-invoked when ready again
    }
    CMSampleBufferRef sb = [_reader copyNext];
    if (!sb) {
      log_event("reader-exhausted");
      [self.renderer stopRequestingMediaData];
      return;
    }
    g_framesRead++;

    double pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb));
    int index = (int)g_framesEnqueued;

    // (2) attach PostNotificationWhenConsumed carrying a full identity
    // payload: this is the round-trip test for WAM's Stamp + generation +
    // exact CMTime echo requirement.
    CMTime ptsT = CMSampleBufferGetPresentationTimeStamp(sb);
    CMTime durT = CMSampleBufferGetDuration(sb);
    CFDictionaryRef payload = (__bridge_retained CFDictionaryRef) @{
      @"magic": @"WAM-layerproto",
      @"layerproto_index": @(index),
      @"generation": @(1),
      @"pts_value": @(ptsT.value),
      @"pts_scale": @(ptsT.timescale),
      @"dur_value": @(durT.value),
      @"dur_scale": @(durT.timescale),
    };
    CMSetAttachment(sb, kCMSampleBufferAttachmentKey_PostNotificationWhenConsumed,
                    payload, kCMAttachmentMode_ShouldNotPropagate);
    CFRelease(payload);

    // Record the IOSurfaceID so copyDisplayedPixelBuffer's return value can be
    // matched back to a specific enqueued frame.
    uint32_t sid = 0;
    CVImageBufferRef ib = CMSampleBufferGetImageBuffer(sb);
    if (ib) {
      IOSurfaceRef s = CVPixelBufferGetIOSurface((CVPixelBufferRef)ib);
      if (s) sid = IOSurfaceGetID(s);
    }
    double durS = CMTIME_IS_NUMERIC(durT) && CMTimeCompare(durT, kCMTimeZero) > 0
                      ? CMTimeGetSeconds(durT) : (1.0 / 30.0);

    // Opt-in surface-retention probe: hold the last N decoded buffers so their
    // IOSurface use counts can be read later. OFF by default -- retaining
    // 1080p surfaces would itself distort the footprint measurement.
    if (g_surfaceProbe > 0 && ib) {
      pthread_mutex_lock(&g_lock);
      g_heldBuffers.push_back((CVPixelBufferRef)CVBufferRetain(ib));
      while ((int)g_heldBuffers.size() > g_surfaceProbe) {
        CVBufferRelease(g_heldBuffers.front());
        g_heldBuffers.erase(g_heldBuffers.begin());
      }
      pthread_mutex_unlock(&g_lock);
    }

    uint64_t enq = now_ns();
    pthread_mutex_lock(&g_lock);
    g_frames.push_back({index, pts, enq, 0, 0, 0, sid, durS});
    pthread_mutex_unlock(&g_lock);

    [self.renderer enqueueSampleBuffer:sb];
    CFRelease(sb);
    g_framesEnqueued++;
    if (g_isOccluded) g_enqueuedWhileOccluded++;

    // Must start the clock at a SMALL prime. The renderer's admission window
    // is only a couple of frames deep while the timebase rate is 0, so waiting
    // for a large prime deadlocks: the layer stops accepting frames and we
    // never reach the threshold that would start playback.
    if (!_started && g_framesEnqueued >= 3) {
      _started = YES;
      dispatch_async(dispatch_get_main_queue(), ^{
        g_playStart_ns = now_ns();
        [self.sync setRate:1.0 time:kCMTimeZero];
        log_event("synchronizer-rate-1.0");
      });
    }
  }
  // Fell out because isReadyForMoreMediaData went NO. In greedy mode the very
  // first such stop is the layer's own admission-window size.
  g_notReadyTransitions++;
  if (g_firstFillCount < 0 && g_framesEnqueued > 0) {
    g_firstFillCount = g_framesEnqueued;
    log_event("first-fill-boundary");
  }
}

- (void)startMetricsPolling {
  if (!self.renderer) return;
  self.metricsTimer =
      [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        (void)t;
        [self sampleMetrics];
      }];
}

- (void)sampleMetrics {
  if (@available(macOS 14.4, *)) {
    uint64_t t = now_ns();
    double elapsed = g_playStart_ns ? (t - g_playStart_ns) / 1.0e9 : 0.0;
    [self.renderer loadVideoPerformanceMetricsWithCompletionHandler:^(
                       AVVideoPerformanceMetrics *m) {
      if (!m) return;
      pthread_mutex_lock(&g_lock);
      g_metrics.push_back({t, elapsed,
                           (long)m.totalNumberOfFrames,
                           (long)m.numberOfDroppedFrames,
                           (long)m.numberOfCorruptedFrames,
                           (long)m.numberOfFramesDisplayedUsingOptimizedCompositing,
                           (double)m.totalAccumulatedFrameDelay});
      pthread_mutex_unlock(&g_lock);
    }];
  }
}

// ---- Metal ----

- (BOOL)setupMetal:(NSError **)err {
  self.device = MTLCreateSystemDefaultDevice();
  if (!self.device) {
    if (err) *err = [NSError errorWithDomain:@"layerproto" code:10
                                    userInfo:@{NSLocalizedDescriptionKey: @"no Metal device"}];
    return NO;
  }
  self.queue = [self.device newCommandQueue];

  CAMetalLayer *ml = [CAMetalLayer layer];
  ml.device = self.device;
  ml.pixelFormat = MTLPixelFormatBGRA8Unorm;
  ml.framebufferOnly = YES;
  ml.frame = self.hostView.bounds;
  CGFloat scale = self.window.backingScaleFactor;
  ml.contentsScale = scale;
  ml.drawableSize = CGSizeMake(self.hostView.bounds.size.width * scale,
                               self.hostView.bounds.size.height * scale);
  ml.maximumDrawableCount = 3;
  ml.backgroundColor = CGColorCreateGenericRGB(0, 0, 0, 1);
  [self.hostView.layer addSublayer:ml];
  self.metalLayer = ml;

  NSError *e = nil;
  id<MTLLibrary> lib = [self.device newLibraryWithSource:kShaderSrc options:nil error:&e];
  if (!lib) { if (err) *err = e; return NO; }
  MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
  pd.vertexFunction = [lib newFunctionWithName:@"v_main"];
  pd.fragmentFunction = [lib newFunctionWithName:@"f_main"];
  pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  self.pipeline = [self.device newRenderPipelineStateWithDescriptor:pd error:&e];
  if (!self.pipeline) { if (err) *err = e; return NO; }

  CVReturn cvr = CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, self.device,
                                           NULL, &g_texCache);
  if (cvr != kCVReturnSuccess) {
    if (err) *err = [NSError errorWithDomain:@"layerproto" code:11
                                    userInfo:@{NSLocalizedDescriptionKey: @"texture cache"}];
    return NO;
  }
  g_timingMechanism = "CADisplayLink (macOS 14+) on the window; frame released "
                      "when its PTS <= elapsed wall time; presentDrawable + "
                      "addPresentedHandler for the display timestamp";
  g_pixelFormatUsed = "420YpCbCr8BiPlanarVideoRange (decoded CVPixelBuffer)";
  return [self startPullReaderDecoded:err];
}

// ---- IOSurface ----

- (BOOL)setupIOSurface:(NSError **)err {
  CALayer *l = [CALayer layer];
  l.frame = self.hostView.bounds;
  l.contentsGravity = kCAGravityResizeAspect;
  l.backgroundColor = CGColorCreateGenericRGB(0, 0, 0, 1);
  [self.hostView.layer addSublayer:l];
  self.plainLayer = l;
  g_timingMechanism = "CADisplayLink paced; CATransaction begin/commit per frame "
                      "with setCompletionBlock: as the proof signal";
  g_pixelFormatUsed = "420YpCbCr8BiPlanarVideoRange (decoded CVPixelBuffer)";
  return [self startPullReaderDecoded:err];
}

// ---- shared pull-mode reader (metal + iosurface) ----

- (BOOL)startPullReaderDecoded:(NSError **)err {
  NSDictionary *settings = @{
    (id)kCVPixelBufferPixelFormatTypeKey:
        @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
    (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    (id)kCVPixelBufferMetalCompatibilityKey: @YES,
  };
  _reader = [[LoopingReader alloc] init];
  if (![_reader openWithClip:@(g_clip.c_str()) settings:settings error:err]) return NO;

  g_slots = dispatch_semaphore_create(6);
  dispatch_queue_t rq = dispatch_queue_create("layerproto.read", DISPATCH_QUEUE_SERIAL);
  dispatch_async(rq, ^{
    int idx = 0;
    while (!self->_finished) {
      if (dispatch_semaphore_wait(g_slots,
              dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC)) != 0)
        continue;
      if (self->_finished) break;
      CMSampleBufferRef sb = [self->_reader copyNext];
      if (!sb) { g_readerDone = true; log_event("reader-exhausted"); break; }
      g_framesRead++;
      CVImageBufferRef ib = CMSampleBufferGetImageBuffer(sb);
      if (!ib) { CFRelease(sb); dispatch_semaphore_signal(g_slots); continue; }
      CVPixelBufferRef pb = (CVPixelBufferRef)CVBufferRetain(ib);
      double pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb));
      CFRelease(sb);
      pthread_mutex_lock(&g_lock);
      g_pending.push_back({pb, pts, idx});
      pthread_mutex_unlock(&g_lock);
      idx++;
    }
  });
  return YES;
}

// ---- display link ----

- (void)startDisplayLink {
  self.link = [self.window displayLinkWithTarget:self selector:@selector(vsync:)];
  [self.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)vsync:(CADisplayLink *)link {
  uint64_t t = now_ns();
  double timeline = 0.0;
  if (self.sync) {
    timeline = CMTimeGetSeconds([self.sync currentTime]);
  } else if (g_playStart_ns) {
    timeline = (t - g_playStart_ns) / 1.0e9;
  }
  pthread_mutex_lock(&g_lock);
  g_vsyncs.push_back({t, link.timestamp, link.targetTimestamp, timeline});
  pthread_mutex_unlock(&g_lock);

  if (g_mode == "metal-blit") [self metalTick:link timeline:timeline];
  else if (g_mode == "iosurface-contents") [self iosurfaceTick:link timeline:timeline];
}

// Pop the newest frame whose PTS has come due; drop older ones. Returns
// false if nothing is due.
- (BOOL)popDue:(double)timeline into:(PendingFrame *)out {
  BOOL got = NO;
  pthread_mutex_lock(&g_lock);
  // Exactly one frame per vsync, never skipped. Source is 30 fps against a
  // 120 Hz display, so presenting every decoded frame in order at the first
  // vsync at-or-after its PTS cannot fall behind structurally, and it keeps
  // frames_enqueued == frames_read so the proof accounting stays exact.
  if (!g_pending.empty() && g_pending.front().pts <= timeline) {
    *out = g_pending.front();
    g_pending.erase(g_pending.begin());
    dispatch_semaphore_signal(g_slots);
    got = YES;
  }
  pthread_mutex_unlock(&g_lock);
  return got;
}

- (void)metalTick:(CADisplayLink *)link timeline:(double)timeline {
  if (!g_playStart_ns) {
    // wait until a couple of frames are buffered, then start the clock
    pthread_mutex_lock(&g_lock);
    size_t n = g_pending.size();
    pthread_mutex_unlock(&g_lock);
    if (n < 3) return;
    g_playStart_ns = now_ns();
    log_event("metal-clock-start");
    return;
  }
  if (g_enqueueLimit > 0 && g_framesEnqueued >= g_enqueueLimit) return;

  PendingFrame f = {NULL, 0, 0};
  if (![self popDue:timeline into:&f]) return;

  id<CAMetalDrawable> drawable = [self.metalLayer nextDrawable];
  if (!drawable) {
    g_droppedNoDrawable++;
    CVBufferRelease(f.pb);
    return;
  }

  size_t w0 = CVPixelBufferGetWidthOfPlane(f.pb, 0);
  size_t h0 = CVPixelBufferGetHeightOfPlane(f.pb, 0);
  size_t w1 = CVPixelBufferGetWidthOfPlane(f.pb, 1);
  size_t h1 = CVPixelBufferGetHeightOfPlane(f.pb, 1);
  CVMetalTextureRef ty = NULL, tc = NULL;
  CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, g_texCache, f.pb, NULL,
                                            MTLPixelFormatR8Unorm, w0, h0, 0, &ty);
  CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, g_texCache, f.pb, NULL,
                                            MTLPixelFormatRG8Unorm, w1, h1, 1, &tc);
  if (!ty || !tc) {
    if (ty) CFRelease(ty);
    if (tc) CFRelease(tc);
    CVBufferRelease(f.pb);
    return;
  }

  int index = (int)g_framesEnqueued;
  uint64_t enq = now_ns();
  pthread_mutex_lock(&g_lock);
  g_frames.push_back({index, f.pts, enq, 0, 0, 0, 0, 1.0/30.0});
  pthread_mutex_unlock(&g_lock);
  g_framesEnqueued++;

  MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
  rp.colorAttachments[0].texture = drawable.texture;
  rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
  rp.colorAttachments[0].storeAction = MTLStoreActionStore;

  id<MTLCommandBuffer> cb = [self.queue commandBuffer];
  id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
  [enc setRenderPipelineState:self.pipeline];
  [enc setFragmentTexture:CVMetalTextureGetTexture(ty) atIndex:0];
  [enc setFragmentTexture:CVMetalTextureGetTexture(tc) atIndex:1];
  [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
  [enc endEncoding];

  [drawable addPresentedHandler:^(id<MTLDrawable> d) {
    uint64_t p = (uint64_t)(d.presentedTime * 1.0e9);
    if (p == 0) return;  // skipped / never presented
    pthread_mutex_lock(&g_lock);
    if (index < (int)g_frames.size() && g_frames[index].proof_ns == 0) {
      g_frames[index].proof_ns = p;
      g_proofCount++;
    }
    pthread_mutex_unlock(&g_lock);
  }];
  [cb presentDrawable:drawable];
  [cb addCompletedHandler:^(id<MTLCommandBuffer> b) {
    (void)b;
    CFRelease(ty);
    CFRelease(tc);
    CVBufferRelease(f.pb);
  }];
  [cb commit];
}

- (void)iosurfaceTick:(CADisplayLink *)link timeline:(double)timeline {
  if (!g_playStart_ns) {
    pthread_mutex_lock(&g_lock);
    size_t n = g_pending.size();
    pthread_mutex_unlock(&g_lock);
    if (n < 3) return;
    g_playStart_ns = now_ns();
    log_event("iosurface-clock-start");
    return;
  }
  if (g_enqueueLimit > 0 && g_framesEnqueued >= g_enqueueLimit) return;

  PendingFrame f = {NULL, 0, 0};
  if (![self popDue:timeline into:&f]) return;

  IOSurfaceRef surf = CVPixelBufferGetIOSurface(f.pb);
  if (!surf) {
    if (g_iosurfaceNote.empty())
      g_iosurfaceNote = "CVPixelBufferGetIOSurface returned NULL";
    CVBufferRelease(f.pb);
    return;
  }

  int index = (int)g_framesEnqueued;
  uint64_t enq = now_ns();
  pthread_mutex_lock(&g_lock);
  g_frames.push_back({index, f.pts, enq, 0, 0, 0, 0, 1.0/30.0});
  pthread_mutex_unlock(&g_lock);
  g_framesEnqueued++;

  CVPixelBufferRef held = f.pb;  // keep alive until the transaction lands
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  [CATransaction setCompletionBlock:^{
    uint64_t p = now_ns();
    pthread_mutex_lock(&g_lock);
    if (index < (int)g_frames.size() && g_frames[index].proof_ns == 0) {
      g_frames[index].proof_ns = p;
      g_proofCount++;
    }
    pthread_mutex_unlock(&g_lock);
    CVBufferRelease(held);
  }];
  self.plainLayer.contents = (__bridge id)surf;
  g_contentsEverSet = true;
  [CATransaction commit];
  if (self.plainLayer.contents == nil && g_iosurfaceNote.empty())
    g_iosurfaceNote = "layer.contents did not retain the IOSurface";
}

// --------------------------------------------------------------- finalize

- (void)finish {
  if (_finished) return;
  _finished = YES;

  if (self.renderer) {
    [self.renderer stopRequestingMediaData];
    AVQueuedSampleBufferRenderingStatus st = self.renderer.status;
    g_layerStatusFinal = (st == AVQueuedSampleBufferRenderingStatusUnknown) ? "unknown"
                       : (st == AVQueuedSampleBufferRenderingStatusRendering) ? "rendering"
                       : "failed";
    if (self.renderer.error)
      g_layerErrorFinal = [self.renderer.error.localizedDescription UTF8String];
    if (self.renderer.requiresFlushToResumeDecoding) g_requiresFlushEvents++;
    // one last metrics sample, synchronously-ish
    [self sampleMetrics];
  }
  [self.link invalidate];
  [self.occlusionTimer invalidate];
  [self.metricsTimer invalidate];
  if (self.sync) self.sync.rate = 0.0;

  // Give the final async metrics load a chance to land.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), ^{
    [self writeResults];
    exit(0);
  });
}

// (3) correlated inference: for each frame PTS, the first vsync at which the
// timebase had reached that PTS. This is an INFERENCE from the timebase, not
// an attestation from the compositor.
- (void)computeInferredDisplayTimes {
  pthread_mutex_lock(&g_lock);
  std::sort(g_vsyncs.begin(), g_vsyncs.end(),
            [](const VsyncRec &a, const VsyncRec &b) { return a.host_ns < b.host_ns; });
  size_t vi = 0;
  for (auto &f : g_frames) {
    while (vi < g_vsyncs.size() && g_vsyncs[vi].timeline_s < f.pts) vi++;
    if (vi < g_vsyncs.size()) f.inferred_ns = g_vsyncs[vi].host_ns;
  }
  pthread_mutex_unlock(&g_lock);
}

static void stats(const std::vector<double> &v, double *mn, double *md, double *p95,
                  double *mx, double *mean) {
  if (v.empty()) { *mn = *md = *p95 = *mx = *mean = 0; return; }
  std::vector<double> s = v;
  std::sort(s.begin(), s.end());
  *mn = s.front();
  *mx = s.back();
  *md = s[s.size() / 2];
  *p95 = s[(size_t)(s.size() * 0.95) < s.size() ? (size_t)(s.size() * 0.95) : s.size() - 1];
  double sum = 0;
  for (double d : s) sum += d;
  *mean = sum / s.size();
}

- (void)writeResults {
  [self computeInferredDisplayTimes];

  pthread_mutex_lock(&g_lock);

  long provenDisplayed = 0;
  std::vector<double> proofLatencyMs;      // proof_ns - inferred display time
  std::vector<double> proofVsEnqueueMs;    // proof_ns - enqueue_ns
  std::vector<double> proof2LatencyMs;     // 2nd ack - inferred display time
  std::vector<double> proof2VsProof1Ms;    // 2nd ack - 1st ack
  for (auto &f : g_frames) {
    if (f.proof_ns) {
      provenDisplayed++;
      proofVsEnqueueMs.push_back((double)((int64_t)f.proof_ns - (int64_t)f.enqueue_ns) / 1e6);
      if (f.inferred_ns)
        proofLatencyMs.push_back((double)((int64_t)f.proof_ns - (int64_t)f.inferred_ns) / 1e6);
    }
    if (f.proof2_ns) {
      proof2VsProof1Ms.push_back((double)((int64_t)f.proof2_ns - (int64_t)f.proof_ns) / 1e6);
      if (f.inferred_ns)
        proof2LatencyMs.push_back((double)((int64_t)f.proof2_ns - (int64_t)f.inferred_ns) / 1e6);
    }
  }

  double lo, med, p95, hi, mean;
  stats(proofLatencyMs, &lo, &med, &p95, &hi, &mean);
  double elo, emed, ep95, ehi, emean;
  stats(proofVsEnqueueMs, &elo, &emed, &ep95, &ehi, &emean);
  double blo, bmed, bp95, bhi, bmean;
  stats(proof2LatencyMs, &blo, &bmed, &bp95, &bhi, &bmean);
  double clo, cmed, cp95, chi, cmean;
  stats(proof2VsProof1Ms, &clo, &cmed, &cp95, &chi, &cmean);

  // vsync-observed effective display fps: distinct frames the timebase crossed
  double timelineSpan = 0;
  if (g_vsyncs.size() > 1)
    timelineSpan = g_vsyncs.back().timeline_s - g_vsyncs.front().timeline_s;
  double wallSpan = g_vsyncs.size() > 1
                        ? (g_vsyncs.back().host_ns - g_vsyncs.front().host_ns) / 1e9
                        : 0;

  MetricsRec first = {0, 0, 0, 0, 0, 0, 0};
  MetricsRec last = {0, 0, 0, 0, 0, 0, 0};
  if (!g_metrics.empty()) { first = g_metrics.front(); last = g_metrics.back(); }

  double playSeconds =
      g_playStart_ns ? (now_ns() - g_playStart_ns) / 1.0e9 : 0.0;
  double expected = 30.0 * (playSeconds > 0 ? playSeconds : g_duration);
  double effectiveFps = playSeconds > 0 ? provenDisplayed / playSeconds : 0.0;

  bool isIdle = (g_mode == "idle-window");
  bool occOK = (g_occludedAfterGrace == 0 && g_occlusionSamples > 2);
  bool fpsOK = isIdle || (provenDisplayed >= 0.98 * expected);
  // A run that wrapped the clip is NOT reportable. Re-opening the
  // AVAssetReader stalls the feeder long enough to miss display deadlines, so
  // the drop and latency statistics across a wrap are not trustworthy --
  // measured: 0 drops on runs with no wrap, 333 drops on an otherwise
  // identical run with one wrap. Keep the measured window inside the clip.
  bool noWrap = (g_readerRestarts == 0);
  bool valid = occOK && fpsOK && noWrap;

  // ---- proof TSV ----
  if (!g_proofLogPath.empty()) {
    FILE *tf = fopen(g_proofLogPath.c_str(), "w");
    if (tf) {
      fprintf(tf, "frame_index\tpts_seconds\tenqueue_host_ns\tproof_host_ns\t"
                  "proof_source\tinferred_display_ns\tack2_host_ns\n");
      const char *src = (g_mode == "metal-blit") ? "drawable-presented"
                      : (g_mode == "iosurface-contents") ? "catransaction-completed"
                      : "consumed-notification";
      for (auto &f : g_frames)
        fprintf(tf, "%d\t%.6f\t%llu\t%llu\t%s\t%llu\t%llu\n", f.index, f.pts,
                (unsigned long long)f.enqueue_ns, (unsigned long long)f.proof_ns,
                f.proof_ns ? src : "none", (unsigned long long)f.inferred_ns,
                (unsigned long long)f.proof2_ns);
      fclose(tf);
    }
  }

  // ---- JSON ----
  NSMutableString *j = [NSMutableString string];
  [j appendString:@"{\n"];
  [j appendFormat:@"  \"mode\": \"%s\",\n", g_mode.c_str()];
  [j appendFormat:@"  \"clip\": \"%s\",\n", g_clip.c_str()];
  [j appendFormat:@"  \"duration_requested_s\": %.3f,\n", g_duration];
  [j appendFormat:@"  \"duration_s\": %.3f,\n", playSeconds];
  [j appendFormat:@"  \"pixel_format\": \"%s\",\n", g_pixelFormatUsed.c_str()];
  [j appendFormat:@"  \"timing_mechanism\": \"%s\",\n", g_timingMechanism.c_str()];
  [j appendFormat:@"  \"frames_read\": %ld,\n", g_framesRead];
  [j appendFormat:@"  \"frames_enqueued\": %ld,\n", g_framesEnqueued];
  [j appendFormat:@"  \"frames_proven_displayed\": %ld,\n", provenDisplayed];
  [j appendFormat:@"  \"frames_expected\": %.1f,\n", expected];
  [j appendFormat:@"  \"effective_display_fps\": %.3f,\n", effectiveFps];
  [j appendFormat:@"  \"reader_loop_restarts\": %ld,\n", g_readerRestarts];
  [j appendFormat:@"  \"enqueue_limit\": %ld,\n", g_enqueueLimit];
  [j appendFormat:@"  \"occlusion_samples\": %d,\n", g_occlusionSamples];
  [j appendFormat:@"  \"occluded_samples\": %d,\n", g_occludedSamples];
  [j appendFormat:@"  \"occluded_samples_after_grace\": %d,\n", g_occludedAfterGrace];
  [j appendFormat:@"  \"not_ready_transitions\": %ld,\n", g_notReadyTransitions];
  [j appendFormat:@"  \"requires_flush_events\": %ld,\n", g_requiresFlushEvents];
  [j appendFormat:@"  \"failed_to_decode_events\": %ld,\n", g_failedToDecodeEvents];
  [j appendFormat:@"  \"dropped_no_drawable\": %ld,\n", g_droppedNoDrawable];
  [j appendFormat:@"  \"ready_for_display_seen\": %s,\n", g_readyForDisplaySeen ? "true" : "false"];
  [j appendFormat:@"  \"ready_for_display_after_first_enqueue_ms\": %.3f,\n",
       (g_readyForDisplaySeen && !g_frames.empty())
           ? ((double)((int64_t)g_readyForDisplay_ns - (int64_t)g_frames[0].enqueue_ns) / 1e6)
           : -1.0];
  [j appendFormat:@"  \"layer_status_final\": \"%s\",\n", g_layerStatusFinal.c_str()];
  [j appendFormat:@"  \"layer_error_final\": \"%s\",\n", g_layerErrorFinal.c_str()];
  [j appendFormat:@"  \"iosurface_note\": \"%s\",\n", g_iosurfaceNote.c_str()];
  [j appendFormat:@"  \"contents_ever_set\": %s,\n", g_contentsEverSet ? "true" : "false"];
  [j appendFormat:@"  \"vsync_samples\": %zu,\n", g_vsyncs.size()];
  [j appendFormat:@"  \"vsync_wall_span_s\": %.3f,\n", wallSpan];
  [j appendFormat:@"  \"vsync_timeline_span_s\": %.3f,\n", timelineSpan];
  [j appendFormat:@"  \"timeline_vs_wall_ratio\": %.5f,\n",
       wallSpan > 0 ? timelineSpan / wallSpan : 0.0];

  [j appendString:@"  \"proof_latency_vs_inferred_display_ms\": "];
  [j appendFormat:@"{\"n\": %zu, \"min\": %.3f, \"median\": %.3f, \"mean\": %.3f, "
                   "\"p95\": %.3f, \"max\": %.3f},\n",
       proofLatencyMs.size(), lo, med, mean, p95, hi];
  [j appendString:@"  \"proof_latency_vs_enqueue_ms\": "];
  [j appendFormat:@"{\"n\": %zu, \"min\": %.3f, \"median\": %.3f, \"mean\": %.3f, "
                   "\"p95\": %.3f, \"max\": %.3f},\n",
       proofVsEnqueueMs.size(), elo, emed, emean, ep95, ehi];

  [j appendString:@"  \"ack2_latency_vs_inferred_display_ms\": "];
  [j appendFormat:@"{\"n\": %zu, \"min\": %.3f, \"median\": %.3f, \"mean\": %.3f, "
                   "\"p95\": %.3f, \"max\": %.3f},\n",
       proof2LatencyMs.size(), blo, bmed, bmean, bp95, bhi];
  [j appendString:@"  \"ack2_minus_ack1_ms\": "];
  [j appendFormat:@"{\"n\": %zu, \"min\": %.3f, \"median\": %.3f, \"mean\": %.3f, "
                   "\"p95\": %.3f, \"max\": %.3f},\n",
       proof2VsProof1Ms.size(), clo, cmed, cmean, cp95, chi];

  [j appendFormat:@"  \"video_performance_metrics_samples\": %zu,\n", g_metrics.size()];
  [j appendString:@"  \"video_performance_metrics_first\": "];
  [j appendFormat:@"{\"elapsed_s\": %.3f, \"totalNumberOfFrames\": %ld, "
                   "\"numberOfDroppedFrames\": %ld, \"numberOfCorruptedFrames\": %ld, "
                   "\"numberOfFramesDisplayedUsingOptimizedCompositing\": %ld, "
                   "\"totalAccumulatedFrameDelay\": %.6f},\n",
       first.elapsed_s, first.total, first.dropped, first.corrupted, first.optimized,
       first.accumulated_delay];
  [j appendString:@"  \"video_performance_metrics_last\": "];
  [j appendFormat:@"{\"elapsed_s\": %.3f, \"totalNumberOfFrames\": %ld, "
                   "\"numberOfDroppedFrames\": %ld, \"numberOfCorruptedFrames\": %ld, "
                   "\"numberOfFramesDisplayedUsingOptimizedCompositing\": %ld, "
                   "\"totalAccumulatedFrameDelay\": %.6f},\n",
       last.elapsed_s, last.total, last.dropped, last.corrupted, last.optimized,
       last.accumulated_delay];
  [j appendFormat:@"  \"metrics_total_minus_dropped\": %ld,\n", last.total - last.dropped];
  [j appendFormat:@"  \"metrics_total_vs_enqueued_delta\": %ld,\n",
       last.total - g_framesEnqueued];

  // ---- (C) enqueue depth / surface-budget instrumentation ----
  std::vector<double> infl(g_inflightSamples.begin(), g_inflightSamples.end());
  double ilo, imed, ip95, ihi, imean;
  stats(infl, &ilo, &imed, &ip95, &ihi, &imean);
  [j appendFormat:@"  \"feed_discipline\": \"%s\",\n", g_feed.c_str()];
  [j appendFormat:@"  \"jit_lead_s\": %.3f,\n", g_jitLeadS];
  [j appendFormat:@"  \"consumed_notifications\": %ld,\n", g_consumedCount];
  [j appendFormat:@"  \"consumed_distinct_frames\": %ld,\n", g_consumedDistinct];
  [j appendFormat:@"  \"consumed_second_acks\": %ld,\n", g_consumedDuplicates];
  [j appendFormat:@"  \"consumed_third_or_more_acks\": %ld,\n", g_consumedBeyondTwo];
  [j appendFormat:@"  \"consumed_out_of_order\": %ld,\n", g_outOfOrderConsumed];
  [j appendFormat:@"  \"consumed_payload_mismatches\": %ld,\n", g_payloadMismatches];
  [j appendFormat:@"  \"first_fill_count\": %ld,\n", g_firstFillCount];
  [j appendString:@"  \"inflight_depth\": "];
  [j appendFormat:@"{\"n\": %zu, \"min\": %.1f, \"median\": %.1f, \"mean\": %.2f, "
                   "\"p95\": %.1f, \"max\": %.1f, \"observed_max\": %ld},\n",
       infl.size(), ilo, imed, imean, ip95, ihi, g_inflightMax];

  // ---- copyDisplayedPixelBuffer paused-attestation probes ----
  long probesNonNull = 0, probesIdentified = 0, probesCovering = 0, probesPlayingNonNull = 0;
  std::vector<double> probeDelays;
  for (auto &p : g_pausedProbes) {
    if (p.nonnull_after_ms >= 0) { probesNonNull++; probeDelays.push_back(p.nonnull_after_ms); }
    if (p.matched_index >= 0) probesIdentified++;
    if (p.covers) probesCovering++;
    if (p.nonnull_while_playing) probesPlayingNonNull++;
  }
  double plo, pmed, pp95, phi, pmean;
  stats(probeDelays, &plo, &pmed, &pp95, &phi, &pmean);
  [j appendFormat:@"  \"paused_probe_count\": %zu,\n", g_pausedProbes.size()];
  [j appendFormat:@"  \"paused_probe_nonnull\": %ld,\n", probesNonNull];
  [j appendFormat:@"  \"paused_probe_identified_frame\": %ld,\n", probesIdentified];
  [j appendFormat:@"  \"paused_probe_covers_position\": %ld,\n", probesCovering];
  [j appendFormat:@"  \"paused_probe_nonnull_while_playing\": %ld,\n", probesPlayingNonNull];
  [j appendString:@"  \"paused_probe_delay_ms\": "];
  [j appendFormat:@"{\"n\": %zu, \"min\": %.3f, \"median\": %.3f, \"mean\": %.3f, "
                   "\"p95\": %.3f, \"max\": %.3f},\n",
       probeDelays.size(), plo, pmed, pmean, pp95, phi];
  [j appendString:@"  \"paused_probes\": [\n"];
  for (size_t i = 0; i < g_pausedProbes.size(); i++) {
    PausedProbe &p = g_pausedProbes[i];
    [j appendFormat:@"    {\"pause_timeline_s\": %.4f, \"nonnull_after_ms\": %.3f, "
                     "\"polls\": %d, \"surface_id\": %u, \"matched_index\": %d, "
                     "\"matched_pts\": %.4f, \"matched_dur\": %.4f, \"candidates\": %d, "
                     "\"expected_index\": %d, \"expected_surface_id\": %u, "
                     "\"covers\": %s, \"nonnull_while_playing\": %s}%s\n",
         p.pause_timeline_s, p.nonnull_after_ms, p.polls, p.surface_id, p.matched_index,
         p.matched_pts, p.matched_dur, p.candidates, p.expected_index,
         p.expected_surface_id, p.covers ? "true" : "false",
         p.nonnull_while_playing ? "true" : "false",
         (i + 1 < g_pausedProbes.size()) ? "," : ""];
  }
  [j appendString:@"  ],\n"];

  // ---- BufferConsumed notifyingObject classes ----
  [j appendString:@"  \"consumed_notifier_classes\": {"];
  {
    bool first_n = true;
    for (auto &kv : g_notifiers) {
      [j appendFormat:@"%s\"%s\": %ld", first_n ? "" : ", ", kv.first.c_str(), kv.second];
      first_n = false;
    }
  }
  [j appendString:@"},\n"];

  // ---- optimized-compositing perturbation (translucent chrome overlay) ----
  [j appendFormat:@"  \"overlay_at_elapsed_s\": %.3f,\n", g_overlayAtElapsed];

  // ---- IOSurface use-count probe ----
  {
    std::vector<double> uc(g_useCountSamples.begin(), g_useCountSamples.end());
    double ulo, umed, up95, uhi, umean;
    stats(uc, &ulo, &umed, &up95, &uhi, &umean);
    [j appendFormat:@"  \"surface_probe_n\": %d,\n", g_surfaceProbe];
    [j appendString:@"  \"surface_use_count\": "];
    [j appendFormat:@"{\"n\": %zu, \"min\": %.1f, \"median\": %.1f, \"mean\": %.2f, \"max\": %.1f},\n",
         uc.size(), ulo, umed, umean, uhi];
  }

  // ---- (D) occlusion behaviour ----
  [j appendFormat:@"  \"occlusion_test_ran\": %s,\n", g_occlusionTestRan ? "true" : "false"];
  [j appendFormat:@"  \"enqueued_while_occluded\": %ld,\n", g_enqueuedWhileOccluded];
  [j appendFormat:@"  \"consumed_while_occluded\": %ld,\n", g_consumedWhileOccluded];

  // ---- flush / invalidation behaviour ----
  [j appendFormat:@"  \"flush_ran\": %s,\n", g_flushRan ? "true" : "false"];
  [j appendFormat:@"  \"inflight_at_flush\": %ld,\n", g_inflightAtFlush];
  [j appendFormat:@"  \"consumed_after_flush\": %ld,\n", g_consumedAfterFlush];

  // metrics time series (small)
  [j appendString:@"  \"metrics_series\": [\n"];
  for (size_t i = 0; i < g_metrics.size(); i++) {
    [j appendFormat:@"    {\"elapsed_s\": %.3f, \"total\": %ld, \"dropped\": %ld, "
                     "\"corrupted\": %ld, \"optimized\": %ld, \"delay\": %.6f}%s\n",
         g_metrics[i].elapsed_s, g_metrics[i].total, g_metrics[i].dropped,
         g_metrics[i].corrupted, g_metrics[i].optimized, g_metrics[i].accumulated_delay,
         (i + 1 < g_metrics.size()) ? "," : ""];
  }
  [j appendString:@"  ],\n"];

  [j appendString:@"  \"events\": [\n"];
  for (size_t i = 0; i < g_events.size() && i < 200; i++) {
    [j appendFormat:@"    {\"host_ns\": %llu, \"what\": \"%s\"}%s\n",
         (unsigned long long)g_events[i].host_ns, g_events[i].what.c_str(),
         (i + 1 < g_events.size() && i < 199) ? "," : ""];
  }
  [j appendString:@"  ],\n"];

  [j appendFormat:@"  \"occlusion_ok\": %s,\n", occOK ? "true" : "false"];
  [j appendFormat:@"  \"fps_sustained\": %s,\n", fpsOK ? "true" : "false"];
  [j appendFormat:@"  \"no_clip_wrap\": %s,\n", noWrap ? "true" : "false"];
  [j appendFormat:@"  \"valid\": %s\n", valid ? "true" : "false"];
  [j appendString:@"}\n"];

  pthread_mutex_unlock(&g_lock);

  if (!g_outPath.empty()) {
    NSError *e = nil;
    [j writeToFile:@(g_outPath.c_str()) atomically:YES
          encoding:NSUTF8StringEncoding error:&e];
  }
  fputs([j UTF8String], stdout);
  fflush(stdout);
}

// --------------------------------------------------------------- run

- (void)run {
  [self buildWindow];
  [self startOcclusionSampling];

  NSError *err = nil;
  BOOL ok = YES;
  if (g_mode == "asbdl-decoded" ||
      g_mode == "asbdl-pausedproof")      ok = [self setupASBDL:YES error:&err];
  else if (g_mode == "asbdl-compressed")  ok = [self setupASBDL:NO error:&err];
  else if (g_mode == "metal-blit")        ok = [self setupMetal:&err];
  else if (g_mode == "iosurface-contents")ok = [self setupIOSurface:&err];
  else if (g_mode == "idle-window")       { g_timingMechanism = "none (control)"; }
  else {
    fprintf(stderr, "unknown mode: %s\n", g_mode.c_str());
    exit(2);
  }
  if (!ok) {
    fprintf(stderr, "setup failed: %s\n", err.localizedDescription.UTF8String);
    exit(3);
  }

  [self startDisplayLink];
  if (self.renderer) [self startMetricsPolling];
  [self scheduleOcclusionExperiment];
  [self scheduleFlushExperiment];
  [self schedulePausedProbes];
  [self scheduleOverlayExperiment];

  g_t0_ns = now_ns();
  double total = g_duration + g_holdAfter;
  [NSTimer scheduledTimerWithTimeInterval:total repeats:NO block:^(NSTimer *t) {
    (void)t;
    [self finish];
  }];
}
@end

// --------------------------------------------------------------- main

static std::string argval(const char *arg, const char *key) {
  size_t klen = strlen(key);
  if (strncmp(arg, key, klen) == 0) return std::string(arg + klen);
  return std::string();
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    for (int i = 1; i < argc; i++) {
      std::string v;
      if (!(v = argval(argv[i], "--mode=")).empty()) g_mode = v;
      else if (!(v = argval(argv[i], "--clip=")).empty()) g_clip = v;
      else if (!(v = argval(argv[i], "--out=")).empty()) g_outPath = v;
      else if (!(v = argval(argv[i], "--proof-log=")).empty()) g_proofLogPath = v;
      else if (!(v = argval(argv[i], "--duration=")).empty()) g_duration = atof(v.c_str());
      else if (!(v = argval(argv[i], "--enqueue-limit=")).empty()) g_enqueueLimit = atol(v.c_str());
      else if (!(v = argval(argv[i], "--hold-after=")).empty()) g_holdAfter = atof(v.c_str());
      else if (!(v = argval(argv[i], "--feed=")).empty()) g_feed = v;
      else if (!(v = argval(argv[i], "--jit-lead=")).empty()) g_jitLeadS = atof(v.c_str());
      else if (!(v = argval(argv[i], "--occlude-after=")).empty()) g_occludeAfter = atof(v.c_str());
      else if (!(v = argval(argv[i], "--occlude-for=")).empty()) g_occludeFor = atof(v.c_str());
      else if (!(v = argval(argv[i], "--flush-at=")).empty()) g_flushAt = atof(v.c_str());
      else if (!(v = argval(argv[i], "--probes=")).empty()) g_probeCount = atoi(v.c_str());
      else if (!(v = argval(argv[i], "--overlay-at=")).empty()) g_overlayAt = atof(v.c_str());
      else if (!(v = argval(argv[i], "--surface-probe=")).empty()) g_surfaceProbe = atoi(v.c_str());
    }
    if (g_mode.empty()) { fprintf(stderr, "--mode required\n"); return 2; }
    if (g_clip.empty() && g_mode != "idle-window") {
      fprintf(stderr, "--clip required\n"); return 2;
    }

    g_frames.reserve(40000);
    g_vsyncs.reserve(80000);
    g_metrics.reserve(2000);

    NSApplication *app = [NSApplication sharedApplication];
    // Regular so the window composites like a real app window, but we never
    // call activateIgnoringOtherApps: -- no focus theft.
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    ProtoApp *p = [[ProtoApp alloc] init];
    dispatch_async(dispatch_get_main_queue(), ^{ [p run]; });
    [app run];
  }
  return 0;
}
