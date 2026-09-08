from pathlib import Path
exec(Path('/private/tmp/wam-phase2g/revert-proofs.py').read_text().split("proof('hardware-parser'")[0].replace("/revert-proofs'","/shipped-revert-proofs'"))
def hardware_mutant():
 p=repo/'src/media/matroska_demuxer.cpp';s=p.read_text().replace('  codecLimits.admitHardwareH264Profiles = true;','');p.write_text(s)
proof('shipped-matroska-hardware',['src/media/matroska_demuxer.cpp'],[('hi10',['build/wam_native_coverage_source_probe','/private/tmp/wam-ffmpeg-phase2/long/hi10p.mkv']),('422',['build/wam_native_coverage_source_probe','/private/tmp/wam-ffmpeg-phase2/long/h264422.mkv'])],hardware_mutant)
proof('hardware-decode-plan',['src/platform/macos/native_video_decode_plan.hpp'],[('444',ct('^native_phase2g_444'))])
