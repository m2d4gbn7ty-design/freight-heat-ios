'use strict';

/**
 * 给 www/index.html 注入 iOS / PWA 增强块（幂等）。
 *
 * Android 侧的 index.html 是构建产物，每次同步都会覆盖成「安卓版」，
 * 所以 iOS 的 meta / manifest / 样式表不能手改，只能由本脚本重新贴一遍。
 * 脚本只做「在 </head> 前插入一段被标记包裹的 HTML」，不碰任何
 * <style> / <script> 里的业务代码，因此不会影响地图、数据、拖拽逻辑。
 *
 * 用法: node ios/tools/patch_index.js ios/www/index.html
 */

const fs = require('node:fs');

const START = '<!--IOS-ENH:START-->';
const END = '<!--IOS-ENH:END-->';

const BLOCK = [
  START,
  '<!-- iOS / PWA 增强：由 ios/build_www.sh 自动注入，请勿手改本文件的这一块 -->',
  '<meta name="apple-mobile-web-app-capable" content="yes">',
  '<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">',
  '<meta name="apple-mobile-web-app-title" content="运价热力">',
  '<meta name="apple-touch-fullscreen" content="yes">',
  '<meta name="application-name" content="运价热力">',
  '<meta name="format-detection" content="telephone=no,email=no,address=no">',
  '<meta name="color-scheme" content="light dark">',
  '<link rel="manifest" href="manifest.webmanifest">',
  '<link rel="apple-touch-icon" sizes="180x180" href="icons/apple-touch-icon-180.png">',
  '<link rel="apple-touch-icon" sizes="167x167" href="icons/apple-touch-icon-167.png">',
  '<link rel="apple-touch-icon" sizes="152x152" href="icons/apple-touch-icon-152.png">',
  '<link rel="apple-touch-icon" sizes="120x120" href="icons/apple-touch-icon-120.png">',
  '<link rel="icon" type="image/png" sizes="192x192" href="icons/icon-192.png">',
  '<link rel="icon" type="image/png" sizes="512x512" href="icons/icon-512.png">',
  '<link rel="stylesheet" href="ios.css">',
  '<script src="ios-boot.js" defer></script>',
  END,
].join('\n');

function stripBlock(html) {
  const startAt = html.indexOf(START);
  if (startAt === -1) return html;
  const endAt = html.indexOf(END, startAt);
  if (endAt === -1) return html;
  let removeEnd = endAt + END.length;
  // 顺带吃掉标记后面的换行，避免重复贴块时堆积空行
  if (html[removeEnd] === '\r') removeEnd += 1;
  if (html[removeEnd] === '\n') removeEnd += 1;
  return html.slice(0, startAt) + html.slice(removeEnd);
}

function main() {
  const target = process.argv[2];
  if (!target) {
    process.stderr.write('用法: node ios/tools/patch_index.js <path/to/index.html>\n');
    process.exit(2);
  }

  const original = fs.readFileSync(target, 'utf8');
  const cleaned = stripBlock(original);

  const closeHead = cleaned.lastIndexOf('</head>');
  if (closeHead === -1) {
    process.stderr.write('未找到 </head>，目标文件不是完整的 HTML：' + target + '\n');
    process.exit(1);
  }

  // 保留 </head> 前的缩进风格（原文件是顶格写法）
  const patched = cleaned.slice(0, closeHead) + BLOCK + '\n' + cleaned.slice(closeHead);

  const changed = patched !== original;
  fs.writeFileSync(target, patched, 'utf8');
  process.stdout.write(
    (changed ? '已注入 iOS 增强块: ' : 'iOS 增强块已是最新: ') + target + '\n'
  );
}

main();
