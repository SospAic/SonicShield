"""install_all.bat 自动化验证（可重复）。

- 在隔离临时目录复制 install_all.bat 并去除 pause 行（交互探测非业务逻辑）
- mock adb 提供 1 ready / 1 unauthorized / 1 offline 三态设备
- 断言：在线数、未就绪诊断、型号显示、安装成功摘要、无 cmd 解析错误
"""
import os
import shutil
import subprocess
import sys
import tempfile

REPO = r'E:\SonicShield'


def main():
    t = tempfile.mkdtemp(prefix='ss_it_')
    print('TMP_DIR=%s' % t)
    # 1) 复制脚本（去 pause 行）+ 造 releases 目录
    shutil.copy(os.path.join(REPO, 'install_all.bat'),
                os.path.join(t, 'install_all.bat'))
    src = os.path.join(t, 'install_all.bat')
    lines = open(src, 'rb').read().decode('utf-8').splitlines()
    lines = [l for l in lines if 'if not errorlevel 1 pause' not in l]
    open(src, 'wb').write('\r\n'.join(lines).encode('utf-8'))

    os.makedirs(os.path.join(t, 'releases'), exist_ok=True)
    os.makedirs(os.path.join(t, 'mock'), exist_ok=True)
    open(os.path.join(t, 'releases', 'SonicShield-Android.apk'), 'wb').write(b'x' * 512)
    open(os.path.join(t, 'releases', 'wireless.txt'), 'w').write('# mock\n')
    shutil.copy(os.path.join(REPO, '_test_install', 'mock', 'adb.cmd'),
                os.path.join(t, 'mock', 'adb.cmd'))

    # 2) 跑（mock 目录优先 PATH；stdin=DEVNULL）
    env = dict(os.environ)
    env['PATH'] = os.path.join(t, 'mock') + ';' + env['PATH']
    r = subprocess.run(['cmd', '/c', 'install_all.bat'], cwd=t, env=env,
                       stdin=subprocess.DEVNULL, capture_output=True, timeout=120)
    out = r.stdout.decode('utf-8', 'replace') + r.stderr.decode('utf-8', 'replace')
    print('EXIT_CODE=%s' % r.returncode)
    print('===== OUTPUT =====')
    print(out)

    # 3) 断言
    checks = [
        ('online count = 1', '[Android] devices online: 1'),
        ('not-ready serials listed', ' BBBB2222 CCCC3333'),
        ('unauthorized hint', 'unauthorized: '),
        ('offline hint', 'offline'),
        ('model shown', 'Google Pixel7Pro'),
        ('install OK', '[OK] installed'),
        ('summary', '[Android] success 1 / failed 0'),
        ('done banner', 'DONE.'),
    ]
    print('===== ASSERTIONS =====')
    failed = 0
    for name, pat in checks:
        ok = pat in out
        print('%s: %s' % ('PASS' if ok else 'FAIL', name))
        if not ok:
            failed += 1
    for bad in ('is not recognized', 'Press any key', '系统找不到'):
        ok = bad not in out
        print('%s: no %r' % ('PASS' if ok else 'FAIL', bad))
        if not ok:
            failed += 1
    print('===== RESULT: %s =====' % ('ALL_PASS' if failed == 0 else 'HAS_FAIL(%d)' % failed))
    # 保留目录供调试
    print('KEEP=%s' % t)
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
