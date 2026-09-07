#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
#define FFMIN(a,b) ((a)<(b)?(a):(b))
static atomic_size_t max_alloc_size=INT_MAX;
#include "../third_party/ffmpeg-patches/wam_memory_reservation.inc"
#define CHECK(x) do { if(!(x)) { fprintf(stderr,"line %d: %s\n",__LINE__,#x);return 1; } } while(0)
int main(void) {
 void* domain=av_wam_reservation_begin(1024);CHECK(domain);
 void* p=av_malloc(512);CHECK(p && (uintptr_t)p%64==0);memset(p,42,512);
 CHECK(!av_malloc(512));CHECK(av_wam_reservation_exhausted(domain));
 CHECK(!av_realloc(p,768));CHECK(((unsigned char*)p)[511]==42);
 av_free(p);CHECK(av_wam_reservation_end(domain)==0);
 domain=av_wam_reservation_begin(2048);CHECK(domain);p=av_malloc(512);memset(p,42,512);
 p=av_realloc(p,768);CHECK(p && ((unsigned char*)p)[511]==42);
 av_free(p);CHECK(av_wam_reservation_end(domain)==0);
 puts("allocation cap, alignment, realloc peak and retirement passed");return 0;
}
