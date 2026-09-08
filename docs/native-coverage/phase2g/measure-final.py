from pathlib import Path
import json,subprocess
root=Path('/private/tmp/wam-phase2g');plan=json.loads((root/'measurement-plan.json').read_text())
for name,assets in plan.items():
 cmd=['python3','tests/native_avcodec_playback.py','--output',str(root/'measurements-registry-final'/name),'--sampler',str(root/'sampler')]
 if name=='no-hardware-seam':cmd+=['--no-hardware']
 for asset in assets:cmd+=['--asset',asset]
 subprocess.run(cmd,cwd='/private/tmp/wam-cov',check=True)
