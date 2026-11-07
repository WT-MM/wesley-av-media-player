#include "media/avcodec/api.hpp"
#include "media/avcodec/closure.hpp"
#include "media/avcodec/runtime.hpp"
#include "fakes/mpv_runtime/mpv_runtime_test_access.hpp"
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QTemporaryDir>
#include <dlfcn.h>
#include <cstdio>
#include <cstring>
#include "support/expect.hpp"
int main(int argc,char** argv) {
  QCoreApplication app(argc,argv);
  using namespace wam::media::avcodec;
  using wam::playback::mpv::MpvRuntimeTestAccess;
  REQUIRE(argc==2);
  QTemporaryDir scratch("/private/tmp/wam-coexistence-XXXXXX");REQUIRE(scratch.isValid());
  const auto contents=scratch.path()+"/Fixture.app/Contents";
  REQUIRE(QDir().mkpath(contents+"/MacOS"));REQUIRE(QDir().mkpath(contents+"/Frameworks"));
  REQUIRE(QFile::copy(QString::fromLocal8Bit(argv[1]),contents+"/Frameworks/WAMMpvFallback.dylib"));
  RuntimeLease first,second;REQUIRE(!first.acquire());REQUIRE(!second.acquire());
  Dl_info symbol{};REQUIRE(dladdr(reinterpret_cast<void*>(api().avcodec_version),&symbol));
  EXPECT(symbol.dli_fname && std::strstr(symbol.dli_fname,"libavcodec-wamnative."));
  const auto before=api().avcodec_version();
  auto fallback=MpvRuntimeTestAccess::load(contents+"/MacOS");REQUIRE(fallback);
  EXPECT(nativeClosurePresent() && foreignClosurePresent());EXPECT(api().avcodec_version()==before);
  first.release();EXPECT(nativeClosurePresent());EXPECT(api().avcodec_version()==before);
  second.release();EXPECT(!nativeClosurePresent());
  EXPECT(foreignClosurePresent() && !nativeClosurePresent());
  REQUIRE(dladdr(reinterpret_cast<void*>(fallback.runtime->api().mpv_client_api_version),&symbol));
  EXPECT(symbol.dli_fname);
  fallback.runtime.reset();EXPECT(foreignClosurePresent());
  REQUIRE(!first.acquire());REQUIRE(!second.acquire());
  EXPECT(nativeClosurePresent() && foreignClosurePresent());
  EXPECT(api().avcodec_version()==before);
  REQUIRE(dladdr(reinterpret_cast<void*>(api().avcodec_version),&symbol));
  EXPECT(symbol.dli_fname && std::strstr(symbol.dli_fname,"libavcodec-wamnative."));
  first.release();EXPECT(nativeClosurePresent());second.release();
  EXPECT(!nativeClosurePresent() && api().avcodec_version==nullptr);
  std::puts("both load orders preserve native symbol ownership and leases; cached fallback permits later native sessions");
  return failures == 0 ? 0 : 1;
}
