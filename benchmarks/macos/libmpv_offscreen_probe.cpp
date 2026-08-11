#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <mach/mach.h>

#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_gl.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
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

std::string stringProperty(mpv_handle *handle, const char *name) {
  char *value = mpv_get_property_string(handle, name);
  if (!value)
    return {};
  std::string result(value);
  mpv_free(value);
  return result;
}

double doubleProperty(mpv_handle *handle, const char *name) {
  double value = 0.0;
  return mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value
                                                                        : 0.0;
}

long long integerProperty(mpv_handle *handle, const char *name) {
  int64_t value = 0;
  return mpv_get_property(handle, name, MPV_FORMAT_INT64, &value) >= 0 ? value
                                                                       : 0;
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

} // namespace

int main(int argc, char **argv) {
  if (argc < 2) {
    std::fprintf(stderr,
                 "usage: %s MEDIA [hwdec-extra-frames] [swapchain-depth] "
                 "[advanced-control] [gpu-dumb-mode] [fbo-format] [hwdec]\n",
                 argv[0]);
    return 2;
  }

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
  setOption(handle, "gpu-hwdec-interop", "auto");
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

  if (mpv_initialize(handle) < 0) {
    std::fprintf(stderr, "unable to initialize libmpv\n");
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

  const char *load[] = {"loadfile", argv[1], "replace", nullptr};
  if (mpv_command(handle, load) < 0)
    return 8;

  bool finished = false;
  bool started = false;
  uint64_t render_count = 0;
  uint64_t update_count = 0;
  uint64_t event_count = 0;
  uint64_t maximum_footprint = 0;
  const auto process_started = Clock::now();
  auto measured_started = process_started;
  auto next_memory_sample = process_started;
  rusage usage_started{};
  getrusage(RUSAGE_SELF, &usage_started);

  while (!finished) {
    if (wake_state.event.exchange(false, std::memory_order_acq_rel)) {
      while (mpv_event *event = mpv_wait_event(handle, 0.0)) {
        if (event->event_id == MPV_EVENT_NONE)
          break;
        ++event_count;
        if (event->event_id == MPV_EVENT_FILE_LOADED) {
          started = true;
          measured_started = Clock::now();
          getrusage(RUSAGE_SELF, &usage_started);
        } else if (event->event_id == MPV_EVENT_END_FILE ||
                   event->event_id == MPV_EVENT_SHUTDOWN) {
          finished = true;
        }
      }
    }

    if (wake_state.render.exchange(false, std::memory_order_acq_rel)) {
      const uint64_t flags = mpv_render_context_update(renderer);
      ++update_count;
      if (flags & MPV_RENDER_UPDATE_FRAME) {
        mpv_opengl_fbo target{static_cast<int>(framebuffer), width, height, 0};
        int flip = 0;
        mpv_render_param render_parameters[] = {
            {MPV_RENDER_PARAM_OPENGL_FBO, &target},
            {MPV_RENDER_PARAM_FLIP_Y, &flip},
            {MPV_RENDER_PARAM_INVALID, nullptr},
        };
        mpv_render_context_render(renderer, render_parameters);
        glFinish();
        ++render_count;
      }
    }

    const auto now = Clock::now();
    if (now >= next_memory_sample) {
      maximum_footprint = std::max(maximum_footprint, physicalFootprint());
      next_memory_sample = now + std::chrono::milliseconds(250);
    }
    if (started && now - measured_started >= std::chrono::seconds(20))
      finished = true;

    std::unique_lock lock(wake_state.mutex);
    wake_state.condition.wait_for(lock, std::chrono::milliseconds(2));
  }

  const auto measured_ended = Clock::now();
  rusage usage_ended{};
  getrusage(RUSAGE_SELF, &usage_ended);
  const double elapsed =
      std::chrono::duration<double>(measured_ended - measured_started).count();
  const double cpu_seconds = timevalSeconds(usage_ended.ru_utime) +
                             timevalSeconds(usage_ended.ru_stime) -
                             timevalSeconds(usage_started.ru_utime) -
                             timevalSeconds(usage_started.ru_stime);
  maximum_footprint = std::max(maximum_footprint, physicalFootprint());

  std::printf("elapsed_s=%.3f\n", elapsed);
  std::printf("cpu_percent=%.3f\n",
              elapsed > 0 ? 100.0 * cpu_seconds / elapsed : 0.0);
  std::printf("phys_footprint_bytes=%llu\n",
              static_cast<unsigned long long>(physicalFootprint()));
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
  std::printf("hwdec_current=%s\n",
              stringProperty(handle, "hwdec-current").c_str());
  std::printf("vo_dropped_frames=%lld\n",
              integerProperty(handle, "vo-drop-frame-count"));
  std::printf("decoder_dropped_frames=%lld\n",
              integerProperty(handle, "decoder-frame-drop-count"));
  std::printf("avsync=%.6f\n", doubleProperty(handle, "avsync"));

  mpv_render_context_set_update_callback(renderer, nullptr, nullptr);
  mpv_render_context_free(renderer);
  mpv_set_wakeup_callback(handle, nullptr, nullptr);
  mpv_terminate_destroy(handle);
  glDeleteFramebuffers(1, &framebuffer);
  glDeleteTextures(1, &texture);
  CGLSetCurrentContext(nullptr);
  CGLDestroyContext(gl_context);
  return 0;
}
