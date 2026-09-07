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
  auto fallback=MpvRuntimeTestAccess::load(contents+"/MacOS");CHECK(fallback);
  CHECK(nativeClosurePresent() && foreignClosurePresent());CHECK(api().avcodec_version()==before);
  first.release();CHECK(nativeClosurePresent());CHECK(api().avcodec_version()==before);
  second.release();CHECK(!nativeClosurePresent());
  CHECK(foreignClosurePresent() && !nativeClosurePresent());
  CHECK(dladdr(reinterpret_cast<void*>(fallback.runtime->api().mpv_client_api_version),&symbol));
  CHECK(symbol.dli_fname);
  fallback.runtime.reset();CHECK(foreignClosurePresent());
  CHECK(!first.acquire());CHECK(!second.acquire());
  CHECK(nativeClosurePresent() && foreignClosurePresent());
  CHECK(api().avcodec_version()==before);
  CHECK(dladdr(reinterpret_cast<void*>(api().avcodec_version),&symbol));
  CHECK(symbol.dli_fname && std::strstr(symbol.dli_fname,"libavcodec-wamnative."));
  first.release();CHECK(nativeClosurePresent());second.release();
  CHECK(!nativeClosurePresent() && api().avcodec_version==nullptr);
  std::puts("both load orders preserve native symbol ownership and leases; cached fallback permits later native sessions");
}
