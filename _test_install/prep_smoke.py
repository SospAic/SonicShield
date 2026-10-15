"""prepare_device.bat 冒烟测试：mock adb 记录调用，验证四态行为，绝不碰真机。"""
import os
import shutil
import subprocess
import sys
import tempfile

REPO = r'E:\SonicShield'

MOCK_ADB = '''@echo off
REM mock adb: logs every invocation to %TEMP%\\ss_mock_calls.log
set "LOG=%TEMP%\\ss_mock_calls.log"
echo %* >> "%LOG%"
if "%1"=="devices" (
  echo List of devices attached
  echo AAAA1111	device
  echo BBBB2222	unauthorized
  exit /b 0
)
if "%1"=="get-standby-bucket" (
  echo 10
  exit /b 0
)
if "%1"=="shell" (
  REM echo back a plausible value for settings get
  echo mock-value
  exit /b 0
)
exit /b 0
'''


def run(t, args, env):
    r = subprocess.run(['cmd', '/c', 'prepare_device.bat'] + args, cwd=t, env=env,
                       stdin=subprocess.DEVNULL, capture_output=True, timeout=60)
    return r.returncode, r.stdout.decode('utf-8', 'replace') + r.stderr.decode('utf-8', 'replace')


def main():
    t = tempfile.mkdtemp(prefix='ss_prep_')
    shutil.copy(os.path.join(REPO, 'prepare_device.bat'),
                os.path.join(t, 'prepare_device.bat'))
    mockdir = os.path.join(t, 'mock')
    os.makedirs(mockdir)
    p = os.path.join(mockdir, 'adb.cmd')
    open(p, 'wb').write(MOCK_ADB.replace('\n', '\r\n').encode('utf-8'))

    env = dict(os.environ)
    env['PATH'] = mockdir + ';' + env['PATH']
    env['TEMP'] = t  # so mock's log lands in the temp dir
    env['TMP'] = t
    logfile = os.path.join(t, 'ss_mock_calls.log')

    fails = 0

    # --- help ---
    rc, out = run(t, ['--help'], env)
    checks = [
        ('help rc=0', rc == 0),
        ('help prints usage', 'Usage: prepare_device.bat' in out),
        ('help no adb call', not os.path.exists(logfile)),
    ]
    # --- apply (two devices: 1 ready) ---
    if os.path.exists(logfile):
        os.remove(logfile)
    rc, out = run(t, [], env)
    calls = open(logfile, encoding='utf-8', errors='replace').read() if os.path.exists(logfile) else ''
    checks += [
        ('apply rc=0', rc == 0),
        ('apply runs stayon true', 'shell svc power stayon true' in calls),
        ('apply sets stay_on_while_plugged_in 3', 'shell settings put global stay_on_while_plugged_in 3' in calls),
        ('apply sets screen_off_timeout', 'shell settings put system screen_off_timeout 2147483647' in calls),
        ('apply locksettings', 'shell locksettings set-disabled true' in calls),
        ('apply keyevent 224 wakeup', 'shell input keyevent 224' in calls),
        ('apply doze whitelist', 'shell dumpsys deviceidle whitelist +com.sonicshield.sonic_shield' in calls),
        ('apply standby bucket', 'shell am set-standby-bucket com.sonicshield.sonic_shield active' in calls),
        ('apply exact alarm op', 'shell appops set com.sonicshield.sonic_shield SCHEDULE_EXACT_ALARM allow' in calls),
        ('apply only ready device', 'AAAA1111' in calls and 'BBBB2222' not in calls),
        ('apply summary printed', 'automation prep applied' in out and 'devices=1' in out),
    ]

    # --- verify ---
    if os.path.exists(logfile):
        os.remove(logfile)
    rc, out = run(t, ['--verify'], env)
    calls = open(logfile, encoding='utf-8', errors='replace').read() if os.path.exists(logfile) else ''
    checks += [
        ('verify rc=0', rc == 0),
        ('verify reads timeout', 'shell settings get system screen_off_timeout' in calls),
        ('verify reads standby bucket', 'shell am get-standby-bucket com.sonicshield.sonic_shield' in calls),
        ('verify writes nothing', 'settings put' not in calls),
        ('verify prints labels', 'screen_off_timeout' in out and 'standby_bucket' in out),
    ]

    # --- restore ---
    if os.path.exists(logfile):
        os.remove(logfile)
    rc, out = run(t, ['--restore'], env)
    calls = open(logfile, encoding='utf-8', errors='replace').read() if os.path.exists(logfile) else ''
    checks += [
        ('restore rc=0', rc == 0),
        ('restore timeout 30000', 'shell settings put system screen_off_timeout 30000' in calls),
        ('restore stayon false', 'shell svc power stayon false' in calls),
        ('restore keeps app whitelist', 'screen defaults restored' in out),
    ]

    # --- single device -s ---
    if os.path.exists(logfile):
        os.remove(logfile)
    rc, out = run(t, ['-s', 'emulator-5554'], env)
    calls = open(logfile, encoding='utf-8', errors='replace').read() if os.path.exists(logfile) else ''
    checks += [
        ('single rc=0', rc == 0),
        ('single targets given serial', '"emulator-5554"' in calls or '-s emulator-5554' in calls),
        ('single count=1', 'devices=1' in out),
    ]

    print('===== prepare_device.bat SMOKE =====')
    for name, ok in checks:
        print('%s: %s' % ('PASS' if ok else 'FAIL', name))
        if not ok:
            fails += 1
    print('===== RESULT: %s =====' % ('ALL_PASS' if fails == 0 else 'HAS_FAIL(%d)' % fails))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
