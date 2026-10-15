"""最小实验：定位 chcp 65001 下 REM 中文注释失效的规律。"""
import os
import subprocess
import sys
import tempfile

CASES = {
    'A_ascii_rem':      b'@echo off\r\nchcp 65001 >nul\r\nREM ---- plain ascii comment ----\r\necho OK_A\r\n',
    'B_fullwidth_comma': b'@echo off\r\nchcp 65001 >nul\r\nREM \xe8\xaf\xb7\xe6\xb3\xa8\xe6\x84\x8f\xef\xbc\x8c\xe7\xbb\xad\xe8\xa1\x8c\r\necho OK_B\r\n',
    'C_fullwidth_period': b'@echo off\r\nchcp 65001 >nul\r\nREM \xe7\xbb\x93\xe6\x9d\x9f\xe3\x80\x82\r\necho OK_C\r\n',
    'D_chinese_only':   b'@echo off\r\nchcp 65001 >nul\r\nREM \xe4\xb8\xad\xe6\x96\x87\xe6\xb3\xa8\xe9\x87\x8a\xe6\xb5\x8b\xe8\xaf\x95\r\necho OK_D\r\n',
    'E_chinese_ascii_mix': b'@echo off\r\nchcp 65001 >nul\r\nREM adb \xe8\xa7\xa3\xe6\x9e\x90\xe5\x88\xb0 PATH \xe9\x87\x8c\r\necho OK_E\r\n',
    'F_no_chcp':        b'@echo off\r\nREM \xe8\xaf\xb7\xe6\xb3\xa8\xe6\x84\x8f\xef\xbc\x8c\xe7\xbb\xad\xe8\xa1\x8c\r\necho OK_F\r\n',
    'G_echo_chinese':   b'@echo off\r\nchcp 65001 >nul\r\necho \xe4\xb8\xad\xe6\x96\x87 echo \xe6\xb5\x8b\xe8\xaf\x95\r\necho OK_G\r\n',
    'H_colon_comment':  b'@echo off\r\nchcp 65001 >nul\r\n:: \xe8\xaf\xb7\xe6\xb3\xa8\xe6\x84\x8f\xef\xbc\x8c\xe7\xbb\xad\xe8\xa1\x8c\r\necho OK_H\r\n',
}

t = tempfile.mkdtemp(prefix='ss_rem_')
for name, content in CASES.items():
    p = os.path.join(t, name + '.bat')
    open(p, 'wb').write(content)
    env = dict(os.environ)
    try:
        r = subprocess.run(['cmd', '/c', name + '.bat'], cwd=t, env=env,
                           stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
        txt = (r.stdout + r.stderr).decode('utf-8', 'replace').strip()
        safe = 'SAFE' if ('OK_' in txt and 'not recognized' not in txt) else 'BROKEN'
        print('%-20s %-7s out=%r rc=%s' % (name, safe, txt, r.returncode))
    except subprocess.TimeoutExpired:
        print('%-20s TIMEOUT' % name)
