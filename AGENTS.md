# AGENTS.md — kacha

macOS 截图工具。**纯 Swift 应用**：AppKit 管窗口 / 原生事件与系统能力，Core Graphics 画界面
并做全部图像处理，ScreenCaptureKit 抓屏；编辑 / 设置窗口的 chrome 用 SwiftUI。
没有 Rust、没有 C ABI、没有第三方 UI 依赖。设计见 [`DESIGN.md`](DESIGN.md)。

## 硬规则

1. **只写 Swift。** 不引入 Rust / C ABI / 第二个语言运行时。`Package.swift` 在仓库根目录，
   唯一可执行目标是 `Sources/KachaMac`。不往仓库里丢构建产物（见 `.gitignore`）。
2. **AppKit 拥有窗口与系统能力。** 窗口 / `NSView` / 事件、状态栏、全局热键、
   ScreenCaptureKit、剪贴板、保存面板、权限都留在 Swift 壳里。
3. **渲染用 Core Graphics，chrome 用 SwiftUI。** 覆盖层与编辑画布用 `NSView.draw(_:)` +
   `CGContext`；没有渲染循环（`CADisplayLink` / Metal）。编辑 / 设置窗口的工具栏、表单是
   SwiftUI，通过 `NSHostingView` 挂进 `NSWindow`，画布用 `NSViewRepresentable` 嵌入；
   设置窗全部是 SwiftUI（含热键录制按钮），只有按键捕获用本地 `NSEvent` 监听。
   Liquid Glass（`glassEffect` / `.buttonStyle(.glass)` / `GlassEffectContainer`）是
   **macOS 26+**：一律 `if #available(macOS 26.0, *)`，否则回退到 `.bar` / `.regularMaterial`；
   部署目标保持 14.0。**二进制必须记录链接 SDK ≥ 26.0**（见下方踩坑），否则系统按旧
   外观画控件（小开关、不透明窗口）。
4. **会话是共享状态。** 一次截图的冻帧、选区、合成图、悬停窗口放在 `CaptureSession`，
   覆盖层 / 编辑窗共享同一实例。大图用 `CGImage`，不要跨窗口反复拷贝。
5. **无常驻主窗。** 产品是菜单栏 app（`main.swift` 里 `.accessory` + 打包 `LSUIElement`），
   窗口只在需要时开（覆盖层 / 编辑窗 / 钉图 / 设置）。一个常驻主窗会挡住要截的目标。
6. **不写截图 / 录屏测试。** 用 `--selfcheck` 的纯逻辑断言（坐标、裁剪、PNG、标注栅格化）
   和 `--smoke-*` 的真实开 / 关窗口路径；不要用 XCTest 去截屏断言。
7. **只实现已确认的阶段。** 需求模糊、要动数据流或影响架构时，先停下问。
8. **不擅自发版 / 提交。** 不打 tag、不建 release，除非明确要求。
9. **`unsafe` / 强解包要有理由。** 优先用可选绑定和 guard；确实需要时写清 `// SAFETY:` /
   注释说明不变量。

## 已知踩坑（别重复）

- **`SCDisplay.width` / `height` / `frame` 都是点（points），不是像素。** 冻帧要原生像素得用
  `NSScreen(for: displayID).backingScaleFactor` 算：`config.width = frame.width * scale`。
  别把 `display.width / frame.width` 当 scale（两者都是点，恒为 1）——否则冻帧是 1x，
  选区导出在 Retina 上糊一半。
- **窗口截图必须用 SCK 单窗口捕获，不能裁冻帧。** 被遮挡的窗口在冻帧里只是上层窗口，
  裁出来是错的。选窗后把 `SCWindow` 交给 ScreenCaptureKit，用
  `SCContentFilter(desktopIndependentWindow:)` + `SCScreenshotManager.captureImage`
  拿该窗口自己的内容；覆盖层只高亮悬停的那一个窗口（不要把 `content.windows` 全部描边）。
- **窗口拾取用 AppKit 命中测试，不要自己用矩形猜。**
  `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)` 是唯一公开的、考虑真实
  z-order / 遮挡 / 透明度的命中测试。以覆盖层的 `windowNumber` 为参考往下测，命中得到的
  window number 就是 `SCWindow.windowID`。
- **程序化 `NSWindow` / `NSPanel` 必须 `isReleasedWhenClosed = false`。** 默认是 `true`，
  而窗口由 ARC 持有；点红钮 / `performClose` 关闭时 AppKit 释放一次、ARC 再释放一次，
  在 `objc_release` 崩溃（EXC_BAD_ACCESS）。回归：`scripts/run.sh --smoke-editor`
  （开编辑窗 → 走 `windowWillClose` 关窗 → 退出，退出码非 0 即失败）。
- **覆盖层第一个 mouse-down 要区分「点窗口」和「拉选区」。** 用位移阈值
  （`SelectionView.clickSlop`）判定：没超过阈值就是点击（选窗口 / 选桌面），超过了才是拖拽圈选。
- **多显示器坐标统一用全局逻辑点，原点左上**（= CoreGraphics 全局坐标）。每个覆盖层减去自己
  `NSScreen.frame` 的 origin 得到局部坐标；选择状态存全局坐标，跨屏选择才成立。
- **标注的默认线宽 / 字号按图片对角线算**，随截图分辨率缩放；别写死像素值，否则 4K 区域上
  细到看不见。marker 工具（高亮 / 马赛克）用 `defaultMarkerStroke`（最小 16px）。
- **高亮 / 马赛克是「涂抹」工具，不是形状。** 两者都按 freehand 折线累积点；高亮用半透明
  黄色 + 粗 round-cap 线，马赛克把整图块平均一次（`Mosaic.make`，缓存）后用
  `replacePathWithStrokedPath()` 裁成粗笔刷再画。别退回成拖矩形。
- **编辑器工具栏用 SwiftUI + SF Symbols。** 图标写在 `Tool.symbol` / `ToolbarSymbol`；缺符号
  回退成文字。文字工具只用中文标签（`Tool.showsTextOnly`），复制 / 保存是「图标 + 中文」，
  保存是 primary（`ToolbarButton.primary` 的 accent 胶囊）。所有按钮共用同一套自绘样式，
  不要用 `.borderedProminent` / `.glassProminent` 这类系统按钮样式（会和玻璃图标按钮不成套）。
  `--selfcheck` 会解析 `ToolbarSymbol.all`，拼错直接失败。玻璃风格只在 macOS 26+ 生效——别把
  `glassEffect` 写在 `#available` 外面，否则部署目标 14.0 会报错。
- **SwiftPM 会把部署目标当成链接 SDK 版本写进 `LC_BUILD_VERSION`。** 结果二进制记的是
  `sdk 14.0`，macOS 就按旧外观（macOS 15）画所有控件——开关是小号的、窗口不透明、没有
  Liquid Glass。`Package.swift` 里用 linker flag 钉死平台版本才会启用新外观：
  `.unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "14.0",
  "-Xlinker", "26.0"])`（minos 保持 14.0，sdk 报 26.0）。验证：`vtool -show-build
  .build/debug/kacha-mac` 要显示 `sdk 26.0`，对比系统设置是 `26.7`。
- **设置窗对齐 macOS 26 系统设置的观感。** 窗口 `.fullSizeContentView` + 透明无标题
  titlebar，SwiftUI 自己画顶栏标题（`ignoresSafeArea(edges: .top)` + 左边距避开红绿灯）和
  底部动作栏。分节标题 / 说明是卡片内第一行（不是卡外的 `Section` header，也不带 SF
  Symbol）；热键是普通 SwiftUI `Button`（走系统 26 的按钮 chrome），别退回 AppKit
  `NSButton`——`.automatic`/`.rounded` 是旧灰条，`.glass` bezel 在卡片里几乎看不见。
- **标注样式存在标注上，不读全局。** `color` / `stroke` / `filled` 是 `Annotation` 的字段
  （新建时从 `EditorState` 快照）；绘制不要去看 `state.color`。工具栏的面板改的是
  `state.color` / `state.strokeFactor` / `state.rectangleFilled`。文字编辑用
  `editingAnnotation` 索引在 `commitText` 里原地替换（清空则删除），别 append 新的。
- **截图提示音不嵌入音频文件。** 优先加载系统截图那声（`/System/Library/Components/
  CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif`），
  失败回退 `NSSound(named: "Tink")`（`/System/Library/Sounds`，还能被 `~/Library/Sounds`
  里的同名文件替换）。那个 CoreAudio 组件路径不是文档化 API，macOS 升级可能挪位置，
  所以 `??` 回退必须有；`--selfcheck` 会断言回退音效可解析。
- **CGContext 画文字 `position` 是基线（baseline），不是左上角。** 要按字体度量（ascent /
  lineHeight）换算；当成左上角会让文字标注上移 / size 标签溢出。

## 构建与验证

```bash
./scripts/dev.sh                     # swift build + selfcheck + 三个 smoke
```

单独：

```bash
swift build                          # 仓库根 Package.swift
.build/debug/kacha-mac --selfcheck
scripts/run.sh --smoke-settings
scripts/run.sh --smoke-editor
scripts/run.sh --smoke-export
scripts/package.sh                   # 组装 dist/kacha.app
```

## 目录地图

| 需要… | 看这里 |
|---|---|
| 总体设计 / 阶段 / 风险 | `DESIGN.md` |
| 生命周期 / 菜单 / 热键 / 入口 | `Sources/KachaMac/AppDelegate.swift`、`MenuBar.swift`、`Hotkeys.swift` |
| 抓屏 / 冻帧 / 单窗口捕获 | `Sources/KachaMac/Capture.swift` |
| 会话（冻帧 / 选区 / 合成） | `Sources/KachaMac/Session.swift`、`Selection.swift`、`Compose.swift` |
| 框选层 / 取色层 | `Sources/KachaMac/OverlayWindow.swift`、`ColorPicker.swift` |
| 编辑窗 / 画布 / 标注 | `Sources/KachaMac/EditorWindow.swift`、`EditorCanvasView.swift`、`Annotate.swift` |
| 钉图 / 设置 / 热键录制 | `PinWindows.swift`、`SettingsWindow.swift`、`HotkeyRecorderView.swift` |
| 截图提示音（系统音效，无资源文件） | `ShotSound.swift`、`Preferences.swift` |
| PNG 导出 / 权限 | `PNG.swift`、`Permissions.swift` |
| 打包 / 脚本 | `packaging/Info.plist`、`scripts/` |
