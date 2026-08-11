#include "media_engine.hpp"

#include <SDL.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>

namespace wam {

MediaEngine::MediaEngine() {
  handle_ = mpv_create();
  if (!handle_) return;

  // Keep decoding/rendering on the GPU and tune for low latency without
  // sacrificing stable A/V sync. mpv falls back cleanly when a codec cannot
  // be decoded by the platform hardware.
  mpv_set_option_string(handle_, "vo", "libmpv");
  mpv_set_option_string(handle_, "hwdec", "auto-safe");
  mpv_set_option_string(handle_, "vd-lavc-dr", "auto");
  mpv_set_option_string(handle_, "gpu-hwdec-interop", "auto");
  mpv_set_option_string(handle_, "hwdec-extra-frames", "2");
  mpv_set_option_string(handle_, "video-sync", "display-resample");
  mpv_set_option_string(handle_, "audio-pitch-correction", "yes");
  mpv_set_option_string(handle_, "keep-open", "yes");
  mpv_set_option_string(handle_, "osc", "no");
  mpv_set_option_string(handle_, "input-default-bindings", "no");
  mpv_set_option_string(handle_, "terminal", "no");
  mpv_set_option_string(handle_, "msg-level", "all=warn");
  mpv_set_option_string(handle_, "cache", "auto");
  mpv_set_option_string(handle_, "demuxer-readahead-secs", "10");
  mpv_set_option_string(handle_, "demuxer-max-bytes", "64MiB");
  mpv_set_option_string(handle_, "demuxer-max-back-bytes", "16MiB");
  mpv_set_option_string(handle_, "scale", "spline36");
  mpv_set_option_string(handle_, "dscale", "mitchell");
  mpv_set_option_string(handle_, "correct-downscaling", "yes");
  mpv_set_option_string(handle_, "sigmoid-upscaling", "no");
  mpv_set_option_string(handle_, "deband", "no");
  mpv_set_option_string(handle_, "interpolation", "no");

  if (mpv_initialize(handle_) < 0) {
    mpv_terminate_destroy(handle_);
    handle_ = nullptr;
    return;
  }

  mpv_opengl_init_params gl_init{&MediaEngine::getProcAddress, nullptr};
  mpv_render_param params[] = {
      {MPV_RENDER_PARAM_API_TYPE, const_cast<char*>(MPV_RENDER_API_TYPE_OPENGL)},
      {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init},
      {MPV_RENDER_PARAM_INVALID, nullptr}};
  if (mpv_render_context_create(&render_, handle_, params) < 0) {
    mpv_terminate_destroy(handle_);
    handle_ = nullptr;
    return;
  }
  mpv_render_context_set_update_callback(render_, &MediaEngine::requestRender, this);
}

MediaEngine::~MediaEngine() {
  if (render_) mpv_render_context_free(render_);
  if (handle_) mpv_terminate_destroy(handle_);
}

void* MediaEngine::getProcAddress(void*, const char* name) {
  return SDL_GL_GetProcAddress(name);
}

void MediaEngine::requestRender(void* context) {
  static_cast<MediaEngine*>(context)->render_requested_ = true;
  // Wake the otherwise event-driven UI loop immediately when mpv has a new
  // frame. SDL_PushEvent is thread-safe and avoids polling while paused.
  SDL_Event event{};
  event.type = SDL_USEREVENT;
  event.user.code = 0x57414D;  // "WAM"
  SDL_PushEvent(&event);
}

bool MediaEngine::open(const std::string& source) {
  if (!valid() || source.empty()) return false;
  const char* command[] = {"loadfile", source.c_str(), "replace", nullptr};
  if (mpv_command(handle_, command) < 0) return false;
  source_ = source;
  return true;
}

bool MediaEngine::enqueue(const std::string& source) {
  if (!valid() || source.empty()) return false;
  const char* command[] = {"loadfile", source.c_str(), "append-play", nullptr};
  return mpv_command(handle_, command) >= 0;
}

void MediaEngine::command(const char* name) {
  if (handle_) mpv_command_string(handle_, name);
}
void MediaEngine::next() { command("playlist-next weak"); }
void MediaEngine::previous() { command("playlist-prev weak"); }
void MediaEngine::frameStep() { command("frame-step"); }
void MediaEngine::frameBackStep() { command("frame-back-step"); }

std::vector<PlaylistItem> MediaEngine::playlist() const {
  std::vector<PlaylistItem> result;
  const auto count = getInt("playlist/count", 0);
  const auto current = getInt("playlist-pos", -1);
  for (int64_t i = 0; i < count; ++i) {
    const auto prefix = "playlist/" + std::to_string(i) + "/";
    PlaylistItem item;
    item.index = static_cast<int>(i);
    item.filename = infoString((prefix + "filename").c_str());
    item.title = infoString((prefix + "title").c_str(),
                            std::filesystem::path(item.filename).filename().string());
    item.current = i == current;
    result.push_back(std::move(item));
  }
  return result;
}

void MediaEngine::playPlaylistItem(int index) {
  if (!handle_ || index < 0) return;
  int64_t value = index;
  mpv_set_property(handle_, "playlist-pos", MPV_FORMAT_INT64, &value);
}
void MediaEngine::removePlaylistItem(int index) {
  if (!handle_ || index < 0) return;
  const auto text = "playlist-remove " + std::to_string(index);
  mpv_command_string(handle_, text.c_str());
}
void MediaEngine::clearPlaylist() { command("playlist-clear"); }
void MediaEngine::shufflePlaylist() { command("playlist-shuffle"); }

void MediaEngine::play() {
  const double duration = durationSeconds();
  if (duration > 0.0 && timeSeconds() >= duration - 0.05) seekSeconds(0.0);
  int value = 0;
  if (handle_) mpv_set_property(handle_, "pause", MPV_FORMAT_FLAG, &value);
}
void MediaEngine::pause() {
  int value = 1;
  if (handle_) mpv_set_property(handle_, "pause", MPV_FORMAT_FLAG, &value);
}
void MediaEngine::togglePause() { isPlaying() ? pause() : play(); }
void MediaEngine::stop() { if (handle_) mpv_command_string(handle_, "stop"); }
bool MediaEngine::isPlaying() const { return handle_ && !getFlag("pause", true) && !getFlag("idle-active", true); }
double MediaEngine::timeSeconds() const { return getDouble("time-pos"); }
double MediaEngine::durationSeconds() const { return getDouble("duration"); }
void MediaEngine::seekSeconds(double seconds) {
  if (!handle_) return;
  double value = std::max(0.0, seconds);
  mpv_set_property(handle_, "time-pos", MPV_FORMAT_DOUBLE, &value);
}
float MediaEngine::position() const { return static_cast<float>(std::clamp(getDouble("percent-pos") / 100.0, 0.0, 1.0)); }
void MediaEngine::setPosition(float position) {
  if (!handle_) return;
  double value = std::clamp(static_cast<double>(position), 0.0, 1.0) * 100.0;
  mpv_set_property(handle_, "percent-pos", MPV_FORMAT_DOUBLE, &value);
}
void MediaEngine::setRate(float rate) {
  if (!handle_) return;
  double value = std::clamp(static_cast<double>(rate), 0.0625, 16.0);
  mpv_set_property(handle_, "speed", MPV_FORMAT_DOUBLE, &value);
}
float MediaEngine::rate() const { return static_cast<float>(getDouble("speed", 1.0)); }
void MediaEngine::setVolume(int volume) {
  if (!handle_) return;
  double value = std::clamp(static_cast<double>(volume), 0.0, 200.0);
  mpv_set_property(handle_, "volume", MPV_FORMAT_DOUBLE, &value);
}
int MediaEngine::volume() const { return static_cast<int>(std::lround(getDouble("volume", 100.0))); }

bool MediaEngine::addSubtitle(const std::filesystem::path& path) {
  if (!handle_) return false;
  const std::string value = path.string();
  const char* command[] = {"sub-add", value.c_str(), "select", nullptr};
  return mpv_command(handle_, command) >= 0;
}

bool MediaEngine::snapshot(const std::filesystem::path& path, unsigned, unsigned) {
  if (!handle_) return false;
  const std::string value = path.string();
  const char* command[] = {"screenshot-to-file", value.c_str(), "video", nullptr};
  return mpv_command(handle_, command) >= 0;
}

double MediaEngine::getDouble(const char* property, double fallback) const {
  double value = fallback;
  return handle_ && mpv_get_property(handle_, property, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : fallback;
}
int64_t MediaEngine::getInt(const char* property, int64_t fallback) const {
  int64_t value = fallback;
  return handle_ && mpv_get_property(handle_, property, MPV_FORMAT_INT64, &value) >= 0 ? value : fallback;
}
bool MediaEngine::getFlag(const char* property, bool fallback) const {
  int value = fallback ? 1 : 0;
  return handle_ && mpv_get_property(handle_, property, MPV_FORMAT_FLAG, &value) >= 0 ? value != 0 : fallback;
}

std::vector<std::pair<int, std::string>> MediaEngine::tracksOfType(const char* type) const {
  std::vector<std::pair<int, std::string>> result;
  const int64_t count = getInt("track-list/count", 0);
  for (int64_t i = 0; i < count; ++i) {
    const std::string prefix = "track-list/" + std::to_string(i) + "/";
    char* track_type = nullptr;
    if (mpv_get_property(handle_, (prefix + "type").c_str(), MPV_FORMAT_STRING, &track_type) < 0) continue;
    const bool matches = track_type && std::strcmp(track_type, type) == 0;
    mpv_free(track_type);
    if (!matches) continue;
    const int id = static_cast<int>(getInt((prefix + "id").c_str(), -1));
    char* title = nullptr;
    char* language = nullptr;
    mpv_get_property(handle_, (prefix + "title").c_str(), MPV_FORMAT_STRING, &title);
    mpv_get_property(handle_, (prefix + "lang").c_str(), MPV_FORMAT_STRING, &language);
    std::string label = title ? title : (language ? language : (std::string(type) + " " + std::to_string(id)));
    if (title) mpv_free(title);
    if (language) mpv_free(language);
    result.emplace_back(id, std::move(label));
  }
  return result;
}

std::vector<std::pair<int, std::string>> MediaEngine::audioTracks() const { return tracksOfType("audio"); }
std::vector<std::pair<int, std::string>> MediaEngine::subtitleTracks() const { return tracksOfType("sub"); }
int MediaEngine::currentAudioTrack() const { return static_cast<int>(getInt("aid", -1)); }
int MediaEngine::currentSubtitleTrack() const { return static_cast<int>(getInt("sid", -1)); }
void MediaEngine::setAudioTrack(int id) { if (handle_) { int64_t value = id; mpv_set_property(handle_, "aid", MPV_FORMAT_INT64, &value); } }
void MediaEngine::setSubtitleTrack(int id) { if (handle_) { int64_t value = id; mpv_set_property(handle_, "sid", MPV_FORMAT_INT64, &value); } }

std::vector<AudioDevice> MediaEngine::audioDevices() const {
  std::vector<AudioDevice> result;
  const auto count = getInt("audio-device-list/count", 0);
  for (int64_t i = 0; i < count; ++i) {
    const auto prefix = "audio-device-list/" + std::to_string(i) + "/";
    AudioDevice device;
    device.name = infoString((prefix + "name").c_str());
    device.description = infoString((prefix + "description").c_str(), device.name);
    if (!device.name.empty()) result.push_back(std::move(device));
  }
  return result;
}
std::string MediaEngine::currentAudioDevice() const {
  return infoString("audio-device", "auto");
}
void MediaEngine::setAudioDevice(const std::string& name) {
  if (handle_ && !name.empty())
    mpv_set_property_string(handle_, "audio-device", name.c_str());
}

void MediaEngine::setABLoop(double start, double end) {
  if (!handle_ || end <= start) return;
  mpv_set_property(handle_, "ab-loop-a", MPV_FORMAT_DOUBLE, &start);
  mpv_set_property(handle_, "ab-loop-b", MPV_FORMAT_DOUBLE, &end);
  mpv_set_property_string(handle_, "ab-loop-count", "inf");
}
void MediaEngine::clearABLoop() {
  if (!handle_) return;
  mpv_set_property_string(handle_, "ab-loop-a", "no");
  mpv_set_property_string(handle_, "ab-loop-b", "no");
}
void MediaEngine::setAudioDelay(double seconds) { if (handle_) mpv_set_property(handle_, "audio-delay", MPV_FORMAT_DOUBLE, &seconds); }
double MediaEngine::audioDelay() const { return getDouble("audio-delay"); }
void MediaEngine::setSubtitleDelay(double seconds) { if (handle_) mpv_set_property(handle_, "sub-delay", MPV_FORMAT_DOUBLE, &seconds); }
double MediaEngine::subtitleDelay() const { return getDouble("sub-delay"); }
void MediaEngine::setAspect(const std::string& aspect) { if (handle_) mpv_set_property_string(handle_, "video-aspect-override", aspect.c_str()); }
void MediaEngine::setRotation(int degrees) { if (handle_) { int64_t value = degrees; mpv_set_property(handle_, "video-rotate", MPV_FORMAT_INT64, &value); } }
void MediaEngine::setDeinterlace(bool enabled) { if (handle_) { int value = enabled ? 1 : 0; mpv_set_property(handle_, "deinterlace", MPV_FORMAT_FLAG, &value); } }
bool MediaEngine::deinterlace() const { return getFlag("deinterlace"); }

void MediaEngine::setPerformanceProfile(PerformanceProfile profile) {
  if (!handle_) return;
  performance_profile_ = profile;
  switch (profile) {
    case PerformanceProfile::Efficiency:
      mpv_set_property_string(handle_, "scale", "bilinear");
      mpv_set_property_string(handle_, "dscale", "bilinear");
      mpv_set_property_string(handle_, "deband", "no");
      mpv_set_property_string(handle_, "sigmoid-upscaling", "no");
      mpv_set_property_string(handle_, "interpolation", "no");
      mpv_set_property_string(handle_, "video-sync", "audio");
      mpv_set_property_string(handle_, "demuxer-max-bytes", "32MiB");
      mpv_set_property_string(handle_, "demuxer-max-back-bytes", "8MiB");
      mpv_set_property_string(handle_, "hwdec-extra-frames", "1");
      break;
    case PerformanceProfile::Balanced:
      mpv_set_property_string(handle_, "scale", "spline36");
      mpv_set_property_string(handle_, "dscale", "mitchell");
      mpv_set_property_string(handle_, "deband", "no");
      mpv_set_property_string(handle_, "sigmoid-upscaling", "no");
      mpv_set_property_string(handle_, "interpolation", "no");
      mpv_set_property_string(handle_, "video-sync", "display-resample");
      mpv_set_property_string(handle_, "demuxer-max-bytes", "64MiB");
      mpv_set_property_string(handle_, "demuxer-max-back-bytes", "16MiB");
      mpv_set_property_string(handle_, "hwdec-extra-frames", "2");
      break;
    case PerformanceProfile::Quality:
      mpv_set_property_string(handle_, "scale", "ewa_lanczossharp");
      mpv_set_property_string(handle_, "dscale", "mitchell");
      mpv_set_property_string(handle_, "deband", "yes");
      mpv_set_property_string(handle_, "sigmoid-upscaling", "yes");
      mpv_set_property_string(handle_, "interpolation", "no");
      mpv_set_property_string(handle_, "video-sync", "display-resample");
      mpv_set_property_string(handle_, "demuxer-max-bytes", "128MiB");
      mpv_set_property_string(handle_, "demuxer-max-back-bytes", "32MiB");
      mpv_set_property_string(handle_, "hwdec-extra-frames", "6");
      break;
  }
}

void MediaEngine::setFileLoop(bool enabled) { if (handle_) mpv_set_property_string(handle_, "loop-file", enabled ? "inf" : "no"); }
bool MediaEngine::fileLoop() const { return infoString("loop-file", "no") != "no"; }
void MediaEngine::toggleMute() { if (handle_) { int value = muted() ? 0 : 1; mpv_set_property(handle_, "mute", MPV_FORMAT_FLAG, &value); } }
bool MediaEngine::muted() const { return getFlag("mute"); }
void MediaEngine::nextChapter() { command("add chapter 1"); }
void MediaEngine::previousChapter() { command("add chapter -1"); }
std::vector<ChapterItem> MediaEngine::chapters() const {
  std::vector<ChapterItem> result;
  const auto count = getInt("chapter-list/count", 0);
  for (int64_t i = 0; i < count; ++i) {
    const auto prefix = "chapter-list/" + std::to_string(i) + "/";
    ChapterItem item;
    item.index = static_cast<int>(i);
    item.time = getDouble((prefix + "time").c_str());
    item.title = infoString((prefix + "title").c_str(), "Chapter " + std::to_string(i + 1));
    result.push_back(std::move(item));
  }
  return result;
}
void MediaEngine::seekChapter(int index) {
  if (!handle_ || index < 0) return;
  int64_t value = index;
  mpv_set_property(handle_, "chapter", MPV_FORMAT_INT64, &value);
}
void MediaEngine::setSubtitleVisible(bool visible) { if (handle_) { int value = visible ? 1 : 0; mpv_set_property(handle_, "sub-visibility", MPV_FORMAT_FLAG, &value); } }
bool MediaEngine::subtitleVisible() const { return getFlag("sub-visibility", true); }
void MediaEngine::setSubtitleScale(double scale) { if (handle_) mpv_set_property(handle_, "sub-scale", MPV_FORMAT_DOUBLE, &scale); }
double MediaEngine::subtitleScale() const { return getDouble("sub-scale", 1.0); }
void MediaEngine::setBrightness(double value) { if (handle_) mpv_set_property(handle_, "brightness", MPV_FORMAT_DOUBLE, &value); }
void MediaEngine::setContrast(double value) { if (handle_) mpv_set_property(handle_, "contrast", MPV_FORMAT_DOUBLE, &value); }
void MediaEngine::setSaturation(double value) { if (handle_) mpv_set_property(handle_, "saturation", MPV_FORMAT_DOUBLE, &value); }
void MediaEngine::setGamma(double value) { if (handle_) mpv_set_property(handle_, "gamma", MPV_FORMAT_DOUBLE, &value); }
bool MediaEngine::startRecording(const std::filesystem::path& output) {
  if (!handle_ || output.empty()) return false;
  return mpv_set_property_string(handle_, "stream-record", output.string().c_str()) >= 0;
}
void MediaEngine::stopRecording() { if (handle_) mpv_set_property_string(handle_, "stream-record", ""); }
bool MediaEngine::recording() const { return !infoString("stream-record").empty(); }

std::string MediaEngine::infoString(const char* property, const std::string& fallback) const {
  if (!handle_) return fallback;
  char* value = nullptr;
  if (mpv_get_property(handle_, property, MPV_FORMAT_STRING, &value) < 0 || !value) return fallback;
  std::string result(value);
  mpv_free(value);
  return result;
}
double MediaEngine::infoDouble(const char* property, double fallback) const { return getDouble(property, fallback); }
int64_t MediaEngine::infoInt(const char* property, int64_t fallback) const { return getInt(property, fallback); }

void MediaEngine::render(unsigned framebuffer, int width, int height) {
  if (!render_ || width <= 0 || height <= 0) return;
  mpv_opengl_fbo fbo{static_cast<int>(framebuffer), width, height, 0};
  int flip = 1;
  mpv_render_param params[] = {
      {MPV_RENDER_PARAM_OPENGL_FBO, &fbo},
      {MPV_RENDER_PARAM_FLIP_Y, &flip},
      {MPV_RENDER_PARAM_INVALID, nullptr}};
  mpv_render_context_render(render_, params);
}

bool MediaEngine::needsRender() {
  if (!render_ || !render_requested_.exchange(false)) return false;
  return (mpv_render_context_update(render_) & MPV_RENDER_UPDATE_FRAME) != 0;
}

void MediaEngine::reportSwap() {
  if (render_) mpv_render_context_report_swap(render_);
}

void MediaEngine::processEvents() {
  if (!handle_) return;
  while (true) {
    mpv_event* event = mpv_wait_event(handle_, 0.0);
    if (!event || event->event_id == MPV_EVENT_NONE) break;
    if (event->event_id == MPV_EVENT_FILE_LOADED)
      source_ = infoString("path", source_);
  }
}

}  // namespace wam
