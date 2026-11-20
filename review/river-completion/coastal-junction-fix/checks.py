from pathlib import Path
import subprocess
r=Path('review/river-completion/work/nov20-acceptance');binary='/tmp/evolving-nov20-release'
commands=[(name,[name]) for name in ['riverfixtures','riverroutingfixtures','riverterrainfixtures']]
commands += [(f'river-{s}',['river',str(s),'2336']) for s in list(range(1,18))+[6393821808673518700]]
commands += [(f'determinism-{s}-{i}',['determinism','2336',str(s)]) for s in [1,14,6393821808673518700] for i in [0,1]]
commands += [('river-saved-4594',['river','6393821808673518700','4594'])]
failed=[]
for name,args in commands:
 with (r/(name+'.txt')).open('w') as f:code=subprocess.run([binary]+args,stdout=f,stderr=subprocess.STDOUT).returncode
 print(name,code,flush=True)
 if code:failed.append(name)
if failed:raise SystemExit('FAILED '+str(failed))
