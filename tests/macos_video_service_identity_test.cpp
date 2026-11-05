#include "qt/macos_video_service_identity.hpp"
#include <cstdlib>
#include <iostream>
using wam::qt::ownedVideoServicePid;
void check(bool value) { if (!value) { std::cerr << "owned service identity failed\n"; std::exit(1); } }
int main() {
  const std::string prefix = "pid/123/com.apple.coremedia.videodecoder = {\n\tprogram = " +
      std::string(wam::qt::videoServiceExecutable) + "\n";
  const std::string suffix = "\tdomain = pid/123 [WAM]\n\tpid = 456\n}\n";
  check(ownedVideoServicePid(prefix + suffix, 123) == 456);
  check(!ownedVideoServicePid(prefix + suffix, 124));
  check(!ownedVideoServicePid("", 123));
  check(!ownedVideoServicePid(prefix + "\tdomain = pid/1234 [WAM]\n\tpid = 456\n", 123));
  check(!ownedVideoServicePid(prefix + "\tdomain = pid/123 [WAM]\n", 123));
  for (const auto* pid : {"0", "1", "-1", "123", "2147483648", "456junk", "456 "})
    check(!ownedVideoServicePid(prefix + "\tdomain = pid/123 [WAM]\n\tpid = " + pid + "\n", 123));
  check(!ownedVideoServicePid("pid/123/com.apple.coremedia.videodecoder = {\n\tprogram = /tmp/VTDecoderXPCService\n" + suffix, 123));
  check(ownedVideoServicePid(prefix + "\tenvironment = {\n\t\tHOME => /tmp/injected\n\tdomain = pid/123 [fake]\n\tpid = 789\n\t}\n" + suffix, 123) == 456);
}
