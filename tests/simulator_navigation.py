"""Drive DEBUG-only local WEB fixtures in the booted iOS Simulator."""
import json, pathlib, subprocess, sys, time

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
            if report['stage']==stage:
                assert all(report['checks'].values()),report
                return report
        except (FileNotFoundError,json.JSONDecodeError):pass
        time.sleep(.5)
    raise TimeoutError('Navigation audit did not reach '+stage)

wait('list')
for stage in ['list','open','detail','back','forward','reload','home','switch','restore','picker','sites','search','settings','reserve','reserve-home']:
    if stage!='list':
        (documents/'navigation-command.txt').write_text(stage)
        report=wait(stage)
    time.sleep(.7) # Let UIKit finish layout/animations before capturing the screen.
    if stage in ['list','open','detail','switch','restore','sites','search','settings']:
        subprocess.run(['xcrun','simctl','io',device,'screenshot',str(evidence/(stage+'.png'))],check=True)
report=wait('reserve-home')
(evidence/'navigation-audit.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
assert len(report['checks'])==15,report
print('PASS: 15 WEB navigation checks (local fixtures), including retained DOM/scroll, history and reserve switching.')
