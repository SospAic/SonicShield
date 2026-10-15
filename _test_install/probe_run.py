"""探针：无线文件放真条目 + adb 调用不吞输出。"""
import os
import shutil
import subprocess
import sys
import tempfile

REPO = r'E:\SonicShield'


def build(t, wireless_content, unredir_adb):
    shutil.copy(os.path.join(REPO, 'install_all.bat'),
                os.path.join(t, 'install_all.bat'))
    src = os.path.join(t, 'install_all.bat')
    raw = open(src, 'rb').read().decode('utf-8')
    raw = raw.replace('if not errorlevel 1 pause', 'if not errorlevel 1 rem')
    if unredir_adb:
        # 仅探针副本：去掉 adb 两行的输出重定向，让报错显形
        raw = raw.replace('"%ADB%" start-server >nul 2>&1', '"%ADB%" start-server')
        raw = raw.replace('"%ADB%" devices >"%DEV%" 2>nul', '"%ADB%" devices >"%DEV%"')
    open(src, 'wb').write(raw.encode('utf-8'))
    os.makedirs(os.path.join(t, 'releases'), exist_ok=True)
    os.makedirs(os.path.join(t, 'mock'), exist_ok=True)
    open(os.path.join(t, 'releases', 'SonicShield-Android.apk'), 'wb').write(b'x' * 512)
    open(os.path.join(t, 'releases', 'wireless.txt'), 'w', newline='').write(wireless_content)
    shutil.copy(os.path.join(REPO, '_test_install', 'mock', 'adb.cmd'),
                os.path.join(t, 'mock', 'adb.cmd'))


def run(t, label):
    env = dict(os.environ)
    env['PATH'] = os.path.join(t, 'mock') + ';' + env['PATH']
    try:
        r = subprocess.run(['cmd', '/c', 'install_all.bat'], cwd=t, env=env,
                           stdin=subprocess.DEVNULL, capture_output=True, timeout=90)
        txt = r.stdout.decode('utf-8', 'replace') + r.stderr.decode('utf-8', 'replace')
        print('=== %s EXIT=%s ===' % (label, r.returncode))
        print(txt)
    except subprocess.TimeoutExpired:
        print('=== %s TIMEOUT(hang) ===' % label)


t1 = tempfile.mkdtemp(prefix='ss_p1_')
build(t1, '192.168.1.9:5555\n', False)
run(t1, 'A: real wireless entry')

t2 = tempfile.mkdtemp(prefix='ss_p2_')
build(t2, '# mock\n', True)
run(t2, 'B: comment-only wireless + adb unredirected')
