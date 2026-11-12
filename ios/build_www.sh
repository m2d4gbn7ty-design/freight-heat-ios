#!/usr/bin/env bash
# =============================================================================
# 运价热力看板 · iOS 资源同步脚本
# -----------------------------------------------------------------------------
# 把 Android 侧已经构建好的 Web 产物（android/assets）整包同步到 ios/www，
# 再叠加 iOS / PWA 的增强文件（meta、manifest、ios.css、图标、sw.js）。
#
# 设计原则：
#   * android/ 只读：本脚本绝不写入 android 目录；
#   * ios/www 可随时删除重建：所有 iOS 增量都放在 ios/pwa-src 里，由本脚本复制；
#   * 幂等：重复执行结果一致，不会重复插入 meta。
#
# 用法（Windows 用 Git Bash / WSL，macOS 用自带 bash）：
#   bash ios/build_www.sh
#
# 依赖：bash、cp、node（用于给 index.html 注入增强块）。
#       可选：python3 + Pillow（用于重新生成图标，缺省时沿用已提交的 PNG）。
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SRC="$ROOT_DIR/android/assets"
DST="$SCRIPT_DIR/www"
PWA_SRC="$SCRIPT_DIR/pwa-src"
APPICON_DIR="$SCRIPT_DIR/FreightHeat/Assets.xcassets/AppIcon.appiconset"

log() { printf '\033[36m[ios]\033[0m %s\n' "$1"; }
warn() { printf '\033[33m[ios]\033[0m %s\n' "$1"; }
die() { printf '\033[31m[ios] %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. 环境检查
# ---------------------------------------------------------------------------
[ -d "$SRC" ] || die "找不到 Android Web 产物目录: $SRC"
[ -f "$SRC/index.html" ] || die "android/assets/index.html 不存在，请先在 Android 侧完成构建"
[ -d "$PWA_SRC" ] || die "找不到 iOS 增强资源目录: $PWA_SRC"

command -v node >/dev/null 2>&1 || die "需要 node 来给 index.html 注入 iOS 增强块（未检测到 node）"

mkdir -p "$DST" "$DST/icons"

# ---------------------------------------------------------------------------
# 1. 同步 Android Web 产物（保留 www 下已有的 iOS 增量文件）
# ---------------------------------------------------------------------------
log "同步 Web 产物: android/assets → ios/www"
cp -R "$SRC/." "$DST/"

# ---------------------------------------------------------------------------
# 2. 叠加 iOS / PWA 增强资源
# ---------------------------------------------------------------------------
log "叠加 iOS 增强资源: ios/pwa-src → ios/www"
cp -R "$PWA_SRC/." "$DST/"

# ---------------------------------------------------------------------------
# 3. 注入 index.html 的 iOS meta / manifest / 样式表（幂等）
# ---------------------------------------------------------------------------
log "注入 iOS 增强块到 index.html"
node "$SCRIPT_DIR/tools/patch_index.js" "$DST/index.html"

# ---------------------------------------------------------------------------
# 3.1 给 Service Worker 打内容戳
# ---------------------------------------------------------------------------
# 同名缓存会把上一版 ios-boot.js / ios.css 继续发给浏览器（stale-while-revalidate），
# 自动化测试复用 profile 时就会「测到旧代码」。这里用资源内容的 cksum 当版本戳：
# 内容不变 → 版本不变（不会无谓失效），内容一变 → 缓存名变 → 旧缓存自动清理。
log "计算 Service Worker 版本戳"
STAMP="$(
  cat "$DST/index.html" "$DST/ios.css" "$DST/ios-boot.js" "$DST/manifest.webmanifest" 2>/dev/null \
    | cksum | awk '{print $1}'
)"
if [ -z "$STAMP" ]; then
  STAMP="dev"
fi
sed "s/__BUILD_STAMP__/${STAMP}/g" "$DST/sw.js" > "$DST/sw.js.tmp"
mv "$DST/sw.js.tmp" "$DST/sw.js"
log "sw 缓存版本: freight-heat-v12.4.1-${STAMP}"

# ---------------------------------------------------------------------------
# 4. 重新生成图标（可选）
# ---------------------------------------------------------------------------
PY=""
if command -v python3 >/dev/null 2>&1; then
  PY="python3"
elif command -v python >/dev/null 2>&1; then
  PY="python"
fi

if [ -n "$PY" ]; then
  if "$PY" "$SCRIPT_DIR/tools/make_pwa_icons.py" \
      "$SRC/logo-brand.png" "$PWA_SRC/icons" "$APPICON_DIR" >/dev/null 2>&1; then
    # 重生成的结果先落回 pwa-src（源），再同步给 www，保证两者永远一致
    cp -R "$PWA_SRC/icons/." "$DST/icons/"
    log "已重新生成 PWA 图标与 AppIcon（1024 / 512 / 192 / 180 / 167 / 152 / 120）"
  else
    warn "图标生成跳过（缺少 Pillow），沿用 pwa-src/icons 里已提交的 PNG"
  fi
else
  warn "未检测到 python3，沿用已提交的图标"
fi

# ---------------------------------------------------------------------------
# 5. 自检：关键文件是否齐全
# ---------------------------------------------------------------------------
REQUIRED=(
  "index.html"
  "ios.css"
  "ios-boot.js"
  "manifest.webmanifest"
  "sw.js"
  "logo-brand.png"
  "earth-bg.jpg"
  "fonts/misans-sub.woff2"
  "icons/icon-192.png"
  "icons/icon-512.png"
  "icons/icon-1024.png"
  "icons/apple-touch-icon-180.png"
)

MISSING=0
for f in "${REQUIRED[@]}"; do
  if [ ! -f "$DST/$f" ]; then
    warn "缺少文件: www/$f"
    MISSING=1
  fi
done
[ "$MISSING" -eq 0 ] || die "自检未通过：请检查上面的缺失文件"

# sw.js 里的版本戳必须已经替换，否则缓存永不失效
if grep -q "__BUILD_STAMP__" "$DST/sw.js"; then
  die "sw.js 仍含未替换的 __BUILD_STAMP__ 令牌"
fi

GEO_COUNT=$(ls "$DST/geo" 2>/dev/null | wc -l | tr -d ' ')
log "自检通过：geo json ${GEO_COUNT} 个，图标 4 类，PWA 清单与 Service Worker 就绪"

# ---------------------------------------------------------------------------
# 6. 输出目录大小
# ---------------------------------------------------------------------------
if du -sh "$DST" >/dev/null 2>&1; then
  log "ios/www 体积: $(du -sh "$DST" | cut -f1)"
fi

log "完成。下一步："
log "  · 真机预览 PWA：cd ios/www && python3 -m http.server 8080，然后 Safari 打开 http://<你的电脑IP>:8080"
log "  · 出 iOS App：cd ios/FreightHeat && xcodegen generate && open FreightHeat.xcodeproj"
