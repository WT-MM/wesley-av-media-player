#include "media/avcodec/runtime.hpp"
#include "media/avcodec/api.hpp"
#include "media/avcodec/closure.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "support/expect.hpp"
using namespace wam::media::avcodec;
int main(int argc, char** argv) {
  EXPECT(!nativeClosurePresent());
  EXPECT(api().avcodec_version == nullptr);
  RuntimeLease first;
  const char* failure = first.acquire();
  if (argc == 2) {
    REQUIRE(failure && std::strstr(failure, argv[1]));
    EXPECT(!nativeClosurePresent());
    EXPECT(api().avcodec_version == nullptr);
    std::puts(failure);
    return failures == 0 ? 0 : 1;
  }
  if (failure) std::fprintf(stderr,"%s\n",failure);
  REQUIRE(!failure);
  REQUIRE(nativeClosurePresent());
  EXPECT(!foreignClosurePresent());
  EXPECT(api().avcodec_version() == LIBAVCODEC_VERSION_INT);
  EXPECT(api().avutil_version() == LIBAVUTIL_VERSION_INT);
  RuntimeLease second;
  EXPECT(!second.acquire());
  first.release();
  EXPECT(nativeClosurePresent());
  second.release();
  EXPECT(!nativeClosurePresent());
  EXPECT(api().avcodec_version == nullptr);
  EXPECT(!runtimeFailure());
  EXPECT(!nativeClosurePresent());
  std::puts("cold: zero images/symbols; leased: codec=63.1.101 util=61.1.101; retirement: zero images/symbols");
  return failures == 0 ? 0 : 1;
}
