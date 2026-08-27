#include "metal_layer_presenter.hpp"
#include "native_video_color.hpp"

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include <CoreVideo/CoreVideo.h>
#include <dispatch/dispatch.h>
#include <simd/simd.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <exception>
#include <memory>
#include <mutex>
#include <new>
#include <stdexcept>
#include <string>
#include <utility>

namespace wam::macos {
namespace {

constexpr double kMaximumDrawablePixels = 1920.0 * 1080.0;

#if defined(WAM_METAL_LAYER_PRESENTER_TESTING)
std::atomic<MetalLayerPresenterFaultPoint> presenterFault{
    MetalLayerPresenterFaultPoint::None};

void throwIfPresenterFault(MetalLayerPresenterFaultPoint point) {
  MetalLayerPresenterFaultPoint expected = point;
  if (presenterFault.compare_exchange_strong(
          expected, MetalLayerPresenterFaultPoint::None,
          std::memory_order_acq_rel, std::memory_order_acquire)) {
    if (point ==
            MetalLayerPresenterFaultPoint::CompletionHandlerInstallation ||
        point == MetalLayerPresenterFaultPoint::CommandBufferCommit) {
      [NSException raise:NSInternalInconsistencyException
                  format:@"injected Metal presenter platform exception"];
    }
    throw std::runtime_error("injected Metal presenter exception");
  }
}
#endif

constexpr char kShaderSource[] = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct VertexOutput {
  float4 position [[position]];
  float2 uv;
};

vertex VertexOutput wam_vertex(uint vertexId [[vertex_id]],
                               constant float2& scale [[buffer(0)]]) {
  constexpr float2 positions[] = {
    float2(-1.0, -1.0), float2(1.0, -1.0),
    float2(-1.0,  1.0), float2(1.0,  1.0)
  };
  constexpr float2 coordinates[] = {
    float2(0.0, 1.0), float2(1.0, 1.0),
    float2(0.0, 0.0), float2(1.0, 0.0)
  };
  VertexOutput output;
  output.position = float4(positions[vertexId] * scale, 0.0, 1.0);
  output.uv = coordinates[vertexId];
  return output;
}

struct ColorParameters {
  float4 range; // y offset, y scale, chroma offset, chroma scale
  float4 siting; // normalized chroma-plane offset (x, y, 0, 0)
  float4 red;
  float4 green;
  float4 blue;
};

fragment float4 wam_yuv_fragment(
    VertexOutput input [[stage_in]],
    texture2d<float, access::sample> luma [[texture(0)]],
    texture2d<float, access::sample> chroma [[texture(1)]],
    constant ColorParameters& color [[buffer(0)]]) {
  constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge,
                                  filter::linear);
  const float y = (luma.sample(linearSampler, input.uv).r - color.range.x) *
                  color.range.y;
  const float2 uv =
      (chroma.sample(linearSampler, input.uv + color.siting.xy).rg -
       color.range.z) *
      color.range.w;
  const float3 yuv = float3(y, uv.x, uv.y);
  const float3 rgb = float3(dot(color.red.xyz, yuv),
                            dot(color.green.xyz, yuv),
                            dot(color.blue.xyz, yuv));
  return float4(saturate(rgb), 1.0);
}

fragment float4 wam_bgra_fragment(
    VertexOutput input [[stage_in]],
    texture2d<float, access::sample> image [[texture(0)]]) {
  constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge,
                                  filter::linear);
  return image.sample(linearSampler, input.uv);
}
)METAL";

struct ColorParameters {
  simd_float4 range;
  simd_float4 siting;
  simd_float4 red;
  simd_float4 green;
  simd_float4 blue;
};

void assignError(std::string* error, std::string message) {
#if defined(WAM_METAL_LAYER_PRESENTER_TESTING)
  throwIfPresenterFault(MetalLayerPresenterFaultPoint::ErrorAssignment);
#endif
  if (error != nullptr) {
    *error = std::move(message);
  }
}

void assignFixedErrorNoexcept(std::string* error, const char* message) noexcept {
  if (error == nullptr) {
    return;
  }
  try {
    error->assign(message);
  } catch (...) {
    // Returning Failed is authoritative. An allocator failure may prevent the
    // optional diagnostic string from being replaced, but may never escape the
    // presentation queue or strand an in-flight reservation.
  }
}

ColorParameters colorParameters(CVPixelBufferRef pixelBuffer) {
  const OSType format = CVPixelBufferGetPixelFormatType(pixelBuffer);
  const bool fullRange =
      format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
      format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
  const bool tenBit =
      format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
      format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;

  ColorParameters result{};
  if (fullRange) {
    if (tenBit) {
      result.range = {0.0F, 65535.0F / (1023.0F * 64.0F),
                      (512.0F * 64.0F) / 65535.0F,
                      65535.0F / (1023.0F * 64.0F)};
    } else {
      result.range = {0.0F, 1.0F, 128.0F / 255.0F, 1.0F};
    }
  } else if (tenBit) {
    result.range = {(64.0F * 64.0F) / 65535.0F,
                    65535.0F / (876.0F * 64.0F),
                    (512.0F * 64.0F) / 65535.0F,
                    65535.0F / (896.0F * 64.0F)};
  } else {
    result.range = {16.0F / 255.0F, 255.0F / 219.0F,
                    128.0F / 255.0F, 255.0F / 224.0F};
  }

  CFTypeRef chromaLocation = CVBufferCopyAttachment(
      pixelBuffer, kCVImageBufferChromaLocationTopFieldKey, nullptr);
  const bool centered =
      chromaLocation != nullptr &&
      CFEqual(chromaLocation, kCVImageBufferChromaLocation_Center);
  if (chromaLocation != nullptr) {
    CFRelease(chromaLocation);
  }
  // Center-sited chroma maps directly through normalized coordinates. Left-
  // sited (and absent, by conventional H.264/HEVC video default) chroma is
  // co-sited with the left luma column and needs a half-luma-pixel shift.
  result.siting = centered
                      ? simd_float4{0.0F, 0.0F, 0.0F, 0.0F}
                      : simd_float4{
                            0.5F / static_cast<float>(
                                       CVPixelBufferGetWidth(pixelBuffer)),
                            0.0F, 0.0F, 0.0F};

  // One shared definition with qt_gl_video_item.mm and qt_metal_video_item.mm
  // -- see native_video_color.hpp. This presenter is the one that already had
  // a BT.2020 branch while the two Qt items rejected BT.2020 outright; that
  // divergence is what the shared header exists to end. An unrecognized
  // explicit matrix keeps this path's historical behaviour of falling back to
  // the SD/HD inference rather than failing the frame.
  YCbCrMatrixKind matrixKind = YCbCrMatrixKind::Bt709;
  if (!ycbcrMatrixForPixelBuffer(pixelBuffer, &matrixKind)) {
    matrixKind = (CVPixelBufferGetWidth(pixelBuffer) <= 1024 &&
                  CVPixelBufferGetHeight(pixelBuffer) <= 576)
                     ? YCbCrMatrixKind::Bt601
                     : YCbCrMatrixKind::Bt709;
  }
  const YCbCrMatrixRows rows = ycbcrMatrixRows(matrixKind);
  result.red = {rows.red[0], rows.red[1], rows.red[2], 0.0F};
  result.green = {rows.green[0], rows.green[1], rows.green[2], 0.0F};
  result.blue = {rows.blue[0], rows.blue[1], rows.blue[2], 0.0F};
  return result;
}

simd_float2 aspectScale(const FrameLease& frame, CGSize drawableSize) {
  if (frame.width() == 0 || frame.height() == 0 || drawableSize.width <= 0.0 ||
      drawableSize.height <= 0.0) {
    return {1.0F, 1.0F};
  }
  const double sourceAspect =
      static_cast<double>(frame.width()) / static_cast<double>(frame.height());
  const double destinationAspect = drawableSize.width / drawableSize.height;
  if (sourceAspect > destinationAspect) {
    return {1.0F, static_cast<float>(destinationAspect / sourceAspect)};
  }
  return {static_cast<float>(sourceAspect / destinationAspect), 1.0F};
}

CGSize boundedDrawableSize(CGSize pointSize, CGFloat backingScale) noexcept {
  double width = std::max(0.0, pointSize.width) *
                 std::max<CGFloat>(1.0, backingScale);
  double height = std::max(0.0, pointSize.height) *
                  std::max<CGFloat>(1.0, backingScale);
  const double pixels = width * height;
  if (pixels > kMaximumDrawablePixels) {
    const double reduction = std::sqrt(kMaximumDrawablePixels / pixels);
    width *= reduction;
    height *= reduction;
  }
  return CGSizeMake(width, height);
}

struct PresenterCompletionState {
  PresenterCompletionState() {
#if defined(WAM_METAL_LAYER_PRESENTER_TESTING)
    throwIfPresenterFault(
        MetalLayerPresenterFaultPoint::CompletionGroupAllocation);
#endif
    group = dispatch_group_create();
    if (group == nil) {
      throw std::bad_alloc();
    }
  }

  __strong dispatch_group_t group{nil};
  mutable std::mutex mutex;
  MetalLayerPresenterStats statistics;
  std::weak_ptr<void> failureLifetime;
  MetalLayerPresenter::FailureHandler failureHandler;
};

// Reserves one of the presenter's two bounded in-flight slots. Until ownership
// is transferred to a CompletionTicket, every return and exception path is
// unwound by this guard without allocating or waiting for the render thread.
class InFlightReservation final {
 public:
  explicit InFlightReservation(
      std::shared_ptr<PresenterCompletionState> completion) noexcept
      : completion_(std::move(completion)) {}

  InFlightReservation(const InFlightReservation&) = delete;
  InFlightReservation& operator=(const InFlightReservation&) = delete;

  ~InFlightReservation() { release(); }

  void activate() noexcept { active_ = true; }
  void transfer() noexcept { active_ = false; }

 private:
  void release() noexcept {
    if (!active_) {
      return;
    }
    active_ = false;
    try {
      std::lock_guard lock(completion_->mutex);
      if (completion_->statistics.inFlightFrames > 0) {
        --completion_->statistics.inFlightFrames;
      }
    } catch (...) {
      // std::mutex operations on a live, non-recursive mutex do not normally
      // fail. Keep the destructor non-throwing if the platform reports one.
    }
  }

  std::shared_ptr<PresenterCompletionState> completion_;
  bool active_{false};
};

// One shared ticket bridges the synchronous encoder and Metal's asynchronous
// completion block. It owns exactly one dispatch-group enter and, once claimed,
// exactly one in-flight reservation. A pre-commit throw, a normal GPU callback,
// or destruction of an uncommitted command buffer can race to finish it; only
// the first path updates accounting and leaves the group.
class PresenterCompletionTicket final {
 public:
  explicit PresenterCompletionTicket(
      std::shared_ptr<PresenterCompletionState> completion) noexcept
      : completion_(std::move(completion)) {
    dispatch_group_enter(completion_->group);
  }

  PresenterCompletionTicket(const PresenterCompletionTicket&) = delete;
  PresenterCompletionTicket& operator=(const PresenterCompletionTicket&) =
      delete;

  ~PresenterCompletionTicket() { finish(false); }

  void claimReservation() noexcept {
    ownsReservation_.store(true, std::memory_order_release);
  }

  void markSubmitted() {
    std::lock_guard lock(completion_->mutex);
    ++completion_->statistics.submittedFrames;
    submitted_.store(true, std::memory_order_release);
  }

  void finish(bool succeeded) noexcept {
    bool expected = false;
    if (!finished_.compare_exchange_strong(
            expected, true, std::memory_order_acq_rel,
            std::memory_order_acquire)) {
      return;
    }

    try {
      std::lock_guard lock(completion_->mutex);
      if (ownsReservation_.load(std::memory_order_acquire) &&
          completion_->statistics.inFlightFrames > 0) {
        --completion_->statistics.inFlightFrames;
      }
      if (submitted_.load(std::memory_order_acquire)) {
        if (succeeded) {
          ++completion_->statistics.completedFrames;
        } else {
          ++completion_->statistics.failedFrames;
        }
      }
    } catch (...) {
      // Always balance the dispatch group below. The completion-state mutex is
      // live for the ticket's entire lifetime and should not fail in practice.
    }
    dispatch_group_leave(completion_->group);
  }

 private:
  std::shared_ptr<PresenterCompletionState> completion_;
  std::atomic<bool> ownsReservation_{false};
  std::atomic<bool> submitted_{false};
  std::atomic<bool> finished_{false};
};

class PresenterCompletionAbortGuard final {
 public:
  explicit PresenterCompletionAbortGuard(
      std::shared_ptr<PresenterCompletionTicket> ticket) noexcept
      : ticket_(std::move(ticket)) {}

  PresenterCompletionAbortGuard(const PresenterCompletionAbortGuard&) =
      delete;
  PresenterCompletionAbortGuard& operator=(
      const PresenterCompletionAbortGuard&) = delete;

  ~PresenterCompletionAbortGuard() {
    if (ticket_) {
      ticket_->finish(false);
    }
  }

  void transferToCommittedBuffer() noexcept { ticket_.reset(); }

 private:
  std::shared_ptr<PresenterCompletionTicket> ticket_;
};

std::string commandBufferFailure(id<MTLCommandBuffer> commandBuffer) {
  std::string message = "Metal command buffer failed with status " +
                        std::to_string(commandBuffer.status);
  NSError* commandError = commandBuffer.error;
  if (commandError != nil && commandError.localizedDescription != nil) {
    const char* description = commandError.localizedDescription.UTF8String;
    if (description != nullptr) {
      message += ": ";
      message += description;
    }
  }
  return message;
}

void removeLayerWithoutBlocking(CAMetalLayer* layer) noexcept {
  if (layer == nil) {
    return;
  }
  void (^removeLayer)(void) = ^{
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.hidden = YES;
    if (layer.superlayer != nil) {
      [layer removeFromSuperlayer];
    }
    [CATransaction commit];
  };
  if ([NSThread isMainThread]) {
    removeLayer();
  } else {
    // Destruction is allowed off-main. Retaining the layer in this block makes
    // teardown safe without synchronously waiting on AppKit's main thread.
    dispatch_async(dispatch_get_main_queue(), removeLayer);
  }
}

}  // namespace

struct MetalLayerPresenter::Impl {
  __strong id<MTLDevice> device{nil};
  __strong id<MTLCommandQueue> commandQueue{nil};
  __strong id<MTLRenderPipelineState> yuvPipeline{nil};
  __strong id<MTLRenderPipelineState> bgraPipeline{nil};
  __strong CAMetalLayer* layer{nil};
  __weak NSView* hostView{nil};
  std::unique_ptr<MetalTextureCache> textureCache;
  std::shared_ptr<PresenterCompletionState> completion{
      std::make_shared<PresenterCompletionState>()};
  mutable std::mutex layerMutex;
  std::uint64_t layerGeneration{0};
  bool attached{false};
  bool visible{false};

  ~Impl() {
    {
      std::lock_guard lock(completion->mutex);
      completion->failureLifetime.reset();
      completion->failureHandler = {};
    }
    CAMetalLayer* layerToRemove = nil;
    {
      std::lock_guard lock(layerMutex);
      attached = false;
      visible = false;
      hostView = nil;
      ++layerGeneration;
      layerToRemove = layer;
      layer = nil;
    }
    removeLayerWithoutBlocking(layerToRemove);

    // Never stall AppKit teardown. Away from the main thread, allow a short
    // grace period for normal GPU completion; a wedged command buffer cannot
    // make teardown unbounded. Completion blocks own their leases/accounting
    // state and remain safe after this object is gone if the grace period ends.
    if (![NSThread isMainThread]) {
      (void)dispatch_group_wait(
          completion->group,
          dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC));
    }
  }
};

MetalLayerPresenter::MetalLayerPresenter(std::unique_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}

MetalLayerPresenter::~MetalLayerPresenter() = default;

std::unique_ptr<MetalLayerPresenter> MetalLayerPresenter::create(
    std::string* error) {
  if (error != nullptr) {
    error->clear();
  }
  std::unique_ptr<Impl> impl;
  try {
    impl = std::make_unique<Impl>();
  } catch (...) {
    assignFixedErrorNoexcept(
        error, "Metal presenter completion-state creation failed");
    return nullptr;
  }
  impl->device = MTLCreateSystemDefaultDevice();
  if (impl->device == nil) {
    assignError(error, "Metal is unavailable on this Mac");
    return nullptr;
  }
  impl->commandQueue = [impl->device newCommandQueue];
  if (impl->commandQueue == nil) {
    assignError(error, "Metal command queue creation failed");
    return nullptr;
  }

  NSError* libraryError = nil;
  NSString* source = [NSString stringWithUTF8String:kShaderSource];
  id<MTLLibrary> library =
      [impl->device newLibraryWithSource:source options:nil error:&libraryError];
  if (library == nil) {
    assignError(error,
                libraryError == nil
                    ? "Metal shader compilation failed"
                    : std::string(libraryError.localizedDescription.UTF8String));
    return nullptr;
  }

  id<MTLFunction> vertex = [library newFunctionWithName:@"wam_vertex"];
  id<MTLFunction> yuvFragment =
      [library newFunctionWithName:@"wam_yuv_fragment"];
  id<MTLFunction> bgraFragment =
      [library newFunctionWithName:@"wam_bgra_fragment"];
  if (vertex == nil || yuvFragment == nil || bgraFragment == nil) {
    assignError(error, "Metal shader entry points are unavailable");
    return nullptr;
  }

  const auto makePipeline = [&](id<MTLFunction> fragment) {
    MTLRenderPipelineDescriptor* descriptor =
        [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = vertex;
    descriptor.fragmentFunction = fragment;
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    NSError* pipelineError = nil;
    id<MTLRenderPipelineState> output =
        [impl->device newRenderPipelineStateWithDescriptor:descriptor
                                                     error:&pipelineError];
    if (output == nil) {
      assignError(error,
                  pipelineError == nil
                      ? "Metal render pipeline creation failed"
                      : std::string(
                            pipelineError.localizedDescription.UTF8String));
      return output;
    }
    return output;
  };
  impl->yuvPipeline = makePipeline(yuvFragment);
  if (impl->yuvPipeline == nil) {
    return nullptr;
  }
  impl->bgraPipeline = makePipeline(bgraFragment);
  if (impl->bgraPipeline == nil) {
    return nullptr;
  }

  impl->textureCache = MetalTextureCache::create(
      (__bridge void*)impl->device, error);
  if (!impl->textureCache) {
    return nullptr;
  }
  return std::unique_ptr<MetalLayerPresenter>(
      new MetalLayerPresenter(std::move(impl)));
}

bool MetalLayerPresenter::attachToView(void* nativeView, std::string* error) {
  if (error != nullptr) {
    error->clear();
  }
  if (![NSThread isMainThread]) {
    assignError(error, "Metal layer attachment must run on the main thread");
    return false;
  }
  NSView* view = (__bridge NSView*)nativeView;
  if (view == nil) {
    assignError(error, "native video host view is unavailable");
    return false;
  }

  CAMetalLayer* retiredLayer = nil;
  std::lock_guard lock(impl_->layerMutex);
  retiredLayer = impl_->layer;
  ++impl_->layerGeneration;
  // Never reuse a detached layer. An already encoded command buffer may still
  // target the retired layer, but it can never present into a later host
  // generation after detach/reattach.
  impl_->layer = [CAMetalLayer layer];
  impl_->layer.device = impl_->device;
  impl_->layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
  impl_->layer.framebufferOnly = YES;
  impl_->layer.opaque = YES;
  impl_->layer.presentsWithTransaction = NO;
  impl_->layer.allowsNextDrawableTimeout = YES;
  impl_->layer.maximumDrawableCount = 2;
  impl_->layer.autoresizingMask =
      kCALayerWidthSizable | kCALayerHeightSizable;
  CGColorSpaceRef colorSpace =
      CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
  impl_->layer.colorspace = colorSpace;
  if (colorSpace != nullptr) {
    CGColorSpaceRelease(colorSpace);
  }
  if (retiredLayer.superlayer != nil) {
    [retiredLayer removeFromSuperlayer];
  }
  view.wantsLayer = YES;
  impl_->hostView = view;
  impl_->attached = true;
  impl_->layer.frame = view.bounds;
  impl_->layer.contentsScale =
      std::max<CGFloat>(1.0, view.window.backingScaleFactor);
  impl_->layer.drawableSize = boundedDrawableSize(
      view.bounds.size, impl_->layer.contentsScale);
  impl_->layer.hidden = impl_->visible ? NO : YES;
  [view.layer insertSublayer:impl_->layer atIndex:0];
  return true;
}

void MetalLayerPresenter::detach() noexcept {
  CAMetalLayer* layer = nil;
  {
    std::lock_guard lock(impl_->layerMutex);
    impl_->attached = false;
    impl_->visible = false;
    impl_->hostView = nil;
    ++impl_->layerGeneration;
    layer = impl_->layer;
    impl_->layer = nil;
  }
  removeLayerWithoutBlocking(layer);
}

void MetalLayerPresenter::resize(double widthPoints, double heightPoints,
                                 double backingScale) noexcept {
  CAMetalLayer* layer = nil;
  {
    std::lock_guard lock(impl_->layerMutex);
    layer = impl_->layer;
  }
  if (layer == nil) {
    return;
  }
  const CGFloat width = std::max(0.0, widthPoints);
  const CGFloat height = std::max(0.0, heightPoints);
  const CGFloat scale = std::max(1.0, backingScale);
  void (^resizeLayer)(void) = ^{
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.frame = CGRectMake(0.0, 0.0, width, height);
    layer.contentsScale = scale;
    layer.drawableSize = boundedDrawableSize(CGSizeMake(width, height), scale);
    [CATransaction commit];
  };
  if ([NSThread isMainThread]) {
    resizeLayer();
  } else {
    dispatch_async(dispatch_get_main_queue(), resizeLayer);
  }
}

void MetalLayerPresenter::setVisible(bool visible) noexcept {
  CAMetalLayer* layer = nil;
  {
    std::lock_guard lock(impl_->layerMutex);
    impl_->visible = visible;
    layer = impl_->layer;
  }
  if (layer == nil) {
    return;
  }
  void (^updateVisibility)(void) = ^{
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.hidden = visible ? NO : YES;
    [CATransaction commit];
  };
  if ([NSThread isMainThread]) {
    updateVisibility();
  } else {
    dispatch_async(dispatch_get_main_queue(), updateVisibility);
  }
}

void MetalLayerPresenter::setFailureHandler(
    std::weak_ptr<void> lifetime, FailureHandler handler) noexcept {
  std::lock_guard lock(impl_->completion->mutex);
  impl_->completion->failureLifetime = std::move(lifetime);
  impl_->completion->failureHandler = std::move(handler);
}

MetalPresentResult MetalLayerPresenter::present(const FrameLease& frame,
                                                std::string* error) noexcept {
  @try {
    try {
      if (error != nullptr) {
        error->clear();
      }
      if (!frame || !frame.isIOSurfaceBacked()) {
        assignError(error, "presenter requires an IOSurface-backed frame");
        return MetalPresentResult::Failed;
      }

      CAMetalLayer* layer = nil;
      CGSize drawableSize = CGSizeZero;
      std::uint64_t layerGeneration = 0;
      {
        std::lock_guard layerLock(impl_->layerMutex);
        if (impl_->layer == nil || !impl_->attached || !impl_->visible) {
          assignError(error, "Metal presentation layer is not visible");
          return MetalPresentResult::DrawableUnavailable;
        }
        // Retain a stable layer snapshot, then release the layer-state lock
        // before nextDrawable/encoding. Main-thread resize and detach must
        // never wait on CAMetalLayer drawable backpressure.
        layer = impl_->layer;
        drawableSize = layer.drawableSize;
        layerGeneration = impl_->layerGeneration;
      }

      const std::shared_ptr<PresenterCompletionState> completion =
          impl_->completion;
      InFlightReservation reservation(completion);
      {
        std::lock_guard completionLock(completion->mutex);
        if (completion->statistics.inFlightFrames >= 2) {
          assignError(error, "Metal presenter in-flight limit reached");
          return MetalPresentResult::Backpressure;
        }
        ++completion->statistics.inFlightFrames;
        reservation.activate();
      }

#if defined(WAM_METAL_LAYER_PRESENTER_TESTING)
      throwIfPresenterFault(MetalLayerPresenterFaultPoint::TextureImport);
#endif
      auto imported = impl_->textureCache->importFrame(frame, error);
      if (!imported) {
        return MetalPresentResult::Failed;
      }
#if defined(WAM_METAL_LAYER_PRESENTER_TESTING)
      throwIfPresenterFault(
          MetalLayerPresenterFaultPoint::FrameLeaseAllocation);
#endif
      auto frameTextures =
          std::make_shared<MetalFrameLease>(std::move(*imported));
      const bool yuv = frameTextures->planeCount() == 2;
      if (!yuv && frameTextures->planeCount() != 1) {
        assignError(error,
                    "Metal presenter received an unsupported plane count");
        return MetalPresentResult::Failed;
      }

      id<CAMetalDrawable> drawable = [layer nextDrawable];
      if (drawable == nil) {
        assignError(error, "CAMetalLayer did not provide a drawable");
        return MetalPresentResult::DrawableUnavailable;
      }
      id<MTLCommandBuffer> commandBuffer = [impl_->commandQueue commandBuffer];
      if (commandBuffer == nil) {
        assignError(error, "Metal command buffer creation failed");
        return MetalPresentResult::Failed;
      }

      MTLRenderPassDescriptor* pass =
          [MTLRenderPassDescriptor renderPassDescriptor];
      pass.colorAttachments[0].texture = drawable.texture;
      pass.colorAttachments[0].loadAction = MTLLoadActionClear;
      pass.colorAttachments[0].storeAction = MTLStoreActionStore;
      pass.colorAttachments[0].clearColor =
          MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
      id<MTLRenderCommandEncoder> encoder =
          [commandBuffer renderCommandEncoderWithDescriptor:pass];
      if (encoder == nil) {
        assignError(error, "Metal render encoder creation failed");
        return MetalPresentResult::Failed;
      }

      const simd_float2 scale = aspectScale(frame, drawableSize);
      [encoder setVertexBytes:&scale length:sizeof(scale) atIndex:0];
      if (yuv) {
        [encoder setRenderPipelineState:impl_->yuvPipeline];
        [encoder setFragmentTexture:(__bridge id<MTLTexture>)
                                        frameTextures->nativeTexture(0)
                            atIndex:0];
        [encoder setFragmentTexture:(__bridge id<MTLTexture>)
                                        frameTextures->nativeTexture(1)
                            atIndex:1];
        const ColorParameters color = colorParameters(frame.pixelBuffer());
        [encoder setFragmentBytes:&color length:sizeof(color) atIndex:0];
      } else {
        [encoder setRenderPipelineState:impl_->bgraPipeline];
        [encoder setFragmentTexture:(__bridge id<MTLTexture>)
                                        frameTextures->nativeTexture(0)
                            atIndex:0];
      }
      [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                  vertexStart:0
                  vertexCount:4];
      [encoder endEncoding];

      {
        std::lock_guard layerLock(impl_->layerMutex);
        if (!impl_->attached || !impl_->visible || impl_->layer != layer ||
            impl_->layerGeneration != layerGeneration) {
          assignError(error,
                      "Metal presentation layer changed during encoding");
          return MetalPresentResult::DrawableUnavailable;
        }
        // Scheduling presentation while the generation is validated prevents
        // detach from winning between validation and presentDrawable. Encoding,
        // drawable acquisition, commit, and GPU work stay outside this lock.
        [commandBuffer presentDrawable:drawable];
      }

      FailureHandler failureHandler;
      std::weak_ptr<void> failureLifetime;
#if defined(WAM_METAL_LAYER_PRESENTER_TESTING)
      throwIfPresenterFault(
          MetalLayerPresenterFaultPoint::FailureHandlerCopy);
#endif
      {
        std::lock_guard completionLock(completion->mutex);
        failureLifetime = completion->failureLifetime;
        failureHandler = completion->failureHandler;
      }

#if defined(WAM_METAL_LAYER_PRESENTER_TESTING)
      throwIfPresenterFault(
          MetalLayerPresenterFaultPoint::CompletionTicketAllocation);
#endif
      auto completionTicket =
          std::make_shared<PresenterCompletionTicket>(completion);
      completionTicket->claimReservation();
      reservation.transfer();
      PresenterCompletionAbortGuard abortGuard(completionTicket);

#if defined(WAM_METAL_LAYER_PRESENTER_TESTING)
      throwIfPresenterFault(
          MetalLayerPresenterFaultPoint::CompletionHandlerInstallation);
#endif
      [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        // Capturing the shared lease keeps the IOSurface and both Metal plane
        // views alive until the GPU has consumed the command buffer.
        (void)frameTextures;
        bool succeeded = false;
        @try {
          succeeded = completed.status == MTLCommandBufferStatusCompleted;
        } @catch (NSException*) {
          succeeded = false;
        }
        completionTicket->finish(succeeded);
        if (!succeeded && failureHandler) {
          // Promotion is the revocation/drain contract: the token owns every
          // handler capture and remains held throughout the invocation.
          if (auto lifetime = failureLifetime.lock()) {
            try {
              @try {
                failureHandler(commandBufferFailure(completed));
              } @catch (NSException*) {
                // Client error reporting must not escape Metal's callback.
              }
            } catch (...) {
              // Client error reporting must not escape Metal's callback.
            }
          }
        }
      }];
      completionTicket->markSubmitted();
#if defined(WAM_METAL_LAYER_PRESENTER_TESTING)
      throwIfPresenterFault(
          MetalLayerPresenterFaultPoint::CommandBufferCommit);
#endif
      [commandBuffer commit];
      abortGuard.transferToCommittedBuffer();
      return MetalPresentResult::Presented;
    } catch (...) {
      assignFixedErrorNoexcept(
          error, "Metal presenter rejected a frame after an internal failure");
      return MetalPresentResult::Failed;
    }
  } @catch (NSException*) {
    assignFixedErrorNoexcept(
        error, "Metal presenter rejected a frame after a platform failure");
    return MetalPresentResult::Failed;
  }
}

MetalLayerPresenterStats MetalLayerPresenter::stats() const noexcept {
  std::lock_guard lock(impl_->completion->mutex);
  return impl_->completion->statistics;
}

#if defined(WAM_METAL_LAYER_PRESENTER_TESTING)
void MetalLayerPresenterTestAccess::failNext(
    MetalLayerPresenterFaultPoint point) noexcept {
  presenterFault.store(point, std::memory_order_release);
}

bool MetalLayerPresenterTestAccess::faultPending() noexcept {
  return presenterFault.load(std::memory_order_acquire) !=
         MetalLayerPresenterFaultPoint::None;
}

MetalLayerPresenterTestAccess::FaultOutcome
MetalLayerPresenterTestAccess::exerciseAccountingFault(
    MetalLayerPresenterFaultPoint point) noexcept {
  FaultOutcome outcome;
  presenterFault.store(point, std::memory_order_release);
  std::shared_ptr<PresenterCompletionState> completion;
  @try {
    try {
      completion = std::make_shared<PresenterCompletionState>();
      InFlightReservation reservation(completion);
      {
        std::lock_guard lock(completion->mutex);
        ++completion->statistics.inFlightFrames;
        reservation.activate();
      }
      if (point == MetalLayerPresenterFaultPoint::ErrorAssignment) {
        std::string diagnostic;
        assignError(&diagnostic, "unused");
      }
      throwIfPresenterFault(MetalLayerPresenterFaultPoint::TextureImport);
      throwIfPresenterFault(
          MetalLayerPresenterFaultPoint::FrameLeaseAllocation);
      throwIfPresenterFault(MetalLayerPresenterFaultPoint::FailureHandlerCopy);
      throwIfPresenterFault(
          MetalLayerPresenterFaultPoint::CompletionTicketAllocation);

      auto ticket = std::make_shared<PresenterCompletionTicket>(completion);
      ticket->claimReservation();
      reservation.transfer();
      PresenterCompletionAbortGuard abortGuard(ticket);
      throwIfPresenterFault(
          MetalLayerPresenterFaultPoint::CompletionHandlerInstallation);
      ticket->markSubmitted();
      throwIfPresenterFault(
          MetalLayerPresenterFaultPoint::CommandBufferCommit);
      abortGuard.transferToCommittedBuffer();
    } catch (...) {
      outcome.exceptionCaught = true;
    }
  } @catch (NSException*) {
    outcome.exceptionCaught = true;
  }

  // A point that did not throw is a malformed test request. Never leave the
  // synthetic committed ticket pending in that case; only known fault points
  // are accepted by the focused test.
  if (completion) {
    {
      std::lock_guard lock(completion->mutex);
      outcome.statistics = completion->statistics;
    }
    outcome.groupIdle =
        dispatch_group_wait(completion->group, DISPATCH_TIME_NOW) == 0;
  } else {
    outcome.groupIdle = true;
  }
  return outcome;
}

bool MetalLayerPresenterTestAccess::completionGroupIdle(
    const MetalLayerPresenter& presenter) noexcept {
  return dispatch_group_wait(presenter.impl_->completion->group,
                             DISPATCH_TIME_NOW) == 0;
}
#endif

}  // namespace wam::macos
