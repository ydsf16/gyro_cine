#!/usr/bin/env python3
"""Monitor an explicitly launched DEBUG --format-matrix run and resume failed cases.
Requires devicectl, an installed Debug app, and a connected/unlocked device.
This tool does not install builds or change user accounts."""
import argparse,subprocess,time,json,pathlib
parser=argparse.ArgumentParser()
parser.add_argument('--device',required=True)
parser.add_argument('--output',required=True,type=pathlib.Path)
args=parser.parse_args()
D=args.device; B='com.tinygrape.RawMotionRecorder'; root=args.output; root.mkdir(parents=True,exist_ok=True)
def run(args):
 return subprocess.run(['xcrun','devicectl',*args],capture_output=True,text=True,timeout=45)
last=None; retries=0; failures=0
while True:
 try:
  r=run(['device','copy','from','--device',D,'--domain-type','appDataContainer','--domain-identifier',B,'--source','Documents/Log/format-matrix/progress.json','--destination',str(root/'progress.json')])
  if r.returncode: raise RuntimeError(r.stderr[-300:])
  p=json.loads((root/'progress.json').read_text()); key=(p['phase'],p.get('index',p.get('nextIndex')))
  if key!=last: print(time.strftime('%H:%M:%S'),json.dumps(p),flush=True);last=key
  failures=0
  if p['phase']=='completed': break
  if p['phase']=='halted':
   retries+=1
   if retries>50: print('STOP too many failing cases',flush=True);break
   run(['device','copy','from','--device',D,'--domain-type','appDataContainer','--domain-identifier',B,'--source','Documents/Log/format-matrix','--destination',str(root)])
   r=run(['device','process','launch','--device',D,'--terminate-existing',B,'--','--format-matrix',f"--matrix-start-index={p['nextIndex']}",'--ssd-matrix','--ssd-duration=3','--ssd-verify-decode','-storageLocation','内部文件','-outputFormat','SonyMov','-lutBurnEnabled','NO','-previewLUTEnabled','NO','-debugEnabled','YES'])
   print('resumed',r.returncode,flush=True);time.sleep(5)
 except Exception as e:
  failures+=1;print('connection',str(e),flush=True)
  if failures>=3: break
 time.sleep(8)
r=run(['device','copy','from','--device',D,'--domain-type','appDataContainer','--domain-identifier',B,'--source','Documents/Log/format-matrix','--destination',str(root)])
print('FINAL',r.returncode,flush=True)
