#!/usr/bin/env python3
"""生成 iOS / PWA 图标：深蓝底 + 现有卡车品牌图标。

设计约束（Apple HIG）：
  * App Icon 必须是**不透明**的整块方形，系统自己切圆角；
  * 主体图形要落在中心 ~66% 的安全区内，避免被圆角切到；
  * 品牌图标原图只有 96x96，直接放大到 1024 会发虚，所以这里用
    LANCZOS 重采样 + 轻度锐化，并用大面积深蓝底把视觉重心稳住。

用法:
  python3 ios/tools/make_pwa_icons.py <logo-brand.png> <pwa-icon-dir> <appicon-dir>

依赖: Pillow（可选）。缺 Pillow 时脚本返回码 3，build_www.sh 会跳过图标生成
并沿用仓库里已经提交的 PNG，不影响 iOS 资源同步。
"""

from __future__ import annotations

import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFilter
except ImportError:  # pragma: no cover - 只在缺少 Pillow 的环境触发
    sys.stderr.write('[icons] 未安装 Pillow，跳过图标生成（沿用已提交的 PNG）\n')
    sys.exit(3)

# ----------------------------------------------------------------------------
# 配色：与 index.html 的 --bg / theme-color 对齐
# ----------------------------------------------------------------------------
BG_TOP = (18, 30, 53)      # #121E35
BG_BOTTOM = (7, 20, 38)    # #071426
GLOW = (86, 116, 164)      # 品牌强调蓝 rgba(86,116,164)

# PWA / Safari 需要的尺寸
PWA_SIZES = {
    'icon-1024.png': 1024,
    'icon-512.png': 512,
    'icon-192.png': 192,
    'apple-touch-icon-180.png': 180,
    'apple-touch-icon-167.png': 167,
    'apple-touch-icon-152.png': 152,
    'apple-touch-icon-120.png': 120,
}

# AppIcon.appiconset 需要的尺寸（文件名 -> 像素）
APPICON_SIZES = {
    'Icon-40.png': 40,
    'Icon-58.png': 58,
    'Icon-60.png': 60,
    'Icon-80.png': 80,
    'Icon-87.png': 87,
    'Icon-120.png': 120,
    'Icon-152.png': 152,
    'Icon-167.png': 167,
    'Icon-180.png': 180,
    'Icon-1024.png': 1024,
}


def build_background(size: int) -> Image.Image:
    """竖向渐变 + 顶部柔光，返回不透明 RGB 图。"""
    base = Image.new('RGB', (1, size))
    px = base.load()
    for y in range(size):
        t = y / max(1, size - 1)
        # 用一点缓动让上半部分更亮，接近原版图标的重心
        e = t ** 0.85
        px[0, y] = (
            round(BG_TOP[0] + (BG_BOTTOM[0] - BG_TOP[0]) * e),
            round(BG_TOP[1] + (BG_BOTTOM[1] - BG_TOP[1]) * e),
            round(BG_TOP[2] + (BG_BOTTOM[2] - BG_TOP[2]) * e),
        )
    canvas = base.resize((size, size), Image.BILINEAR).convert('RGBA')

    # 顶部柔光：一个椭圆径向渐变，用高斯模糊做出过渡
    glow = Image.new('L', (size, size), 0)
    draw = ImageDraw.Draw(glow)
    cx, cy = size / 2, size * 0.30
    rx, ry = size * 0.52, size * 0.34
    draw.ellipse([cx - rx, cy - ry, cx + rx, cy + ry], fill=72)
    glow = glow.filter(ImageFilter.GaussianBlur(size * 0.10))
    glow_layer = Image.new('RGBA', (size, size), GLOW + (0,))
    glow_layer.putalpha(glow)
    return Image.alpha_composite(canvas, glow_layer)


def load_mark(source: str) -> Image.Image:
    """裁掉品牌图标的透明留白，只留实心部分。"""
    mark = Image.open(source).convert('RGBA')
    bbox = mark.split()[3].point(lambda a: 255 if a > 24 else 0).getbbox()
    if bbox:
        mark = mark.crop(bbox)
    return mark


def compose(size: int, mark: Image.Image) -> Image.Image:
    """把品牌图形贴到深蓝底上，输出 RGB 图（无 alpha）。"""
    canvas = build_background(size)

    # 主体占画布宽度的 68%，高度不足时按高度再收一次，保证不出血
    target_w = size * 0.68
    ratio = target_w / mark.width
    if mark.height * ratio > size * 0.56:
        ratio = (size * 0.56) / mark.height
    w = max(1, round(mark.width * ratio))
    h = max(1, round(mark.height * ratio))

    scaled = mark.resize((w, h), Image.LANCZOS)
    # 小图放大后边缘偏软，轻度锐化把卡车轮廓提回来
    scaled = scaled.filter(ImageFilter.UnsharpMask(radius=max(1, size // 320), percent=55, threshold=2))

    x = (size - w) // 2
    y = (size - h) // 2 + round(size * 0.01)
    canvas.alpha_composite(scaled, (x, y))
    return canvas.convert('RGB')


def main() -> int:
    if len(sys.argv) < 4:
        sys.stderr.write(__doc__ or '')
        sys.stderr.write('用法: make_pwa_icons.py <logo> <pwa-dir> <appicon-dir>\n')
        return 2

    logo_path, pwa_dir, appicon_dir = sys.argv[1], sys.argv[2], sys.argv[3]
    if not os.path.isfile(logo_path):
        sys.stderr.write('[icons] 找不到品牌图标: %s\n' % logo_path)
        return 1

    mark = load_mark(logo_path)
    os.makedirs(pwa_dir, exist_ok=True)
    os.makedirs(appicon_dir, exist_ok=True)

    # 1024 母版只渲染一次，其余尺寸从母版重采样，保证所有图标完全一致
    master = compose(1024, mark)

    for name, px in PWA_SIZES.items():
        img = master if px == 1024 else master.resize((px, px), Image.LANCZOS)
        out = os.path.join(pwa_dir, name)
        img.save(out, 'PNG', optimize=True)
        sys.stdout.write('[icons] %s (%dx%d)\n' % (out, px, px))

    for name, px in APPICON_SIZES.items():
        img = master if px == 1024 else master.resize((px, px), Image.LANCZOS)
        out = os.path.join(appicon_dir, name)
        img.save(out, 'PNG', optimize=True)
        sys.stdout.write('[icons] %s (%dx%d)\n' % (out, px, px))

    return 0


if __name__ == '__main__':
    sys.exit(main())
