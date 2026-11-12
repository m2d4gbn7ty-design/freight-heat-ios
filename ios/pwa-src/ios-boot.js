/* ============================================================================
 * 运价热力看板 · iOS 引导脚本
 * ----------------------------------------------------------------------------
 * 只做三件事，完全不触碰原有业务逻辑：
 *   1. 给 <html> 打上运行环境标记（独立窗口 / WKWebView 壳 / 普通 Safari）
 *   2. 暴露 window.__iosApplySafeArea()，供 Swift 壳把真实安全区写进 CSS 变量
 *   3. 在 http(s) 环境下注册最简单的离线缓存；WKWebView 的自定义 scheme
 *      不支持 Service Worker，所以那里安静跳过
 * ========================================================================= */
(function () {
  'use strict';

  var root = document.documentElement;

  /* ---------- 1. 运行环境标记 ---------- */
  var isStandalone =
    (window.navigator.standalone === true) ||
    (window.matchMedia && window.matchMedia('(display-mode: standalone)').matches);
  if (isStandalone) root.classList.add('ios-standalone');

  var isShell = typeof window.webkit !== 'undefined' &&
    typeof window.webkit.messageHandlers !== 'undefined' &&
    typeof window.webkit.messageHandlers.iosBridge !== 'undefined';
  if (isShell) root.classList.add('ios-shell');

  /* ---------- 2. 安全区桥 ---------- */
  /* Swift 侧拿到 view.safeAreaInsets 后调用本函数；单位是 CSS px。
     变量只写在 :root 上，ios.css 里用 max(var(--ios-safe-*), env(...)) 取值，
     两条通道谁大用谁，避免 WKWebView 里 env() 退化成 0 时顶栏压到刘海。 */
  function applySafeArea(top, bottom, left, right) {
    var n = function (v) {
      var x = typeof v === 'number' ? v : parseFloat(v);
      return isFinite(x) && x >= 0 ? x : 0;
    };
    root.style.setProperty('--ios-safe-top', n(top) + 'px');
    root.style.setProperty('--ios-safe-bottom', n(bottom) + 'px');
    root.style.setProperty('--ios-safe-left', n(left) + 'px');
    root.style.setProperty('--ios-safe-right', n(right) + 'px');

    // 走页面自己的重排路径：resize 处理会防抖 180ms 后执行
    // measure() + paint(targetOf(snapped))，把 --sheet-h / --sheet-peek /
    // --sheet-ty 一起重算 —— 这是唯一能同时修正「档位高度」和「transform 位移」
    // 的官方入口（只调 remeasure() 会把 --sheet-h 改小却不改 --sheet-ty，
    // 条带反而塌成几个像素）。首次注入时页面已绑定 resize，安全。
    window.dispatchEvent(new Event('resize'));

    // 兜底：resize 路径万一没跑到（例如页面 resize 监听尚未绑定、
    // 或只改了横向安全区），再用 syncSheet 做一次定点校正。
    scheduleSync(0);
  }
  window.__iosApplySafeArea = applySafeArea;

  /* ---------- 2.1 面板 peek 档位与安全区对齐 ---------- */
  /* 背景：底部面板的「收起档」高度 PEEK 是页面自己算的
     `grip.offsetHeight + h3.offsetHeight`，而 ios.css 把底部安全区加在
     `#side h3` 的下内边距上 —— 只要这条样式在页面首次 measure() 之前就已生效
     （Safari / PWA 走 env()，解析期就有值），PEEK 天然包含安全区，一切正常。
     但两种情况下顺序会反过来：
       · WKWebView 壳在 didFinish 之后才把 safeAreaInsets 推成 CSS 变量；
       · 外部注入/调试工具在加载完成后才写 --ios-safe-bottom。
     此时 h3 变高了，PEEK 却还是旧值，--sheet-ty 也就没把面板抬起来 ——
     表现就是可见条带仍是 53px、标题正好压在 home indicator 上。
     处理办法：发现「实际 peek ≠ 把手 + 标题」时，调用页面自己暴露的
     remeasure() 重算几何，再把面板吸附回新 peek。只改壳层，不动业务逻辑。 */
  function syncSheet() {
    var sheet = window.__fxSheet;
    if (!sheet || typeof sheet.peek !== 'function' || typeof sheet.remeasure !== 'function') {
      return false;
    }
    if (document.body && document.body.classList.contains('sheet-drag')) return false;

    var grip = document.getElementById('sheetGrip');
    var title = document.querySelector('#side h3');
    if (!grip || !title) return false;

    var expected = Math.round(grip.offsetHeight + title.offsetHeight);
    var actual = Math.round(sheet.peek());
    if (!expected || Math.abs(expected - actual) <= 2) return false;

    var wasVisible = Math.round(sheet.visible());
    try {
      sheet.remeasure();
    } catch (err) {
      return false;
    }
    if (Math.round(sheet.peek()) === actual) return false;

    // 只有在「收起档」时才需要重新吸附：面板已经拉起（half / full）时
    // 标题一直可见，位置由用户手势决定，不要替他改状态。
    if (wasVisible > actual + 24) return true;

    var side = document.getElementById('side');
    var prevTransition = side ? side.style.transition : '';
    if (side) side.style.transition = 'none'; // 启动阶段不要看到 340ms 的抬升动画
    try {
      sheet.collapse();
    } catch (err) {
      /* 失败就保持原样，最坏情况也还是今天的行为 */
    }
    if (side) {
      // 用 setTimeout 而不是 rAF：面板的吸附动画必须恢复，
      // 后台标签页里 rAF 不触发会让 transition:none 永久留在元素上。
      setTimeout(function () {
        side.style.transition = prevTransition;
      }, 60);
    }
    return true;
  }
  window.__iosSyncSheet = syncSheet;

  /* ---------- 3.1 长按后的「幽灵 click」守卫 ---------- */
  /* 页面的长按下钻在命中后会把 window.__fxSuppressClick 置真并保持 800ms，
     用来挡掉松手瞬间系统合成的 click。但这条守卫只写在「省份 path」自己的
     click 处理里（index.html:2360 `if(moved||window.__fxSuppressClick) return;`），
     而 svg#map 上还挂着一个
         svg.addEventListener('click', function(){ if(!moved) closeEditor(); });
     幽灵 click 从 path 冒泡到 svg 时没有人检查这个标志 —— 于是长按弹出的录入
     面板会在松手后被立刻关掉（QA 实测：display:block 后 900ms 变 none）。
     这里在 document 的捕获阶段把它拦在 svg 之前；只拦 #map 内部的目标，
     录入面板的「保存 / 取消」不在 #map 里，不受影响。 */
  document.addEventListener(
    'click',
    function (e) {
      if (!window.__fxSuppressClick) return;
      var target = e.target;
      if (!target || typeof target.closest !== 'function') return;
      if (!target.closest('#map')) return;
      if (e.cancelable) e.preventDefault();
      e.stopPropagation();
      if (e.stopImmediatePropagation) e.stopImmediatePropagation();
    },
    true
  );

  /* ---------- 3.1b 长按「按住超过 800ms」的补充抑制窗口 ---------- */
  /* 页面自己的抑制标志只在长按触发后维持 800ms（`__fxSuppressClick` +
     800ms 定时器）。可用户完全可能按住 1.5 秒才松手 —— 那时标志已经过期，
     松手产生的幽灵 click 又会长驱直入把面板关掉（QA Round 2 仍然复现）。
     这里的做法不依赖那个固定时长，而是按「这一次触摸到底干了什么」判断：
        按下时记时间戳 / 是否落在 #map / 按下前面板是否已打开；
        松手时若「按住 >380ms（已超过点击阈值）」「按下前面板没开」
        「松手后面板开着」「中途没拖动」，就重新武装抑制窗口 450ms，
        让下面这道 capture 守卫把这颗幽灵 click 吃掉。
     全程只读 DOM 状态、只写页面本来就有的两个全局量，不改业务逻辑。 */
  var pressTrack = { at: 0, x: 0, y: 0, inMap: false, editorWasOpen: false, dragged: false };

  function isEditorOpen() {
    var editor = document.getElementById('editor');
    if (!editor) return false;
    var display = editor.style.display || window.getComputedStyle(editor).display;
    return display !== 'none' && display !== '';
  }

  function isInsideMap(node) {
    return !!(node && typeof node.closest === 'function' && node.closest('#map'));
  }

  document.addEventListener(
    'touchstart',
    function (e) {
      if (!e.touches || e.touches.length !== 1) {
        pressTrack.at = 0; // 多指（缩放）：不参与长按判定
        return;
      }
      var touch = e.touches[0];
      pressTrack = {
        at: Date.now(),
        x: touch.clientX,
        y: touch.clientY,
        inMap: isInsideMap(e.target),
        editorWasOpen: isEditorOpen(),
        dragged: false,
      };
    },
    true
  );

  document.addEventListener(
    'touchmove',
    function (e) {
      if (!pressTrack.at) return;
      var touch = e.touches && e.touches[0];
      if (!touch) return;
      // 超过 12px 视为拖拽（地图平移 / 面板拖拽），拖拽不会弹录入面板
      if (Math.abs(touch.clientX - pressTrack.x) > 12 || Math.abs(touch.clientY - pressTrack.y) > 12) {
        pressTrack.dragged = true;
      }
    },
    true
  );

  document.addEventListener(
    'touchend',
    function () {
      // 先把需要的字段抄出来再清状态：pressTrack 是同一个对象，
      // 直接 `pressTrack.at = 0` 会把下面要判定的值一起清掉。
      var startedAt = pressTrack.at;
      var dragged = pressTrack.dragged;
      var insideMap = pressTrack.inMap;
      var editorWasOpen = pressTrack.editorWasOpen;
      pressTrack.at = 0;

      if (!startedAt || dragged || !insideMap) return;
      if (Date.now() - startedAt < 380) return; // 快速点按：交给页面正常下钻
      if (editorWasOpen) return; // 按下前面板就开着，松手关闭是预期行为
      if (!isEditorOpen()) return; // 长按没弹出面板（落空 / 被页面取消）

      // 长按确实弹出了面板：重新武装抑制窗口，覆盖「按住超过 800ms」的情况
      window.__fxSuppressClick = true;
      clearTimeout(window.__fxSuppressTimer);
      window.__fxSuppressTimer = setTimeout(function () {
        window.__fxSuppressClick = false;
      }, 450);
    },
    true
  );

  /* ---------- 3.2 手势收敛 ---------- */
  /* WKWebView / iOS Safari 都会忽略 user-scalable=no 的双指缩放限制，
     这里在页面层面兜住多指缩放，单指拖拽（面板 / 地图）不受影响。 */
  document.addEventListener(
    'touchmove',
    function (e) {
      if (e.touches && e.touches.length > 1 && e.cancelable) e.preventDefault();
    },
    { passive: false }
  );

  /* Safari 的私有 gesture 事件（双指缩放 / 旋转）同样屏蔽 */
  ['gesturestart', 'gesturechange', 'gestureend'].forEach(function (name) {
    document.addEventListener(name, function (e) {
      if (e.cancelable) e.preventDefault();
    }, { passive: false });
  });

  /* ---------- 4. 离线缓存（仅 http/https） ---------- */
  var httpLike = location.protocol === 'http:' || location.protocol === 'https:';
  if (httpLike && 'serviceWorker' in navigator) {
    window.addEventListener('load', function () {
      navigator.serviceWorker.register('sw.js', { scope: './' }).catch(function () {
        /* 注册失败不影响页面功能：SW 只是断网时的加速层 */
      });
    });
  }

  /* ---------- 5. 状态栏配色（仅提示，真正生效靠 Info.plist） ---------- */
  var themeColor = document.querySelector('meta[name="theme-color"]');
  if (!themeColor) {
    themeColor = document.createElement('meta');
    themeColor.setAttribute('name', 'theme-color');
    themeColor.setAttribute('content', '#071426');
    document.head.appendChild(themeColor);
  }

  /* ---------- 6. 安全区到位后重新对齐面板 ---------- */
  /* 安全区可能在任意时刻才可用，所以多条通道都接上，不押注单一时序：
       1. <html> 的 style 被写入（Swift 推 insets、外部注入、调试工具）；
       2. DOM 解析完成 / load 完成（env() 生效但页面 measure 已跑过）；
       3. 旋屏 / 尺寸变化（页面自己 180ms 后会 remeasure，这里在其之后再兜一次）；
       4. 启动后 5 秒内的低频轮询（兜住不上报 attribute 的注入方式）。
     全部幂等：CSS 已经算对时会立即短路返回，不会产生任何副作用。
     注意这里统一用 setTimeout 而不是 requestAnimationFrame —— 后台标签页 /
     无头浏览器里 rAF 会被节流甚至不触发，而这段逻辑必须可靠。 */
  function scheduleSync(delay) {
    setTimeout(function () {
      syncSheet();
    }, delay);
  }

  if (typeof MutationObserver === 'function') {
    var styleObserver = new MutationObserver(function () {
      scheduleSync(0);
    });
    styleObserver.observe(root, { attributes: true, attributeFilter: ['style'] });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () {
      scheduleSync(0);
    });
  } else {
    scheduleSync(0);
  }

  window.addEventListener('load', function () {
    scheduleSync(80);
    startSyncWatch();
  });
  window.addEventListener('orientationchange', function () {
    scheduleSync(400);
  });
  window.addEventListener('resize', function () {
    scheduleSync(320);
  });

  /* 启动窗口内的兜底轮询：一旦对齐成功就自己停掉，不常驻。 */
  function startSyncWatch() {
    var ticks = 0;
    var timer = setInterval(function () {
      ticks += 1;
      var grip = document.getElementById('sheetGrip');
      var title = document.querySelector('#side h3');
      var sheet = window.__fxSheet;
      if (grip && title && sheet && typeof sheet.peek === 'function') {
        var aligned = Math.abs(grip.offsetHeight + title.offsetHeight - sheet.peek()) <= 2;
        if (aligned) {
          clearInterval(timer);
          return;
        }
      }
      syncSheet();
      if (ticks >= 25) clearInterval(timer);
    }, 200);
  }
})();
