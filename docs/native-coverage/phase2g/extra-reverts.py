from pathlib import Path
exec(Path('/private/tmp/wam-phase2g/revert-proofs.py').read_text().split("proof('hardware-parser'")[0].replace("/revert-proofs'","/extra-revert-proofs'"))
def tuple_mutant():
 p=repo/'src/media/native_media_source.cpp';s=p.read_text();a=s.index('  const bool qualified444 =');b=s.index('  return qualified444',a);s=s[:a]+'  const bool qualified444 = true;\n'+s[b:];s=s.replace('!video.fullRangeVideo && ','');p.write_text(s)
proof('qualified-tuple-boundary',['src/media/native_media_source.cpp'],[('source',ct('^macos_avfoundation_media_source$'))],tuple_mutant)
def range_mutant():
 p=repo/'src/platform/macos/avfoundation_media_source.mm';s=p.read_text().replace('video.fullRangeVideo = range && CFEqual(range, kCFBooleanTrue);','video.fullRangeVideo = false;');p.write_text(s)
 p=repo/'src/media/matroska_demuxer.cpp';s=p.read_text().replace('format.fullRangeVideo = colour.range ? *colour.range == 2 : facts.color.fullRange;','format.fullRangeVideo = false;');p.write_text(s)
proof('range-source',['src/platform/macos/avfoundation_media_source.mm','src/media/matroska_demuxer.cpp'],[('source',ct('^macos_avfoundation_media_source$')),('matroska',ct('^matroska_demuxer$'))],range_mutant)
proof('audio-edit-refusal-corrected',['src/platform/macos/native_audio_converter.mm'],[('refusal',['python3','/private/tmp/wam-phase2g/assert-audio-refusal-bounded.py'])])
def dts_mutant():
 p=repo/'src/media/software_audio_packet.hpp';s=p.read_text().replace('bytes != packetBytes','bytes > packetBytes');p.write_text(s)
proof('dts-core-extension',['src/media/software_audio_packet.hpp'],[('packet',ct('^software_audio_packet$'))],dts_mutant)
