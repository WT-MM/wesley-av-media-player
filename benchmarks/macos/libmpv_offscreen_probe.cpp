#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <mach/mach.h>

#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_gl.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <mutex>
#include <string>
#include <sys/resource.h>
#include <thread>

namespace {

using Clock = std::chrono::steady_clock;
using TimePoint = Clock::time_point;

uint64_t physicalFootprint();

enum class Phase : std::size_t {
  ProbeStarted,
  OpenGlReady,
  MpvConfigured,
  MpvInitialized,
  RendererCreated,
  LoadSubmitted,
  StartFile,
  FileLoaded,
  FirstFrame,
  PlaybackRestart,
  MeasurementEnded,
  Count,
};

constexpr std::array<const char *, static_cast<std::size_t>(Phase::Count)>
    kPhaseNames = {
        "probe_started",     "opengl_ready",    "mpv_configured",
        "mpv_initialized",   "renderer_created", "load_submitted",
        "start_file",        "file_loaded",     "first_frame",
        "playback_restart",  "measurement_ended",
};

struct PhaseSample {
  TimePoint observed_at{};
  rusage usage{};
  uint64_t footprint = 0;
  bool captured = false;
};

struct PhaseTelemetry {
  std::array<PhaseSample, static_cast<std::size_t>(Phase::Count)> samples{};

  void capture(Phase phase, TimePoint observed_at) {
    auto &sample = samples[static_cast<std::size_t>(phase)];
    if (sample.captured)
      return;
    sample.observed_at = observed_at;
    getrusage(RUSAGE_SELF, &sample.usage);
    sample.footprint = physicalFootprint();
    sample.captured = true;
  }

  const PhaseSample &get(Phase phase) const {
    return samples[static_cast<std::size_t>(phase)];
  }
};

constexpr std::size_t kScrubPreviewSeekCount = 7;
constexpr std::size_t kScrubSeekCount = kScrubPreviewSeekCount + 1;
constexpr std::array<double, kScrubSeekCount> kScrubTargetFractions = {
    0.10, 0.22, 0.34, 0.46, 0.58, 0.70, 0.82, 0.83,
};
constexpr uint64_t kScrubCommandBase = 0x57414d530000ULL;
constexpr uint64_t kScrubDurationObservation = 0x57414d440001ULL;
constexpr uint64_t kLoadCommand = 0x57414d4c0001ULL;
constexpr uint64_t kSnapshotPropertyBase = 0x57414d500000ULL;
constexpr std::size_t kSnapshotPropertyCount = 6;
constexpr auto kLoadTimeout = std::chrono::seconds(15);

enum class SnapshotProperty : std::size_t {
  GpuHwdecInteropConfigured,
  HwdecCurrent,
  HwdecInteropCurrent,
  VoDroppedFrames,
  DecoderDroppedFrames,
  Avsync,
};

struct EndPropertySnapshot {
  std::string gpu_hwdec_interop_configured;
  std::string hwdec_current;
  std::string hwdec_interop_current;
  int64_t vo_dropped_frames = 0;
  int64_t decoder_dropped_frames = 0;
  double avsync = 0.0;
  std::array<bool, kSnapshotPropertyCount> replied{};
  std::size_t pending = 0;
  bool failed = false;
};

struct ScrubSeekSample {
  double target_seconds = 0.0;
  std::array<char, 32> target_text{};
  TimePoint submitted_at{};
  TimePoint command_reply_at{};
  TimePoint seek_event_at{};
  TimePoint playback_restart_at{};
  TimePoint first_render_at{};
  TimePoint last_render_at{};
  TimePoint completed_at{};
  rusage usage_submitted{};
  rusage usage_completed{};
  uint64_t completion_footprint = 0;
  uint64_t render_updates = 0;
  uint64_t rendered_frames = 0;
  int command_error = 0;
  bool submitted = false;
  bool command_reply = false;
  bool seek_event = false;
  bool playback_restart = false;
  bool first_render = false;
  bool completed = false;
};

struct WakeState {
  std::atomic<bool> event{false};
  std::atomic<bool> render{false};
  std::mutex mutex;
  std::condition_variable condition;
};

void wakeEvents(void *opaque) {
  auto &state = *static_cast<WakeState *>(opaque);
  state.event.store(true, std::memory_order_release);
  state.condition.notify_one();
}

void wakeRenderer(void *opaque) {
  auto &state = *static_cast<WakeState *>(opaque);
  state.render.store(true, std::memory_order_release);
  state.condition.notify_one();
}

void *openGlProcAddress(void *, const char *name) {
  return name ? dlsym(RTLD_DEFAULT, name) : nullptr;
}

bool setOption(mpv_handle *handle, const char *name, const char *value) {
  const int result = mpv_set_option_string(handle, name, value);
  if (result >= 0)
    return true;
  std::fprintf(stderr, "option %s=%s: %s\n", name, value,
               mpv_error_string(result));
  return false;
}

uint64_t physicalFootprint() {
  task_vm_info_data_t information{};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO,
                reinterpret_cast<task_info_t>(&information),
                &count) != KERN_SUCCESS) {
    return 0;
  }
  return information.phys_footprint;
}

double timevalSeconds(const timeval &value) {
  return static_cast<double>(value.tv_sec) +
         static_cast<double>(value.tv_usec) / 1'000'000.0;
}

double cpuSeconds(const rusage &value) {
  return timevalSeconds(value.ru_utime) + timevalSeconds(value.ru_stime);
}

double elapsedMilliseconds(TimePoint started, TimePoint ended) {
  return std::chrono::duration<double, std::milli>(ended - started).count();
}

double optionalElapsedMilliseconds(bool captured, TimePoint started,
                                   TimePoint ended) {
  return captured ? elapsedMilliseconds(started, ended) : -1.0;
}

} // namespace

int main(int argc, char **argv) {
  if (argc < 2) {
    std::fprintf(stderr,
                 "usage: %s MEDIA [hwdec-extra-frames] [swapchain-depth] "
                 "[advanced-control] [gpu-dumb-mode] [fbo-format] [hwdec] "
                 "[gpu-hwdec-interop] [scrub]\n",
                 argv[0]);
    return 2;
  }
  const char *gpu_hwdec_interop = argc >= 9 ? argv[8] : "auto";
  const bool scrub_requested = argc >= 10;
  if (argc > 10) {
    std::fprintf(stderr, "too many probe arguments\n");
    return 2;
  }
  if (scrub_requested && std::strcmp(argv[9], "scrub") != 0) {
    std::fprintf(stderr, "unknown probe mode: %s (expected 'scrub')\n",
                 argv[9]);
    return 2;
  }

  PhaseTelemetry phases;
  phases.capture(Phase::ProbeStarted, Clock::now());

  CGLPixelFormatAttribute attributes[] = {
      kCGLPFAOpenGLProfile,
      static_cast<CGLPixelFormatAttribute>(kCGLOGLPVersion_3_2_Core),
      kCGLPFAAccelerated,
      static_cast<CGLPixelFormatAttribute>(0),
  };
  CGLPixelFormatObj pixel_format = nullptr;
  GLint pixel_format_count = 0;
  CGLContextObj gl_context = nullptr;
  if (CGLChoosePixelFormat(attributes, &pixel_format, &pixel_format_count) !=
          kCGLNoError ||
      !pixel_format ||
      CGLCreateContext(pixel_format, nullptr, &gl_context) != kCGLNoError ||
      !gl_context) {
    std::fprintf(stderr, "unable to create an offscreen OpenGL context\n");
    if (pixel_format)
      CGLDestroyPixelFormat(pixel_format);
    return 3;
  }
  CGLDestroyPixelFormat(pixel_format);
  CGLSetCurrentContext(gl_context);

  constexpr int width = 1180;
  constexpr int height = 720;
  GLuint framebuffer = 0;
  GLuint texture = 0;
  glGenFramebuffers(1, &framebuffer);
  glGenTextures(1, &texture);
  glBindTexture(GL_TEXTURE_2D, texture);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA,
               GL_UNSIGNED_BYTE, nullptr);
  glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                         texture, 0);
  if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
    std::fprintf(stderr, "unable to create the offscreen framebuffer\n");
    return 4;
  }
  phases.capture(Phase::OpenGlReady, Clock::now());

  mpv_handle *handle = mpv_create();
  if (!handle)
    return 5;

  setOption(handle, "config", "no");
  setOption(handle, "load-scripts", "no");
  setOption(handle, "load-auto-profiles", "no");
  setOption(handle, "vo", "libmpv");
  setOption(handle, "ao", "null");
  setOption(handle, "hwdec", "auto-safe");
  setOption(handle, "vd-lavc-dr", "auto");
  if (!setOption(handle, "gpu-hwdec-interop", gpu_hwdec_interop))
    return 6;
  setOption(handle, "video-sync", "audio");
  setOption(handle, "osc", "no");
  setOption(handle, "osd-level", "0");
  setOption(handle, "input-default-bindings", "no");
  setOption(handle, "terminal", "no");
  setOption(handle, "msg-level", "all=warn");
  setOption(handle, "cache", "no");
  setOption(handle, "cache-secs", "0");
  setOption(handle, "demuxer-readahead-secs", "1");
  setOption(handle, "demuxer-max-bytes", "16MiB");
  setOption(handle, "demuxer-max-back-bytes", "0");
  setOption(handle, "scale", "bilinear");
  setOption(handle, "dscale", "bilinear");
  setOption(handle, "correct-downscaling", "no");
  setOption(handle, "linear-downscaling", "no");
  setOption(handle, "sigmoid-upscaling", "no");
  setOption(handle, "deband", "no");
  setOption(handle, "interpolation", "no");
  if (argc >= 3)
    setOption(handle, "hwdec-extra-frames", argv[2]);
  if (argc >= 4)
    setOption(handle, "swapchain-depth", argv[3]);
  if (argc >= 6)
    setOption(handle, "gpu-dumb-mode", argv[5]);
  if (argc >= 7)
    setOption(handle, "fbo-format", argv[6]);
  if (argc >= 8)
    setOption(handle, "hwdec", argv[7]);
  if (scrub_requested)
    setOption(handle, "pause", "yes");

  phases.capture(Phase::MpvConfigured, Clock::now());

  const auto initialize_started = Clock::now();
  const int initialize_result = mpv_initialize(handle);
  const auto initialize_ended = Clock::now();
  phases.capture(Phase::MpvInitialized, initialize_ended);
  if (initialize_result < 0) {
    std::fprintf(stderr, "unable to initialize libmpv\n");
    return 6;
  }

  double scrub_duration = 0.0;
  bool scrub_duration_available = false;
  if (scrub_requested &&
      mpv_observe_property(handle, kScrubDurationObservation, "duration",
                           MPV_FORMAT_DOUBLE) < 0) {
    std::fprintf(stderr, "unable to observe media duration for scrub mode\n");
    return 6;
  }

  WakeState wake_state;
  mpv_set_wakeup_callback(handle, wakeEvents, &wake_state);
  mpv_opengl_init_params gl_init{openGlProcAddress, nullptr};
  int advanced_control = argc >= 5 && std::strcmp(argv[4], "1") == 0 ? 1 : 0;
  mpv_render_param creation_parameters[] = {
      {MPV_RENDER_PARAM_API_TYPE,
       const_cast<char *>(MPV_RENDER_API_TYPE_OPENGL)},
      {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init},
      {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced_control},
      {MPV_RENDER_PARAM_INVALID, nullptr},
  };
  mpv_render_context *renderer = nullptr;
  if (mpv_render_context_create(&renderer, handle, creation_parameters) < 0) {
    std::fprintf(stderr, "unable to create libmpv renderer\n");
    return 7;
  }
  mpv_render_context_set_update_callback(renderer, wakeRenderer, &wake_state);
  wake_state.render.store(false, std::memory_order_release);
  static_cast<void>(mpv_render_context_update(renderer));
  phases.capture(Phase::RendererCreated, Clock::now());

  const char *load[] = {"loadfile", argv[1], "replace", nullptr};
  phases.capture(Phase::LoadSubmitted, Clock::now());
  const auto load_submitted = Clock::now();
  const int load_result = mpv_command_async(handle, kLoadCommand, load);
  if (load_result < 0)
    return 8;

  bool finished = false;
  bool started = false;
  uint64_t render_count = 0;
  uint64_t update_count = 0;
  uint64_t event_count = 0;
  uint64_t maximum_footprint = 0;
  auto measured_started = load_submitted;
  auto next_memory_sample = Clock::now();
  rusage usage_started{};
  getrusage(RUSAGE_SELF, &usage_started);

  std::array<ScrubSeekSample, kScrubSeekCount> scrub_seeks{};
  std::size_t scrub_index = 0;
  bool scrub_active = false;
  bool scrub_complete = false;
  bool scrub_failed = false;
  const char *scrub_status = scrub_requested ? "awaiting_startup" : "disabled";
  uint64_t start_file_count = 0;
  TimePoint load_command_reply_at{};
  int load_command_error = 0;
  bool load_command_reply = false;
  bool load_timed_out = false;

  const auto submitScrubSeek = [&](std::size_t index) {
    auto &sample = scrub_seeks[index];
    std::snprintf(sample.target_text.data(), sample.target_text.size(), "%.9f",
                  sample.target_seconds);
    const char *seek_mode =
        index < kScrubPreviewSeekCount ? "absolute+keyframes"
                                       : "absolute+exact";
    const char *command[] = {"seek", sample.target_text.data(), seek_mode,
                             nullptr};
    getrusage(RUSAGE_SELF, &sample.usage_submitted);
    sample.submitted_at = Clock::now();
    sample.submitted = true;
    const int result =
        mpv_command_async(handle, kScrubCommandBase + index, command);
    if (result < 0) {
      sample.command_error = result;
      scrub_failed = true;
      scrub_active = false;
      scrub_status = "command_submit_failed";
      finished = true;
      return false;
    }
    scrub_active = true;
    scrub_status = index < kScrubPreviewSeekCount ? "preview_seeking"
                                                  : "final_exact_seeking";
    return true;
  };

  const auto beginScrub = [&]() {
    if (!scrub_duration_available || !std::isfinite(scrub_duration) ||
        scrub_duration <= 0.0) {
      scrub_failed = true;
      scrub_status = "duration_unavailable";
      finished = true;
      return;
    }
    const double last_safe_time = std::max(0.0, scrub_duration - 0.250);
    for (std::size_t index = 0; index < kScrubSeekCount; ++index) {
      scrub_seeks[index].target_seconds =
          std::clamp(scrub_duration * kScrubTargetFractions[index], 0.0,
                     last_safe_time);
    }
    scrub_index = 0;
    submitScrubSeek(scrub_index);
  };

  while (!finished) {
    if (wake_state.event.exchange(false, std::memory_order_acq_rel)) {
      while (mpv_event *event = mpv_wait_event(handle, 0.0)) {
        if (event->event_id == MPV_EVENT_NONE)
          break;
        ++event_count;
        const auto event_seen = Clock::now();
        if (event->event_id == MPV_EVENT_START_FILE) {
          ++start_file_count;
          phases.capture(Phase::StartFile, event_seen);
          if (scrub_requested && start_file_count > 1) {
            scrub_failed = true;
            scrub_active = false;
            scrub_status = "multiple_start_files_unsupported";
            finished = true;
          }
        } else if (event->event_id == MPV_EVENT_FILE_LOADED) {
          phases.capture(Phase::FileLoaded, event_seen);
          started = true;
          measured_started = event_seen;
          getrusage(RUSAGE_SELF, &usage_started);
        } else if (event->event_id == MPV_EVENT_PLAYBACK_RESTART) {
          phases.capture(Phase::PlaybackRestart, event_seen);
          if (scrub_active) {
            auto &sample = scrub_seeks[scrub_index];
            if (sample.seek_event && !sample.playback_restart) {
              sample.playback_restart_at = event_seen;
              sample.playback_restart = true;
            }
          }
        } else if (event->event_id == MPV_EVENT_SEEK) {
          if (scrub_active) {
            auto &sample = scrub_seeks[scrub_index];
            if (!sample.seek_event) {
              sample.seek_event_at = event_seen;
              sample.seek_event = true;
            }
          }
        } else if (event->event_id == MPV_EVENT_COMMAND_REPLY) {
          const uint64_t command_id = event->reply_userdata;
          if (command_id == kLoadCommand) {
            load_command_reply_at = event_seen;
            load_command_reply = true;
            load_command_error = event->error;
            if (event->error < 0) {
              if (scrub_requested) {
                scrub_failed = true;
                scrub_active = false;
                scrub_status = "load_command_failed";
              }
              finished = true;
            }
          } else if (command_id >= kScrubCommandBase &&
              command_id < kScrubCommandBase + kScrubSeekCount) {
            const std::size_t index =
                static_cast<std::size_t>(command_id - kScrubCommandBase);
            auto &sample = scrub_seeks[index];
            sample.command_reply_at = event_seen;
            sample.command_reply = true;
            sample.command_error = event->error;
            if (event->error < 0) {
              scrub_failed = true;
              scrub_active = false;
              scrub_status = "command_reply_failed";
              finished = true;
            }
          }
        } else if (event->event_id == MPV_EVENT_PROPERTY_CHANGE) {
          if (event->reply_userdata == kScrubDurationObservation) {
            const auto *property =
                static_cast<const mpv_event_property *>(event->data);
            if (property && property->format == MPV_FORMAT_DOUBLE &&
                property->data) {
              scrub_duration = *static_cast<const double *>(property->data);
              scrub_duration_available = std::isfinite(scrub_duration) &&
                                         scrub_duration > 0.0;
            }
          }
        } else if (event->event_id == MPV_EVENT_QUEUE_OVERFLOW) {
          if (scrub_requested) {
            scrub_failed = true;
            scrub_active = false;
            scrub_status = "event_queue_overflow";
            finished = true;
          }
        } else if (event->event_id == MPV_EVENT_END_FILE ||
                   event->event_id == MPV_EVENT_SHUTDOWN) {
          if (scrub_requested && !scrub_complete && !scrub_failed) {
            scrub_failed = true;
            scrub_active = false;
            scrub_status = event->event_id == MPV_EVENT_END_FILE
                               ? "end_file_before_completion"
                               : "shutdown_before_completion";
          }
          finished = true;
        }
      }
    }

    if (wake_state.render.exchange(false, std::memory_order_acq_rel)) {
      const uint64_t flags = mpv_render_context_update(renderer);
      ++update_count;
      if (scrub_active)
        ++scrub_seeks[scrub_index].render_updates;
      if (flags & MPV_RENDER_UPDATE_FRAME) {
        mpv_render_frame_info frame_info{};
        mpv_render_param frame_info_parameter{
            MPV_RENDER_PARAM_NEXT_FRAME_INFO, &frame_info};
        const bool frame_info_available =
            mpv_render_context_get_info(renderer, frame_info_parameter) >= 0;
        const bool qualifying_media_frame =
            frame_info_available &&
            (frame_info.flags & MPV_RENDER_FRAME_INFO_PRESENT) &&
            !(frame_info.flags & MPV_RENDER_FRAME_INFO_REDRAW) &&
            !(frame_info.flags & MPV_RENDER_FRAME_INFO_REPEAT);
        mpv_opengl_fbo target{static_cast<int>(framebuffer), width, height, 0};
        int flip = 0;
        mpv_render_param render_parameters[] = {
            {MPV_RENDER_PARAM_OPENGL_FBO, &target},
            {MPV_RENDER_PARAM_FLIP_Y, &flip},
            {MPV_RENDER_PARAM_INVALID, nullptr},
        };
        if (mpv_render_context_render(renderer, render_parameters) >= 0) {
          glFinish();
          const auto render_completed = Clock::now();
          ++render_count;
          if (qualifying_media_frame)
            phases.capture(Phase::FirstFrame, render_completed);
          if (scrub_active && qualifying_media_frame) {
            auto &sample = scrub_seeks[scrub_index];
            if (!sample.first_render) {
              sample.first_render_at = render_completed;
              sample.first_render = true;
            }
            sample.last_render_at = render_completed;
            ++sample.rendered_frames;
          }
        }
      }
    }

    if (scrub_requested && !scrub_failed && !scrub_complete &&
        !scrub_active && started && scrub_duration_available &&
        phases.get(Phase::FirstFrame).captured &&
        phases.get(Phase::PlaybackRestart).captured) {
      beginScrub();
    }

    if (scrub_active) {
      auto &sample = scrub_seeks[scrub_index];
      if (sample.command_reply && sample.command_error >= 0 &&
          sample.seek_event && sample.playback_restart &&
          sample.first_render) {
        sample.completed_at = std::max(
            std::max(sample.command_reply_at, sample.seek_event_at),
            std::max(sample.playback_restart_at, sample.first_render_at));
        getrusage(RUSAGE_SELF, &sample.usage_completed);
        sample.completion_footprint = physicalFootprint();
        sample.completed = true;
        scrub_active = false;
        if (++scrub_index < kScrubSeekCount) {
          submitScrubSeek(scrub_index);
        } else {
          scrub_complete = true;
          scrub_status = "complete";
          finished = true;
        }
      }
    }

    const auto now = Clock::now();
    if (now >= next_memory_sample) {
      maximum_footprint = std::max(maximum_footprint, physicalFootprint());
      next_memory_sample = now + std::chrono::milliseconds(250);
    }
    if (!started && now - load_submitted >= kLoadTimeout) {
      load_timed_out = true;
      if (scrub_requested) {
        scrub_failed = true;
        scrub_active = false;
        scrub_status = "load_timeout";
      }
      finished = true;
    }
    if (started && now - measured_started >= std::chrono::seconds(20)) {
      if (scrub_requested && !scrub_complete && !scrub_failed) {
        scrub_failed = true;
        scrub_active = false;
        scrub_status = "timeout";
      }
      finished = true;
    }

    std::unique_lock lock(wake_state.mutex);
    wake_state.condition.wait_for(lock, std::chrono::milliseconds(2));
  }

  const auto measured_ended = Clock::now();
  phases.capture(Phase::MeasurementEnded, measured_ended);
  const rusage usage_ended = phases.get(Phase::MeasurementEnded).usage;
  const double elapsed =
      std::chrono::duration<double>(measured_ended - measured_started).count();
  const double cpu_seconds = cpuSeconds(usage_ended) - cpuSeconds(usage_started);
  maximum_footprint = std::max(maximum_footprint, physicalFootprint());

  EndPropertySnapshot property_snapshot;
  constexpr std::array<const char *, kSnapshotPropertyCount>
      snapshot_property_names = {
          "options/gpu-hwdec-interop", "hwdec-current", "hwdec-interop",
          "frame-drop-count", "decoder-frame-drop-count", "avsync",
      };
  constexpr std::array<mpv_format, kSnapshotPropertyCount>
      snapshot_property_formats = {
          MPV_FORMAT_STRING, MPV_FORMAT_STRING, MPV_FORMAT_STRING,
          MPV_FORMAT_INT64,  MPV_FORMAT_INT64,  MPV_FORMAT_DOUBLE,
      };
  for (std::size_t index = 0; index < kSnapshotPropertyCount; ++index) {
    const int result = mpv_get_property_async(
        handle, kSnapshotPropertyBase + index, snapshot_property_names[index],
        snapshot_property_formats[index]);
    if (result >= 0) {
      ++property_snapshot.pending;
    } else {
      property_snapshot.replied[index] = true;
      property_snapshot.failed = true;
    }
  }

  const auto snapshot_deadline = Clock::now() + std::chrono::seconds(1);
  while (property_snapshot.pending > 0 && Clock::now() < snapshot_deadline) {
    while (mpv_event *event = mpv_wait_event(handle, 0.0)) {
      if (event->event_id == MPV_EVENT_NONE)
        break;
      if (event->event_id != MPV_EVENT_GET_PROPERTY_REPLY ||
          event->reply_userdata < kSnapshotPropertyBase ||
          event->reply_userdata >=
              kSnapshotPropertyBase + kSnapshotPropertyCount) {
        continue;
      }
      const std::size_t index = static_cast<std::size_t>(
          event->reply_userdata - kSnapshotPropertyBase);
      if (property_snapshot.replied[index])
        continue;
      property_snapshot.replied[index] = true;
      --property_snapshot.pending;
      if (event->error < 0 || !event->data) {
        property_snapshot.failed = true;
        continue;
      }
      const auto *property =
          static_cast<const mpv_event_property *>(event->data);
      if (property->format != snapshot_property_formats[index] ||
          !property->data) {
        property_snapshot.failed = true;
        continue;
      }
      switch (static_cast<SnapshotProperty>(index)) {
      case SnapshotProperty::GpuHwdecInteropConfigured: {
        const char *value = *static_cast<char **>(property->data);
        property_snapshot.gpu_hwdec_interop_configured = value ? value : "";
        break;
      }
      case SnapshotProperty::HwdecCurrent: {
        const char *value = *static_cast<char **>(property->data);
        property_snapshot.hwdec_current = value ? value : "";
        break;
      }
      case SnapshotProperty::HwdecInteropCurrent: {
        const char *value = *static_cast<char **>(property->data);
        property_snapshot.hwdec_interop_current = value ? value : "";
        break;
      }
      case SnapshotProperty::VoDroppedFrames:
        property_snapshot.vo_dropped_frames =
            *static_cast<int64_t *>(property->data);
        break;
      case SnapshotProperty::DecoderDroppedFrames:
        property_snapshot.decoder_dropped_frames =
            *static_cast<int64_t *>(property->data);
        break;
      case SnapshotProperty::Avsync:
        property_snapshot.avsync = *static_cast<double *>(property->data);
        break;
      }
    }

    if (wake_state.render.exchange(false, std::memory_order_acq_rel)) {
      const uint64_t flags = mpv_render_context_update(renderer);
      if (flags & MPV_RENDER_UPDATE_FRAME) {
        mpv_opengl_fbo target{static_cast<int>(framebuffer), width, height, 0};
        int flip = 0;
        mpv_render_param render_parameters[] = {
            {MPV_RENDER_PARAM_OPENGL_FBO, &target},
            {MPV_RENDER_PARAM_FLIP_Y, &flip},
            {MPV_RENDER_PARAM_INVALID, nullptr},
        };
        if (mpv_render_context_render(renderer, render_parameters) >= 0)
          glFinish();
      }
    }

    if (property_snapshot.pending > 0) {
      std::unique_lock lock(wake_state.mutex);
      wake_state.condition.wait_for(lock, std::chrono::milliseconds(2));
    }
  }
  if (property_snapshot.pending > 0)
    property_snapshot.failed = true;
  const bool property_snapshot_complete =
      property_snapshot.pending == 0 && !property_snapshot.failed;

  mpv_render_context_set_update_callback(renderer, nullptr, nullptr);
  mpv_render_context_free(renderer);

  std::printf("elapsed_s=%.3f\n", elapsed);
  std::printf("cpu_percent=%.3f\n",
              elapsed > 0 ? 100.0 * cpu_seconds / elapsed : 0.0);
  std::printf("phys_footprint_bytes=%llu\n",
              static_cast<unsigned long long>(
                  phases.get(Phase::MeasurementEnded).footprint));
  std::printf("max_sampled_footprint_bytes=%llu\n",
              static_cast<unsigned long long>(maximum_footprint));
  std::printf("context_switches=%ld\n",
              (usage_ended.ru_nvcsw + usage_ended.ru_nivcsw) -
                  (usage_started.ru_nvcsw + usage_started.ru_nivcsw));
  std::printf("render_callbacks=%llu\n",
              static_cast<unsigned long long>(update_count));
  std::printf("rendered_frames=%llu\n",
              static_cast<unsigned long long>(render_count));
  std::printf("client_events=%llu\n",
              static_cast<unsigned long long>(event_count));
  std::printf("load_timed_out=%d\n", load_timed_out ? 1 : 0);
  std::printf("property_snapshot_complete=%d\n",
              property_snapshot_complete ? 1 : 0);
  std::printf("gpu_hwdec_interop_requested=%s\n", gpu_hwdec_interop);
  std::printf("gpu_hwdec_interop_configured=%s\n",
              property_snapshot.gpu_hwdec_interop_configured.c_str());
  std::printf("hwdec_interop_current=%s\n",
              property_snapshot.hwdec_interop_current.c_str());
  std::printf("hwdec_current=%s\n",
              property_snapshot.hwdec_current.c_str());
  std::printf("vo_dropped_frames=%lld\n",
              static_cast<long long>(property_snapshot.vo_dropped_frames));
  std::printf(
      "decoder_dropped_frames=%lld\n",
      static_cast<long long>(property_snapshot.decoder_dropped_frames));
  std::printf("avsync=%.6f\n", property_snapshot.avsync);

  std::printf("mpv_initialize_ms=%.3f\n",
              elapsedMilliseconds(initialize_started, initialize_ended));
  std::printf("load_command_reply_ms=%.3f\n",
              optionalElapsedMilliseconds(load_command_reply, load_submitted,
                                          load_command_reply_at));
  std::printf("load_command_error=%d\n", load_command_error);
  const auto printLoadTiming = [&](const char *name, Phase destination) {
    const auto &sample = phases.get(destination);
    std::printf("%s=%.3f\n", name,
                optionalElapsedMilliseconds(sample.captured, load_submitted,
                                            sample.observed_at));
  };
  printLoadTiming("load_to_start_file_ms", Phase::StartFile);
  printLoadTiming("load_to_file_loaded_ms", Phase::FileLoaded);
  printLoadTiming("load_to_first_frame_render_complete_ms", Phase::FirstFrame);
  printLoadTiming("load_to_playback_restart_ms", Phase::PlaybackRestart);

  const auto &probe_sample = phases.get(Phase::ProbeStarted);
  const double probe_cpu = cpuSeconds(probe_sample.usage);
  for (std::size_t index = 0; index < kPhaseNames.size(); ++index) {
    const auto &sample = phases.samples[index];
    const char *name = kPhaseNames[index];
    const double phase_elapsed_ms =
        sample.captured
            ? elapsedMilliseconds(probe_sample.observed_at, sample.observed_at)
            : -1.0;
    const double phase_cpu_ms =
        sample.captured ? 1000.0 * (cpuSeconds(sample.usage) - probe_cpu) : -1.0;
    std::printf("phase_%s_captured=%d\n", name, sample.captured ? 1 : 0);
    std::printf("phase_%s_elapsed_ms=%.3f\n", name,
                phase_elapsed_ms);
    std::printf("phase_%s_cpu_ms=%.3f\n", name, phase_cpu_ms);
    std::printf("phase_%s_cpu_percent=%.3f\n", name,
                phase_elapsed_ms > 0.0
                    ? 100.0 * phase_cpu_ms / phase_elapsed_ms
                    : 0.0);
    std::printf("phase_%s_phys_footprint_bytes=%llu\n", name,
                static_cast<unsigned long long>(sample.captured
                                                    ? sample.footprint
                                                    : 0));
  }

  std::size_t scrub_completed_count = 0;
  for (const auto &sample : scrub_seeks) {
    if (sample.completed)
      ++scrub_completed_count;
  }
  std::printf("scrub_requested=%d\n", scrub_requested ? 1 : 0);
  std::printf("scrub_status=%s\n", scrub_status);
  std::printf("scrub_planned_seek_count=%zu\n",
              scrub_requested ? kScrubSeekCount : 0);
  std::printf("scrub_completed_seek_count=%zu\n", scrub_completed_count);
  if (scrub_requested) {
    for (std::size_t index = 0; index < kScrubSeekCount; ++index) {
      const auto &sample = scrub_seeks[index];
      const char *mode = index < kScrubPreviewSeekCount ? "keyframes" : "exact";
      std::printf("scrub_seek_%zu_mode=%s\n", index, mode);
      std::printf("scrub_seek_%zu_target_s=%.6f\n", index,
                  sample.target_seconds);
      std::printf("scrub_seek_%zu_submitted=%d\n", index,
                  sample.submitted ? 1 : 0);
      std::printf("scrub_seek_%zu_command_reply_ms=%.3f\n", index,
                  optionalElapsedMilliseconds(sample.command_reply,
                                              sample.submitted_at,
                                              sample.command_reply_at));
      std::printf("scrub_seek_%zu_seek_event_ms=%.3f\n", index,
                  optionalElapsedMilliseconds(sample.seek_event,
                                              sample.submitted_at,
                                              sample.seek_event_at));
      std::printf("scrub_seek_%zu_playback_restart_ms=%.3f\n", index,
                  optionalElapsedMilliseconds(sample.playback_restart,
                                              sample.submitted_at,
                                              sample.playback_restart_at));
      std::printf("scrub_seek_%zu_first_frame_render_complete_ms=%.3f\n", index,
                  optionalElapsedMilliseconds(sample.first_render,
                                              sample.submitted_at,
                                              sample.first_render_at));
      std::printf("scrub_seek_%zu_complete_ms=%.3f\n", index,
                  optionalElapsedMilliseconds(sample.completed,
                                              sample.submitted_at,
                                              sample.completed_at));
      const double cadence =
          sample.rendered_frames > 1
              ? elapsedMilliseconds(sample.first_render_at, sample.last_render_at) /
                    static_cast<double>(sample.rendered_frames - 1)
              : -1.0;
      const double seek_cpu_ms =
          sample.completed
              ? 1000.0 * (cpuSeconds(sample.usage_completed) -
                          cpuSeconds(sample.usage_submitted))
              : -1.0;
      const double seek_complete_ms = optionalElapsedMilliseconds(
          sample.completed, sample.submitted_at, sample.completed_at);
      std::printf("scrub_seek_%zu_render_cadence_ms=%.3f\n", index, cadence);
      std::printf("scrub_seek_%zu_render_callbacks=%llu\n", index,
                  static_cast<unsigned long long>(sample.render_updates));
      std::printf("scrub_seek_%zu_rendered_frames=%llu\n", index,
                  static_cast<unsigned long long>(sample.rendered_frames));
      std::printf("scrub_seek_%zu_cpu_ms=%.3f\n", index, seek_cpu_ms);
      std::printf("scrub_seek_%zu_cpu_percent=%.3f\n", index,
                  seek_complete_ms > 0.0
                      ? 100.0 * seek_cpu_ms / seek_complete_ms
                      : 0.0);
      std::printf("scrub_seek_%zu_phys_footprint_bytes=%llu\n", index,
                  static_cast<unsigned long long>(sample.completed
                                                      ? sample.completion_footprint
                                                      : 0));
      std::printf("scrub_seek_%zu_command_error=%d\n", index,
                  sample.command_error);
    }
  }

  mpv_set_wakeup_callback(handle, nullptr, nullptr);
  mpv_terminate_destroy(handle);
  glDeleteFramebuffers(1, &framebuffer);
  glDeleteTextures(1, &texture);
  CGLSetCurrentContext(nullptr);
  CGLDestroyContext(gl_context);
  if (load_timed_out || (load_command_reply && load_command_error < 0))
    return 8;
  if (scrub_requested && !scrub_complete)
    return 9;
  if (!property_snapshot_complete)
    return 10;
  return 0;
}
