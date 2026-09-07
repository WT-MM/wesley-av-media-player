#include "media/avcodec/runtime.hpp"
#include "media/avcodec/api.hpp"
#include "media/avcodec/closure.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>
using namespace wam::media::avcodec;
#define CHECK(x) do { if (!(x)) { std::fprintf(stderr,"line %d: %s\n",__LINE__,#x); std::abort(); } } while (0)
int main(int argc, char** argv) {
  CHECK(!nativeClosurePresent());
  CHECK(api().avcodec_version == nullptr);
  RuntimeLease first;
  const char* failure = first.acquire();
  if (argc == 2) {
    CHECK(failure && std::strstr(failure, argv[1]));
    CHECK(!nativeClosurePresent());
    CHECK(api().avcodec_version == nullptr);
    std::puts(failure);
    return 0;
  }
  if (failure) std::fprintf(stderr,"%s\n",failure);
  CHECK(!failure);
  CHECK(nativeClosurePresent());
  CHECK(!foreignClosurePresent());
  CHECK(api().avcodec_version() == AV_VERSION_INT(63,1,101));
  CHECK(api().avutil_version() == AV_VERSION_INT(61,1,101));
  RuntimeLease second;
  CHECK(!second.acquire());
  first.release();
  CHECK(nativeClosurePresent());
  second.release();
  CHECK(!nativeClosurePresent());
  CHECK(api().avcodec_version == nullptr);
  CHECK(!runtimeFailure());
  CHECK(!nativeClosurePresent());
  std::puts("cold: zero images/symbols; leased: codec=63.1.101 util=61.1.101; retirement: zero images/symbols");
}
