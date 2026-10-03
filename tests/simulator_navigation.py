"""Drive DEBUG-only local WEB fixtures in the booted iOS Simulator."""
import json, os, pathlib, subprocess, sys, time

device=sys.argv[1]
bundle='com.miuiproking.OneWinClock'
container=pathlib.Path(subprocess.check_output(['xcrun','simctl','get_app_container',device,bundle,'data'],text=True).strip())
documents=container/'Documents'
evidence=pathlib.Path.cwd()/'navigation-evidence'; evidence.mkdir(exist_ok=True)

def wait(stage):
    deadline=time.monotonic()+45
    while time.monotonic()<deadline:
        try:
            report=json.loads((documents/'navigation-audit.json').read_text())
            (evidence/'navigation-audit.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
            if report['stage']==stage:
                assert all(report['checks'].values()),report
                return report
        except (FileNotFoundError,json.JSONDecodeError):pass
        time.sleep(.5)
    subprocess.run(['xcrun','simctl','io',device,'screenshot',str(evidence/('timeout-'+stage+'.png'))],check=False)
    raise TimeoutError('Navigation audit did not reach '+stage+'; last report='+json.dumps(report))

wait('list')
for stage in ['list','open','detail','back','forward','reload','home','switch','restore','picker','sites','search','settings','reserve','reserve-home','live-switch','live-many','live-sites','live-close-web']:
    if stage!='list':
        temporary=documents/'navigation-command.new'
        temporary.write_text(stage)
        os.replace(temporary,documents/'navigation-command.txt')
        report=wait(stage)
    time.sleep(.7) # Let UIKit finish layout/animations before capturing the screen.
    if stage in ['list','open','detail','switch','restore','sites','search','settings','live-sites','live-close-web']:
        subprocess.run(['xcrun','simctl','io',device,'screenshot',str(evidence/(stage+'.png'))],check=True)
report=wait('live-close-web')
(evidence/'navigation-audit.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
assert len(report['checks'])==19,report
print('PASS: 19 WEB navigation/live checks (local fixtures), including retained DOM/scroll, history and reserve switching.')
