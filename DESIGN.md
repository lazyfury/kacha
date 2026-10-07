# kacha — 设计文档（macOS 截图工具 / 纯 Swift）

> 状态：**已实现并收尾**。工作名 `kacha`。当前实现是纯 Swift（AppKit + Core Graphics +
> ScreenCaptureKit），没有 Rust / C ABI。旧的 Rust（igui）设计保留在 git 历史里。
> 系统要求：**macOS 14.0 (Sonoma) 起**。

---

## 1. 定位

一个常驻菜单栏、全局热键触发的 macOS 截图工具：

- **截图模式**：框选区域、点选窗口、点桌面抓整屏。
- **框选层**：触发后先抓取所有显示器，「冻结」整个桌面；用户拖拽框选 / 调整手柄；
  `Enter` 确认、`Esc` 取消。层内带十字线、尺寸读数。
- **编辑窗**：预览 + 标注（矩形 / 箭头 / 画笔 / 高亮 / 文字 / 马赛克）+ 撤销重做；
  复制到剪贴板、保存 PNG、钉在桌面；**OCR 文字识别**（系统 Vision，离线）。
- **取色器**：在冻帧上取样，放大镜 + hex，点击复制。
- **看图模式**：菜单栏「看图」开一个空编辑窗（工具禁用），拖入图片后进入和截图一样的
  标注 / 导出 / OCR 流程。
- **零第三方依赖**：界面用 AppKit / Core Graphics 画，抓屏用系统 ScreenCaptureKit。

### 1.1 非目标（MVP 不做）

- 录屏 / GIF、滚屏长图、云上传与分享链接。
- 多用户 / 账户 / 同步。
- Windows / Linux 壳。
- 用截图做**测试**验证（见 §7）。

---

## 2. 总体架构

一句话：**AppKit 拥有窗口、系统能力与事件；SwiftUI 负责编辑 / 设置窗口的 chrome（macOS 26
上是 Liquid Glass）；Core Graphics 拥有全部画布绘制与图像处理；ScreenCaptureKit 提供像素数据。**

```
┌─────────────────────────────────────────────────────────────┐
│ AppKit (Swift)                                              │
│  NSApplication(.accessory) / NSStatusItem / 菜单            │
│  Carbon RegisterEventHotKey（全局热键）                      │
│  每屏无边框 NSPanel（覆盖层）/ NSWindow（编辑窗 / 钉图 / 设置）│
│  ScreenCaptureKit（冻帧 / 窗列表 / 单窗口捕获）              │
│  NSPasteboard / NSSavePanel / TCC 权限                       │
├─────────────────────────────────────────────────────────────┤
│ SwiftUI (NSHostingView)                                     │
│  编辑窗工具栏（玻璃浮条）/ 设置窗表卡                       │
│  macOS 26+：glassEffect / GlassEffectContainer；否则材质回退 │
├─────────────────────────────────────────────────────────────┤
│ Core Graphics (Swift)                                       │
│  NSView.draw → CGContext：遮罩 / 选区 / 手柄 / 十字线 / 文字  │
│  编辑器画布：底图 + 标注栅格化（AppKit 仍管画布）            │
│  Compose：选区 → 原生像素 RGBA；PNG：ImageIO 编码            │
└─────────────────────────────────────────────────────────────┘
```

- **同一个进程 / 主线程**：AppKit 宿主窗口，SwiftUI 通过 `NSHostingView` 嵌入，画布通过
  `NSViewRepresentable` 双向桥接；热键录制是 SwiftUI 控件 + 本地 `NSEvent` 监听。没有 FFI 边界。
- **没有渲染循环**：画布是 AppKit 普通视图，状态变化时 `setNeedsDisplay`；不跑
  `CADisplayLink` / Metal。
- **帧由事件驱动**：鼠标 / 键盘事件改 `CaptureSession` / `EditorState` 的状态，视图重绘。
- **主线程隔离**：状态与 UI 类（`CaptureSession` / `EditorState` / 各窗口与控制器 /
  `AnnotationRenderer`）一律标注 `@MainActor`；`main.swift` 顶层代码用
  `MainActor.assumeIsolated` 进入该隔离。纯函数 / 系统包装（`Selection` / `Compose` /
  `Mosaic` / `Preferences` / `PNG` 等）保持 nonisolated。

---

## 3. 目录布局

```
kacha/
├── Package.swift                 # SwiftPM：可执行目标 kacha-mac
├── Sources/KachaMac/
│   ├── main.swift                # NSApplication + .accessory + 启动参数（保持在 target 根）
│   ├── App/                      # 生命周期与入口
│   │   ├── AppDelegate.swift     # 生命周期 / 菜单 / 热键 / 截图·取色入口 / smoke
│   │   ├── MenuBar.swift         # NSStatusItem + 菜单
│   │   └── LaunchOptions.swift   # --selfcheck / --smoke-* 参数
│   ├── Core/                     # 纯逻辑 / 模型 / 抓屏结果（不建窗口）
│   │   ├── Capture.swift         # ScreenCaptureKit：冻帧 / 单窗口
│   │   ├── Session.swift         # CaptureSession：冻帧 / 选区 / 合成图 / 悬停
│   │   ├── Selection.swift       # 选区几何与拖拽状态（纯逻辑）
│   │   ├── Compose.swift         # 选区 → 原生像素 RGBA
│   │   ├── Annotate.swift        # 标注数据模型 + SF Symbols
│   │   ├── EditorState.swift     # 编辑状态（工具 / 颜色 / 标注 / 撤销栈）
│   │   ├── EditorGeometry.swift  # 画布几何与尺寸启发（纯函数）
│   │   └── Mosaic.swift          # 块平均马赛克源 + 像素取样
│   ├── UI/
│   │   ├── AppKit/               # NSWindow / NSView + Core Graphics 绘制
│   │   │   ├── OverlayWindow.swift     # 每屏 NSPanel + CaptureSelectionView / ColorPickView
│   │   │   ├── EditorWindow.swift      # 编辑窗（NSWindow 宿主）
│   │   │   ├── EditorCanvasView.swift  # 画布：鼠标 / 文字输入 / 导出
│   │   │   ├── AnnotationRenderer.swift # 标注栅格化（预览与导出共用）
│   │   │   ├── LiveTextOverlay.swift    # VisionKit 识别文字（原位选字）覆盖层
│   │   │   ├── PinWindows.swift        # 钉图悬浮窗
│   │   │   ├── ColorPicker.swift       # 放大镜 + 像素取样 + hex
│   │   │   └── WindowChrome.swift      # 窗口 chrome / isReleasedWhenClosed 统一设置
│   │   └── SwiftUI/              # NSHostingView 承载的 chrome
│   │       ├── EditorRootView.swift     # 编辑窗：玻璃工具栏 + 画布 representable
│   │       ├── OCRResultView.swift      # OCR 识别结果 sheet（可编辑 / 复制）
│   │       ├── SettingsWindow.swift     # 设置窗（NSWindow 宿主）
│   │       ├── SettingsRootView.swift   # 设置窗：系统设置风顶栏 / 卡片 / 底栏
│   │       └── HotkeyRecorderView.swift # 热键录制按钮 + 本地 NSEvent 监听
│   └── Helper/                   # 系统能力与工具
│       ├── Hotkeys.swift         # Carbon RegisterEventHotKey
│       ├── Preferences.swift     # 热键 / 开机自启（UserDefaults）
│       ├── LaunchAtLogin.swift   # SMAppService
│       ├── Permissions.swift     # 屏幕录制 TCC 引导
│       ├── PNG.swift             # ImageIO PNG 编码
│       ├── Export.swift          # 剪贴板 / 保存面板（编辑器与钉图共用）
│       ├── OCR.swift             # VisionKit 文本分析 + 合并换行
│       ├── ShotSound.swift       # 系统截图提示音
│       └── SelfCheck.swift       # --selfcheck 纯逻辑断言
├── packaging/Info.plist          # LSUIElement=true、LSMinimumSystemVersion=14.0
├── packaging/AppIcon.png         # 应用图标源图（1024×1024，macOS 图标网格）
└── scripts/{build,run,package,dev}.sh
    scripts/make-icon.sh          # AppIcon.png → dist/kacha.app/Contents/Resources/kacha.icns
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
覆盖层的 `NSPanel` 把冻帧作为背景（1:1，无缩放），上面叠一个透明的覆盖层视图画
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
    var composed: ComposedImage?   // 确认后裁剪出的合成图（CGImage + 惰性 RGBA8）
    var hover: CGRect?             // 鼠标下的窗口（全局逻辑点）
}
```

覆盖层确认后把 `composed` 交给编辑窗；编辑窗只持有这张图与自己的标注数组。

### 4.5 统一覆盖层（区域 / 窗口 / 整屏）

一个 `CaptureSelectionView` 同时处理三种目标，用「点击 vs 拖拽」区分：

- 按下后位移 < `clickSlop`（4pt）→ 视为**点击**：鼠标下有窗口就选该窗口，否则选整屏。
- 位移超过阈值 → 视为**拖拽**：进入矩形圈选，画手柄，`Enter` 确认。
- 未开始时高亮鼠标下的窗口（用 `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)`
  命中测试，考虑真实 z-order / 遮挡）。
- **两级返回 / 拦截单击**：有选区时，单击空白、右键或 `Esc` 都只清掉选区、回到上面这一步
  （重新选窗口 / 整屏），不会直接触发截取；没有选区时才 `cancel()` 整个截图。底部提示随
  「有无选区」换文案，让回退可见。

### 4.6 合成与导出

`Compose.compose(displayList, selection:)` 把选区从各屏冻帧裁出拼成一张图：输出 scale 跟随
选区左上角所在显示器，常见情况是精确 1:1；跨 DPI 时取最大 scale。结果保留 `CGImage`
（画布用）；紧凑 RGBA8（马赛克取样用）按需惰性栅格化并缓存。PNG 导出走 ImageIO，颜色由
Core Graphics 管理。

### 4.7 编辑器画布

`EditorCanvasView` 在视图坐标与**图像像素坐标**之间做映射（letterbox 缩放 / 平移），标注
一律存图像像素坐标，所以导出不受画布缩放影响。标注是纯数据模型（`Annotate.swift`），
绘制时栅格化到 `CGContext`。形状 / 画笔的默认线宽、字号按图片对角线派生；高亮 / 马赛克是
marker 工具，用 `defaultMarkerStroke`（最小 16px）的粗笔刷。

- **高亮**：半透明黄（alpha 0.35）的 freehand 粗线（round cap / join），文字能透出来。
- **马赛克**：`Mosaic.make` 把整张合成图按 `mosaicBlock` 做一次块平均并缓存，绘制时用
  `replacePathWithStrokedPath()` 把 freehand 折线变成粗笔刷轮廓 `clip()`，再把块平均图
  无插值放大画进去。所以是「涂抹」而不是拖矩形，而且每次重绘不重算平均色。
- **矩形填充**：`Annotation.filled` 存在标注上；填充用颜色 alpha 0.35，然后再描边。
- **颜色 / 线宽**：工具栏改的是 `EditorState.color`（8 色）与 `strokeFactor`（乘
  `defaultStroke(image)`，4 档）；新建标注时快照到 `Annotation`。高亮的半透明色从所选颜色
  派生（alpha 0.35）。
- **文字二次编辑**：文字工具点已有文字（或双击，任意工具）进入编辑；命中用
  `NSAttributedString.size()` 在图像像素里算包围盒；编辑时隐藏原标注、提交时原地替换，
  清空则删除。

### 4.8 UI 框架与 Liquid Glass

- **分工**：AppKit 宿窗口与原生事件；SwiftUI 只做编辑窗工具栏和设置窗表单；画布 / 覆盖层
  仍是 AppKit + Core Graphics（自绘 + 鼠标 / IME）。两边界用 `NSHostingView`
  （SwiftUI→AppKit）和 `NSViewRepresentable`（AppKit→SwiftUI）桥接。
- **Liquid Glass 是 macOS 26+**（`glassEffect` / `.buttonStyle(.glass)` /
  `GlassEffectContainer`）。代码一律 `if #available(macOS 26.0, *)`，旧系统回退到 `.bar` /
  `.regularMaterial`，**部署目标保持 14.0**。
- **新外观由链接 SDK 版本决定。** SwiftPM 默认把部署目标（14.0）当作
  `LC_BUILD_VERSION.sdk`，系统就按 macOS 15 旧外观画控件（小开关、不透明窗口、无玻璃）。
  `Package.swift` 用 linker flag `-platform_version macos 14.0 26.0` 把 sdk 钉到 26.0，
  才会启用 macOS 26 外观。验证：`vtool -show-build .build/debug/kacha-mac` 显示 `sdk 26.0`。
- **编辑窗**：`.fullSizeContentView`，顶部一条留给工具栏（`VStack`：工具栏 + 画布，居中），
  画布只在工具栏下方，图片不会被浮条压住。因为标题栏没得拖了，浮条最左边加了一个
  `WindowDragArea` 拖拽把手（调 `performDrag`）。当前工具用 accent 胶囊标记。窗口
  `contentMinSize = 840×460`；`titlebarAppearsTransparent` + `titleVisibility = .hidden` +
  `titlebarSeparatorStyle = .none`。
- **设置窗**：对齐 macOS 26 系统设置的观感。窗口用 `.fullSizeContentView` +
  `titlebarAppearsTransparent` + `titleVisibility = .hidden`，SwiftUI 自己画顶栏标题
  （左边距避开红绿灯）、原生 `Form(.grouped)` 卡片和底部动作栏。分节标题 / 说明是卡片内的
  第一行（不再是卡外的 `Section` header，也不带 SF Symbol 图标）；热键是普通 SwiftUI
  `Button`（走系统 26 的按钮 chrome），不再是 AppKit `NSButton`。按键捕获用本地 `NSEvent`
  监听：`NSEvent.addLocalMonitorForEvents(matching: [.keyDown])`。

### 4.9 钉图

钉图是 `PinWindow`（borderless + `.floating`）里放 `PinView`：静态画 `NSImage`，悬停才在
左上角画关闭按钮、右下角画缩放手柄。交互全在 `PinView`：拖拽改窗口 origin、拖四角缩放
（居中锁宽高比，锚在对面角，最小 80×60）、双击 / `Esc` 关闭、右键菜单（复制 / 保存 / 关闭）；
大图按屏幕 80% 缩放，窗口用 `orderFrontRegardless()` 展示以免抢焦点。菜单栏提供「关闭所有钉图」。

### 4.10 OCR 文字识别（系统 VisionKit）

离线、无第三方，只有一条路径：工具栏「识别文字」开关（`text.viewfinder`）用
`VisionKit.ImageAnalysisOverlayView`（`.textSelection`）+ `ImageAnalyzer`，在画布上按
`state.imageRect` 叠一个对齐的 `NSImageView` + 覆盖层，直接在图上拖选、右键复制（和
iPhone 相册一致）。开启时画布暂停画标注，`Esc` 或再点按钮退出。

右键菜单还有「复制全部文字」和「显示全部文字…」——后者打开一个 SwiftUI sheet，可编辑 /
复制，并带「合并换行」开关（CJK 之间不插空格）。识别在后台跑，`Package.swift` 链接
`VisionKit`。`--smoke-ocr` 用 CoreText 渲染已知文字再经 `ImageAnalyzer` 识别并断言，覆盖
文本路径且不需要录屏权限。

### 4.11 看图模式

菜单栏「看图」用同一个 `EditorWindow` 开一个空窗（`session.composed == nil`）：画布画空态
提示「拖入图片开始编辑」，工具栏按钮在 `state.hasImage == false` 时全部禁用（只有关闭可用）。
把图片（文件 URL / PNG / TIFF）拖到画布上，`EditorCanvasView` 的 `NSDraggingDestination`
读成 `CGImage` → `Compose.composed(from:)` 写回 `session.composed` 并置 `state.hasImage`，
之后的标注 / 复制 / 保存 / 钉图 / OCR 流程与截图完全一致。

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
  默认截图 `⌘⇧A`、全屏 `⌘⇧F`、取色 `⌘⇧C`，在设置窗里可改（`HotkeyRecorderView`）。
- 屏幕录制是 per-user TCC：首次抓屏前用 `CGPreflightScreenCaptureAccess` /
  `CGRequestScreenCaptureAccess` 引导，授予后需重启 app。
- 开机自启用 `SMAppService`（macOS 13+），只在真正的 `.app` bundle 里有意义。

---

## 7. 验证策略

- **不写截图 / 录屏测试**（见 AGENTS 硬规则）。
- `--selfcheck`：纯逻辑断言，无窗口、无屏幕录制权限、无 XCTest。覆盖坐标 / 裁剪 / PNG /
  标注栅格化等纯函数。
- `--smoke-settings` / `--smoke-editor` / `--smoke-export` / `--smoke-ocr` / `--smoke-viewer`：
  真实开 / 关窗口路径、Vision 识别路径与看图空窗拖放路径，回归 `isReleasedWhenClosed`
  崩溃与编辑窗生命周期。
- `scripts/dev.sh` 串起 build + selfcheck + 五个 smoke。

---

## 8. 已知缺口 / 后续

- 形状 / 画笔的线宽有 4 档预设、颜色 8 色预设，但没有连续滑块 / 自定义取色。
- 文字字号仍按对角线派生（没有字号选择器）；文字可点选 / 双击二次编辑。
- 窗口拾取不做 app 级分组 / 子窗口选择。
- 序号 / 椭圆 / 裁剪 / 延时 / 滚屏长图未做。
- 多显示器非均匀缩放下的跨屏拼接以最大 scale 兜底，尚未逐屏混合。
- Liquid Glass 只在 macOS 26+ 生效，旧系统是材质回退；部署目标仍是 14.0。
