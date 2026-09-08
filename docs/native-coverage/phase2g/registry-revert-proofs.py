from revert_proof_support import create_runner

proof,ct=create_runner('/private/tmp/wam-phase2g/registry-revert-proofs')
proof('registry-lifetime',['src/platform/macos/native_audio_session.mm','src/platform/macos/native_video_consumer.mm'],[('audio',ct('^native_process_registry_audio_exit$')),('video',ct('^native_process_registry_video_exit$'))])
