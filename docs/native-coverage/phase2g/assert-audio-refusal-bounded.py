import pathlib,subprocess,shlex,sys
root=pathlib.Path('/private/tmp/wam-phase2g');repo=pathlib.Path('/private/tmp/wam-cov')
src=root/'audio-edit-refusal-probe.mm';src.write_text((repo/'tests/native_coverage_audio_probe.mm').read_text().replace('timeline.trimAfterCeiling = true;','timeline.trimAfterCeiling = false;'))
commands=subprocess.check_output(['ninja','-C','build','-t','commands','wam_native_coverage_audio_probe'],text=True).splitlines()
compile=shlex.split(next(x for x in commands if x.endswith('-c /tmp/wam-cov/tests/native_coverage_audio_probe.mm')))
for flag in ['-MF','-MT','-o']:compile[compile.index(flag)+1]=str(root/('audio-edit-refusal-probe.o.d' if flag=='-MF' else 'audio-edit-refusal-probe.o'))
compile[-1]=str(src);subprocess.run(compile,cwd=repo/'build',check=True)
link=shlex.split(commands[-1].removeprefix(': && ').removesuffix(' && :'))
link=[str(root/'audio-edit-refusal-probe.o') if x.endswith('/tests/native_coverage_audio_probe.mm.o') else x for x in link]
link[link.index('-o')+1]=str(root/'audio-edit-refusal-probe');subprocess.run(link,cwd=repo/'build',check=True)
r=subprocess.run([str(root/'audio-edit-refusal-probe'),'/Users/wesleymaa/Downloads/PXL_20250729_045448421.mp4',str(root/'audio-edit-refusal-proof.f32')],capture_output=True,text=True)
print(r.returncode,r.stdout,r.stderr)
sys.exit(0 if 'CoreMediaAudioEditExactTimelineProofMissing' in (r.stdout+r.stderr) else 1)
