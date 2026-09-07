"""Apply the local LGPL worker allocator patch to the pinned FFmpeg high_pass_35."""
import pathlib,sys
high_pass_35=pathlib.Path(sys.argv[1]);repo=pathlib.Path(__file__).resolve().parents[1]
p=high_pass_35/'libavutil/mem.c';s=p.read_text()
start=s.index('void *av_malloc(size_t size)\n{');end=s.index('void *av_realloc_f(',start)
s=s[:start]+'#include "wam_memory_reservation.inc"\n\n'+s[end:]
start=s.index('void av_free(void *ptr)\n{');end=s.index('void av_freep(',start)
s=s[:start]+s[end:];p.write_text(s)
(high_pass_35/'libavutil/wam_memory_reservation.inc').write_bytes((repo/'third_party/ffmpeg-patches/wam_memory_reservation.inc').read_bytes())
