# 运价热力看板 · iOS 版本

本目录把 Android 版已经构建好的 Web 产物（`android/assets`）原样复用，产出两条
iPhone 交付路径，**没有任何业务逻辑重写**：地图、运价数据、下钻、拖拽面板、
导入导出、设置面板的行为与 Android 版完全一致。

| 路径 | 产物 | 适用场景 | 需要 macOS |
| --- | --- | --- | --- |
| A. PWA | `ios/www/` 静态站点 | 同事用 Safari 打开即可，可「添加到主屏幕」，断网可用 | 否 |
| B. 原生壳 | `ios/FreightHeat/`（WKWebView） | 需要 App 图标 / 分发 / 上架，产出 `.ipa` | **是** |

> ⚠️ 当前开发环境是 Windows，**没有编译过 iOS 工程**。Swift 源码与 XcodeGen
> 配置均已按 iOS 15+ 的标准写法完成，但首次编译必须在 macOS + Xcode 上进行，
> 详见文末「已知限制」。
>
> 👉 **只想拿到 `.ipa` 安装包？看 [`how-to-get-ipa.md`](how-to-get-ipa.md)**：
> 里面是用 GitHub 免费 macOS 机器编译的 3 步流程（无需自己有 Mac）。

---

## 目录结构

```
ios/
├── www/                      # 可直接部署的 PWA（由 build_www.sh 生成，可随时重建）
│   ├── index.html            # android/assets/index.html + iOS 增强块（幂等注入）
│   ├── ios.css               # iOS 专用样式：系统字体 / 安全区 / 触屏手势
│   ├── ios-boot.js           # 环境标记 + 安全区桥 + SW 注册
│   ├── manifest.webmanifest   # display=standalone, theme/background=#071426
│   ├── sw.js                 # 最简离线缓存（导航网络优先，静态资源缓存优先）
│   ├── icons/                # 192 / 512 / 1024 + apple-touch-icon 180/167/152/120
│   ├── geo/                  # 362 个边界 json（原样复制）
│   ├── fonts/misans-sub.woff2
│   ├── earth-bg.jpg
│   └── logo-brand.png
├── pwa-src/                  # iOS 增量的「源」，build_www.sh 从这里复制到 www
│   ├── ios.css / ios-boot.js / manifest.webmanifest / sw.js
│   └── icons/
├── FreightHeat/              # Xcode WKWebView 壳工程源码
│   ├── FreightHeatApp.swift  # SwiftUI App 入口 + 启动遮罩
│   ├── WebView.swift         # WKWebView 容器 / 通道选择 / 安全区回传 / 导出分享
│   ├── LocalHTTPServer.swift # 回环静态文件服务（默认通道）
│   ├── AssetSchemeHandler.swift # appassets:// 兜底通道
│   ├── WebAssetLocator.swift # 路径解析 + MIME
│   ├── Info.plist
│   ├── Assets.xcassets/      # AppIcon（含 1024）+ AccentColor + LaunchBackground
│   └── project.yml           # XcodeGen 工程描述
├── tools/
│   ├── patch_index.js        # 给 index.html 注入 iOS meta（幂等）
│   └── make_pwa_icons.py     # 由 logo-brand.png 合成深蓝底图标
└── build_www.sh              # 资源同步脚本
```

---

## A. PWA：在 iPhone 上直接使用（无需 macOS）

### 本地预览

```bash
cd ios/www
python3 -m http.server 8080      # 或任意静态服务器
# iPhone 与电脑同一 Wi-Fi，Safari 打开 http://<电脑的局域网 IP>:8080
```

### 添加到主屏幕

1. Safari 打开上面的地址，**等地图渲染出来**（首屏要解析 700KB+ 的内联数据）；
2. 点底部「分享」→「添加到主屏幕」；
3. 图标名称自动取 `apple-mobile-web-app-title` = **运价热力**，状态栏为
   `black-translucent`，启动后全屏无 Safari 工具栏；
4. 之后从主屏幕图标进入即为独立窗口（`display=standalone`）。

### 正式部署

`ios/www` 是纯静态目录，放到任意 HTTPS 静态托管即可（Service Worker 与
「添加到主屏幕」都要求 HTTPS；`http://localhost` 除外）。部署后建议在
iOS Safari 里复测一次：首屏 → 下钻到省 → 下钻到市 → 刷新后数据仍在。

---

## B. Xcode 壳：产出可安装的 App（需要 macOS）

### 前置

- macOS 13+，Xcode 15+（iOS 15.0 部署目标）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`
- 先同步一次 Web 资源（`ios/www` 必须存在，否则 App 内会显示「资源未就绪」）：

```bash
bash ios/build_www.sh
```

### 生成并运行

```bash
cd ios/FreightHeat
xcodegen generate          # 生成 FreightHeat.xcodeproj
open FreightHeat.xcodeproj
```

在 Xcode 里：

1. 选中 `FreightHeat` target → Signing & Capabilities → 选择你的 Team
   （`project.yml` 里 `CODE_SIGN_STYLE = Automatic`，`DEVELOPMENT_TEAM` 留空）；
2. 选择一台 iPhone（或模拟器）→ Run；
3. 真机首次运行需要在「设置 → 通用 → VPN 与设备管理」信任开发者证书。

### 为什么提供 project.yml 而不是 .xcodeproj

`.xcodeproj` 是工程 plist 的二进制化产物，手写极易出现「能打开但构建失败」的
隐性错误，而当前环境（Windows）没有 Xcode 可以验证。用 `project.yml` 在
macOS 上一条命令生成，结构一定正确、可复现。

### 壳工程做了什么（以及为什么）

页面是同一个 `www/index.html`，原生侧只补平台能力：

| 能力 | 实现 | 为什么必须原生 |
| --- | --- | --- |
| 资源加载 | `LocalHTTPServer`（127.0.0.1 随机端口） | 自定义 scheme 的页面是 opaque origin，`localStorage` 不可用、`fetch()` 不支持自定义协议；而本工具的运价数据全在 localStorage、地图要 `fetch('geo/*.json')` |
| 兜底加载 | `AssetSchemeHandler`（`appassets://local/…`） | 回环端口异常时至少能显示页面（此通道下数据不落盘，仅应急） |
| 安全区 | 把 `view.safeAreaInsets` 写进 CSS 变量 `--ios-safe-*` | `env(safe-area-inset-*)` 在 WKWebView 个别配置下会退化为 0，变量与 `env()` 取 `max()` 双保险 |
| 双指缩放 | `scrollView.pinchGestureRecognizer.isEnabled = false` | WKWebView 会忽略 `user-scalable=no` |
| 导出 JSON | 拦截 `a[download]` + Blob → 系统分享面板 | WKWebView 不会为 Blob 触发下载，页面原本的 `a.click()` 会静默失败 |
| 导入 JSON | 原生 `<input type=file>` | WKWebView 自带文件选择器，无需额外代码 |
| 状态栏 | `Info.plist`：`UIStatusBarStyleLightContent` + `black-translucent` | 与 PWA 视觉一致 |
| ATS | `NSAllowsLocalNetworking = true`（未开启 `NSAllowsArbitraryLoads`） | 只放行回环 http，外网请求仍强制 HTTPS |

不涉及任何数据解析或业务分支，因此 Android 侧逻辑改动后**只需重跑
`build_www.sh`**，壳工程代码不用动。

### 底部面板「收起档」与安全区的一次性对齐

页面自己实现了一个三档吸附的底部面板，收起档高度 `PEEK` 是它在启动时用
`grip.offsetHeight + h3.offsetHeight` 算出来的**一次性快照**，之后只随窗口 resize
重算。而 iOS 的安全区是加在 `#side h3` 的下内边距上的（这样收起档自然抬高、
展开档又不会盖住顶栏）。两者只在一种顺序下自洽：**安全区在页面第一次 measure()
之前就已经生效**。

实际有两种情况顺序会反过来：

- WKWebView 壳在 `didFinish` 之后才把 `safeAreaInsets` 写进 CSS 变量；
- 外部注入 / 调试工具在页面加载完成后才写 `--ios-safe-bottom`。

此时标题行变高了，`PEEK` 还是旧值（53），`--sheet-ty` 没把面板抬起来 ——
表现就是可见条带仍是 53px、标题文字正好压在 home indicator 上。

`ios-boot.js` 的 `__iosApplySafeArea()` 在写完变量后做两件事：

1. **`window.dispatchEvent(new Event('resize'))`（主路径）** —— 走页面自己的
   resize 处理：防抖 180ms 后执行 `measure() + paint(targetOf(snapped))`，
   一次把 `--sheet-h` / `--sheet-peek` / `--sheet-ty` 全部重算。
   这是唯一能同时修正「档位高度」和「transform 位移」的官方入口；
   ⚠️ 只调 `__fxSheet.remeasure()` **不够**：它会把 `--sheet-h` 从 798 改成 751
   却不动 `--sheet-ty`（仍是 745），可见条带反而塌成几像素。
2. **`syncSheet()`（兜底）** —— 定点校正：比较「把手 + 标题」实测高度与
   `__fxSheet.peek()`，差值 > 2px 才调用 `remeasure()` 并把面板吸附回新 peek
   （仅在原本停在收起档时；展开态不打断、拖拽中跳过）。
   触发源：`<html>` style 的 MutationObserver、DOM 完成 / load、旋屏、启动后
   5 秒内 200ms 轮询。全部幂等，几何已经正确时立即短路。

### 长按录入面板的「幽灵 click」守卫

页面实现了「长按省份 → 弹出运价录入面板」，并在触发后把
`window.__fxSuppressClick` 置真、800ms 后清除，用来挡掉松手瞬间系统合成的 click。
但这条判断只写在省份 `path` 的 click 处理里（`if(moved||window.__fxSuppressClick) return;`），
而 `svg#map` 上还有一个 `svg.addEventListener('click', function(){ if(!moved) closeEditor(); })` ——
幽灵 click 从 path 冒泡到 svg 时没人检查这个标志，于是面板刚弹出就被关掉
（QA 复现：`display:block` 后 900ms 变 `none`，390 与 430 两台都中）。

`ios-boot.js` 在 document 的**捕获阶段**补了一道守卫：`__fxSuppressClick` 为真
且事件目标在 `#map` 内部时 `preventDefault + stopPropagation`，把幽灵 click 拦在
svg 之前。只拦 `#map` 内部，录入面板的「保存 / 取消」按钮不在其中，不受影响
（已回归验证：抑制窗口内点「取消」仍能关闭面板）。

**第二层：抑制窗口过期的情况。** 页面只在长按触发后维持 800ms。用户完全可能
按住 1.5 秒以上再松手 —— 那时标志早已过期，守卫拦不到，面板照样被关掉
（QA Round 2 仍复现）。所以 `ios-boot.js` 又按「这次触摸到底干了什么」重新判定：

| 时机 | 记录 / 判定 |
| --- | --- |
| `touchstart` | 记 `pressStartAt`、是否落在 `#map`、按下前 `#editor` 是否已 `display:block` |
| `touchmove` | 位移 > 12px 记为拖拽（拖地图 / 拖面板），不参与后续判定 |
| `touchend` | 若「按住 > 380ms」「按下前面板没开」「松手后面板开着」「没拖动」→ 重新置 `__fxSuppressClick=true`，`clearTimeout` 旧的 800ms 定时器后 450ms 清除 |

这条逻辑只读 DOM 状态、只写页面本来就有的 `__fxSuppressClick` / `__fxSuppressTimer`
两个全局量，不改变任何业务分支；快速点按（<380ms）不会触发它，下钻不受影响。

> iOS Safari 长按松手是否合成 click 与 Chromium 不保证一致，所以这两层都是
> 「有则拦截、无则无副作用」，真机上需要复核长按→录入的完整流程。

---

## 更新 Web 资源（Android 改版之后）

```bash
bash ios/build_www.sh
```

脚本动作（幂等，可重复执行）：

1. `android/assets/` → `ios/www/`（**只读 android，不写入**）；
2. `ios/pwa-src/` → `ios/www/`（ios.css / ios-boot.js / manifest / sw.js / icons）；
3. `tools/patch_index.js` 在 `</head>` 前重新注入 iOS 增强块（先删旧块再插新块，
   不会重复堆叠）；
4. 给 `sw.js` 打**内容版本戳**（`index.html + ios.css + ios-boot.js + manifest`
   的 cksum），缓存名随之变化 → 旧 shell 缓存自动作废。少了这步，浏览器
   （尤其是自动化测试复用的 profile）会继续用 Service Worker 里的旧
   `ios-boot.js`，改完代码却「测到旧行为」；
5. 若本机有 `python3 + Pillow`，由 `logo-brand.png` 重新合成 1024/512/192/180/
   167/152/120 图标与 AppIcon 全套尺寸；没有则沿用已提交的 PNG；
6. 自检关键文件、校验版本戳已替换，并打印缺失项。

只想换图标：

```bash
python3 ios/tools/make_pwa_icons.py \
  android/assets/logo-brand.png \
  ios/pwa-src/icons \
  ios/FreightHeat/Assets.xcassets/AppIcon.appiconset
bash ios/build_www.sh
```

---

## 验证记录（Windows + headless Edge，非 iOS 真机）

用 iframe 精确固定视口（headless 在 Windows 下窗口宽度会被钳制，直接用
`--window-size` 会得到错误布局，所以走 iframe 方案）：

**390×844 / 430×932 布局**

| 指标 | 390×844 | 430×932 |
| --- | --- | --- |
| 顶栏 | 0–46px，无换行 | 0–46px |
| 地图区 | 46–791px，铺满 | 46–879px |
| 底部面板 peek | 53px（= 把手 15 + 标题 38） | 53px |
| 横向溢出 | 无 | 无 |
| 文档滚动高度 | 844（整页不滚动） | 932 |
| 列表条目 / 面包屑 | 18 条 / 「全国 · 省级」 | 同 |

**模拟安全区**（注入 `--ios-safe-top:47px`、`--ios-safe-bottom:34px`）

分两种时序各测一遍（这是 v2 修复的重点，见上一节）：

| 指标 | 安全区在解析期就位 | 安全区在加载完成后注入 |
| --- | --- | --- |
| 面板 peek（API） | 87px | 87px ✅ |
| 可见条带高度 | 87px | 87px ✅ |
| 面板顶边 | 757 / 845 | 757 / 845 ✅ |
| 标题文字底边 | 800.6 / 888.6 | 800.6 / 888.6 ✅ |
| home indicator 带起点 | 810 / 898 | 810 / 898 |
| 标题是否压手势条 | 否（余量 9.4px） | 否（余量 9.4px）✅ |
| 面板已展开时注入 | — | 保持展开（886/798px），不被打断 ✅ |
| 顶栏 `padding-top` | 55px（8 + 47） | 55px |
| `#side` 底部内边距 | 34px（展开档按钮条不被手势条覆盖） | 34px |
| 设置面板底部留白 | 50px（16 + 34） | 50px |
| 缩放按钮 / 返回键 | 顶部偏移 +47px | +47px |

> 复现与回归脚本的注意点：headless 的虚拟时钟不推进 CSS 过渡，直接量
> `getBoundingClientRect()` 会读到过渡起始值（面板永远是 791）。测量前需要
> 先把 `#side` 的 `transition` 置为 `none` 再读，否则会误判成「面板没动」。

**Round 2 回归（针对 QA 报的两个缺陷）**

用和壳工程完全一致的入口 `__iosApplySafeArea(47, 34, 0, 0)` 复现，两台视口结果一致：

| 断言 | 390×844 | 430×932 |
| --- | --- | --- |
| 长按 700ms → 录入面板显示 | `block`（标题「北京市」） | 同 |
| 松手后 touchend + 合成 click → 面板仍在 | **`block`** ✅（修复前 `none`） | 同 |
| 普通单击仍能下钻 | 面包屑 全国·省级 → 北京市·地市级 ✅ | 同 |
| 抑制窗口内点「取消」仍能关闭面板 | `none` ✅（守卫只拦 `#map` 内） | 同 |
| 抑制窗口内点地图被吞掉 | 面包屑不变 ✅ | 同 |
| 抑制窗口结束后点地图恢复 | 北京市·地市级 ✅ | 同 |
| 安全区注入后 peek（API） | **87** | **87** |
| 可见条带 | 87 | 87 |
| 标题文字底边 < 手势带起点 | 800.6 < 810 ✅ | 888.6 < 898 ✅ |
| 顶栏 `padding-top` / `#side` 底内边距 | 55 / 34 | 55 / 34 |

**Round 3 回归（长按「按住超过 800ms」场景，含对照组）**

合成 TouchEvent 驱动，每次用干净 iframe + 清空的 localStorage；`mouseup` 按真机
习惯在 `touchend` 之后补发，否则页面的 `moved` 不会复位、测不到关闭路径。

| 用例 | 断言 | 实测 |
| --- | --- | --- |
| T1 长按 700ms → 置 `__fxSuppressClick` → click | 面板应保持在 | `block` ✅ |
| T2 长按 700ms → **强制 `__fxSuppressClick=false`** → click | 面板应被关闭（对照组，证明 T1 非假阳性） | `none` ✅ |
| T3 普通 click（无触摸序列） | 应正常下钻 | 全国·省级 → 北京市·地市级 ✅ |
| T4 按住 1600ms（页面 800ms 已过期）松手 | **`__fxSuppressClick` 应被重新置真** | `true` ✅ |
| T4 续：幽灵 click | 面板应保持在 | `block` ✅ |
| T4 续：450ms 窗口过后 | 标志应自动清除 | `true`（已清除）✅ |
| T4 续：窗口后再点地图 | 应恢复下钻 | 北京市·地市级 ✅ |

**功能冒烟**（同源 iframe 内直接调用页面 API）

- `fetch('geo/330000.json')` → 200，11 个 features，`application/json`
- `localStorage.setItem/getItem` → 正常（回环 http 源）
- `manifest.webmanifest` → 解析成功，3 个图标
- `ios.css` / `ios-boot.js` → 加载成功（6,108 / 8,709 字节）
- `__fxSheet.expand()` → 面板高度 798px，peek 53px（无安全区时）
- `__iosSyncSheet()` → 可通过控制台手动校正 peek，便于现场排查
- 列表渲染 18 条，面包屑正常，字体栈为 `-apple-system…`

**截图检查**：390×844 默认态 / 430×932 默认态 / 390 模拟安全区 / 面板展开 /
设置面板 —— 均无文字截断、无控件溢出、地图铺满。

---

**交付时的文件清单自检**（`bash ios/build_www.sh` 会复查前 12 项）

| 检查项 | 期望 | 实测 |
| --- | --- | --- |
| `www/index.html` | 含且仅含 1 个 `IOS-ENH` 块 | 1 个（772,648 字节） |
| `www/geo/*.json` | 与 android/assets 一致 | 362 个 |
| `www/fonts/misans-sub.woff2` | 存在 | 1.4MB |
| `www/icons/` | 7 个 PNG（192/512/1024 + 4 个 apple-touch） | 7 个 |
| `AppIcon.appiconset/` | 10 个 PNG + Contents.json | 11 个文件 |
| 壳工程 Swift | 5 个源文件 | 5 个 |
| `Assets.xcassets` | AppIcon + AccentColor + LaunchBackground + 根 Contents | 齐全 |
| `android/` 是否被改动 | 零改动 | 无 `IOS-ENH` 痕迹 |
| `ios/www` 体积 | ≈ android/assets | 16MB（geo 占 13MB） |

**未验证项**（无 macOS，诚实标注）

- Swift 工程编译、真机启动、签名归档
- iOS Safari 真机的 `env(safe-area-inset-*)` 实际取值（用注入变量的方式等价验证过）
- Service Worker 在 HTTPS 托管下的实际缓存命中（沿用标准写法，未在 iOS 上跑过）
- **iOS Safari 长按松手是否合成 click**：Chromium 会（守卫已按该行为验证），
  真机若不合成 click 则守卫空转、无副作用，但「长按→录入」整条链路仍需真机走一遍
- `__iosApplySafeArea()` 由 Swift 在 `didFinish` / `safeAreaInsetsDidChange` 调用，
  这两处回调的时序在真机上未实测（浏览器侧用等价调用验证）

---

## 已知限制

1. **未在 iOS 真机 / 模拟器编译验证**：本环境无 macOS + Xcode，Swift 工程只做了
   代码级自审。首次在 macOS 上构建如报错，优先检查 Xcode 版本与
   `xcodegen generate` 的告警。
2. **`www` 是构建产物**：目录可能被脚本整体覆盖，任何手工修改都应改在
   `ios/pwa-src/`，否则下次同步会丢失。
3. **兜底通道功能受限**：走 `appassets://` 时（回环服务启动失败才会用到）
   `localStorage` 与 `fetch` 不可用，运价数据不会持久化、地图只能看内置省级边界。
   正常情况不会触发，`WebSession.channel` 会标记当前通道，便于排查。
4. **首屏体积**：`index.html` 约 771KB（内联全国边界数据），首次加载 1s 左右，
   之后由 Service Worker 缓存。
5. **导出走系统分享**：不落「文件」App 的固定目录，用户需要在分享面板里选择
   「存储到文件」。导入仍走原生文件选择器，行为与 Android 一致。
6. **横屏**：`Info.plist` 允许竖屏 + 左右横屏，页面本身在 ≤900px 断点下按移动布局
   渲染；横屏时底部面板会占据较大高度，这是原设计的既有表现。
