#include "media/avcodec/api.hpp"
#include "media/avcodec/closure.hpp"
#include "media/avcodec/runtime.hpp"
#include "playback/mpv/mpv_runtime.hpp"
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QTemporaryDir>
#include <dlfcn.h>
#include <cstdio>
#include <cstring>
namespace wam::playback::mpv {
class MpvRuntimeTestAccess final {
public:
  static MpvRuntimeLoadResult load(const QString& directory) {return MpvRuntime::load(directory);}
};
}
#define CHECK(x) do { if(!(x)) {std::fprintf(stderr,"line %d: %s\n",__LINE__,#x);return 1;} } while(0)
int main(int argc,char** argv) {
  QCoreApplication app(argc,argv);
  using namespace wam::media::avcodec;
  using wam::playback::mpv::MpvRuntimeTestAccess;
  CHECK(argc==2);
  QTemporaryDir scratch("/private/tmp/wam-coexistence-XXXXXX");CHECK(scratch.isValid());
  const auto contents=scratch.path()+"/Fixture.app/Contents";
  CHECK(QDir().mkpath(contents+"/MacOS"));CHECK(QDir().mkpath(contents+"/Frameworks"));
  CHECK(QFile::copy(QString::fromLocal8Bit(argv[1]),contents+"/Frameworks/WAMMpvFallback.dylib"));
  RuntimeLease first,second;CHECK(!first.acquire());CHECK(!second.acquire());
  Dl_info symbol{};CHECK(dladdr(reinterpret_cast<void*>(api().avcodec_version),&symbol));
  CHECK(symbol.dli_fname && std::strstr(symbol.dli_fname,"libavcodec-wamnative."));
  const auto before=api().avcodec_version();
  auto refused=MpvRuntimeTestAccess::load(contents+"/MacOS");
  CHECK(!refused);CHECK(refused.detail=="DecoderUnavailable: PlaybackFfmpegClosureConflict");
  CHECK(nativeClosurePresent() && !foreignClosurePresent());CHECK(api().avcodec_version()==before);
  first.release();CHECK(nativeClosurePresent());CHECK(api().avcodec_version()==before);
  second.release();CHECK(!nativeClosurePresent());
  auto fallback=MpvRuntimeTestAccess::load(contents+"/MacOS");CHECK(fallback);
  CHECK(foreignClosurePresent() && !nativeClosurePresent());
  CHECK(dladdr(reinterpret_cast<void*>(fallback.runtime->api().mpv_client_api_version),&symbol));
  CHECK(symbol.dli_fname);
  fallback.runtime.reset();CHECK(foreignClosurePresent());
  const char* reason=first.acquire();CHECK(reason && std::strstr(reason,"PlaybackFfmpegClosureConflict"));
  CHECK(!nativeClosurePresent() && api().avcodec_version==nullptr);
  std::puts("native symbol owner verified; fallback refused with two native leases alive; native retirement zero images; cached fake fallback blocks later native by name; no duplicate codec images");
}
