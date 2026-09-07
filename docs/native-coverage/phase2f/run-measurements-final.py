import json,subprocess,pathlib
repo=pathlib.Path('/Users/wesleymaa/Documents/WAM');root=pathlib.Path('/private/tmp/wam-phase2f')
for mode,file in [('normal','measure-shipped.json'),('no-hardware','measure-shipped-no-hardware.json')]:
 rows=json.loads((repo/'docs/native-coverage/phase2e'/file).read_text())
 cmd=['python3',str(repo/'tests/native_avcodec_playback.py'),'--output',str(root/('measure-final-'+mode)),'--sampler',str(root/'sampler')]
 if mode=='no-hardware':cmd.append('--no-hardware')
 for row in rows:cmd+=['--asset',row['asset']]
 subprocess.run(cmd,check=True)
