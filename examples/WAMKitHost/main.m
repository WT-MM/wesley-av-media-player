#import <AppKit/AppKit.h>
#import <WAMKit/WAMKitObjC.h>
#include <errno.h>
#include <math.h>

static int exitStatus=0;
static BOOL integer(NSString *text,uint64_t *value){
  if(!text.length || [text rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location!=NSNotFound)return NO;
  errno=0;unsigned long long parsed=strtoull(text.UTF8String,NULL,10);
  if(errno==ERANGE || parsed>INT64_MAX)return NO;*value=parsed;return YES;
}
static wam_time_t parseTime(NSString *text) {
  NSArray *ratio=[text componentsSeparatedByString:@"/"];
  uint64_t numerator=0,scale=1;
  if(ratio.count==2){
    if(!integer(ratio[0],&numerator)||!integer(ratio[1],&scale)||!scale||scale>INT32_MAX)return (wam_time_t){0};
  }else{
    NSArray *decimal=[text componentsSeparatedByString:@"."];
    if(decimal.count>2 || !integer(decimal[0],&numerator))return (wam_time_t){0};
    if(decimal.count==2){NSString *fraction=decimal[1];uint64_t trailing=0;
      if(fraction.length>9 || !integer(fraction,&trailing))return (wam_time_t){0};
      for(NSUInteger i=0;i<fraction.length;++i)scale*=10;
      if(numerator>((uint64_t)INT64_MAX-trailing)/scale)return (wam_time_t){0};
      numerator=numerator*scale+trailing;
    }
  }
  return (wam_time_t){(int64_t)numerator,(int32_t)scale,0};
}
@interface Host : NSObject <NSApplicationDelegate,NSWindowDelegate>
@end
@implementation Host {
  wam_player_t player;
  NSWindow *window;
  NSTextField *target;
  NSTextField *status;
  NSFileHandle *metrics;
  dispatch_queue_t writer;
  unsigned pendingWrites;
  BOOL measured, closing, didSeek, apiMode, reentered, callbackActive, quarantineMode, quarantined, replaceMode, replaced;
  unsigned completedRequests, releaseCallbacks;
  wam_player_t disposable;
  double seekWhen;
  wam_time_t seekTarget;
  wam_request_id_t closeRequest;
}
static BOOL hexadecimal(NSString *value) {
  if(value.length!=64)return NO;
  return [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location==NSNotFound;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  (void)notification;
  NSDictionary *env=NSProcessInfo.processInfo.environment;
  measured=[env[@"WAM_NATIVE_BENCHMARK_TELEMETRY"] isEqual:@"1"] &&
    [[NSUUID alloc] initWithUUIDString:env[@"WAM_NATIVE_BENCHMARK_RUN_ID"]]!=nil &&
    hexadecimal(env[@"WAM_NATIVE_BENCHMARK_ASSET_SHA256"]) && hexadecimal(env[@"WAM_NATIVE_BENCHMARK_CANDIDATE_ID"]);
  wam_error_t error={0};
  if(wam_player_create(&player,&error)!=WAM_OK){fprintf(stderr,"create refused: %s %s\n",error.name,error.detail);exitStatus=1;[NSApp terminate:nil];return;}
  window=[[NSWindow alloc] initWithContentRect:NSMakeRect(100,100,720,450)
    styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
  window.title=@"WAMKit Host";window.delegate=self;
  NSView *video=(__bridge NSView *)wam_player_presentation_view(player);
  video.translatesAutoresizingMaskIntoConstraints=NO;
  [window.contentView addSubview:video];
  NSStackView *controls=[NSStackView stackViewWithViews:@[
    [NSButton buttonWithTitle:@"Open…" target:self action:@selector(open:)],
    [NSButton buttonWithTitle:@"Play" target:self action:@selector(play:)],
    [NSButton buttonWithTitle:@"Pause" target:self action:@selector(pause:)]]];
  target=[NSTextField textFieldWithString:@"1001/30000"];target.placeholderString=@"numerator/timescale";
  [target.widthAnchor constraintEqualToConstant:120].active=YES;
  [controls addArrangedSubview:target];
  [controls addArrangedSubview:[NSButton buttonWithTitle:@"Seek" target:self action:@selector(seek:)]];
  [controls addArrangedSubview:[NSButton buttonWithTitle:@"Close" target:self action:@selector(close:)]];
  status=[NSTextField labelWithString:@"Empty"];
  NSStackView *footer=[NSStackView stackViewWithViews:@[controls,status]];footer.orientation=NSUserInterfaceLayoutOrientationVertical;footer.alignment=NSLayoutAttributeLeading;footer.spacing=6;
  footer.translatesAutoresizingMaskIntoConstraints=NO;[window.contentView addSubview:footer];
  [NSLayoutConstraint activateConstraints:@[
    [video.topAnchor constraintEqualToAnchor:window.contentView.topAnchor],
    [video.leadingAnchor constraintEqualToAnchor:window.contentView.leadingAnchor],
    [video.trailingAnchor constraintEqualToAnchor:window.contentView.trailingAnchor],
    [video.bottomAnchor constraintEqualToAnchor:footer.topAnchor constant:-8],
    [footer.leadingAnchor constraintEqualToAnchor:window.contentView.leadingAnchor constant:12],
    [footer.bottomAnchor constraintEqualToAnchor:window.contentView.bottomAnchor constant:-10]]];
  wam_player_observe(player, hostEvent, (__bridge void *)self);
  if(measured){
    int width=480,height=270,x=2400,y=1000;
    sscanf([env[@"WAM_TEST_GEOMETRY"] UTF8String],"%dx%d+%d+%d",&width,&height,&x,&y);
    [window setFrame:NSMakeRect(x,y,width,height) display:NO];
    [window orderBack:nil];
    NSString *path=env[@"WAM_PLAYBACK_METRICS_PATH"];
    if(path.length){
      writer=dispatch_queue_create("WAMKitHost.metrics",DISPATCH_QUEUE_SERIAL);
      dispatch_async(writer,^{
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        NSFileHandle *handle=[NSFileHandle fileHandleForWritingAtPath:path];
        dispatch_async(dispatch_get_main_queue(),^{self->metrics=handle;[self beginMeasured:env];});
      });
    }else [self beginMeasured:env];
  }else{[window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];}
}
- (void)beginMeasured:(NSDictionary *)env {
    wam_player_set_metrics_enabled(player,1);
    NSString *script=env[@"WAM_TEST_SEEK_SCRIPT"];
    NSArray *parts=[script componentsSeparatedByString:@"@"];
    if(parts.count==2){double when=[parts[1] doubleValue];if(isfinite(when)&&when>=0){seekTarget=parseTime(parts[0]);seekWhen=when;}}
    replaceMode=[env[@"WAM_TEST_REPLACE"] isEqual:@"1"];
    quarantineMode=[env[@"WAM_TEST_RETIRE_STALL"] isEqual:@"1"];
    apiMode=[env[@"WAM_TEST_API"] isEqual:@"1"];
    if(apiMode)[self checkAPI];
    NSArray *arguments=NSProcessInfo.processInfo.arguments;
    if(!apiMode && arguments.count>1)wam_player_open_file(player,[arguments[1] fileSystemRepresentation],(wam_time_t){0,1,0},0,NULL,NULL);
    double seconds=[env[@"WAM_TEST_QUIT_AFTER_MS"] doubleValue]/1000.0;if(seconds<=0)seconds=4000.0/1000.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(seconds*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[self close:nil];});
}
static void hostEvent(void *context,const wam_event_t *event){[(__bridge Host *)context receive:event];}
static void releaseEvent(void *context,const wam_event_t *event){
  Host *host=(__bridge Host*)context;
  if(event->kind==WAM_EVENT_RESULT){++host->releaseCallbacks;wam_player_release(host->disposable);host->disposable=NULL;}
}
- (void)checkAPI {
  wam_time_t decimal=parseTime(@"0.125"),ratio=parseTime(@"1001/30000");
  if(decimal.value*8!=decimal.timescale || !decimal.timescale || ratio.value!=1001 || ratio.timescale!=30000 || parseTime(@"9223372036854775808").timescale || parseTime(@"nan").timescale)exitStatus=1;
  wam_capabilities_t capabilities={.struct_size=sizeof(capabilities)};
  if(wam_copy_capabilities(&capabilities)!=WAM_OK || capabilities.maximum_sessions!=16 || capabilities.maximum_session_surfaces!=10 || capabilities.compositor_metrics_available!=0)exitStatus=1;
  wam_error_t error={0};
  if(wam_player_seek(player,(wam_time_t){-1,3,0},NULL,&error)!=WAM_INVALID_ARGUMENT || strcmp(error.name,"InvalidTime"))exitStatus=1;
  if(wam_player_set_rate(player,0,1,NULL,&error)!=WAM_INVALID_ARGUMENT || strcmp(error.name,"RateUnsupported"))exitStatus=1;
  if(wam_player_set_volume(player,5,NULL,&error)!=WAM_INVALID_ARGUMENT || strcmp(error.name,"InvalidVolume"))exitStatus=1;
  for(unsigned i=0;i<32;++i)if(wam_player_set_volume(player,1,NULL,NULL)!=WAM_OK)exitStatus=1;
  if(wam_player_set_volume(player,1,NULL,NULL)!=WAM_BACKPRESSURE)exitStatus=1;
  if(wam_player_create(&disposable,NULL)!=WAM_OK)exitStatus=1;
  wam_player_observe(disposable,releaseEvent,(__bridge void*)self);
  wam_player_set_volume(disposable,1,NULL,NULL);wam_player_set_volume(disposable,1,NULL,NULL);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{
    wam_snapshot_t snapshot={.struct_size=sizeof(snapshot)};
    wam_status_t result=wam_player_copy_snapshot(self->player,&snapshot);
    dispatch_async(dispatch_get_main_queue(),^{if(result!=WAM_WRONG_THREAD)exitStatus=1;});
  });
}
- (void)receive:(const wam_event_t *)event {
  if(callbackActive)exitStatus=1;
  callbackActive=YES;
  if(apiMode && event->kind==WAM_EVENT_RESULT && event->request_id!=closeRequest){
    ++completedRequests;
    if(!reentered){reentered=YES;if(wam_player_set_volume(player,1,NULL,NULL)!=WAM_OK)exitStatus=1;}
  }
  status.stringValue=[NSString stringWithFormat:@"State %u · %.3f s · %s",event->snapshot.state,event->snapshot.display_seconds,event->error.name];
  if(metrics && pendingWrites<64){
    NSDictionary *env=NSProcessInfo.processInfo.environment;
    wam_capabilities_t capabilities={.struct_size=sizeof(capabilities)};wam_copy_capabilities(&capabilities);
    NSMutableArray *related=[NSMutableArray array];
    for(unsigned i=0;i<event->error.related_count;++i)[related addObject:@(event->error.related_names[i])];
    NSDictionary *row=@{@"kind":@(event->kind),@"request_id":@(event->request_id),@"result":@(event->result),
      @"state":@(event->snapshot.state),@"generation":@(event->snapshot.generation),@"drawn_frames":@(event->snapshot.drawn_frames),
      @"clock_rate":@(event->snapshot.clock_rate),@"clock_valid":@(event->snapshot.clock_valid),@"position":@(event->snapshot.display_seconds),
      @"first_pts_value":@(event->snapshot.first_pts.value),@"first_pts_timescale":@(event->snapshot.first_pts.timescale),
      @"requested_value":@(event->requested_target.value),@"requested_timescale":@(event->requested_target.timescale),
      @"audio_start_value":@(event->audio_presentation_start.value),@"audio_start_timescale":@(event->audio_presentation_start.timescale),
      @"charged_sessions":@(capabilities.charged_sessions),@"related_refusals":related,@"retiring":@(event->snapshot.retiring),@"refusal":@(event->error.name),@"detail":@(event->error.detail),
      @"run_id":env[@"WAM_NATIVE_BENCHMARK_RUN_ID"],@"asset_sha256":env[@"WAM_NATIVE_BENCHMARK_ASSET_SHA256"],@"candidate_id":env[@"WAM_NATIVE_BENCHMARK_CANDIDATE_ID"]};
    NSData *data=[NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingSortedKeys error:nil];++pendingWrites;
    dispatch_async(writer,^{[self->metrics writeData:data];[self->metrics writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
      dispatch_async(dispatch_get_main_queue(),^{--self->pendingWrites;});});
  }
  if(replaceMode && !replaced && event->kind==WAM_EVENT_FIRST_FRAME){
    replaced=YES;NSString *path=NSProcessInfo.processInfo.arguments[1];
    wam_player_open_file(player,path.fileSystemRepresentation,(wam_time_t){1,1,0},0,NULL,NULL);
  }
  if(measured && seekTarget.timescale>0 && !didSeek && event->kind==WAM_EVENT_METRICS && event->snapshot.display_seconds>=seekWhen){
    didSeek=YES;wam_player_seek(player,seekTarget,NULL,NULL);
  }
  if(closing && event->kind==WAM_EVENT_RESULT && event->request_id==closeRequest){
    if(quarantineMode && event->result==WAM_QUARANTINED){
      quarantined=YES;callbackActive=NO;return;
    }
    if(event->result!=WAM_COMPLETED || quarantineMode)exitStatus=1;
    if(apiMode){if(completedRequests!=33 || !reentered || releaseCallbacks!=1)exitStatus=1;fprintf(stderr,"API checks %s: %u terminal results\n",exitStatus?"FAILED":"passed",completedRequests);}
    if(measured){dispatch_async(writer?:dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{
      [self->metrics closeFile];dispatch_async(dispatch_get_main_queue(),^{[NSApp terminate:nil];});});}
  }
  if(quarantined && event->snapshot.state==WAM_PLAYER_CLOSED && !event->snapshot.retiring){
    dispatch_async(writer,^{[self->metrics closeFile];dispatch_async(dispatch_get_main_queue(),^{[NSApp terminate:nil];});});
  }
  callbackActive=NO;
}
- (void)open:(id)sender {(void)sender;NSOpenPanel *panel=[NSOpenPanel openPanel];[panel beginSheetModalForWindow:window completionHandler:^(NSModalResponse result){if(result==NSModalResponseOK)wam_player_open_file(self->player,panel.URL.path.fileSystemRepresentation,(wam_time_t){0,1,0},0,NULL,NULL);}];}
- (void)play:(id)sender {(void)sender;wam_player_set_paused(player,0,NULL,NULL);}
- (void)pause:(id)sender {(void)sender;wam_player_set_paused(player,1,NULL,NULL);}
- (void)seek:(id)sender {(void)sender;wam_time_t value=parseTime(target.stringValue);if(value.timescale)wam_player_seek(player,value,NULL,NULL);}

- (void)close:(id)sender {(void)sender;if(closing)return;closing=YES;wam_player_close(player,&closeRequest,NULL);}
- (BOOL)windowShouldClose:(NSWindow *)sender {(void)sender;[self close:nil];return YES;}
- (void)applicationWillTerminate:(NSNotification *)notification {(void)notification;if(player){wam_player_release(player);player=NULL;}}
@end
int main(int argc,const char **argv){(void)argc;(void)argv;@autoreleasepool{NSApplication *app=[NSApplication sharedApplication];Host *host=[Host new];app.delegate=host;[app run];}return exitStatus;}
