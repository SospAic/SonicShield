"""用 install_all.bat 里真实的 REM 行逐条实验，找出触发失效的精确行。"""
import os
import re
import subprocess
import sys
import tempfile

REPO = r'E:\SonicShield'


def main():
    raw = open(os.path.join(REPO, 'install_all.bat'), 'rb').read()
    text = raw.decode('utf-8')
    lines = text.split('\r\n')
    t = tempfile.mkdtemp(prefix='ss_real_')
    i = 0
    for ln, line in enumerate(lines, 1):
        if not line.startswith('REM'):
            continue
        i += 1
        name = 'L%03d' % ln
        content = '@echo off\r\nchcp 65001 >nul\r\n%s\r\necho OK_%s\r\n' % (line, name)
        p = os.path.join(t, name + '.bat')
        open(p, 'wb').write(content.encode('utf-8'))
        env = dict(os.environ)
        try:
            r = subprocess.run(['cmd', '/c', name + '.bat'], cwd=t, env=env,
                               stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
            txt = (r.stdout + r.stderr).decode('utf-8', 'replace').strip()
            ok = ('OK_' + name) in txt
            mark = 'SAFE ' if ok else 'BROKEN'
            print('%s L%-4d %s' % (mark, ln, line.strip()[:60]))
            if not ok:
                print('        out=%r rc=%s' % (txt[:200], r.returncode))
        except subprocess.TimeoutExpired:
            print('HANG  L%d %s' % (ln, line.strip()[:60]))


if __name__ == '__main__':
    main()
