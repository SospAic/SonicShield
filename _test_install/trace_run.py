"""打点版：在 install_all.bat 副本每 N 行插 echo [TRACE] 定位静默死亡点。"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

REPO = r'E:\SonicShield'


def main():
    t = tempfile.mkdtemp(prefix='ss_trace_')
    print('TMP=%s' % t)
    shutil.copy(os.path.join(REPO, 'install_all.bat'),
                os.path.join(t, 'install_all.bat'))
    src = os.path.join(t, 'install_all.bat')
    raw = open(src, 'rb').read().decode('utf-8')
    # 去 pause
    raw = raw.replace('if not errorlevel 1 pause', 'if not errorlevel 1 rem')
    lines = raw.splitlines()
    # 打点：每 3 行插一行 TRACE（跳过 for 块内，因为不能破坏括号！只插在行级）
    out = []
    in_paren = 0
    for i, l in enumerate(lines, 1):
        out.append(l)
        # 简化：计算行内括号平衡，仅在块外插点
        opens = l.count('(') - l.count(')')
        in_paren += opens
        if in_paren <= 0 and i % 3 == 0 and l.strip() and not l.strip().startswith('REM') \
                and not l.strip().startswith('echo') and not l.strip().startswith(':'):
            out.append('echo [TRACE] after line %d' % i)
    open(src, 'wb').write('\r\n'.join(out).encode('utf-8'))

    os.makedirs(os.path.join(t, 'releases'), exist_ok=True)
    os.makedirs(os.path.join(t, 'mock'), exist_ok=True)
    open(os.path.join(t, 'releases', 'SonicShield-Android.apk'), 'wb').write(b'x' * 512)
    open(os.path.join(t, 'releases', 'wireless.txt'), 'w').write('# mock\n')
    shutil.copy(os.path.join(REPO, '_test_install', 'mock', 'adb.cmd'),
                os.path.join(t, 'mock', 'adb.cmd'))

    env = dict(os.environ)
    env['PATH'] = os.path.join(t, 'mock') + ';' + env['PATH']
    print('PATHEXT=%r' % env.get('PATHEXT'))
    r = subprocess.run(['cmd', '/c', 'install_all.bat'], cwd=t, env=env,
                       stdin=subprocess.DEVNULL, capture_output=True, timeout=120)
    txt = r.stdout.decode('utf-8', 'replace') + r.stderr.decode('utf-8', 'replace')
    print('EXIT=%s' % r.returncode)
    print(txt)
    # 打印 DEV 内容
    dev = os.path.join(os.environ.get('TEMP', t), 'ss_devices.txt')
    print('--- ss_devices.txt ---')
    try:
        print(open(dev, encoding='utf-8', errors='replace').read())
    except OSError as e:
        print('cannot read: %s' % e)
    return 0


if __name__ == '__main__':
    sys.exit(main())
