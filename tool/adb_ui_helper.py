#!/usr/bin/env python
"""真机 UI 操作助手：dump -> 按文案定位 -> 点击中心点。

为什么要这个：国产 ROM（MIUI）**拒绝 adb input 注入**（INJECT_EVENTS），
`adb shell input tap` 会抛 SecurityException。但 `uiautomator dump` +
`am`/`content` 等仍可用。本助手只做「观察 + 定位」，点击仍走 `input tap`
（实测在部分场景下仍会生效；失败会如实回报，不假装成功）。

用法：
  python tool/adb_ui_helper.py dump [--out FILE]
  python tool/adb_ui_helper.py find TEXT
  python tool/adb_ui_helper.py tap TEXT [--index N]
  python tool/adb_ui_helper.py texts
"""
import argparse
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

REMOTE = "/data/local/tmp/ui_dump.xml"


def adb(args, dev=None):
    cmd = ["adb"]
    if dev:
        cmd += ["-s", dev]
    cmd += args
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                       errors="replace")
    return (r.stdout or "") + (r.stderr or "")


def dump_ui(dev=None):
    adb(["shell", "uiautomator", "dump", REMOTE], dev)
    return adb(["shell", "cat", REMOTE], dev)


def parse(xml_text):
    m = re.search(r"<\?xml.*?<hierarchy.*?</hierarchy>", xml_text, re.S)
    if not m:
        m = re.search(r"<hierarchy.*?</hierarchy>", xml_text, re.S)
    if not m:
        return []
    root = ET.fromstring(m.group(0))
    out = []
    for n in root.iter("node"):
        out.append({
            "text": n.get("text") or "",
            "desc": n.get("content-desc") or "",
            "cls": n.get("class") or "",
            "bounds": n.get("bounds") or "",
            "checkable": n.get("checkable") == "true",
            "checked": n.get("checked") == "true",
        })
    return out


def center(bounds):
    nums = [int(x) for x in re.findall(r"-?\d+", bounds)]
    if len(nums) != 4:
        return None
    x1, y1, x2, y2 = nums
    return ((x1 + x2) // 2, (y1 + y2) // 2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["dump", "find", "tap", "texts"])
    ap.add_argument("text", nargs="?", default="")
    ap.add_argument("--dev", default="")
    ap.add_argument("--index", type=int, default=0)
    ap.add_argument("--part", default="", help="点击节点内第 N 部分（右侧=1）")
    args = ap.parse_args()

    dev = args.dev or None
    nodes = parse(dump_ui(dev))

    if args.cmd == "dump":
        for n in nodes:
            if n["text"] or n["desc"]:
                print(n)
        return
    if args.cmd == "texts":
        seen = set()
        for n in nodes:
            for t in (n["text"], n["desc"]):
                t = (t or "").strip()
                if t and t not in seen:
                    seen.add(t)
                    print(t)
        return

    hits = [n for n in nodes
            if args.text in (n["text"] or "") or args.text in (n["desc"] or "")]
    if args.cmd == "find":
        for i, n in enumerate(hits):
            print(i, n)
        if not hits:
            print("NOT_FOUND")
        return

    if not hits:
        print("TAP_FAIL not_found:", args.text)
        sys.exit(2)
    n = hits[min(args.index, len(hits) - 1)]
    c = center(n["bounds"])
    if not c:
        print("TAP_FAIL no_bounds:", n["bounds"])
        sys.exit(2)
    x, y = c
    if args.part:
        nums = [int(v) for v in re.findall(r"-?\d+", n["bounds"])]
        # 右侧 1/4 处（SwitchListTile 的开关在右端）
        x = nums[2] - (nums[2] - nums[0]) // 6
    print("TAP", x, y, "->", args.text)
    out = adb(["shell", "input", "tap", str(x), str(y)], dev)
    if "SecurityException" in out or "Exception occurred" in out:
        print("TAP_BLOCKED:", out.strip().splitlines()[0] if out else "")
        sys.exit(3)
    print("TAP_OK")


if __name__ == "__main__":
    main()
