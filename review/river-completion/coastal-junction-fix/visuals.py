from pathlib import Path
import subprocess
r=Path('review/river-completion');out=r/'work'/'nov20-acceptance';binary='/tmp/evolving-nov20-release'
cases=list(sorted((r/'cases').glob('*.json')))+list(sorted(out.glob('seed14-coast-*.json')))
for case in cases:
 with (out/(case.stem+'-render.txt')).open('w') as f:subprocess.run([binary,'riverreview',str(case),str(out/'views'/case.stem),'all','--no-ids'],stdout=f,stderr=subprocess.STDOUT,check=True)
 print('captured',case.stem,flush=True)
for name,args in [('matrix',['riverreviewmatrix',str(out/'matrix')]),('material',['rivermaterialcheck',str(out/'material')]),('lake',['riverlakefixture',str(out/'lake')]),('camera',['cameracheck',str(out/'camera')])]:
 with (out/(name+'.txt')).open('w') as f:subprocess.run([binary]+args,stdout=f,stderr=subprocess.STDOUT,check=True)
 print(name,'PASS',flush=True)
