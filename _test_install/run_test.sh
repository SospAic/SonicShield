#!/bin/bash
# install_all.bat 自动化验证（可重复）：
# ① 隔离环境中用 mock adb 跑脚本；② 断言关键输出；③ 不碰真实 releases/。
set -u
cd /e/SonicShield
T=$(mktemp -d)
cp install_all.bat "$T/install_all.bat"
# 副本去掉 pause（交互探测非业务逻辑，CI/无 stdin 环境必须去掉）
sed -i 's/^if not errorlevel 1 pause/if not errorlevel 1 rem/' "$T/install_all.bat"
mkdir -p "$T/releases" "$T/mock"
head -c 1024 /dev/urandom > "$T/releases/SonicShield-Android.apk"
echo "# mock wireless (empty)" > "$T/releases/wireless.txt"
cp _test_install/mock/adb.cmd "$T/mock/adb.cmd"
echo "TEST_DIR=$T"
cd "$T"
export PATH="$T/mock:$PATH"
# 关键：stdin 必须来自 /dev/null，且 cmdcmdline 里脚本以 call 形式调用
cmd //c install_all.bat < /dev/null > out.log 2>&1
rc=$?
echo "EXIT_CODE=$rc"
echo "===== OUTPUT ====="
cat out.log
echo "===== ASSERTIONS ====="
fail=0
check() { # name, pattern
  if grep -qF "$2" out.log; then
    echo "PASS: $1"
  else
    echo "FAIL: $1  (missing: $2)"
    fail=1
  fi
}
negcheck() { # name, must-not pattern
  if grep -qF "$2" out.log; then
    echo "FAIL: $1  (found forbidden: $2)"
    fail=1
  else
    echo "PASS: $1"
  fi
}
check "online count = 1"        "[Android] devices online: 1"
check "not-ready diag listed"    "( BBBB2222 9900ffdd0001 )"
check "unauthorized hint"        "unauthorized:"
check "offline hint"             "offline"
check "model shown"              "Google Pixel7Pro"
check "install OK"               "[OK] installed"
check "summary line"             "[Android] success 1 / failed 0"
negcheck "no cmd-recognized error" "is not recognized"
negcheck "no pause hang"           "Press any key"
echo "===== RESULT: $([ $fail = 0 ] && echo ALL_PASS || echo HAS_FAIL) ====="
rm -rf "$T"
exit $fail
