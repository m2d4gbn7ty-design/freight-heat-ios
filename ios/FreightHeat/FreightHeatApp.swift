//
//  FreightHeatApp.swift
//  FreightHeat
//
//  SwiftUI App 入口。
//  全屏 WKWebView 承载与 Android 版完全相同的 web 页面（ios/www），
//  原生侧只负责：资源服务、安全区、导出分享、状态栏样式。
//

import SwiftUI

// MARK: - 主题常量

/// 与页面 `:root` / theme-color 对齐的配色，避免启动瞬间闪白。
enum Theme {
    static let deepNavy = Color(red: 7 / 255, green: 20 / 255, blue: 38 / 255)
    static let midnight = Color(red: 18 / 255, green: 30 / 255, blue: 53 / 255)
    static let ink = Color(red: 232 / 255, green: 238 / 255, blue: 248 / 255)
    static let dim = Color(red: 154 / 255, green: 172 / 255, blue: 194 / 255)
}

// MARK: - App

@main
struct FreightHeatApp: App {

    var body: some Scene {
        WindowGroup {
            RootView()
                // 深色界面：让状态栏文字保持浅色，与 black-translucent 视觉一致
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - 根视图

struct RootView: View {

    @StateObject private var session = WebSession()

    var body: some View {
        ZStack {
            // 底层兜底色：页面首帧之前不会有白屏
            LinearGradient(
                colors: [Theme.midnight, Theme.deepNavy],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // Web 内容铺满全屏，安全区由页面 CSS 自己让开
            WebView(session: session)
                .ignoresSafeArea()

            if !session.isReady {
                LaunchOverlay(message: session.failureMessage)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.28), value: session.isReady)
    }
}

// MARK: - 启动遮罩

/// 页面首帧之前的过渡层。资源缺失时会直接把原因显示出来，方便现场排查。
private struct LaunchOverlay: View {

    let message: String?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.midnight, Theme.deepNavy],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Theme.ink.opacity(0.92))
                    .padding(22)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )
                    )

                Text("运价热力看板")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)

                if let message {
                    Text(message)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.dim)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .padding(.horizontal, 32)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(Theme.dim)
                            .scaleEffect(0.85)
                        Text("正在加载离线地图资源…")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.dim)
                    }
                }
            }
            .padding(28)
        }
    }
}
