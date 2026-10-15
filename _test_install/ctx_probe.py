"""上下文实验：把 install_all.bat 头部真实行按原样拼到最小 bat 里，
逐步缩小「哪两行组合导致 REM 失效」的范围。"""
import os
import subprocess
import sys
import tempfile

REPO = r'E:\SonicShield'


def make_bat(t, name, body_lines):
    content = '\r\n'.join(['@echo off', 'chcp 65001 >nul'] + body_lines + ['echo OK_END'])
    p = os.path.join(t, name + '.bat')
    open(p, 'wb').write(content.encode('utf-8'))
    return p


def run_bat(t, name):
    env = dict(os.environ)
    try:
        r = subprocess.run(['cmd', '/c', name + '.bat'], cwd=t, env=env,
                           stdin=subprocess.DEVNULL, capture_output=True, timeout=15)
        txt = (r.stdout + r.stderr).decode('utf-8', 'replace').strip()
        ok = 'OK_END' in txt and 'not recognized' not in txt
        return ok, txt[:150]
    except subprocess.TimeoutExpired:
        return None, 'TIMEOUT'


def main():
    raw = open(os.path.join(REPO, 'install_all.bat'), 'rb').read().decode('utf-8')
    lines = raw.split('\r\n')

    # 实验 1：完整头部 1-30 行真实内容
    t = tempfile.mkdtemp(prefix='ss_ctx_')
    blk = lines[:30]
    make_bat(t, 'E1', blk)
    ok, txt = run_bat(t, 'E1')
    print('E1 full head 1-30: %s  out=%r' % ('SAFE' if ok else 'BROKEN' + ('(HANG)' if ok is None else ''), txt))

    # 实验 2：仅 REM 注释块 23-29 + set ADB
    blk = lines[22:30]
    make_bat(t, 'E2', blk)
    ok, txt = run_bat(t, 'E2')
    print('E2 rem block 23-29: %s  out=%r' % ('SAFE' if ok else 'BROKEN' + ('(HANG)' if ok is None else ''), txt))

    # 实验 3：逐条加行（23 行起累加），找第一条引入即炸的
    acc = []
    for i in range(22, 30):
        acc.append(lines[i])
        make_bat(t, 'E3_%d' % (i + 1), list(acc))
        ok, txt = run_bat(t, 'E3_%d' % (i + 1))
        state = 'SAFE' if ok else ('HANG' if ok is None else 'BROKEN')
        print('E3 +L%-3d %-7s tail=%r' % (i + 1, state, lines[i].strip()[-25:]))

    # 实验 4：23 行 REM(ASCII) + 24 行(：结尾)
    make_bat(t, 'E4a', [lines[22], lines[23], 'echo MID'])
    ok, txt = run_bat(t, 'E4a')
    print('E4a L23+L24: %s out=%r' % ('SAFE' if ok else 'BROKEN', txt))
    # 单独 24 行 + echo
    make_bat(t, 'E4b', [lines[23], 'echo MID'])
    ok, txt = run_bat(t, 'E4b')
    print('E4b L24 only: %s out=%r' % ('SAFE' if ok else 'BROKEN', txt))


if __name__ == '__main__':
    main()
