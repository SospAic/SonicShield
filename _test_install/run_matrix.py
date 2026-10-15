"""install_all.bat 场景矩阵测试（可重复）。

场景：
  mixed    : 1 ready + 1 unauthorized + 1 offline（无线文件仅注释）
  none     : 0 台在线（wireless.txt 不存在）→ 无设备诊断路径
  sigfail  : install 报签名冲突 → 触发 uninstall 重装路径
  mdns     : wireless.txt 写 mdns 指令 → 走 auto-discovery 子程序
每个场景都跑全局负向断言（无 cmd 解析错误/无挂起/无中文乱码命令）。
"""
import os
import shutil
import subprocess
import sys
import tempfile

REPO = r'E:\SonicShield'

SCENARIOS = [
    # (name, scenario, wireless_content or None, [positive checks], [negative checks])
    ('mixed', 'mixed', '# mock\r\n',
     ['[Android] devices online: 1',
      '( BBBB2222 CCCC3333)',
      'unauthorized: ', 'offline',
      'Google Pixel7Pro', '[OK] installed',
      '[Android] success 1 / failed 0', 'DONE.'],
     ['is not recognized', 'Press any key', '系统找不到', 'missing']),
    ('none', 'none', None,
     ['[Android] devices online: 0',
      '( DDDD4444 EEEE5555)',
      'no device found',
      'USB调试', '开发者选项',
      '[Android] success 0 / failed 0', 'DONE.'],
     ['is not recognized', 'Press any key', '系统找不到']),
    ('sigfail', 'sigfail', '# mock\r\n',
     ['INSTALL_FAILED_UPDATE_INCOMPATIBLE',
      'uninstalling',
      '[OK] installed',
      '[Android] success 1 / failed 0'],
     ['is not recognized', 'Press any key', '系统找不到']),
    ('mdns', 'mdns', 'mdns\r\n',
     ['[mdns] discovering wireless devices',
      'found adb-XXYY12 -> connect 5555',
      'found adb-ZZWW34 -> connect 5556',
      '[Android] devices online: 1',
      'Google Pixel7Pro'],
     ['is not recognized', 'Press any key', '系统找不到']),
]


def run_scenario(name, scenario, wireless, positives, negatives):
    t = tempfile.mkdtemp(prefix='ss_%s_' % name)
    shutil.copy(os.path.join(REPO, 'install_all.bat'),
                os.path.join(t, 'install_all.bat'))
    src = os.path.join(t, 'install_all.bat')
    lines = open(src, 'rb').read().decode('utf-8').splitlines()
    lines = [l for l in lines if 'if not errorlevel 1 pause' not in l]
    open(src, 'wb').write('\r\n'.join(lines).encode('utf-8'))

    os.makedirs(os.path.join(t, 'releases'), exist_ok=True)
    os.makedirs(os.path.join(t, 'mock'), exist_ok=True)
    open(os.path.join(t, 'releases', 'SonicShield-Android.apk'), 'wb').write(b'x' * 512)
    if wireless is not None:
        with open(os.path.join(t, 'releases', 'wireless.txt'), 'wb') as f:
            f.write(wireless.encode('utf-8'))
    shutil.copy(os.path.join(REPO, '_test_install', 'mock', 'adb.cmd'),
                os.path.join(t, 'mock', 'adb.cmd'))

    env = dict(os.environ)
    env['PATH'] = os.path.join(t, 'mock') + ';' + env['PATH']
    env['SS_MOCK_SCENARIO'] = scenario
    r = subprocess.run(['cmd', '/c', 'install_all.bat'], cwd=t, env=env,
                       stdin=subprocess.DEVNULL, capture_output=True, timeout=120)
    out = r.stdout.decode('utf-8', 'replace') + r.stderr.decode('utf-8', 'replace')

    print('===== SCENARIO %s (exit=%s) =====' % (name, r.returncode))
    if '-v' in sys.argv:
        print(out)
    failed = 0
    for pat in positives:
        ok = pat in out
        print('  %s: %r' % ('PASS' if ok else 'FAIL', pat[:60]))
        failed += 0 if ok else 1
    for pat in negatives:
        ok = pat not in out
        print('  %s: no %r' % ('PASS' if ok else 'FAIL', pat[:60]))
        failed += 0 if ok else 1
    shutil.rmtree(t, ignore_errors=True)
    return failed


def main():
    only = [a for a in sys.argv[1:] if not a.startswith('-')]
    total = 0
    for name, scenario, wireless, pos, neg in SCENARIOS:
        if only and name not in only:
            continue
        total += run_scenario(name, scenario, wireless, pos, neg)
    print('===== MATRIX RESULT: %s =====' % ('ALL_PASS' if total == 0 else 'HAS_FAIL(%d)' % total))
    return 1 if total else 0


if __name__ == '__main__':
    sys.exit(main())
