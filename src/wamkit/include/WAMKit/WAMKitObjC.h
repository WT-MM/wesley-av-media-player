#ifndef WAMKIT_OBJC_H
#define WAMKIT_OBJC_H
#if defined(__OBJC__)
#import <AppKit/AppKit.h>
#import <WAMKit/WAMKit.h>
NS_ASSUME_NONNULL_BEGIN
WAM_EXPORT @interface WAMPresentationView : NSView
- (instancetype)initWithFrame:(NSRect)frame NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
@end
__attribute__((swift_attr("@MainActor"))) WAM_EXPORT @interface WAMPlayer : NSObject
@property(nonatomic, readonly) WAMPresentationView *presentationView;
@property(nonatomic, copy, nullable) void (^eventHandler)(const wam_event_t *event);
- (nullable instancetype)initWithError:(NSError **)error;
- (instancetype)init NS_UNAVAILABLE;
- (BOOL)openFileURL:(NSURL *)url initialPosition:(wam_time_t)position paused:(BOOL)paused error:(NSError **)error;
- (BOOL)setPaused:(BOOL)paused error:(NSError **)error;
- (BOOL)seekToTime:(wam_time_t)target error:(NSError **)error;
- (BOOL)closeWithError:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
#endif
#endif
