"""逐行打点：块外每行后插 echo [T##]，括号块内跳过。精确死亡定位。"""
import os
import shutil
import subprocess
import sys
import tempfile

REPO = r'E:\SonicShield'


def main():
    t = tempfile.mkdtemp(prefix='ss_lt_')
    shutil.copy(os.path.join(REPO, 'install_all.bat'),
                os.path.join(t, 'install_all.bat'))
    src = os.path.join(t, 'install_all.bat')
    raw = open(src, 'rb').read().decode('utf-8')
    raw = raw.replace('if not errorlevel 1 pause', 'if not errorlevel 1 rem')
    lines = raw.split('\r\n') if '\r\n' in raw else raw.split('\n')
    out = []
    depth = 0
    for i, l in enumerate(lines, 1):
        out.append(l)
        # 括号深度（粗略：只数未在引号内的 —— 本脚本 if exist "x" ( ... ) 模式）
        stripped = l
        opens = stripped.count('(') - stripped.count(')')
        if opens > 0:
            depth += opens
        elif opens < 0:
            depth += opens
        if depth <= 0:
            s = l.strip()
            if s and not s.startswith('REM') and not s.startswith('echo') \
                    and not s.startswith(':') and not s.startswith('title'):
                out.append('echo [T%d]' % i)
    open(src, 'wb').write('\r\n'.join(out).encode('utf-8'))

    os.makedirs(os.path.join(t, 'releases'), exist_ok=True)
    os.makedirs(os.path.join(t, 'mock'), exist_ok=True)
    open(os.path.join(t, 'releases', 'SonicShield-Android.apk'), 'wb').write(b'x' * 512)
    # 注意：用 CRLF 写无线文件（与 install_all.bat 一致）
    with open(os.path.join(t, 'releases', 'wireless.txt'), 'wb') as f:
        f.write(b'# mock\r\n')
    shutil.copy(os.path.join(REPO, '_test_install', 'mock', 'adb.cmd'),
                os.path.join(t, 'mock', 'adb.cmd'))

    env = dict(os.environ)
    env['PATH'] = os.path.join(t, 'mock') + ';' + env['PATH']
    r = subprocess.run(['cmd', '/c', 'install_all.bat'], cwd=t, env=env,
                       stdin=subprocess.DEVNULL, capture_output=True, timeout=90)
    txt = r.stdout.decode('utf-8', 'replace') + r.stderr.decode('utf-8', 'replace')
    print('EXIT=%s' % r.returncode)
    print(txt)
    return 0


if __name__ == '__main__':
    sys.exit(main())
