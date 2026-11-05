#pragma once

#include <charconv>
#include <optional>
#include <string>
#include <string_view>

namespace wam::qt {
inline constexpr std::string_view videoServiceName = "com.apple.coremedia.videodecoder";
inline constexpr std::string_view videoServiceExecutable =
    "/System/Library/Frameworks/VideoToolbox.framework/Versions/A/XPCServices/"
    "VTDecoderXPCService.xpc/Contents/MacOS/VTDecoderXPCService";

// Fail closed on unknown launchctl output. The actual domain/pid fields follow
// the environment blocks, so embedded newlines in inherited environment values
// cannot nominate a different PID. OS process identity is checked separately.
inline std::optional<int> ownedVideoServicePid(std::string_view text, int self) {
  const std::string target = "pid/" + std::to_string(self);
  if (!text.starts_with(target + "/" + std::string(videoServiceName) + " = {\n")) return {};
  const auto program = text.find("\n\tprogram = ");
  if (program == text.npos ||
      !text.substr(program).starts_with("\n\tprogram = " + std::string(videoServiceExecutable) + "\n")) return {};
  const auto domain = text.rfind("\n\tdomain = ");
  if (domain == text.npos || !text.substr(domain).starts_with("\n\tdomain = " + target + " [")) return {};
  const auto field = text.find("\n\tpid = ", domain);
  if (field == text.npos) return {};
  const auto start = text.data() + field + 8;
  int pid = 0;
  const auto parsed = std::from_chars(start, text.data() + text.size(), pid);
  if (parsed.ec != std::errc{} || parsed.ptr == text.data() + text.size() ||
      *parsed.ptr != '\n' || pid <= 1 || pid == self) return {};
  return pid;
}
} // namespace wam::qt
