import json, pathlib, subprocess, tempfile, shutil
root=pathlib.Path.cwd()
lab=pathlib.Path(tempfile.mkdtemp(prefix='.sandbox-proof-',dir=root))
def run(args,cwd=None,ok=True):
    p=subprocess.run(args,cwd=cwd or root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    print('$ '+ ' '.join(map(str,args)),flush=True)
    print(p.stdout,end='',flush=True)
    print('exit='+str(p.returncode),flush=True)
    if ok: assert p.returncode==0
    return p
try:
    proj=lab/'project'; wt=lab/'worker'; home=lab/'home'; proj.mkdir(); (home/'data').mkdir(parents=True); (home/'state').mkdir()
    run(['git','init','-q','-b','main',str(proj)])
    run(['git','config','user.name','Sandbox Proof'],proj);run(['git','config','user.email','proof@example.invalid'],proj)
    (proj/'initial').write_text('initial\n');run(['git','add','.'],proj);run(['git','commit','-qm','initial'],proj)
    run(['git','worktree','add','-q','-b','fixture',str(wt)],proj)
    task='sandbox-proof';data=home/'data'/task;status=home/'state'/(task+'.status');inbox=home/'state'/(task+'.inbox')
    lib=root/'bin/fm-codex-workspace-write-lib.sh'
    p=run(['bash','-c','source "$1"; fm_codex_workspace_write_prepare "${@:2}" && fm_codex_workspace_write_roots "${@:2}"','_',str(lib),str(wt),str(data),str(status),str(inbox),task])
    grants=p.stdout.strip().splitlines();assert len(grants)==9
    (inbox/'001.msg').write_text('steering\n')
    def sandbox(script,roots):
        return run(['codex','sandbox','-c','sandbox_mode="workspace-write"','-c','sandbox_workspace_write.writable_roots='+json.dumps(roots), '--','/bin/bash','-c',script],cwd=wt,ok=False)
    baseline=sandbox('git checkout -b fm/'+task,[])
    assert baseline.returncode!=0,'Baseline unexpectedly writable'
    script='''set -e
git checkout -b fm/"$1"
printf 'ok\\n' > live-ok.txt
git add live-ok.txt
git commit -m sandbox-proof
printf 'LIVE\\n' > "$2/report.md"
printf 'done-sandbox-proof\\n' >> "$3"
mv "$4/001.msg" "$4/handled/"
git log -1 --format='%h %s'
cat "$2/report.md" "$3" "$4/handled/001.msg"
'''
    import shlex
    cmd='/bin/bash -c '+shlex.quote(script)+' _ '+ ' '.join(shlex.quote(str(x)) for x in [task,data,status,inbox])
    success=sandbox(cmd,grants);assert success.returncode==0,'Granted writes failed'
    for label,script in [('sibling ref','git update-ref refs/heads/fm/sibling HEAD'),('sibling status','echo bad > '+shlex.quote(str(home/'state/sibling.status'))),('shared config','echo bad >> '+shlex.quote(str(proj/'.git/config')))]:
        denial=sandbox(script,grants);assert denial.returncode!=0,label+' unexpectedly writable'
    assert (data/'report.md').read_text()=='LIVE\n'
    assert status.read_text()=='done-sandbox-proof\n'
    assert (inbox/'handled/001.msg').read_text()=='steering\n'
    assert not (proj/'.git/refs/heads/fm/sibling').exists()
    assert not (home/'state/sibling.status').exists()
    print('VERIFIED: denied without grant; branch, commit, report, outcome and inbox acknowledgement succeed with grant; sibling refs/status and shared config remain denied.')
finally:
    shutil.rmtree(lab)
