from revert_proof_support import create_runner

proof,ct=create_runner('/private/tmp/wam-phase2g/revert-proofs')
proof('hardware-parser',['src/media/video_codec_configuration.cpp'],[('parser',ct('^video_codec_configuration$')),('444',ct('^native_phase2g_444'))])
proof('ambient-admission',['src/media/native_media_source.cpp'],[('source',ct('^macos_avfoundation_media_source$'))])
proof('source-metadata',['src/platform/macos/avfoundation_media_source.mm'],[('source',ct('^macos_avfoundation_media_source$')),('444-source',['build/wam_native_coverage_source_probe','tests/fixtures/native-phase2g/444-709.mp4'])])
proof('decoder-output',['src/platform/macos/video_toolbox_decoder.mm'],[('444',ct('^native_phase2g_444')),('ambient',ct('^native_phase2g_hlg'))])
proof('display-range',['src/platform/macos/native_layer_host_view.mm'],[('layer',ct('^macos_native_layer_video_output$'))])
proof('software-hdr',['src/media/software_color_qualification.hpp'],[('color',ct('^software_color_qualification$'))])
proof('scenegraph-refusal',['src/platform/macos/native_presentation_admission.hpp'],[('consumer',ct('^macos_native_video_consumer$'))])

proof("audio-edit-refusal",["src/platform/macos/native_audio_converter.mm"],[("refusal",["python3","/private/tmp/wam-phase2g/assert-audio-refusal.py"])])
