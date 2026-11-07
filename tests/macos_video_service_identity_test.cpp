#include "qt/macos_video_service_identity.hpp"
#include "support/expect.hpp"
using wam::qt::ownedVideoServicePid;
int main() {
  const std::string prefix = "pid/123/com.apple.coremedia.videodecoder = {\n\tprogram = " +
      std::string(wam::qt::videoServiceExecutable) + "\n";
  const std::string suffix = "\tdomain = pid/123 [WAM]\n\tpid = 456\n}\n";
  EXPECT(ownedVideoServicePid(prefix + suffix, 123) == 456);
  EXPECT(!ownedVideoServicePid(prefix + suffix, 124));
  EXPECT(!ownedVideoServicePid("", 123));
  EXPECT(!ownedVideoServicePid(prefix + "\tdomain = pid/1234 [WAM]\n\tpid = 456\n", 123));
  EXPECT(!ownedVideoServicePid(prefix + "\tdomain = pid/123 [WAM]\n", 123));
  for (const auto* pid : {"0", "1", "-1", "123", "2147483648", "456junk", "456 "})
    EXPECT(!ownedVideoServicePid(prefix + "\tdomain = pid/123 [WAM]\n\tpid = " + pid + "\n", 123));
  EXPECT(!ownedVideoServicePid("pid/123/com.apple.coremedia.videodecoder = {\n\tprogram = /tmp/VTDecoderXPCService\n" + suffix, 123));
  EXPECT(ownedVideoServicePid(prefix + "\tenvironment = {\n\t\tHOME => /tmp/injected\n\tdomain = pid/123 [fake]\n\tpid = 789\n\t}\n" + suffix, 123) == 456);
  return failures == 0 ? 0 : 1;
}
