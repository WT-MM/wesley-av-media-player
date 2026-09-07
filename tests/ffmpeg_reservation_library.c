#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#define FFMIN(a,b) ((a)<(b)?(a):(b))
static atomic_size_t max_alloc_size=INT_MAX;
#include "../third_party/ffmpeg-patches/wam_memory_reservation.inc"
