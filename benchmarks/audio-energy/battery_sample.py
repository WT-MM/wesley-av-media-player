#!/usr/bin/env python3
"""Read only battery/power fields; never serials or unrelated registry data."""
import argparse,subprocess,plistlib,time,json,pathlib
p=argparse.ArgumentParser();p.add_argument('--seconds',type=int,default=600);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
a.output.parent.mkdir(parents=True,exist_ok=True)
with a.output.open('x') as f:
 end=time.monotonic()+a.seconds
 while time.monotonic()<end:
  rows=plistlib.loads(subprocess.check_output(['/usr/sbin/ioreg','-r','-c','AppleSmartBattery','-a']))
  b=rows[0];t=b.get('PowerTelemetryData',{})
  row={'unix':time.time()}
  for k in ['UpdateTime','Voltage','Amperage','AppleRawCurrentCapacity','AppleRawMaxCapacity','NominalChargeCapacity','DesignCapacity','CurrentCapacity','ExternalConnected','IsCharging']:
   row[k]=b.get(k)
  for k in ['SystemLoad','BatteryPower','SystemPowerIn','AccumulatedSystemLoad','SystemLoadAccumulatorCount']:row[k]=t.get(k)
  f.write(json.dumps(row)+'\n');f.flush();time.sleep(2)
