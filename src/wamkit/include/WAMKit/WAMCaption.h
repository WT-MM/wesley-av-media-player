#ifndef WAM_CAPTION_H
#define WAM_CAPTION_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Independent ABI v1. All strings are copied on entry and borrowed during
   callbacks. Callbacks are serialized off-main; never release in a callback.
   One operation at a time. cancel is nonblocking; finish is asynchronous.
   Release only after FINISHED. Handles must not race release with any call. */
typedef void *wam_caption_session_v1;
typedef void (*wam_caption_callback_v1)(void *context, uint64_t generation,
    int32_t kind, double start, double end, double progress, int32_t flags,
    const char *utf8);
enum { WAM_CAPTION_CAPABILITIES = 1, WAM_CAPTION_PREPARED = 2,
       WAM_CAPTION_SEGMENT = 3, WAM_CAPTION_PROGRESS = 4,
       WAM_CAPTION_COMPLETED = 5, WAM_CAPTION_ERROR = 6,
       WAM_CAPTION_CANCELLED = 7, WAM_CAPTION_FINISHED = 8 };
/* Capabilities flags: available=1, ready=2, needs-download=4. Size unknown.
   Segment flag 1 means final. Times are relative to the current input file. */
wam_caption_session_v1 wam_caption_create_v1(wam_caption_callback_v1, void *);
void wam_caption_query_v1(wam_caption_session_v1, uint64_t, const char *locale);
void wam_caption_prepare_v1(wam_caption_session_v1, uint64_t, int32_t consent);
void wam_caption_start_v1(wam_caption_session_v1, uint64_t, const char *wav);
void wam_caption_cancel_v1(wam_caption_session_v1);
void wam_caption_finish_v1(wam_caption_session_v1, uint64_t);
void wam_caption_release_v1(wam_caption_session_v1);
#ifdef __cplusplus
}
#endif
#endif
