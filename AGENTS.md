# AGENTS.md — ushot

macOS 截图工具。**纯 Swift 应用**：AppKit 管窗口 / 原生事件与系统能力，Core Graphics 画界面
并做全部图像处理，ScreenCaptureKit 抓屏。没有 Rust、没有 C ABI、没有第三方 UI 依赖。
设计见 [`DESIGN.md`](DESIGN.md)。

## 硬规则

1. **只写 Swift。** 不引入 Rust / C ABI / 第二个语言运行时。`Package.swift` 在仓库根目录，
   唯一可执行目标是 `Sources/UShotMac`。不往仓库里丢构建产物（见 `.gitignore`）。
2. **AppKit 拥有窗口与系统能力。** 窗口 / `NSView` / 事件、状态栏、全局热键、
   ScreenCaptureKit、剪贴板、保存面板、权限都留在 Swift 壳里。
3. **渲染用 Core Graphics。** 覆盖层与编辑画布都用 `NSView.draw(_:)` + `CGContext`；
   没有渲染循环（`CADisplayLink` / Metal），只在状态变化时 `setNeedsDisplay`。
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
- **CGContext 画文字 `position` 是基线（baseline），不是左上角。** 要按字体度量（ascent /
  lineHeight）换算；当成左上角会让文字标注上移 / size 标签溢出。

## 构建与验证

```bash
./scripts/dev.sh                     # swift build + selfcheck + 三个 smoke
```

单独：

```bash
swift build                          # 仓库根 Package.swift
.build/debug/ushot-mac --selfcheck
scripts/run.sh --smoke-settings
scripts/run.sh --smoke-editor
scripts/run.sh --smoke-export
scripts/package.sh                   # 组装 dist/ushot.app
```

## 目录地图

| 需要… | 看这里 |
|---|---|
| 总体设计 / 阶段 / 风险 | `DESIGN.md` |
| 生命周期 / 菜单 / 热键 / 入口 | `Sources/UShotMac/AppDelegate.swift`、`MenuBar.swift`、`Hotkeys.swift` |
| 抓屏 / 冻帧 / 单窗口捕获 | `Sources/UShotMac/Capture.swift` |
| 会话（冻帧 / 选区 / 合成） | `Sources/UShotMac/Session.swift`、`Selection.swift`、`Compose.swift` |
| 框选层 / 取色层 | `Sources/UShotMac/OverlayWindow.swift`、`ColorPicker.swift` |
| 编辑窗 / 画布 / 标注 | `Sources/UShotMac/EditorWindow.swift`、`EditorCanvasView.swift`、`Annotate.swift` |
| 钉图 / 设置 / 热键录制 | `PinWindows.swift`、`SettingsWindow.swift`、`HotkeyRecorderView.swift` |
| PNG 导出 / 权限 | `PNG.swift`、`Permissions.swift` |
| 打包 / 脚本 | `packaging/Info.plist`、`scripts/` |
