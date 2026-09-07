"""Temporary mutation, failing runtime proof, byte-identical restore and retest."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--output',required=True)
    parser.add_argument('--scratch',required=True)
    parser.add_argument('--groups',default='u8,rates,retry,retry-retirement,retry-source,he-aac,ebml,opus,notice,progress,progress-publication')
    a=parser.parse_args()
    repo=Path(__file__).resolve().parents[1]
    scratch=Path(a.scratch);scratch.mkdir(parents=True,exist_ok=True)
    output=Path(a.output);output.mkdir(parents=True,exist_ok=True)
    common=[sys.executable,'tests/native_coverage_integration.py','--audio','build/wam_native_coverage_audio_probe',
            '--source','build/wam_native_coverage_source_probe','--ffmpeg','/opt/homebrew/bin/ffmpeg']
    gui=[sys.executable,'tests/native_coverage_wiring_test.py','--app','build/WAM.app/Contents/MacOS/WAM',
         '--ffmpeg','/opt/homebrew/bin/ffmpeg','--slow-fixture','/private/tmp/wam-adversarial2/media/long70-4k.mp4']
    groups={
      'u8':('src/media/matroska_apple_audio.hpp',[("floating ? 1U : depth == 8 ? 0U : 4U","floating ? 1U : 4U")],common+['--case','pcm-u8']),
      'rates':('src/media/matroska_demuxer.cpp',[("nearestAudioPacketForMatroskaTick(","nearestAacAccessUnitForMatroskaTick("),("audioPacketGridTime(","aacAccessUnitGridTime(")],common+['--case','matroska-rates']),
      'retry':('src/media/native_media_dispatcher.cpp',[("if (mayRetryAudio && audioVerdict == OpenConfigureVerdict::Rejected &&","if (false && mayRetryAudio && audioVerdict == OpenConfigureVerdict::Rejected &&")],['build/wam_native_media_dispatcher_test']),
      'retry-retirement':('src/platform/macos/native_audio_session.mm',[("bool NativeAudioSession::resetRejectedConfiguration(\n    media::MediaGeneration generation) noexcept {","bool NativeAudioSession::resetRejectedConfiguration(\n    media::MediaGeneration generation) noexcept {\n  return false;")],gui+['--case','retry']),
      'retry-source':('src/media/matroska_demuxer.cpp',[("!rejectedAudio.contains(trackId(candidate.number).value_or(0)) &&","true &&")],gui+['--case','retry']),
      'he-aac':('src/media/matroska_demuxer.cpp',[("result.message = bestRefusal + \"; candidates: [\" + candidateRefusals + \"]\";","result.message = \"no selected audio candidate passed complete codec admission\";")],common+['--case','he-aac']),
      'ebml':('tests/native_coverage_integration.py',[("            while len(payload) >= (1 << (7*sw))-1:\n                sw += 1\n                assert sw <= 8, 'EBML payload exceeds finite size envelope'\n","")],common+['--case','opus']),
      'opus':('src/media/matroska_demuxer.cpp',[("OpusOutputSampleRateUnsupported","AudioCodecConfigurationRefused")],common+['--case','opus']),
      'notice':('src/qt/native_playback_owner.mm',[("if (admissionRouteChoice) {","if (false && admissionRouteChoice) {")],gui+['--case','notice']),
      'progress-publication':('src/platform/macos/native_media_session.mm',[("          progressCommitSeek();\n          publishMetrics();", "          progressCommitSeek();")],gui+['--case','progress']),
      'progress':('src/qt/native_playback_owner.mm',[("if (!nativeSeekProgress_.expired(progress.decodedPrerollFrames)) {","if (false && !nativeSeekProgress_.expired(progress.decodedPrerollFrames)) {")],gui+['--case','progress']),
    }
    report=output/'revert-proofs.json'
    receipts=json.loads(report.read_text()) if report.exists() else []
    def run(argv,log):
        with log.open('w') as stream:
            result=subprocess.run(argv,cwd=repo,stdout=stream,stderr=subprocess.STDOUT)
            if result.returncode in (-9,137):
                stream.write('\nEnvironmental launch kill; rerunning same binary.\n');stream.flush()
                result=subprocess.run(argv,cwd=repo,stdout=stream,stderr=subprocess.STDOUT)
        return result.returncode
    def build(log):
        rc=run(['cmake','--build','build','--parallel'],log)
        assert rc==0, f'build failed: {log}'
    build(scratch/'build-initial.log')
    for name in a.groups.split(','):
        filename,edits,test=groups[name]
        path=repo/filename;original=path.read_bytes();mutated=original.decode()
        for before,after in edits:
            assert before in mutated,(name,before)
            mutated=mutated.replace(before,after)
        row=dict(group=name,file=filename,original_sha256=hashlib.sha256(original).hexdigest(),test=test)
        assert run(test,output/f'{name}.before.log')==0, f'{name} baseline failed'
        print(f'{name}: baseline passed',flush=True)
        try:
            path.write_text(mutated)
            build(scratch/f'{name}.mutated-build.log')
            row['mutated_exit']=run(test,output/f'{name}.mutated.log')
            assert row['mutated_exit'] not in (0,-9,137), f'{name}: mutation survived or environmental failure'
        finally:
            path.write_bytes(original)
            assert path.read_bytes()==original
            row['restored_sha256']=hashlib.sha256(path.read_bytes()).hexdigest()
            build(scratch/f'{name}.restored-build.log')
        row['restored_exit']=run(test,output/f'{name}.restored.log')
        assert row['restored_exit']==0, f'{name}: restored test failed'
        row['byte_identical_restore']=row['original_sha256']==row['restored_sha256']
        row['restored_executable_sha256']=hashlib.sha256((repo/'build/WAM.app/Contents/MacOS/WAM').read_bytes()).hexdigest()
        receipts.append(row);report.write_text(json.dumps(receipts,indent=2)+'\n')
        print(f'{name}: mutation failed ({row["mutated_exit"]}); byte-identical restore passed',flush=True)


if __name__=='__main__':main()
