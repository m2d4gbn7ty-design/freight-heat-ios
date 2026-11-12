/* ============================================================================
 * 运价热力看板 · Service Worker（iOS / PWA 离线缓存）
 * ----------------------------------------------------------------------------
 * 目标只有一个：把「添加到主屏幕」后的首屏做到断网可用。
 * 不缓存任何用户数据（运价数据全部走 localStorage，不进 SW）。
 *
 * 策略：
 *   导航请求（index.html）→ 网络优先 + 3s 超时 → 回退缓存
 *   同源静态资源        → 缓存优先，后台静默更新（stale-while-revalidate）
 *   跨域 / 非 GET       → 直接放行
 * ========================================================================= */

/* 版本号里的 __BUILD_STAMP__ 由 ios/build_www.sh 在同步时替换成内容摘要：
   资源一变，缓存名就跟着变，旧的 shell 缓存会在 activate 阶段被清掉，
   避免浏览器（以及自动化测试里复用的 profile）继续命中上一版 ios-boot.js。
   直接拿本文件当源用（不经 build）时，令牌保持原样也能正常工作，只是不再自动失效。 */
var VERSION = 'freight-heat-v12.4.1-__BUILD_STAMP__';
var SHELL_CACHE = VERSION + '-shell';
var RUNTIME_CACHE = VERSION + '-runtime';

/* 首屏必需资源；缺失任何一个都不影响安装（逐个 try） */
var SHELL_ASSETS = [
  './',
  './index.html',
  './ios.css',
  './ios-boot.js',
  './manifest.webmanifest',
  './logo-brand.png',
  './earth-bg.jpg',
  './fonts/misans-sub.woff2',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/icon-1024.png',
  './icons/apple-touch-icon-180.png'
];

self.addEventListener('install', function (event) {
  event.waitUntil(
    caches.open(SHELL_CACHE).then(function (cache) {
      return Promise.all(
        SHELL_ASSETS.map(function (url) {
          return cache.add(new Request(url, { cache: 'reload' })).catch(function () {
            /* 单个文件缺失（比如被裁剪的字体）不应阻塞安装 */
            return null;
          });
        })
      );
    }).then(function () {
      return self.skipWaiting();
    })
  );
});

self.addEventListener('activate', function (event) {
  event.waitUntil(
    caches.keys().then(function (keys) {
      return Promise.all(
        keys.map(function (key) {
          if (key !== SHELL_CACHE && key !== RUNTIME_CACHE) return caches.delete(key);
          return null;
        })
      );
    }).then(function () {
      return self.clients.claim();
    })
  );
});

/** 网络优先，超时后回退缓存（用于 index.html）。 */
function networkFirst(request, timeoutMs) {
  return new Promise(function (resolve) {
    var settled = false;
    var timer = setTimeout(function () {
      if (settled) return;
      caches.match(request).then(function (cached) {
        if (cached) {
          settled = true;
          resolve(cached);
        }
      });
    }, timeoutMs);

    fetch(request)
      .then(function (response) {
        clearTimeout(timer);
        if (settled) return;
        settled = true;
        if (response && response.status === 200) {
          var copy = response.clone();
          caches.open(SHELL_CACHE).then(function (cache) {
            cache.put(request, copy).catch(function () {});
          });
        }
        resolve(response);
      })
      .catch(function () {
        clearTimeout(timer);
        if (settled) return;
        settled = true;
        caches.match(request).then(function (cached) {
          resolve(cached || caches.match('./index.html'));
        });
      });
  });
}

/** 缓存优先 + 后台更新（用于 geo json / 字体 / 图片）。 */
function staleWhileRevalidate(request) {
  return caches.match(request).then(function (cached) {
    var network = fetch(request)
      .then(function (response) {
        if (response && response.status === 200 && response.type === 'basic') {
          var copy = response.clone();
          caches.open(RUNTIME_CACHE).then(function (cache) {
            cache.put(request, copy).catch(function () {});
          });
        }
        return response;
      })
      .catch(function () {
        return cached;
      });
    return cached || network;
  });
}

self.addEventListener('fetch', function (event) {
  var request = event.request;
  if (request.method !== 'GET') return;

  var url;
  try {
    url = new URL(request.url);
  } catch (err) {
    return;
  }
  if (url.origin !== self.location.origin) return;

  var isNavigation =
    request.mode === 'navigate' ||
    (request.headers.get('accept') || '').indexOf('text/html') !== -1;

  if (isNavigation) {
    event.respondWith(networkFirst(request, 3000));
    return;
  }

  event.respondWith(staleWhileRevalidate(request));
});
