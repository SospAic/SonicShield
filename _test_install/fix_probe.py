"""验证修复候选：
A. UTF-8 BOM + 原中文 REM（cmd.exe 对带 BOM 的 bat 应按 UTF-8 解析）
B. 无 BOM + REM 全 ASCII
C. 无 BOM + 原中文 REM（对照组，应 BROKEN）
"""
import os
import subprocess
import sys
import tempfile

REPO = r'E:\SonicShield'


def run_bat(t, name, content_bytes):
    p = os.path.join(t, name + '.bat')
    open(p, 'wb').write(content_bytes)
    env = dict(os.environ)
    try:
        r = subprocess.run(['cmd', '/c', name + '.bat'], cwd=t, env=env,
                           stdin=subprocess.DEVNULL, capture_output=True, timeout=15)
        txt = (r.stdout + r.stderr).decode('utf-8', 'replace')
        ok = 'OK_END' in txt and 'not recognized' not in txt
        return ok, txt.strip()[:120].replace('\r', '').replace('\n', ' | ')
    except subprocess.TimeoutExpired:
        return None, 'TIMEOUT'


def main():
    raw = open(os.path.join(REPO, 'install_all.bat'), 'rb').read().decode('utf-8')
    lines = raw.split('\r\n')
    head = '\r\n'.join(lines[0:30]) + '\r\n' + 'echo OK_END\r\n'
    head_b = head.encode('utf-8')

    # B 方案：REM 中文 -> ASCII（把 L24-27 与 L82-83 换掉）
    ascii_rem = lines[:]
    ascii_rem[23] = 'REM   NOTE: every adb invocation below uses the call prefix.'
    ascii_rem[24] = 'REM   If PATH resolves adb to a .cmd/.bat shim instead of .exe,'
    ascii_rem[25] = 'REM   a non-call batch invocation transfers control and never returns:'
    ascii_rem[26] = 'REM   under cmd /c the child batch exit /b kills the whole cmd.exe,'
    ascii_rem[27] = 'REM   silently ending this script with exit code 0. Do not remove call.'
    head_ascii = '\r\n'.join(ascii_rem[0:30]) + '\r\n' + 'echo OK_END\r\n'

    t = tempfile.mkdtemp(prefix='ss_fix_')
    for label, data in [
        ('C_no_bom_chinese_rem (control)', head_b),
        ('A_bom_chinese_rem', b'\xef\xbb\xbf' + head_b),
        ('B_ascii_rem_no_bom', head_ascii.encode('utf-8')),
    ]:
        ok, txt = run_bat(t, label[0], data)
        state = 'SAFE' if ok else ('HANG' if ok is None else 'BROKEN')
        print('%-32s %-6s %s' % (label, state, txt))


if __name__ == '__main__':
    main()
