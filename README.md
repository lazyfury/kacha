# ushot

macOS 截图工具。**纯 Swift**：AppKit 管窗口、Core Graphics 画界面、ScreenCaptureKit 抓屏；
编辑 / 设置窗口的界面用 **SwiftUI**（macOS 26 上是 Liquid Glass，旧系统回退到材质）。
菜单栏常驻（`.accessory` + `LSUIElement`），无常驻主窗，窗口只在需要时打开。

**系统要求：macOS 14.0 (Sonoma) 起**（ScreenCaptureKit 单帧捕获从 14 才有）。

没有 Rust、没有 C ABI、没有第三方 UI 依赖。`Package.swift` 在仓库根目录，Xcode 直接打开
本目录即可当作项目构建 / 运行。

## 功能

- **截图**（默认 `⌘⇧A`）：冻结所有显示器 → 每屏一个无边框覆盖层。
  - 拖拽 / 手柄圈选区域，十字线 + 尺寸读数 + 底部提示；`Enter` 确认。**有选区时单击空白
    只会清掉选区（不会直接截全屏 / 窗口），右键 / `Esc` 同样返回上一步；没有选区时再按才
    取消整个截图。**
  - 直接**点选窗口**（AppKit 命中测试，考虑真实 z-order / 遮挡），点空白处则抓整屏。
- **全屏截图**（默认 `⌘⇧F`）：直接抓鼠标所在显示器进编辑窗，不走覆盖层。
- **取色器**（默认 `⌘⇧C`）：在冻帧上取样，放大镜 + hex 读数；点击或 `Enter` 复制 hex，
  `Esc` 取消。
- **编辑窗**：矩形（可填充）/ 箭头 / 画笔 / 文字（支持 IME，**可二次编辑**）/
  **半透明粗笔高亮** / **可涂抹马赛克** + 撤销重做；工具栏是 SwiftUI **Liquid Glass** 浮条，
  颜色（8 色）与线宽（4 档）可选，画布仍是 AppKit。
  复制到剪贴板、保存 PNG、钉到桌面。钉图是可交互的置顶悬浮图：拖拽移动、**拖四角缩放
  （锁宽高比）**、悬停左上角关闭、右键菜单（复制 / 保存 / 关闭）、双击或 `Esc` 关闭；
  菜单栏还有「关闭所有钉图」。
- **设置**：自定义截图 / 全屏 / 取色三个全局热键、开机自启。
- 截图与导出都是**原生像素**（Retina 2x）。

## 架构

```text
Sources/UShotMac/
  main.swift              NSApplication + .accessory + 启动参数
  AppDelegate.swift       生命周期、菜单、热键、截图/取色入口、smoke 自检
  MenuBar.swift           NSStatusItem + 菜单
  Hotkeys.swift           Carbon RegisterEventHotKey（无需辅助功能权限）
  Preferences.swift       热键 / 开机自启（UserDefaults）
  LaunchAtLogin.swift     SMAppService
  Permissions.swift       屏幕录制 TCC 引导

  Capture.swift           ScreenCaptureKit：冻帧 / 单窗口捕获
  Session.swift           一次截图会话的共享状态（冻帧、选区、合成图、悬停窗口）
  OverlayWindow.swift     每屏一个无边框 NSPanel：冻帧背景 + 选区 / 窗口高亮 / 取色
  Selection.swift         选区拖拽几何（纯逻辑，可单测）
  Compose.swift           选区 → 原生像素 RGBA
  ColorPicker.swift       取色器放大镜 + hex

  EditorWindow.swift      编辑窗（NSWindow 宿主）
  EditorRootView.swift    编辑窗 SwiftUI：玻璃工具栏 + 画布 representable
  EditorCanvasView.swift  画布：合成图 + 标注绘制 + 图像/视图坐标映射
  Annotate.swift          标注数据模型 + SF Symbols
  PinWindows.swift        钉图悬浮窗
  SettingsWindow.swift    设置窗（NSWindow 宿主）
  SettingsRootView.swift  设置窗 SwiftUI：原生分组表单 + 热键录制 representable
  HotkeyRecorderView.swift AppKit 热键录制按钮
  PNG.swift               ImageIO PNG 编码
  SelfCheck.swift         `--selfcheck` 纯逻辑断言

packaging/Info.plist      LSUIElement=true、LSMinimumSystemVersion=14.0
scripts/{build,run,package}.sh
```

## 构建 / 运行

```bash
scripts/build.sh                 # swift build
scripts/run.sh                   # 构建并运行（菜单栏，无窗口）
scripts/run.sh --smoke-editor    # 开/关编辑窗，走 AppKit 真实关闭路径
scripts/run.sh --smoke-export    # 注入合成图 → 编辑 → 复制到剪贴板
scripts/package.sh [--open]      # 组装并 ad-hoc 签名 dist/ushot.app

./scripts/dev.sh                 # build + selfcheck + settings/editor/export smoke
```

也可以直接用 **Xcode** 打开仓库根目录（`Package.swift` 即项目），选 `ushot-mac` scheme 运行。

首次截图需在「系统设置 › 隐私与安全性 › 屏幕录制」里授予权限并重启。

## 自检

- `--selfcheck`：纯逻辑断言（坐标、裁剪、PNG、标注栅格化），无窗口、无屏幕录制权限、无 XCTest。
- `--smoke-settings` / `--smoke-editor` / `--smoke-export`：真实开 / 关窗口路径。
- **不写截图 / 录屏测试**：渲染与捕获用自检 + 纯函数单测覆盖。

## 已知缺口

- 形状 / 画笔固定红色 2px，文字固定 18px（按图片对角线缩放）；高亮是半透明黄、马赛克是
  粗笔刷涂抹，宽度按对角线缩放（最小 16px）。没有颜色 / 线宽选择器。
- 文字提交后不能二次编辑（可撤销）。
- 窗口拾取不做 app 级分组 / 子窗口选择。
- 序号 / 延时 / OCR / 滚屏长图未做。
