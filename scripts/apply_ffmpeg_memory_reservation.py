"""Apply the local LGPL worker allocator patch to the pinned FFmpeg source."""
import pathlib,sys
source=pathlib.Path(sys.argv[1]);repo=pathlib.Path(__file__).resolve().parents[1]
p=source/'libavutil/mem.c';s=p.read_text()
start=s.index('void *av_malloc(size_t size)\n{');end=s.index('void *av_realloc_f(',start)
s=s[:start]+'#include "wam_memory_reservation.inc"\n\n'+s[end:]
start=s.index('void av_free(void *ptr)\n{');end=s.index('void av_freep(',start)
s=s[:start]+s[end:];p.write_text(s)
(source/'libavutil/wam_memory_reservation.inc').write_bytes((repo/'third_party/ffmpeg-patches/wam_memory_reservation.inc').read_bytes())
