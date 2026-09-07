from pathlib import Path
import shutil,json,re,hashlib
r=Path('/private/tmp/wam-phase2f');d=Path('/Users/wesleymaa/Documents/WAM/docs/native-coverage/phase2f')
for name in ['shipped-final-build.json','ctest-shipped-final.txt','configure-shipped-final.txt','package-refresh.json','package-audit.json','packaging-final.txt','final-validation.py']:
 shutil.copyfile(r/name,d/name)
for p in r.glob('build-shipped-final-*.txt'):shutil.copyfile(p,d/p.name)
if (r/'ctest-shipped-final-rerun.txt').exists():shutil.copyfile(r/'ctest-shipped-final-rerun.txt',d/'ctest-shipped-final-rerun.txt')
candidate=json.loads((r/'shipped-final-build.json').read_text())['candidate_sha256']
lines=['# Final shipped measurements','','Fourteen-second quiet launches; AVFORMAT ON / AVCODEC OFF. CPU is percentage of one core; process energy is the sampler\'s process-J reading, not whole-machine energy. Native-refused rows may run the repaired bundled mpv fallback, so their costs must not be attributed to native software decoding. The OFF build does not consume the no-hardware seam.','','| Specimen | CPU % | Process J | Peak MiB | Native drawn / late / superseded |','| --- | ---: | ---: | ---: | --- |']
for mode in ['normal','no-hardware']:
 source=r/f'measure-final-{mode}';rows=json.loads((source/'results.json').read_text());shutil.copyfile(source/'results.json',d/f'measure-shipped-final-{mode}.json')
 target=d/'measurements-final'/mode
 for p in source.iterdir():
  if p.is_dir():
   t=target/p.name;t.mkdir(parents=True,exist_ok=True)
   for f in ['stdout.txt','stderr.txt','usage.json','metrics.jsonl']:shutil.copyfile(p/f,t/f)
 for row in rows:
  assert row['candidate_sha256']==candidate
  u=row['usage'];s=row['last_sample'] or {};native=row['first_frame'] and not row['failures'] and (s.get('drawn_frames') or 0)>0
  outcome=f"{s['drawn_frames']} / {s['discarded_late_frames']} / {s['superseded_frames']}" if native else 'Native refused'
  label=Path(row['asset']).stem+(' / no-HW seam' if mode=='no-hardware' else '')
  lines.append(f"| {label} | {u['cpu_percent_one_core']:.2f} | {u['energy_joules_process']:.3f} | {u['peak_footprint_bytes']/1048576:.1f} | {outcome} |")
lines+=['',f'Candidate `{candidate}`. Raw identities, logs, usage and streamed metrics are retained under `measurements-final/`. Sampler SHA-256 `8bdfb68e431544f2933f778c73a1f7fbdb3bfff453dc39e960d63efb658c5772`. Earlier `measurements/` files are intermediate pre-deadline/coexistence trials and are superseded by this table. These measurements do not assert an energy improvement over earlier campaigns.']
(d/'MEASUREMENTS.md').write_text('\n'.join(lines)+'\n')
import sys
if '--measure-only' in sys.argv:
 print('\n'.join(lines),flush=True);sys.exit(0)
source=r/'corpus-final';summary=json.loads((source/'summary.json').read_text());assert summary['candidate_sha256']==candidate
shutil.copyfile(source/'summary.json',d/'corpus-final-summary.json');shutil.copyfile(source/'results.json',d/'corpus-final-results.json')
for p in source.iterdir():
 if p.is_dir():
  t=d/'corpus-final'/p.name;t.mkdir(parents=True,exist_ok=True)
  for f in ['log.txt','metrics.jsonl']:
   if (p/f).exists():shutil.copyfile(p/f,t/f)
print(json.dumps(summary,indent=2));print('\n'.join(lines))
