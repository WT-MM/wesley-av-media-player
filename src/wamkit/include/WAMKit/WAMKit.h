#ifndef WAMKIT_H
#define WAMKIT_H
#include <stdint.h>
#include <stddef.h>
#if defined(__GNUC__)
#define WAM_EXPORT __attribute__((visibility("default")))
#else
#define WAM_EXPORT
#endif
#ifdef __cplusplus
extern "C" {
#endif

typedef struct wam_player *wam_player_t;
typedef uint64_t wam_request_id_t;
typedef uint32_t wam_status_t;
enum { WAM_OK = 0, WAM_INVALID_ARGUMENT = 1, WAM_WRONG_THREAD = 2,
       WAM_CLOSED = 3, WAM_BACKPRESSURE = 4, WAM_REFUSED = 5 };
typedef uint32_t wam_state_t;
enum { WAM_EMPTY = 0, WAM_PREPARING = 1, WAM_READY = 2, WAM_PLAYING = 3,
       WAM_PAUSED = 4, WAM_SEEKING = 5, WAM_ENDED = 6, WAM_STOPPING = 7,
       WAM_FAILED = 8, WAM_PLAYER_CLOSED = 9 };
typedef uint32_t wam_result_t;
enum { WAM_COMPLETED = 0, WAM_SUPERSEDED = 1, WAM_CANCELLED = 2,
       WAM_RESULT_FAILED = 3, WAM_QUARANTINED = 4 };
typedef uint32_t wam_event_kind_t;
enum { WAM_EVENT_STATE = 1, WAM_EVENT_RESULT = 2, WAM_EVENT_REFUSAL = 3,
       WAM_EVENT_METRICS = 4, WAM_EVENT_FIRST_FRAME = 5 };
typedef uint32_t wam_refusal_t;
enum { WAM_REASON_NONE = 0, WAM_REASON_UNSUPPORTED_SOURCE_SCHEME = 1,
       WAM_REASON_SOURCE_ACCESS_DENIED = 2, WAM_REASON_UNSUPPORTED_CONTAINER = 3,
       WAM_REASON_DECODER_STAGE_NOT_BUILT = 4, WAM_REASON_DECODER_UNAVAILABLE = 5,
       WAM_REASON_PRESENTATION_REQUIRES_MACOS14 = 6, WAM_REASON_PRESENTATION_UNAVAILABLE = 7,
       WAM_REASON_INVALID_TIME = 8, WAM_REASON_TIME_OVERFLOW = 9,
       WAM_REASON_SEEK_OUT_OF_RANGE = 10, WAM_REASON_SEEK_STALLED = 11,
       WAM_REASON_RATE_UNSUPPORTED = 12, WAM_REASON_INVALID_VOLUME = 13,
       WAM_REASON_SESSION_BUDGET_EXCEEDED = 14, WAM_REASON_RETIREMENT_CAPACITY_UNAVAILABLE = 15,
       WAM_REASON_AUDIO_OUTPUT_UNAVAILABLE = 16, WAM_REASON_INTERNAL_PROTOCOL_VIOLATION = 17,
       WAM_REASON_HE_AAC_SBR_DECODER_DELAY_UNPROVEN = 18,
       WAM_REASON_NATIVE_DETAIL = 255 };
typedef struct { int64_t value; int32_t timescale; uint32_t reserved; } wam_time_t;
typedef struct {
  uint32_t struct_size; wam_refusal_t code;
  char name[128]; char detail[768];
  uint32_t related_count; char related_names[8][128];
} wam_error_t;
typedef struct {
  uint32_t struct_size; uint32_t reserved;
  wam_state_t state; uint32_t requested_paused;
  uint64_t generation; uint64_t session_epoch;
  wam_time_t duration; wam_time_t first_pts;
  double display_seconds; double clock_rate;
  uint64_t drawn_frames; uint64_t audio_rendered_frames;
  uint32_t clock_valid; uint32_t retiring;
} wam_snapshot_t;
typedef struct {
  uint32_t struct_size; wam_event_kind_t kind;
  wam_request_id_t request_id; wam_result_t result; uint32_t reserved;
  wam_snapshot_t snapshot; wam_error_t error;
  wam_time_t requested_target; wam_time_t audio_presentation_start;
  wam_time_t decode_start; wam_time_t video_start; wam_time_t video_duration;
  uint32_t audio_absent; uint32_t video_absent;
} wam_event_t;
typedef struct {
  uint32_t struct_size; uint32_t abi_version;
  uint32_t avformat_stage; uint32_t avcodec_stage; uint32_t software_vp8;
  uint32_t compositor_metrics_available;
  uint32_t maximum_sessions; uint32_t charged_sessions;
  uint64_t maximum_session_surfaces; uint64_t maximum_session_surface_bytes;
  uint64_t maximum_process_surfaces; uint64_t maximum_process_surface_bytes;
} wam_capabilities_t;

typedef void (*wam_event_callback_t)(void *context, const wam_event_t *event);

/* Commands, snapshots, view access and handle ownership require AppKit main.
   Callbacks run asynchronously on main; callback commands execute next turn.
   Input strings are copied; callback payloads are borrowed for that call. */
WAM_EXPORT uint32_t wam_abi_version(void);
WAM_EXPORT wam_status_t wam_copy_capabilities(wam_capabilities_t *capabilities);
WAM_EXPORT const char *wam_refusal_name(wam_refusal_t code);
WAM_EXPORT wam_status_t wam_player_create(wam_player_t *out_player, wam_error_t *error);
WAM_EXPORT wam_status_t wam_player_retain(wam_player_t player);
WAM_EXPORT wam_status_t wam_player_release(wam_player_t player);
WAM_EXPORT wam_status_t wam_player_observe(wam_player_t player, wam_event_callback_t callback, void *context);
WAM_EXPORT wam_status_t wam_player_open_file(wam_player_t player, const char *absolute_utf8_path, wam_time_t initial_position, uint32_t paused, wam_request_id_t *request, wam_error_t *error);
WAM_EXPORT wam_status_t wam_player_set_paused(wam_player_t player, uint32_t paused, wam_request_id_t *request, wam_error_t *error);
WAM_EXPORT wam_status_t wam_player_seek(wam_player_t player, wam_time_t target, wam_request_id_t *request, wam_error_t *error);
WAM_EXPORT wam_status_t wam_player_set_volume(wam_player_t player, float gain, wam_request_id_t *request, wam_error_t *error);
WAM_EXPORT wam_status_t wam_player_set_muted(wam_player_t player, uint32_t muted, wam_request_id_t *request, wam_error_t *error);
WAM_EXPORT wam_status_t wam_player_set_rate(wam_player_t player, uint32_t units_per_64, uint32_t preserve_pitch, wam_request_id_t *request, wam_error_t *error);
WAM_EXPORT wam_status_t wam_player_stop(wam_player_t player, wam_request_id_t *request, wam_error_t *error);
WAM_EXPORT wam_status_t wam_player_close(wam_player_t player, wam_request_id_t *request, wam_error_t *error);
WAM_EXPORT wam_status_t wam_player_copy_snapshot(wam_player_t player, wam_snapshot_t *snapshot);
WAM_EXPORT wam_status_t wam_player_set_metrics_enabled(wam_player_t player, uint32_t enabled);
/* Borrowed NSView*. The player owns one presentation; the host owns placement. */
WAM_EXPORT void *wam_player_presentation_view(wam_player_t player);
#ifdef __cplusplus
}
#endif
#endif
