#pragma once

#include "cancellation.hpp"

#include <atomic>
#include <filesystem>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace wam {

// Export presets, not a codec zoo. Each one names a container AND the codec
// pair that container is actually good at, because the interesting choice a
// user makes here is "what do I need this file to do" -- play on a phone, go
// in a web page, stay lossless, become a reaction image -- and never "which
// entropy coder".
//
// The enumerator VALUES are persisted through the QML surface and the
// controller property, so they are append-only.
enum class ExportFormat : int {
  Mp4H264 = 0,  // Default. Hardware h264_videotoolbox, exactly as before.
  Mp4Hevc = 1,  // hevc_videotoolbox; half the size, narrower playback support.
  WebmVp9 = 2,  // libvpx-vp9 + Opus. SOFTWARE, and therefore slow.
  MkvCopy = 3,  // Stream copy when that is legal; see exportUsesStreamCopy.
  Gif = 4,      // Palette-optimized, capped in both fps and duration.
};

// A crop rectangle in NORMALIZED source coordinates: the fraction of the
// source frame, not pixels. Storing it this way is what lets the same
// rectangle be drawn over a video item of any on-screen size and still map to
// exact source pixels at export time -- the ffmpeg `crop` filter is given the
// fractions and multiplies by `iw`/`ih` itself, so no dimension probe, no
// display-scale arithmetic, and no rounding happens on this side at all.
struct CropRect {
  double x = 0.0;
  double y = 0.0;
  double width = 1.0;
  double height = 1.0;

  // A rectangle that selects the whole frame is not a crop. Compared with a
  // tolerance because the value arrives from a pointer drag through a double.
  [[nodiscard]] bool active() const;
};

struct EditOptions {
  std::filesystem::path input;
  std::filesystem::path output;
  double in_seconds = 0.0;
  double out_seconds = 0.0;
  double speed = 1.0;
  bool preserve_pitch = true;
  bool prefer_hardware_encoder = true;
  ExportFormat format = ExportFormat::Mp4H264;
  CropRect crop{};
};

// The filename extension the muxer for `format` is selected by. FFmpeg picks
// its muxer from the OUTPUT PATH, and the path it is actually handed is the
// staging file, so this governs the staging suffix too.
[[nodiscard]] const char* exportFormatExtension(ExportFormat format);

// True when the request can be satisfied without re-encoding a single frame.
// Stream copy cannot retime and cannot crop, because it never decodes; those
// two conditions are the whole rule.
//
// CAVEAT that must reach the user, not just this header: a copied trim starts
// at the nearest keyframe at or before the in point, because the first packet
// of a copied stream has to be a keyframe. The out point is exact.
[[nodiscard]] bool exportUsesStreamCopy(const EditOptions& options);

// The `crop` filter expression for a normalized rectangle, or an empty string
// when the rectangle selects everything.
//
// EVEN-DIMENSION RULE: every one of width, height, x and y is rounded DOWN to
// an even number of source pixels (`floor(iw*f/2)*2`). H.264, HEVC and VP9 in
// 4:2:0 all subsample chroma by two, so an odd width or an odd offset either
// fails outright or silently shifts the chroma planes by half a pixel. Down,
// not nearest, so the result can never exceed the rectangle the user drew or
// run past the frame edge.
[[nodiscard]] std::string cropFilter(const CropRect& crop);

// GIF is capped on both axes, and the caps are stated here so the UI can name
// the same numbers it will actually get.
inline constexpr double kGifMaximumOutputSeconds = 15.0;
inline constexpr int kGifFramesPerSecond = 15;
inline constexpr int kGifMaximumWidth = 640;

// A shell-free child process description. Arguments are UTF-8 on every
// platform; the executable remains a filesystem path so Windows can launch it
// through its native wide-character API without lossy conversion.
struct ProcessCommand {
  std::filesystem::path executable;
  std::vector<std::string> arguments;
};

std::string quoteArg(const std::string& value);
std::string atempoFilter(double speed);
std::string varispeedFilter(double speed);
std::string buildExportCommand(const std::filesystem::path& ffmpeg,
                               const EditOptions& options);
ProcessCommand buildExportProcess(const std::filesystem::path& ffmpeg,
                                  const EditOptions& options);

// Export transactions encode into a reserved same-directory file, then use a
// single filesystem replacement only after a non-empty result is verified.
std::filesystem::path reserveExportStagingFile(
    const std::filesystem::path& destination, std::string* error = nullptr);
bool commitExportStagingFile(const std::filesystem::path& staging,
                             const std::filesystem::path& destination,
                             std::string* error = nullptr);
void removeExportStagingFile(
    const std::filesystem::path& staging) noexcept;

class BackgroundJob {
 public:
  BackgroundJob() = default;
  ~BackgroundJob();
  BackgroundJob(const BackgroundJob&) = delete;
  BackgroundJob& operator=(const BackgroundJob&) = delete;

  bool start(std::string label, std::string command);
  bool start(std::string label, ProcessCommand command);
  bool running() const { return running_.load(); }
  bool succeeded() const { return finished_.load() && exit_code_.load() == 0; }
  bool finished() const { return finished_.load(); }
  int exitCode() const { return exit_code_.load(); }
  std::string label() const;
  void cancel() noexcept;
  void wait();
  void reset();

 private:
  bool startWorker(std::string label,
                   std::function<int(const detail::CancellationFlag&)>
                       operation);

  std::thread worker_;
  detail::CancellationFlag cancellation_;
  mutable std::mutex worker_mutex_;
  std::atomic<bool> running_{false};
  std::atomic<bool> finished_{false};
  std::atomic<int> exit_code_{-1};
  mutable std::mutex label_mutex_;
  std::string label_;
};

// Every external file WAM launches or loads is located through one ordered
// search, most trusted first:
//
//   1. the runtime packaged inside the app, so a shipping build never depends
//      on anything installed on the host;
//   2. the developer runtime beside the build tree (`build/runtime`), which is
//      what scripts/build_whisper.sh and scripts/fetch_whisper_model.sh fill;
//   3. an explicit environment override (WAM_FFMPEG, WAM_WHISPER_CLI,
//      WAM_WHISPER_MODEL);
//   4. the standard package-manager prefixes;
//   5. PATH.
//
// PATH is deliberately last and never the whole answer. A GUI launch goes
// through LaunchServices, which hands the process the stock
// /usr/bin:/bin:/usr/sbin:/sbin -- no /opt/homebrew/bin -- so a PATH-only
// lookup fails for every launch that did not come from a shell even when the
// tool is installed.
struct ToolSearch {
  std::string tool;                               // "FFmpeg"
  std::string file;                               // "ffmpeg"
  std::vector<std::filesystem::path> candidates;  // probe order
};

// Answers whether one candidate is usable. Injected so the ordering can be
// tested without touching the filesystem.
using ToolProbe = std::function<bool(const std::filesystem::path&)>;

ToolSearch executableSearch(const char* tool, const char* file,
                            const char* argv0);
ToolSearch captionModelSearch(const char* argv0);

// Pure over `probe`: the first accepted candidate, or an empty path.
std::filesystem::path resolveTool(const ToolSearch& search,
                                  const ToolProbe& probe);

// Real-filesystem probes: a regular file that is executable, and a regular
// non-empty file respectively.
bool toolIsExecutable(const std::filesystem::path& path);
bool toolFileExists(const std::filesystem::path& path);

// Names what was looked for and every place it was looked in, for the
// error/notice channel.
std::string toolSearchFailure(const ToolSearch& search);

// Best-effort convenience wrappers over the search above. They fall back to
// the bare name / the packaged location so callers that only need a path keep
// a non-empty result; callers that must report a failure should run the search
// themselves and use toolSearchFailure().
std::filesystem::path findBundledTool(const char* executable, const char* argv0);
std::filesystem::path defaultWhisperModel(const char* argv0);

}  // namespace wam
