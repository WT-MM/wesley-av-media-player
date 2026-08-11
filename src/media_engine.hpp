#pragma once

#include <atomic>
#include <filesystem>
#include <string>
#include <utility>
#include <vector>

#include <mpv/client.h>
#include <mpv/render_gl.h>

namespace wam {

enum class PerformanceProfile { Efficiency, Balanced, Quality };

struct PlaylistItem {
  int index = -1;
  std::string title;
  std::string filename;
  bool current = false;
};

struct ChapterItem {
  int index = -1;
  double time = 0.0;
  std::string title;
};

struct AudioDevice {
  std::string name;
  std::string description;
};

class MediaEngine {
 public:
  MediaEngine();
  ~MediaEngine();
  MediaEngine(const MediaEngine&) = delete;
  MediaEngine& operator=(const MediaEngine&) = delete;

  bool valid() const { return handle_ && render_; }
  bool open(const std::string& source);
  bool enqueue(const std::string& source);
  void next();
  void previous();
  std::vector<PlaylistItem> playlist() const;
  void playPlaylistItem(int index);
  void removePlaylistItem(int index);
  void clearPlaylist();
  void shufflePlaylist();
  void frameStep();
  void frameBackStep();
  void play();
  void pause();
  void togglePause();
  void stop();
  bool isPlaying() const;
  double timeSeconds() const;
  double durationSeconds() const;
  void seekSeconds(double seconds);
  float position() const;
  void setPosition(float position);
  void setRate(float rate);
  float rate() const;
  void setVolume(int volume);
  int volume() const;
  bool addSubtitle(const std::filesystem::path& path);
  bool snapshot(const std::filesystem::path& path, unsigned width = 0, unsigned height = 0);
  const std::string& source() const { return source_; }
  std::vector<std::pair<int, std::string>> audioTracks() const;
  std::vector<std::pair<int, std::string>> subtitleTracks() const;
  int currentAudioTrack() const;
  int currentSubtitleTrack() const;
  void setAudioTrack(int id);
  std::vector<AudioDevice> audioDevices() const;
  std::string currentAudioDevice() const;
  void setAudioDevice(const std::string& name);
  void setSubtitleTrack(int id);
  void setABLoop(double start, double end);
  void clearABLoop();
  void setAudioDelay(double seconds);
  double audioDelay() const;
  void setSubtitleDelay(double seconds);
  double subtitleDelay() const;
  void setAspect(const std::string& aspect);
  void setRotation(int degrees);
  void setDeinterlace(bool enabled);
  bool deinterlace() const;
  void setPerformanceProfile(PerformanceProfile profile);
  PerformanceProfile performanceProfile() const { return performance_profile_; }
  void setFileLoop(bool enabled);
  bool fileLoop() const;
  void toggleMute();
  bool muted() const;
  void nextChapter();
  void previousChapter();
  std::vector<ChapterItem> chapters() const;
  void seekChapter(int index);
  void setSubtitleVisible(bool visible);
  bool subtitleVisible() const;
  void setSubtitleScale(double scale);
  double subtitleScale() const;
  void setBrightness(double value);
  void setContrast(double value);
  void setSaturation(double value);
  void setGamma(double value);
  bool startRecording(const std::filesystem::path& output);
  void stopRecording();
  bool recording() const;
  std::string infoString(const char* property, const std::string& fallback = {}) const;
  double infoDouble(const char* property, double fallback = 0.0) const;
  int64_t infoInt(const char* property, int64_t fallback = 0) const;

  // Draws the current video frame into an OpenGL framebuffer. The caller owns
  // the framebuffer and must have its GL context current.
  void render(unsigned framebuffer, int width, int height);
  bool needsRender();
  void reportSwap();
  void processEvents();

 private:
  static void* getProcAddress(void* context, const char* name);
  static void requestRender(void* context);
  double getDouble(const char* property, double fallback = 0.0) const;
  int64_t getInt(const char* property, int64_t fallback = -1) const;
  bool getFlag(const char* property, bool fallback = false) const;
  void command(const char* name);
  std::vector<std::pair<int, std::string>> tracksOfType(const char* type) const;

  mpv_handle* handle_ = nullptr;
  mpv_render_context* render_ = nullptr;
  std::atomic<bool> render_requested_{true};
  std::string source_;
  PerformanceProfile performance_profile_ = PerformanceProfile::Balanced;
};

}  // namespace wam
