#import "include/WAMKit/WAMKitObjC.h"
#include "platform/macos/native_playback_owner.hpp"
#include "platform/macos/native_open_preflight.hpp"
#include "platform/macos/native_layer_host_view.hpp"
#include "platform/macos/native_layer_video_output.hpp"
#include "platform/macos/native_audio_test_mute.hpp"
#include "platform/macos/native_embedding_support.hpp"
#include "platform/macos/native_surface_budget.hpp"
#include <array>
#include <cassert>
#include <cmath>
#include <cstring>
#include <limits>

using namespace wam::macos;
namespace media = wam::media;
namespace protocol = media::native_playback;
namespace router = media::playback_router;

@interface WAMPresentationView ()
- (instancetype)initPrivate;
@end
@implementation WAMPresentationView
- (instancetype)initPrivate { return [super initWithFrame:NSMakeRect(0,0,480,270)]; }
@end

namespace {
constexpr const char* names[] = {"None", "UnsupportedSourceScheme", "SourceAccessDenied",
 "UnsupportedContainer", "DecoderStageNotBuilt", "DecoderUnavailable", "PresentationRequiresMacOS14",
 "PresentationUnavailable", "InvalidTime", "TimeOverflow", "SeekOutOfRange", "SeekStalled",
 "RateUnsupported", "InvalidVolume", "SessionBudgetExceeded", "RetirementCapacityUnavailable",
 "AudioOutputUnavailable", "InternalProtocolViolation", "HeAacSbrDecoderDelayUnproven"};
wam_time_t timeValue(media::MediaTime value) { return {value.value,value.timescale,0}; }
media::MediaTime timeValue(wam_time_t value) { return {value.value,value.timescale}; }
wam_error_t errorValue(const char* name, const char* detail = "") {
  wam_error_t result{}; result.struct_size = sizeof(result); result.code = WAM_REASON_NATIVE_DETAIL;
  for (unsigned i=0;i<std::size(names);++i) if (!std::strcmp(names[i],name)) result.code=i;
  std::snprintf(result.name,sizeof(result.name),"%s",name);
  std::snprintf(result.detail,sizeof(result.detail),"%s",detail);
  const auto symbolic=[](const char* start,std::size_t length){
    if(!length || length>=128 || start[0]<'A' || start[0]>'Z')return false;
    for(std::size_t i=0;i<length;++i)if(!((start[i]>='A'&&start[i]<='Z')||(start[i]>='a'&&start[i]<='z')||(start[i]>='0'&&start[i]<='9')||start[i]=='_'))return false;
    return true;
  };
  for(const char* colon=std::strchr(detail,':');colon && result.related_count<8;colon=std::strchr(colon+1,':')){
    const char* begin=colon;while(begin>detail && begin[-1]!=' ' && begin[-1]!=';' && begin[-1]!=':')--begin;
    const auto length=static_cast<std::size_t>(colon-begin);
    if(symbolic(begin,length) && !(std::strlen(name)==length && !std::memcmp(begin,name,length))){
      bool duplicate=false;for(unsigned i=0;i<result.related_count;++i)if(std::strlen(result.related_names[i])==length && !std::memcmp(begin,result.related_names[i],length))duplicate=true;
      if(!duplicate)std::memcpy(result.related_names[result.related_count++],begin,length);
    }
  }
  return result;
}
enum class Operation { Open, Pause, Seek, Volume, Mute, Rate, Stop, Close };
struct Command {
  Operation operation{}; std::uint64_t id{0}; wam_time_t time{};
  float gain{1}; std::uint32_t value{0}, flag{0}; std::array<char,4096> path{};
};
class Engine final : public NativePlaybackOwner, public std::enable_shared_from_this<Engine> {
public:
  WAMPresentationView* __strong view;
  std::shared_ptr<NativeLayerHostView> layer;
  wam_event_callback_t callback{nullptr}; void* context{nullptr};
  wam_snapshot_t snapshot{};
  bool closed{false}, disposed{false}, metricsEnabled{false};
  unsigned outstanding{0};
  std::uint64_t nextRequest{0};
  Engine() {
#if defined(WAMKIT_ENABLE_TEST_SUPPORT)
    const auto hex=[](const char* value,std::size_t count){if(!value||std::strlen(value)!=count)return false;for(std::size_t i=0;i<count;++i)if(!((value[i]>='0'&&value[i]<='9')||(value[i]>='a'&&value[i]<='f')))return false;return true;};
    const char* run=std::getenv("WAM_NATIVE_BENCHMARK_RUN_ID");
    const char* enabled=std::getenv("WAM_NATIVE_BENCHMARK_TELEMETRY");
    const char* quiet=std::getenv("WAM_TEST_MUTED");
    if(enabled && !std::strcmp(enabled,"1") && quiet && !std::strcmp(quiet,"1") &&
       run && [[NSUUID alloc] initWithUUIDString:@(run)] &&
       hex(std::getenv("WAM_NATIVE_BENCHMARK_ASSET_SHA256"),64) &&
       hex(std::getenv("WAM_NATIVE_BENCHMARK_CANDIDATE_ID"),64)){
      NativeEmbeddingSupport::setTestMuted(true);
      const char* stall=std::getenv("WAM_TEST_RETIRE_STALL");
      if(stall && !std::strcmp(stall,"1"))NativeRetirement::setTestPaused(true);
    }
#endif
    snapshot.struct_size=sizeof(snapshot); snapshot.requested_paused=1;
    view=[[WAMPresentationView alloc] initPrivate];
    std::string error;
    layer=NativeLayerHostView::createDetached(480,270,&error);
    if (!layer) throw std::runtime_error(error.empty()?"PresentationUnavailable":error);
    NSView* child=(__bridge NSView*)layer->view(); child.frame=view.bounds;
    child.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable; [view addSubview:child];
    preflight=std::make_unique<NativeOpenPreflight>([this](NativeOpenPreflightResult result){ opened(std::move(result)); });
  }
  ~Engine() override { if (timer) dispatch_source_cancel(timer); }
  wam_status_t submit(Command command, wam_request_id_t* request, wam_error_t* error) {
    if (closed || disposed) return WAM_CLOSED;
    if (outstanding>=32 || nextRequest==UINT64_MAX) return WAM_BACKPRESSURE;
    command.id=++nextRequest; ++outstanding; if(request)*request=command.id;
    if(command.operation==Operation::Close) closed=true;
#if defined(WAMKIT_ENABLE_TEST_SUPPORT)
    if(command.operation==Operation::Seek && NativeEmbeddingSupport::testMuted()) {
      const char* recovery=std::getenv("WAM_TEST_DEVICE_RECOVERY_SEEK");
      if(recovery && !std::strcmp(recovery,"1")) nativeAudioDeviceRecoverySeekTestGate().store(true);
    }
#endif
    auto self=shared_from_this();
    dispatch_async(dispatch_get_main_queue(), ^{ self->perform(command); });
    if(error) *error={};
    return WAM_OK;
  }
  void dispose() {
    disposed=true; callback=nullptr; context=nullptr; preflight->stop();
    enableMetrics(false);
    abandonNativeSession();
  }
  void enableMetrics(bool enabled) {
    metricsEnabled=enabled;
    setNativeMetricsEnabled(enabled);
    if(timer){dispatch_source_cancel(timer);timer=nullptr;}
    if(!enabled || disposed)return;
    timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
    std::weak_ptr<Engine> weak=shared_from_this();
    dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,0),250*NSEC_PER_MSEC,25*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{ if(auto self=weak.lock()){self->sample();self->event(WAM_EVENT_METRICS);} });
    dispatch_resume(timer);
  }
  void sample() {
    snapshot.retiring=retirementPending(); snapshot.generation=router_.snapshot().generation.value;
    if(hasNativeSession() && metricsEnabled){
      const auto metrics=nativeMetrics(); snapshot.session_epoch=metrics.sessionEpoch;
      snapshot.drawn_frames=metrics.drawnFrames; snapshot.audio_rendered_frames=metrics.audioRenderedFrames;
      snapshot.display_seconds=metrics.mediaSeconds; snapshot.clock_rate=metrics.clockRate;
      snapshot.clock_valid=metrics.clockValid;
    }
  }
private:
  std::unique_ptr<NativeOpenPreflight> preflight;
  std::optional<NativeOpenPreflightResult> source;
  std::optional<Command> opening, seeking, pausing, stopping;
  std::optional<NativeMediaSessionInitialPosition> initial;
  wam_error_t refusal{};
  float gain{1}; bool muted{false};
  dispatch_source_t timer{nullptr};
  std::array<wam_event_t,128> events{}; unsigned eventCount{0}; bool deliveryQueued{false};
  void event(wam_event_kind_t kind, std::uint64_t request=0, wam_result_t result=WAM_COMPLETED,
             const protocol::ExactCommitReady* ready=nullptr) {
    wam_event_t event{}; event.struct_size=sizeof(event);event.kind=kind;event.request_id=request;
    event.result=result;event.snapshot=snapshot;event.error=refusal;
    if(ready){event.requested_target=timeValue(ready->requestedTarget);event.audio_presentation_start=timeValue(ready->audioPresentationStart);
      event.decode_start=timeValue(ready->actualDecodeStart);event.video_start=timeValue(ready->videoStart);
      event.video_duration=timeValue(ready->videoDuration);event.audio_absent=ready->audioLaneAbsent;event.video_absent=ready->videoLaneAbsent;}
    if(kind==WAM_EVENT_METRICS || kind==WAM_EVENT_STATE){
      for(unsigned i=0;i<eventCount;++i)if(events[i].kind==kind){events[i]=event;return;}
    }
    assert(eventCount<events.size());
    events[eventCount++]=event;
    if(deliveryQueued)return;
    deliveryQueued=true;auto self=shared_from_this();
    dispatch_async(dispatch_get_main_queue(), ^{ self->deliver(); });
  }
  void deliver() {
    deliveryQueued=false;
    const auto count=eventCount; auto batch=events;eventCount=0;
    for(unsigned i=0;i<count;++i){
      if(batch[i].kind==WAM_EVENT_RESULT){assert(outstanding);--outstanding;}
      if(callback && !disposed)callback(context,&batch[i]);
    }
  }
  void state(wam_state_t value){snapshot.state=value;event(WAM_EVENT_STATE);}
  void finish(std::optional<Command>& pending,wam_result_t result,const protocol::ExactCommitReady* ready=nullptr){
    if(!pending)return;const auto id=pending->id;pending.reset();event(WAM_EVENT_RESULT,id,result,ready);
  }
  void reject(const char* name,const char* detail="") {refusal=errorValue(name,detail);state(WAM_FAILED);event(WAM_EVENT_REFUSAL);}
  void perform(Command command) {
    if(disposed){event(WAM_EVENT_RESULT,command.id,WAM_CANCELLED);return;}
    switch(command.operation){
    case Operation::Open:
      finish(opening,WAM_SUPERSEDED);finish(seeking,WAM_CANCELLED);finish(pausing,WAM_CANCELLED);
      opening=command;refusal={};snapshot.first_pts={};snapshot.duration={};snapshot.drawn_frames=0;
      snapshot.requested_paused=command.flag;state(WAM_PREPARING);
      initial=NativeMediaSession::preflightInitialPosition(timeValue(command.time));
      if(!initial){reject("InvalidTime");finish(opening,WAM_RESULT_FAILED);return;}
      if(!preflight->enqueue({{command.id},command.path.data(),0.0,bool(command.flag),true})){
        reject("SourceAccessDenied");finish(opening,WAM_RESULT_FAILED);
      }
      return;
    case Operation::Pause:
      finish(pausing,WAM_SUPERSEDED);pausing=command;snapshot.requested_paused=command.value;
      if(!nativeOwnsTransport()){finish(pausing,WAM_RESULT_FAILED);return;}
      execute(router_.setPaused(bool(command.value),nextTick()));return;
    case Operation::Seek:
      finish(seeking,WAM_SUPERSEDED);seeking=command;
      if(commitSeek(timeValue(command.time),command.id,command.id,bool(snapshot.requested_paused))!=SeekDisposition::NativeHandled){
        refusal=errorValue("SeekOutOfRange");finish(seeking,WAM_RESULT_FAILED);
      }else state(WAM_SEEKING);
      return;
    case Operation::Volume: gain=command.gain; if(nativeOwnsTransport())static_cast<void>(setGain(gain));break;
    case Operation::Mute: muted=command.value; if(nativeOwnsTransport())static_cast<void>(setMuted(muted));break;
    case Operation::Rate:
      execute(router_.setPreservePitch(command.flag,nextTick()));execute(router_.setRate(command.value/64.0,nextTick()));break;
    case Operation::Stop: case Operation::Close:
      preflight->cancel();finish(opening,WAM_CANCELLED);finish(seeking,WAM_CANCELLED);finish(pausing,WAM_CANCELLED);
      finish(stopping,WAM_SUPERSEDED);stopping=command;state(WAM_STOPPING);
      if(!deferOwnerCommand([this]{execute(router_.stop(nextTick()));pruneSourceRecords();})){
        execute(router_.stop(nextTick()));pruneSourceRecords();
      }
      if(command.operation==Operation::Close){
        std::weak_ptr<Engine> weak=shared_from_this();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC),dispatch_get_main_queue(),^{
          if(auto self=weak.lock();self && self->stopping && self->stopping->id==command.id){
            self->snapshot.retiring=1;self->state(WAM_PLAYER_CLOSED);self->finish(self->stopping,WAM_QUARANTINED);
#if defined(WAMKIT_ENABLE_TEST_SUPPORT)
            NativeRetirement::setTestPaused(false);
#endif
          }
        });
      }
      return;
    }
    event(WAM_EVENT_RESULT,command.id);
  }
  void opened(NativeOpenPreflightResult result){
    if(disposed || !opening || result.sourceKey.value!=opening->id)return;
    source=std::move(result);
    if(source->route!=router::Route::NativeEligibleLocal){
      reject(source->sourceClass==NativeSourceClass::Network?"UnsupportedSourceScheme":"SourceAccessDenied");
      finish(opening,WAM_RESULT_FAILED);return;
    }
    const auto command=[this]{
      if(!opening || !source)return;
      execute(router_.open({source->sourceKey,router::Route::NativeEligibleLocal,initial->seconds(),bool(snapshot.requested_paused)},nextTick()));
    };
    if(!deferOwnerCommand(command))command();
  }
  static NativeMediaSessionPresentation presentation(void* context,NativeTrackedVideoOutputWakeSeam wake,std::string* error) noexcept{
    auto* self=static_cast<Engine*>(context);
    auto output=NativeLayerVideoOutput::createTracked(self->layer->displayLayer(),wake,error);
    if(!output && error){try{*error="PresentationUnavailable: "+*error;}catch(...){error->clear();}}
    return {std::move(output),self->layer};
  }
  std::optional<Preparation> preparationFor(protocol::SourceKey key) override{
    if(!source || !initial || source->sourceKey!=key)return {};
    return Preparation{source->absoluteLocalPath,*initial,{this,presentation},{},gain,muted};
  }
  std::optional<router::Transition> beginFallbackCreate(const router::Action& action) override{
    if(!refusal.name[0])refusal=errorValue("UnsupportedContainer");
    state(WAM_FAILED);event(WAM_EVENT_REFUSAL);finish(opening,WAM_RESULT_FAILED);finish(seeking,WAM_RESULT_FAILED);finish(pausing,WAM_RESULT_FAILED);
    return router_.onFallbackFailed({action.fallback.stamp},nextTick());
  }
  bool beginFallbackOpen(const router::Action&) override{return false;}
  bool beginFallbackStop(const router::Action&) override{return false;}
  std::optional<router::Transition> applyFallbackRunState(const router::Action&) override{return {};}
  void pruneSourceRecords() override{
    if(router_.snapshot().state==router::State::Idle && !retirementPending() && stopping){
      snapshot.retiring=0;state(stopping->operation==Operation::Close?WAM_PLAYER_CLOSED:WAM_EMPTY);
      finish(stopping,WAM_COMPLETED);if(closed)enableMetrics(false);
    }else if(closed && !retirementPending() && snapshot.state==WAM_PLAYER_CLOSED && snapshot.retiring){
      snapshot.retiring=0;state(WAM_PLAYER_CLOSED);enableMetrics(false);
    }
  }
  void maybeCompleteFallbackStop() override{}
  void sessionCleared() noexcept override{}
  void publishDiagnostic(const NativeMediaSessionDiagnostic& diagnostic) override{
    refusal=errorValue(diagnostic.name.data(),diagnostic.detail.data());
  }
  void surfaceNativeError(const char* message) override{
    if(refusal.name[0])return;
    for(const auto* name:names){const auto length=std::strlen(name);if(!std::strncmp(message,name,length) && (message[length]==0 || message[length]==':')){refusal=errorValue(name,message);return;}}
    refusal=errorValue("InternalProtocolViolation",message);
  }
  void ownerError(const char* message) override{surfaceNativeError(message);}
  void ownerNotice(const char*) override{}
  void seekProgress(std::uint64_t) override{}
  void commitFailed(std::uint64_t,std::uint64_t request) override{if(seeking && seeking->id==request)finish(seeking,WAM_RESULT_FAILED);}
  void publishLifecycle(const NativeMediaSessionFact& fact,bool) override{
    std::visit([this](const auto& item){using T=std::decay_t<decltype(item)>;
      if constexpr(std::is_same_v<T,protocol::Prepared>){
        snapshot.first_pts={};snapshot.drawn_frames=0;snapshot.audio_rendered_frames=0;
        snapshot.session_epoch=0;snapshot.clock_valid=0;
        snapshot.generation=router_.snapshot().generation.value;
        if(hasNativeSession()){auto descriptor=nativeDescriptor();if(descriptor)snapshot.duration=timeValue(descriptor->duration);}
        state(WAM_READY);finish(opening,WAM_COMPLETED);
      }else if constexpr(std::is_same_v<T,protocol::Ended>)state(WAM_ENDED);
      else if constexpr(std::is_same_v<T,protocol::Failed>){state(WAM_FAILED);}
    },fact);
  }
  void publishRunState(const NativeMediaSessionRunStateApplied& value) override{
    snapshot.generation=value.command.generation.value;state(value.command.paused?WAM_PAUSED:WAM_PLAYING);
    if(pausing && bool(pausing->value)==value.command.paused)finish(pausing,WAM_COMPLETED);
  }
  void publishAudioClock(const protocol::AudioClockProof& proof) override{
    snapshot.display_seconds=proof.positionSeconds;snapshot.clock_rate=proof.rate;snapshot.clock_valid=1;
  }
  void publishVideoDraw(const protocol::VideoDrawProof&,bool) override{}
  void publishExactDraw(const NativeMediaSessionExactDraw& draw) override{
    if(snapshot.first_pts.timescale)return;snapshot.first_pts=timeValue(draw.start);event(WAM_EVENT_FIRST_FRAME);
  }
  void publishPreviewPresented(const protocol::PreviewPresented&) override{}
  void publishPreviewFailed(const protocol::PreviewFailed&) override{}
  void publishCommitReady(const protocol::CommitReady&) override{}
  void publishExactCommitReady(const protocol::ExactCommitReady& ready) override{
    if(seeking && seeking->id==ready.request.value)finish(seeking,WAM_COMPLETED,&ready);
  }
};
}
struct wam_player { std::shared_ptr<Engine> engine; unsigned references{1}; };
namespace {
wam_status_t valid(wam_player_t player){if(![NSThread isMainThread])return WAM_WRONG_THREAD;return player?WAM_OK:WAM_INVALID_ARGUMENT;}
wam_status_t failure(wam_error_t* error,const char* name){if(error)*error=errorValue(name);return WAM_INVALID_ARGUMENT;}
wam_status_t submit(wam_player_t player,Command command,wam_request_id_t* request,wam_error_t* error){
  const auto status=valid(player);if(status)return status;
  try{return player->engine->submit(command,request,error);}catch(...){return failure(error,"InternalProtocolViolation");}
}
}
extern "C" {
uint32_t wam_abi_version(void){return 1;}
wam_status_t wam_copy_capabilities(wam_capabilities_t* capabilities){
  if(!capabilities || capabilities->struct_size<sizeof(*capabilities))return WAM_INVALID_ARGUMENT;
  *capabilities={};capabilities->struct_size=sizeof(*capabilities);capabilities->abi_version=1;
#if defined(WAM_ENABLE_AVFORMAT_STAGE)
  capabilities->avformat_stage=1;
#endif
#if defined(WAM_ENABLE_AVCODEC_STAGE)
  capabilities->avcodec_stage=1;
#endif
#if defined(WAM_ENABLE_SOFTWARE_VP8)
  capabilities->software_vp8=1;
#endif
  capabilities->maximum_sessions=NativeEmbeddingSupport::maximumWindows;capabilities->charged_sessions=NativeRetirement::charged();
  capabilities->maximum_session_surfaces=kNativeSurfaceBudgetMaximumSurfaces;
  capabilities->maximum_session_surface_bytes=kNativeSurfaceBudgetMaximumBytes;
  capabilities->maximum_process_surfaces=kNativeSurfaceBudgetProcessMaximumSurfaces;
  capabilities->maximum_process_surface_bytes=kNativeSurfaceBudgetProcessMaximumBytes;
  return WAM_OK;
}
const char* wam_refusal_name(wam_refusal_t code){return code<std::size(names)?names[code]:"NativeDetail";}
wam_status_t wam_player_create(wam_player_t* result,wam_error_t* error){
  if(![NSThread isMainThread])return WAM_WRONG_THREAD;if(!result)return WAM_INVALID_ARGUMENT;*result=nullptr;
  if(@available(macOS 14.0,*)){}else{if(error)*error=errorValue("PresentationRequiresMacOS14");return WAM_REFUSED;}
  try{auto engine=std::make_shared<Engine>();*result=new wam_player{std::move(engine)};if(error)*error={};return WAM_OK;}
  catch(const std::exception& exception){if(error)*error=errorValue("PresentationUnavailable",exception.what());return WAM_REFUSED;}
  catch(...){return failure(error,"InternalProtocolViolation");}
}
wam_status_t wam_player_retain(wam_player_t player){auto status=valid(player);if(status)return status;if(player->references==UINT_MAX)return WAM_BACKPRESSURE;++player->references;return WAM_OK;}
wam_status_t wam_player_release(wam_player_t player){auto status=valid(player);if(status)return status;if(!--player->references){player->engine->dispose();delete player;}return WAM_OK;}
wam_status_t wam_player_observe(wam_player_t player,wam_event_callback_t callback,void* context){auto status=valid(player);if(status)return status;player->engine->callback=callback;player->engine->context=context;return WAM_OK;}
wam_status_t wam_player_open_file(wam_player_t player,const char* path,wam_time_t time,uint32_t paused,wam_request_id_t* request,wam_error_t* error){
  if(auto status=valid(player))return status;
  if(!path || path[0]!='/' || strnlen(path,4096)>=4096 || paused>1)return failure(error,"UnsupportedSourceScheme");
  if(time.reserved || !media::canonicalNonnegativeTime(timeValue(time)))return failure(error,"InvalidTime");
  Command command;command.operation=Operation::Open;command.time=time;command.flag=paused;std::strcpy(command.path.data(),path);return submit(player,command,request,error);
}
wam_status_t wam_player_set_paused(wam_player_t player,uint32_t paused,wam_request_id_t* request,wam_error_t* error){if(paused>1)return failure(error,"InternalProtocolViolation");Command command;command.operation=Operation::Pause;command.value=paused;return submit(player,command,request,error);}
wam_status_t wam_player_seek(wam_player_t player,wam_time_t time,wam_request_id_t* request,wam_error_t* error){if(time.reserved || !media::canonicalNonnegativeTime(timeValue(time)))return failure(error,"InvalidTime");Command command;command.operation=Operation::Seek;command.time=time;return submit(player,command,request,error);}
wam_status_t wam_player_set_volume(wam_player_t player,float gain,wam_request_id_t* request,wam_error_t* error){if(!std::isfinite(gain)||gain<0||gain>4)return failure(error,"InvalidVolume");Command command;command.operation=Operation::Volume;command.gain=gain;return submit(player,command,request,error);}
wam_status_t wam_player_set_muted(wam_player_t player,uint32_t muted,wam_request_id_t* request,wam_error_t* error){if(muted>1)return failure(error,"InternalProtocolViolation");Command command;command.operation=Operation::Mute;command.value=muted;return submit(player,command,request,error);}
wam_status_t wam_player_set_rate(wam_player_t player,uint32_t units,uint32_t pitch,wam_request_id_t* request,wam_error_t* error){if(units<16||units>256||pitch>1)return failure(error,"RateUnsupported");Command command;command.operation=Operation::Rate;command.value=units;command.flag=pitch;return submit(player,command,request,error);}
wam_status_t wam_player_stop(wam_player_t player,wam_request_id_t* request,wam_error_t* error){Command command;command.operation=Operation::Stop;return submit(player,command,request,error);}
wam_status_t wam_player_close(wam_player_t player,wam_request_id_t* request,wam_error_t* error){Command command;command.operation=Operation::Close;return submit(player,command,request,error);}
wam_status_t wam_player_copy_snapshot(wam_player_t player,wam_snapshot_t* snapshot){if(auto status=valid(player))return status;if(!snapshot || snapshot->struct_size<sizeof(*snapshot))return WAM_INVALID_ARGUMENT;*snapshot=player->engine->snapshot;return WAM_OK;}
wam_status_t wam_player_set_metrics_enabled(wam_player_t player,uint32_t enabled){if(auto status=valid(player))return status;if(enabled>1)return WAM_INVALID_ARGUMENT;player->engine->enableMetrics(enabled);return WAM_OK;}
void* wam_player_presentation_view(wam_player_t player){return valid(player)?nullptr:(__bridge void*)player->engine->view;}
}

@implementation WAMPlayer { wam_player_t _handle; }
- (instancetype)initWithError:(NSError**)error {
  self=[super init];if(self){wam_error_t failure{};if(wam_player_create(&_handle,&failure)!=WAM_OK){
    if(error)*error=[NSError errorWithDomain:@"WAMKitErrorDomain" code:failure.code userInfo:@{NSLocalizedDescriptionKey:@(failure.name)}];return nil;}
    wam_player_observe(_handle,[](void* context,const wam_event_t* event){WAMPlayer* player=(__bridge WAMPlayer*)context;if(player.eventHandler)player.eventHandler(event);},(__bridge void*)self);
  }return self;
}
- (void)dealloc { if(_handle)wam_player_release(_handle); }
- (WAMPresentationView*)presentationView {return (__bridge WAMPresentationView*)wam_player_presentation_view(_handle);}
- (BOOL)result:(wam_status_t)status errorValue:(wam_error_t)value error:(NSError**)error {
  if(status==WAM_OK)return YES;if(error)*error=[NSError errorWithDomain:@"WAMKitErrorDomain" code:status userInfo:@{NSLocalizedDescriptionKey:@(value.name)}];return NO;
}
- (BOOL)openFileURL:(NSURL*)url initialPosition:(wam_time_t)position paused:(BOOL)paused error:(NSError**)error {
  wam_error_t value{};const auto status=wam_player_open_file(_handle,url.isFileURL?url.path.fileSystemRepresentation:nullptr,position,paused,nullptr,&value);return [self result:status errorValue:value error:error];
}
- (BOOL)setPaused:(BOOL)paused error:(NSError**)error {wam_error_t value{};const auto status=wam_player_set_paused(_handle,paused,nullptr,&value);return [self result:status errorValue:value error:error];}
- (BOOL)seekToTime:(wam_time_t)time error:(NSError**)error {wam_error_t value{};const auto status=wam_player_seek(_handle,time,nullptr,&value);return [self result:status errorValue:value error:error];}
- (BOOL)closeWithError:(NSError**)error {wam_error_t value{};const auto status=wam_player_close(_handle,nullptr,&value);return [self result:status errorValue:value error:error];}
@end
