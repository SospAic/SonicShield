#!/usr/bin/env python3
"""生成声盾 SonicShield 的全套应用图标（Android mipmap + iOS AppIcon）。

## 为什么用脚本而不是手放 PNG

FR-83（第八十四轮用户明文）要求「应用图标按用户拟定样式替换」。图标是**多密度、
双平台、共 20+ 个文件**的资源，手工逐个导出必然漂移（尺寸错、漏密度、忘记 iOS）。
脚本化后：
  - **可复现**：任何时候 `python tool/gen_icon.py` 都产出同一套图（几何全部由代码定义）；
  - **可校验**：`tool/verify_icon.py` + `test/app_icon_lock_test.dart` 逐文件核对
    尺寸/存在性/入库状态 —— 人工核对会漏，机器不会。

## 图形（用户拟定风格：深色底 + 盾牌 + 声波）

  - 背景：深蓝黑渐变（品牌主色，衬托"声盾"的守护感）
  - 主体：青绿色盾牌轮廓（守护）+ 白色同心声波弧线（声音）
  - 圆角：Android 自适应背景由 `mipmap-anydpi-v26` 的 XML 提供前景/背景分层，
    本脚本产出**传统方图**（各密度 `ic_launcher.png`），兼容 API 24–25。

用法：
    python tool/gen_icon.py            # 生成全套
    python tool/gen_icon.py --check    # 只校验，不写文件（CI 可用）
"""

from __future__ import annotations

import argparse
import os
import sys

from PIL import Image, ImageDraw

# ── 品牌色（与 lib/core/theme.dart 的 AppColors 同源；此处为脚本内常量） ──
BG_TOP = (13, 27, 42)       # 深蓝黑（渐变上）
BG_BOTTOM = (8, 16, 26)     # 更深的蓝黑（渐变下）
SHIELD_FILL = (0, 168, 150)  # 青绿（盾牌填充，品牌主色）
SHIELD_EDGE = (0, 220, 196)  # 亮青（盾牌描边高光）
WAVE = (235, 255, 252)       # 近白（声波弧线，保证深色底上高对比）

# Android 传统图标密度 → 边长（px），与 res/mipmap-*/ 约定一致。
ANDROID_SIZES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}

# iOS AppIcon 文件名 → 边长（px）。与现有 Contents.json 的条目一一对应。
IOS_SIZES = {
    "Icon-App-20x20@1x.png": 20,
    "Icon-App-20x20@2x.png": 40,
    "Icon-App-20x20@3x.png": 60,
    "Icon-App-29x29@1x.png": 29,
    "Icon-App-29x29@2x.png": 58,
    "Icon-App-29x29@3x.png": 87,
    "Icon-App-40x40@1x.png": 40,
    "Icon-App-40x40@2x.png": 80,
    "Icon-App-40x40@3x.png": 120,
    "Icon-App-60x60@2x.png": 120,
    "Icon-App-60x60@3x.png": 180,
    "Icon-App-76x76@1x.png": 76,
    "Icon-App-76x76@2x.png": 152,
    "Icon-App-83.5x83.5@2x.png": 167,
    "Icon-App-1024x1024@1x.png": 1024,
}

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _lerp(a: tuple[int, int, int], b: tuple[int, int, int], t: float):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def render(size: int) -> Image.Image:
    """按目标边长渲染一张图标（背景渐变 + 盾牌 + 声波）。"""
    # 超采样 4× 再缩小 ⇒ 边缘平滑（无需依赖字体/矢量库）。
    ss = 4
    S = size * ss
    img = Image.new("RGB", (S, S), BG_BOTTOM)

    # ── 1) 竖向渐变背景 ──
    d = ImageDraw.Draw(img)
    for y in range(S):
        d.line([(0, y), (S, y)], fill=_lerp(BG_TOP, BG_BOTTOM, y / max(1, S - 1)))

    # ── 2) 盾牌（居中，宽 = 0.56S，高 = 0.68S） ──
    cx, cy = S / 2, S * 0.52
    w, h = S * 0.56, S * 0.68
    left, top, right = cx - w / 2, cy - h / 2, cx + w / 2

    def shield_pts(inset: float):
        """盾牌轮廓：顶边平直 + 两侧下收 + 底部尖。inset 为内缩比例。"""
        l, t, r = left + inset, top + inset, right - inset
        b = top + h - inset
        mid = (l + r) / 2
        # 顶部两角带圆（用贝塞尔近似为多点折线）
        return [
            (l + w * 0.06, t),
            (r - w * 0.06, t),
            (r, t + h * 0.12),
            (r, b - h * 0.28),
            (mid, b),
            (l, b - h * 0.28),
            (l, t + h * 0.12),
        ]

    d.polygon(shield_pts(S * 0.012), fill=SHIELD_EDGE)          # 描边（外扩）
    d.polygon(shield_pts(S * 0.022), fill=SHIELD_FILL)          # 填充（内缩）

    # ── 3) 声波（盾牌内并排三条竖向弧线；中间最高） ──
    bars = [
        (cx - w * 0.22, h * 0.20),
        (cx, h * 0.34),
        (cx + w * 0.22, h * 0.20),
    ]
    bar_w = max(1, int(S * 0.045))
    r_bar = bar_w / 2
    for bx, bh in bars:
        d.rounded_rectangle(
            [bx - bar_w / 2, cy - bh / 2, bx + bar_w / 2, cy + bh / 2],
            radius=r_bar,
            fill=WAVE,
        )

    return img.resize((size, size), Image.LANCZOS)


def outputs() -> dict[str, str]:
    """返回 {绝对路径: 尺寸说明} 的目标文件集合。"""
    files: dict[str, str] = {}
    for dens, sz in ANDROID_SIZES.items():
        p = os.path.join(
            ROOT, "android", "app", "src", "main", "res", f"mipmap-{dens}",
            "ic_launcher.png")
        files[p] = f"android/{dens} {sz}px"
    ios_dir = os.path.join(
        ROOT, "ios", "Runner", "Assets.xcassets", "AppIcon.appiconset")
    for name, sz in IOS_SIZES.items():
        files[os.path.join(ios_dir, name)] = f"ios {sz}px"
    return files


def main() -> int:
    ap = argparse.ArgumentParser(description="生成 SonicShield 全套应用图标")
    ap.add_argument("--check", action="store_true",
                    help="只校验现存图标尺寸，不写文件")
    args = ap.parse_args()

    files = outputs()
    if args.check:
        bad = []
        for path, desc in files.items():
            if not os.path.exists(path):
                bad.append(f"缺失：{desc} → {path}")
                continue
            with Image.open(path) as im:
                exp = int(desc.split()[-1].rstrip("px"))
                if im.size != (exp, exp):
                    bad.append(f"尺寸不符：{desc} → {path} 实际 {im.size}")
        if bad:
            print("图标校验失败：")
            for b in bad:
                print("  -", b)
            return 1
        print(f"图标校验通过：{len(files)} 个文件尺寸/存在性全部正确")
        return 0

    for path, desc in files.items():
        exp = int(desc.split()[-1].rstrip("px"))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        render(exp).save(path, "PNG", optimize=True)
    print(f"已生成 {len(files)} 个图标文件")
    for path, desc in files.items():
        rel = os.path.relpath(path, ROOT).replace("\\", "/")
        print(f"  {desc:14s} {rel}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
