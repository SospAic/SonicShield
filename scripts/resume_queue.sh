#!/usr/bin/env bash
# ============================================================================
# 声盾 SonicShield · 任务队列驱动（可自动恢复）
#
# 用途：把「跨会话的长任务」落盘成队列，任何一次中断后都能**从断点继续**，
#       不必重新梳理上下文。与 DiskForge 的 `.workbuddy/automation/queue.json`
#       同族（那套已验证过的做法）。
#
# 用法：
#   bash scripts/resume_queue.sh           # 打印「下一个待办」+ 全队列概览
#   bash scripts/resume_queue.sh --json    # 只输出下一个待办项的 JSON（供自动化消费）
#
# 恢复协议（真源见 `.workbuddy-ai/queue.json` 的 `resumeProtocol`）：
#   取 status=='pending' 的最小 seq → 执行 → 置 'done' 并写证据（提交号/文件/输出）
#   → 全 done 则把自动化置 PAUSED。
#
# ⚠️ 队列文件是**本地**的（`.workbuddy-ai/` 在 .gitignore 内，不入库）；
#    本脚本入库，是为了把「恢复协议」本身变成**可执行、可审计**的东西 ——
#    否则它只是一段会漂移的散文。
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
Q="$ROOT/.workbuddy-ai/queue.json"

if [[ ! -f "$Q" ]]; then
  echo "queue.json 不存在：$Q" >&2
  echo "（首次使用请先创建，结构见 .workbuddy-ai/memory/ 里的说明）" >&2
  exit 2
fi

# 找一个可用的 python（本机 python 常不在 PATH，故带上受管 venv 兜底）。
PY=""
for c in python python3 \
         "D:/AppData/.workbuddy-ai/binaries/python/envs/default/Scripts/python.exe" \
         "C:/Users/sospa/.workbuddy-ai/binaries/python/envs/default/Scripts/python.exe"; do
  if command -v "$c" >/dev/null 2>&1 || [[ -x "$c" ]]; then PY="$c"; break; fi
done
if [[ -z "$PY" ]]; then
  echo "未找到 python，无法解析队列（可用编辑器直接读 $Q）" >&2
  exit 3
fi

MODE="${1:-}"

"$PY" - "$Q" "$MODE" <<'PYEOF'
import io, json, sys

path, mode = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "")
with io.open(path, encoding="utf-8") as f:
    q = json.load(f)

items = q.get("items", [])
pending = sorted([i for i in items if i.get("status") == "pending"], key=lambda x: x["seq"])
blocked = [i for i in items if i.get("status") == "blocked"]
done = [i for i in items if i.get("status") == "done"]

if mode == "--json":
    print(json.dumps(pending[0] if pending else {}, ensure_ascii=False))
    sys.exit(0)

print("项目：%s" % q.get("project"))
print("主题：%s" % q.get("topic"))
print("更新：%s" % q.get("updatedAt"))
print("-" * 68)
for i in items:
    mark = {"done": "[x]", "pending": "[ ]", "in_progress": "[~]", "blocked": "[!]"}.get(
        i.get("status"), "[?]")
    print("%s #%s %-10s %s" % (mark, i.get("seq"), i.get("id"), i.get("title")))
    if i.get("note"):
        print("        note: %s" % i["note"])
print("-" * 68)
print("进度：done=%d pending=%d blocked=%d / 共 %d" % (len(done), len(pending), len(blocked), len(items)))
if pending:
    n = pending[0]
    print(">>> 下一个待办： #%s %s" % (n.get("seq"), n.get("title")))
    print("    id=%s" % n.get("id"))
else:
    print(">>> 无 pending：若全部 done，请把自动化置 PAUSED。")
PYEOF
