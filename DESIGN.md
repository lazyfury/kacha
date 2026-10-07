# ushot — 设计文档（macOS 截图工具 / 纯 Swift）

> 状态：**已实现并收尾**。工作名 `ushot`。当前实现是纯 Swift（AppKit + Core Graphics +
> ScreenCaptureKit），没有 Rust / C ABI。旧的 Rust（igui）设计保留在 git 历史里。

---

## 1. 定位

一个常驻菜单栏、全局热键触发的 macOS 截图工具：

- **截图模式**：框选区域、点选窗口、点桌面抓整屏。
- **框选层**：触发后先抓取所有显示器，「冻结」整个桌面；用户拖拽框选 / 调整手柄；
  `Enter` 确认、`Esc` 取消。层内带十字线、尺寸读数。
- **编辑窗**：预览 + 标注（矩形 / 箭头 / 画笔 / 高亮 / 文字 / 马赛克）+ 撤销重做；
  复制到剪贴板、保存 PNG、钉在桌面。
- **取色器**：在冻帧上取样，放大镜 + hex，点击复制。
- **零第三方依赖**：界面用 AppKit / Core Graphics 画，抓屏用系统 ScreenCaptureKit。

### 1.1 非目标（MVP 不做）

- 录屏 / GIF、滚屏长图、云上传与分享链接。
- 多用户 / 账户 / 同步。
- Windows / Linux 壳。
- 用截图做**测试**验证（见 §7）。

---

## 2. 总体架构

一句话：**AppKit 拥有窗口、系统能力与事件；Core Graphics 拥有全部 UI 绘制与图像处理；
ScreenCaptureKit 提供像素数据。**

```
┌─────────────────────────────────────────────────────────────┐
│ AppKit (Swift)                                              │
│  NSApplication(.accessory) / NSStatusItem / 菜单            │
│  Carbon RegisterEventHotKey（全局热键）                      │
│  每屏无边框 NSPanel（覆盖层）/ NSWindow（编辑窗 / 钉图 / 设置）│
│  ScreenCaptureKit（冻帧 / 窗列表 / 单窗口捕获）              │
│  NSPasteboard / NSSavePanel / TCC 权限                       │
├─────────────────────────────────────────────────────────────┤
│ Core Graphics (Swift)                                       │
│  NSView.draw → CGContext：遮罩 / 选区 / 手柄 / 十字线 / 文字  │
│  编辑器画布：底图 + 标注栅格化                                │
│  Compose：选区 → 原生像素 RGBA；PNG：ImageIO 编码            │
└─────────────────────────────────────────────────────────────┘
```

- **没有 FFI 边界**：窗口、UI、图像处理都在同一个 Swift 进程 / 同一个主线程。
- **没有渲染循环**：窗口是 AppKit 普通视图，状态变化时 `setNeedsDisplay`；不跑
  `CADisplayLink` / Metal。
- **帧由事件驱动**：鼠标 / 键盘事件改 `CaptureSession` 的状态，视图重绘。

---

## 3. 目录布局

```
ushot/
├── Package.swift                 # SwiftPM：可执行目标 ushot-mac
├── Sources/UShotMac/
│   ├── main.swift                # NSApplication + .accessory + 启动参数
│   ├── AppDelegate.swift         # 生命周期 / 菜单 / 热键 / 截图·取色入口 / smoke
│   ├── MenuBar.swift             # NSStatusItem + 菜单
│   ├── Hotkeys.swift             # Carbon RegisterEventHotKey
│   ├── Preferences.swift         # 热键 / 开机自启（UserDefaults）
│   ├── LaunchAtLogin.swift       # SMAppService
│   ├── Permissions.swift         # 屏幕录制 TCC 引导
│   ├── Capture.swift             # ScreenCaptureKit：冻帧 / 单窗口
│   ├── Session.swift             # CaptureSession：冻帧 / 选区 / 合成图 / 悬停
│   ├── OverlayWindow.swift       # 每屏一个 NSPanel + SelectionView
│   ├── Selection.swift           # 选区几何与拖拽状态（纯逻辑）
│   ├── Compose.swift             # 选区 → 原生像素 RGBA
│   ├── ColorPicker.swift         # 放大镜 + 像素取样 + hex
│   ├── EditorWindow.swift        # 编辑窗 + 工具栏
│   ├── EditorCanvasView.swift    # 画布：底图 + 标注 + 坐标映射
│   ├── Annotate.swift            # 标注数据模型
│   ├── PinWindows.swift          # 钉图悬浮窗
│   ├── SettingsWindow.swift      # 设置窗
│   ├── HotkeyRecorderView.swift  # 热键录制按钮
│   ├── PNG.swift                 # ImageIO PNG 编码
│   └── SelfCheck.swift           # --selfcheck 纯逻辑断言
├── packaging/Info.plist          # LSUIElement=true、LSMinimumSystemVersion=14.0
└── scripts/{build,run,package,dev}.sh
```

---

## 4. 关键技术决策

### 4.1 抓屏：ScreenCaptureKit（macOS 14+）

- 单帧：`SCScreenshotManager.captureImage(contentFilter:configuration:)`（macOS 14，async）。
- 列表：`SCShareableContent.current`（显示器 / 窗口）、`SCContentFilter`。
- **排除自身**：filter 排除本 app 的窗口（否则覆盖层拍到自己）；同时把所有本 app 窗口
  `sharingType = .none` 双保险。
- 最低系统 **macOS 14.0**，与 `Package.swift` 的 `.macOS(.v14)` 一致。

### 4.2 冻结观感

macOS 自带截图「画面冻住」是因为它**先抓后显**。本工具同法：热键 → 抓所有屏 →
覆盖层的 `NSPanel` 把冻帧作为背景（1:1，无缩放），上面叠一个透明 `SelectionView` 画
遮罩 / 选区 / 手柄 / 十字线 / 尺寸读数。

### 4.3 多显示器与坐标系

- 内部统一 **全局逻辑点，原点左上**（= CoreGraphics 全局坐标）。
- 每个覆盖层减去自己 `NSScreen.frame` 的 origin 得到局部坐标。
- 冻帧按 backing scale 抓成**原生像素**；布局用**逻辑尺寸**、纹理用**像素尺寸**。
- 选择状态（矩形）存在会话里、用全局坐标；跨屏选择自然成立。
- 菜单栏 / 刘海 / 非均匀缩放（外接屏 1x + 内建 2x）都按「每屏自己的 scale」处理。

### 4.4 会话（共享状态）

一次截图从创建到结束共享一个 `CaptureSession`：

```swift
final class CaptureSession {
    private(set) var displays: [CGDirectDisplayID: CapturedDisplay]  // 冻帧 + 几何
    var mode: OverlayMode          // .capture / .colorPicker
    var selection: CGRect?         // 全局逻辑点
    var composed: ComposedImage?   // 确认后裁剪出的合成图（CGImage + RGBA8）
    var hover: CGRect?             // 鼠标下的窗口（全局逻辑点）
}
```

覆盖层确认后把 `composed` 交给编辑窗；编辑窗只持有这张图与自己的标注数组。

### 4.5 统一覆盖层（区域 / 窗口 / 整屏）

一个 `SelectionView` 同时处理三种目标，用「点击 vs 拖拽」区分：

- 按下后位移 < `clickSlop`（4pt）→ 视为**点击**：鼠标下有窗口就选该窗口，否则选整屏。
- 位移超过阈值 → 视为**拖拽**：进入矩形圈选，画手柄，`Enter` 确认。
- 未开始时高亮鼠标下的窗口（用 `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)`
  命中测试，考虑真实 z-order / 遮挡）。

### 4.6 合成与导出

`Compose.compose(displayList, selection:)` 把选区从各屏冻帧裁出拼成一张图：输出 scale 跟随
选区左上角所在显示器，常见情况是精确 1:1；跨 DPI 时取最大 scale。结果同时保留 `CGImage`
（画布用）与紧凑 RGBA8（马赛克取样用）。PNG 导出走 ImageIO，颜色由 Core Graphics 管理。

### 4.7 编辑器画布

`EditorCanvasView` 在视图坐标与**图像像素坐标**之间做映射（letterbox 缩放 / 平移），标注
一律存图像像素坐标，所以导出不受画布缩放影响。标注是纯数据模型（`Annotate.swift`），
绘制时栅格化到 `CGContext`。形状 / 画笔的默认线宽、字号按图片对角线派生；高亮 / 马赛克是
marker 工具，用 `defaultMarkerStroke`（最小 16px）的粗笔刷。

- **高亮**：半透明黄（alpha 0.35）的 freehand 粗线（round cap / join），文字能透出来。
- **马赛克**：`Mosaic.make` 把整张合成图按 `mosaicBlock` 做一次块平均并缓存，绘制时用
  `replacePathWithStrokedPath()` 把 freehand 折线变成粗笔刷轮廓 `clip()`，再把块平均图
  无插值放大画进去。所以是「涂抹」而不是拖矩形，而且每次重绘不重算平均色。

---

## 5. 数据流（时序）

```
热键 ⌘⇧A
  └─ AppDelegate.startCapture()
       ├─ Capture.freezeAllDisplays()  → [CapturedDisplay]
       ├─ 建 CaptureSession(mode: .capture) + 每屏 OverlayWindow
       └─ 用户交互：拖拽圈选 / 点击窗口 / 点击桌面
            └─ Enter 或点击 → session.confirm()（Compose 裁剪出 composed）
                 └─ overlays.onConfirm → EditorWindow.show(session:)
                      └─ 标注 / 复制 / 保存 / 钉图 → EditorAction
                           └─ AppDelegate 执行系统动作（NSPasteboard / NSSavePanel / PinWindows）
```

取色器同流程，只是 `mode = .colorPicker`，确认时把 hex 写进剪贴板。

---

## 6. 热键与权限

- 全局热键用 Carbon `RegisterEventHotKey`：**不需要辅助功能权限**，且能拦到其他 app 的按键。
  默认截图 `⌘⇧A`、取色 `⌘⇧C`，在设置窗里可改（`HotkeyRecorderView`）。
- 屏幕录制是 per-user TCC：首次抓屏前用 `CGPreflightScreenCaptureAccess` /
  `CGRequestScreenCaptureAccess` 引导，授予后需重启 app。
- 开机自启用 `SMAppService`（macOS 13+），只在真正的 `.app` bundle 里有意义。

---

## 7. 验证策略

- **不写截图 / 录屏测试**（见 AGENTS 硬规则）。
- `--selfcheck`：纯逻辑断言，无窗口、无屏幕录制权限、无 XCTest。覆盖坐标 / 裁剪 / PNG /
  标注栅格化等纯函数。
- `--smoke-settings` / `--smoke-editor` / `--smoke-export`：真实开 / 关窗口路径，回归
  `isReleasedWhenClosed` 崩溃与编辑窗生命周期。
- `scripts/dev.sh` 串起 build + selfcheck + 三个 smoke。

---

## 8. 已知缺口 / 后续

- 形状 / 画笔固定红色 2px，文字固定 18px（按对角线缩放）；没有颜色 / 线宽选择器。
  高亮固定半透明黄、马赛克涂抹，宽度按对角线缩放（最小 16px）。
- 文字提交后不能二次编辑（可撤销）。
- 窗口拾取不做 app 级分组 / 子窗口选择。
- 序号 / 椭圆 / 裁剪 / 延时 / OCR / 滚屏长图未做。
- 多显示器非均匀缩放下的跨屏拼接以最大 scale 兜底，尚未逐屏混合。
