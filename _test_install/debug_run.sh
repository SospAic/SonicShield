#!/bin/bash
# 调试版：保留临时目录，便于查看中间产物
set -u
cd /e/SonicShield
T="/c/Users/sospa/AppData/Local/Temp/ss_it_debug"
rm -rf "$T"; mkdir -p "$T/releases" "$T/mock"
cp install_all.bat "$T/install_all.bat"
sed -i 's/^if not errorlevel 1 pause/if not errorlevel 1 rem/' "$T/install_all.bat"
echo "=== sed 后脚本尾部 5 行（验证 pause 行被替换） ==="
tail -5 "$T/install_all.bat"
head -c 512 /dev/urandom > "$T/releases/SonicShield-Android.apk"
echo "# mock" > "$T/releases/wireless.txt"
cp _test_install/mock/adb.cmd "$T/mock/adb.cmd"
echo "=== 跑 bat（MSYS_NO_PATHCONV=1 防路径转换） ==="
cd "$T"
MSYS_NO_PATHCONV=1 cmd /c install_all.bat < /dev/null > out.log 2>&1
echo "EXIT=$?"
echo "=== 输出 ==="
cat out.log
echo "TMP_DIR=$T"
