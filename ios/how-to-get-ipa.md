# 怎么拿到真正的 .ipa

## 先说清楚一件事

`.ipa` 不是改后缀能改出来的。它的内部是：

```
Payload/
  FreightHeat.app/
    FreightHeat          ← ARM64 机器码，Swift 编译产物
    Info.plist
    www/                 ← 网页资源
```

那个 `FreightHeat` 可执行文件**只能由 Apple 的 Xcode 工具链在 macOS 上生成**。
Windows 没有 iOS SDK、没有 Apple 链接器，改后缀 / 压缩 / 转换都做不出能装进 iPhone 的包。
这不是配置问题，是平台限制。绕过去只有一条路：**借一台 macOS 编译**。GitHub 免费提供。

---

## 路线 A：用你桌面的 GitHub Desktop（推荐，4 步）

仓库我已经在本机初始化好了（`.gitignore` 已排除 APK、87MB 截图、48MB 测试依赖，
待提交 **418 个文件 / 16MB**），你只需要把它推上去。

### 1. 打开仓库

打开 **GitHub Desktop** → 菜单 **File → Add local repository…**

选择这个目录：

```
C:\Users\85826\WorkBuddy\2026-11-11-00-47-51\货运老司机工具
```

> 它已经是 Git 仓库，不会提示创建，直接显示 418 个待提交文件。
> 如果它要求先登录，用你的 GitHub 账号登录一次；如果要求 Configure Git，随便填你的名字和邮箱。

### 2. 提交（已经做好了，可跳过）

本机仓库里已经有一次提交：

```
1c8133d  iOS 版：PWA + WKWebView 壳 + 云端编译 ipa 流程
```

419 个文件，`.gitattributes` 已锁定 LF。如果你在 GitHub Desktop 里还看到零散改动，
顺手 Commit 一下；没有就直接下一步。

### 3. 发布到 GitHub

点右上角 **Publish repository**，在弹出的窗口里：

- **Name**：改成英文，例如 `freight-heat`（默认是中文目录名，URL 会很难看）
- **Description**：可留空
- **Keep this code private**：**取消勾选**

> 为什么建议公开：GitHub 对 **Public** 仓库的 macOS 机器**不限时长、完全免费**；
> Private 仓库走额度（macOS 按 10 倍计费，免费额度大约只够 30 次构建）。
> 这个项目里没有任何密钥、账号、真实客户数据，公开源码不会泄露隐私。介意的话也可以选 Private。

点 **Publish repository**。

### 4. 等编译，下载 ipa

推送完成后打开 `https://github.com/你的用户名/freight-heat` → 顶部 **Actions** 标签，
会自动开始跑 **Build unsigned IPA**：

| 阶段 | 耗时 |
| --- | --- |
| 检查源码 | 10 秒 |
| 装 XcodeGen | 1~2 分钟 |
| 生成工程 → 归档 → 打包 ipa | 2~4 分钟 |

跑完点进这次运行记录，页面底部 **Artifacts** → 下载 `FreightHeat-ipa`，解压得到：

```
FreightHeat-12.4.1-unsigned.ipa
```

> 失败了就下载同页的 `build-logs`，把里面 `archive.log` 发我。
> 流程里已加硬断言：网页资源没打进 App 会直接报 `Bundle 内缺少 www/index.html`，
> 不会出现「编译成功但装上白屏」这种坑。

---

## 装进 iPhone（未签名 ipa 必须自签一次）

Apple 不允许未签名 App 安装，要用自己的 Apple ID 现签。Windows 上用 **Sideloadly**：

1. 电脑装 **iTunes**（apple.com 下桌面版，别用 Microsoft Store 版）和 **iCloud**，装完重启。
2. 下载 **Sideloadly**：https://sideloadly.io/
3. iPhone 数据线连电脑，手机上点「信任此电脑」。
4. Sideloadly 里把 `.ipa` 拖进 **IPA** 框，**Apple ID** 填自己的，点 **Start**。
5. 弹窗输 Apple ID 密码（走 Apple 官方接口申请免费开发证书）。
6. iPhone：**设置 → 通用 → VPN 与设备管理 → 开发者 App → 信任**。
7. iOS 16 以上还要开：**设置 → 隐私与安全性 → 开发者模式 → 打开 → 重启**。

### 免费 Apple ID 的限制

- 签出的 App **7 天**后失效，重新用 Sideloadly 装一次即可，App 里的数据不丢。
- 同时最多 3 个自签 App。
- 想省事：
  - Apple Developer Program（99 美元/年）→ 签名有效期 1 年；
  - 或设备在 **iOS 14.0–16.6.1** 且支持 **TrollStore** → 直接装未签名 ipa，永久有效。

---

## 路线 B：不想用 GitHub Desktop，走网页上传

需要两个文件：`ios-source.zip`（6MB）+ `.github/workflows/build-ipa.yml` 的内容。

1. https://github.com/new 建空仓库（不勾任何初始化文件）。
2. 仓库里 **Add file → Create new file**，文件名填 `.github/workflows/build-ipa.yml`，
   把本机 `.github/workflows/build-ipa.yml` 全文粘进去，提交。
3. **Add file → Upload files** 上传 `ios-source.zip`，提交。
4. Actions 自动跑，产物同上。

> 走这条路必须用 zip：GitHub 网页单次上传上限 100 个文件，而 `www/geo` 里有 362 个 JSON。
> 流程里的第一步会自动把它解压成 `ios/` 再编译。

---

## 路线 C：自己有 Mac

```bash
brew install xcodegen
cd ios/FreightHeat
xcodegen generate
open FreightHeat.xcodeproj
```

Xcode 选自己的 Team → 连 iPhone → Run。要 ipa：**Product → Archive → Distribute App**。
Bundle ID 是 `com.freightheat.ios`，签不上就改成 `com.你的名字.freightheat`。

---

## 路线 D：其实你不需要 ipa

目的只是「在 iPhone 上像 App 一样用」，PWA 就够，不用签名、不会 7 天过期：

1. 把 `ios/www/` 传到任意 HTTPS 静态托管（Vercel / Netlify / Cloudflare Pages 拖拽即部署）。
2. iPhone Safari 打开地址。
3. 底部**分享** → **添加到主屏幕**。

结果：桌面图标、全屏无地址栏、可离线（Service Worker 已内置）。代价是没有 `.ipa` 这个文件。

---

## 常见问题

**Q：能不能把 APK 转成 ipa？**
不能。不同系统、不同 CPU 指令集、不同包格式，没有转换工具能做到。

**Q：为什么你不直接帮我推到 GitHub？**
这机器没有登录任何 GitHub 账号，`gh` 命令行也装不上（下载通道被网络限制）。
账号和仓库公开性该由你决定，我不擅自代传。

**Q：Publish 按钮是灰的？**
说明还没提交。先在第 2 步点 **Commit to main**。

**Q：构建报 `xcodegen: command not found`？**
流程里会自动 `brew install xcodegen`；brew 偶发超时的话，重新 Run 一次。
