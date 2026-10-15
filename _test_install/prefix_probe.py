"""前缀 bisect：head[0:k] + REM块(23-29) 找最小触发组合。"""
import os
import subprocess
import sys
import tempfile

REPO = r'E:\SonicShield'


def run_bat(t, name, content_lines):
    content = '\r\n'.join(content_lines)
    p = os.path.join(t, name + '.bat')
    open(p, 'wb').write(content.encode('utf-8'))
    env = dict(os.environ)
    try:
        r = subprocess.run(['cmd', '/c', name + '.bat'], cwd=t, env=env,
                           stdin=subprocess.DEVNULL, capture_output=True, timeout=15)
        txt = (r.stdout + r.stderr).decode('utf-8', 'replace').strip()
        ok = 'OK_END' in txt and 'not recognized' not in txt
        return (None if 'TIMEOUT' in txt else ok), txt[:120]
    except subprocess.TimeoutExpired:
        return None, 'TIMEOUT'


def main():
    raw = open(os.path.join(REPO, 'install_all.bat'), 'rb').read().decode('utf-8')
    lines = raw.split('\r\n')
    rem_block = lines[22:29]  # L23-29

    t = tempfile.mkdtemp(prefix='ss_pb_')

    # 二分：head[0:k] + rem_block
    lo, hi = 0, 23  # k in [lo, hi]
    # 先验证 k=23 = E1 BROKEN, k=0 = SAFE
    for k in [0, 5, 11, 14, 19, 22, 23]:
        content = ['@echo off'] if k == 0 else lines[0:k]
        ok, txt = run_bat(t, 'K%02d' % k, content + rem_block + ['echo OK_END'])
        state = 'SAFE' if ok else ('HANG' if ok is None else 'BROKEN')
        print('k=%-3d %-6s out=%r' % (k, state, txt[:100]))


if __name__ == '__main__':
    main()
