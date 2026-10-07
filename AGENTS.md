# AGENTS.md — ushot

macOS 截图工具。Swift 壳 + Rust（igui）核心。设计见 [`DESIGN.md`](DESIGN.md)。

## 硬规则

1. **产品是 Swift/macOS app；Rust 一个包。** 根包 `ushot-app`（`src/`，`lib` + `staticlib`）
   产出 `libushot_app.a`，SwiftPM（`macos/`）静态链接。不要往根目录丢构建产物。
2. **FFI 边界包含 UI。** Swift 只做窗口 / `CAMetalLayer` / 原生事件 / 系统能力
   （状态栏、全局热键、ScreenCaptureKit、剪贴板、保存面板、权限）；UI、渲染、图像处理都在
   Rust。唯一契约是 `include/ushot_host.h`（`ushot_host_*`）。
3. **依赖方向单向**：`macos/` → `ushot-app` → `igui*`。Rust 不反向依赖 Swift。
   `src/ui` 只用 `igui_*` 的公开 API，不认识 Swift / AppKit。
4. **会话在 Rust**：冻结帧、选区、合成图、标注历史都放 `src/session.rs`；Swift 只持 `u64` id，
   大 buffer 不过 ABI。Rust→Swift 的请求用「停放 + 轮询」（照 cgb 的 `take_fullscreen`）。
5. **不写截图 / 录屏测试。** 用 `igui_headless` / `igui_backend_recording` 录 `DrawList` +
   `igui_profile::inspect`，或 core 侧纯函数单测（坐标、裁剪、PNG、标注栅格化）。
   产品本身能截图，与这条不冲突。
6. **只实现已确认的阶段。** 每阶段结束出报告、等确认（P0→P5 见 `DESIGN.md` §10）；
   需求模糊、要动 ABI 或阶段划分时先停下问。
7. **输出走「停放 + 轮询」。** 编辑窗工具栏把动作写进 session（`request`），
   `EditorApp::update` 用离屏 `WgpuBackend` 把合成图 + 标注栅格化成 PNG 存 `export_png`；
   Swift 轮询 `ushot_host_take_action` → `ushot_host_action_png` → `ushot_host_action_done`。
8. **不擅自发版 / 提交。** 不打 tag、不建 release，除非明确要求。
9. **igui 的边界**：`igui_core` / `igui_scene` / `igui_ui` / `igui_components` 不得依赖
   `wgpu` / DOM；应用只用公开 API。要改 igui 用 `[patch]`，不直接改 checkout。
10. **每个 `unsafe` 块必须有 `// SAFETY:` 注释**（`clippy::undocumented_unsafe_blocks` 在 gate 里守）。

## 已知踩坑（别重复）

- **`SCDisplay.width` / `height` / `frame` 都是点（points），不是像素。** 冻屏要原生像素得用
  `NSScreen(for: displayID).backingScaleFactor` 来算：`config.width = frame.width * scale`。
  别把 `display.width / frame.width` 当 scale（两者都是点，恒为 1）——否则冻帧是 1x，
  选区导出在 Retina 上软一半。

- **窗口截图必须用 SCK 单窗口捕获，不能裁冻帧。** 被遮挡的窗口在冻屏里只是上层窗口，
  裁出来是错的。选窗后把 `SCWindow` 交给 Swift，用
  `SCContentFilter(desktopIndependentWindow:)` + `SCScreenshotManager.captureImage`
  拿该窗口自己的内容，再用 `ushot_session_set_composed` 塞回会话；覆盖层只高亮悬停的
  那一个窗口（不要把 `content.windows` 全部描边，很噪）。
- **窗口列表必须按 z-order 排。** `SCWindow` 没有顺序，用它的列表会高亮鼠标下被遮挡的
  窗口（“不可视窗口还有框”）。选窗后把 `SCWindow` 交给 Swift，用
  `SCContentFilter(desktopIndependentWindow:)` + `SCScreenshotManager.captureImage`
  拿该窗口自己的内容，再用 `ushot_session_set_composed` 塞回会话；覆盖层只高亮悬停的
  那一个窗口（不要把 `content.windows` 全部描边，很噪）。
- **“从鼠标位置拿窗口”用 AppKit 的命中测试，不要自己用矩形猜。**
  `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)` 是唯一公开的、考虑真实
  z-order/遮挡/透明度的命中测试（`SCWindow` 不提供）。Swift 在每帧取
  `NSEvent.mouseLocation`，以覆盖层面板的 `windowNumber` 为参考往下测，循环跳过不在
  `windowsByID` 里的窗口号（我们自己的编辑/钉图窗、SCK 没列的），命中得到的 window
  number 就是 `SCWindow.windowID`；把悬停窗口的矩形用 `ushot_session_set_hover` 推给
  Rust，点击时 Rust 只置 `picked`，由 Swift 捕获它跟踪的那个窗口。
- **无常驻主窗。** 产品是菜单栏 app（`main.swift` 里 `.accessory` + 打包 `LSUIElement`），
  窗口只在需要时开（覆盖层 / 编辑窗 / 钉图）。一个常驻主窗会挡住你要截的窗口（即使不在
  最顶层，命中测试也会先命中它）。
- **程序化 `NSWindow` 必须 `isReleasedWhenClosed = false`。** 默认是 `true`，而窗口由 ARC
  持有；点红钮 / `performClose` 关闭时 AppKit 释放一次、ARC 再释放一次，
  在 `objc_release` 崩溃（EXC_BAD_ACCESS）。主窗 / 编辑窗 / 覆盖层面板都已设。
  回归：`macos/scripts/run.sh --smoke-editor`（开编辑窗 → 走 `windowWillClose` 关窗 → 退出，
  退出码非 0 即失败）。
- **销毁 Rust app 前先清 `HostView.app`。** `orderOut` / 窗口 teardown 会同步派发事件
  （`mouseExited` 等），`HostView` 会转发给已释放的指针；所有 `close`/`dismiss` 都先置 nil。
- **igui 的布局根会忽略自己的 container。** `into_tree()` 挂载的那个组件是布局根，它的
  **直接子节点按 anchor 摆放**，flex 只从它的**唯一子节点**开始生效。最外层必须是
  「只有一个子节点」的壳（`demo_app` / `deepseek_balance` 的形状）。
- **别在中间层加 `grow`。** 布局根的唯一子节点如果带 `grow`，会塌成内容大小而不是铺满；
  正确做法是**把 flex 本身作为挂载根**，里面再 `grow`（`src/ui/overlay.rs` 的
  `build_tree`）。否则多个子节点会重叠在原点，或整块塌掉。
  回归：`src/ui/overlay.rs`（冻帧铺满）、`src/ui/editor.rs`（画布 + 工具栏）的布局断言。
- **覆盖层 / 编辑窗的 surface 要跟随 drawable 变化重配。** `HostView` 挂进 window 前的
  第一遍几何是 1x（`window == nil`），所以开窗前先 `window.layoutIfNeeded()` 再读
  `pixelSize` / `scaleFactor`；之后由 `HostView.onGeometryChange` 调 `ushot_host_resize`
  跟随后续 backing / 尺寸变化。少了这步，首帧会按旧尺寸画进新 drawable，就是
  「冻屏缩放闪一下」。无边框覆盖层另加 `window.animationBehavior = .none`，关掉 AppKit
  的开窗动画。
- **`PaintContext::draw_text` 的 `position` 是基线（baseline），不是左上角。** 画文字要
  `y + ascent`（`TextMeasurer::ascent`，回退 `0.8 * font_size`），光标 / IME 候选窗也按
  行框（`line_height`）算。当成左上角会让 size label 上溢、文字标注跑到点击点上方一行。
  回归：`src/ui/overlay.rs`、`src/ui/canvas.rs` 的基线断言。
- **标注的默认线宽 / 字号按图片对角线算**（`canvas::default_stroke` /
  `default_text_size`），随截图分辨率缩放；别写死 2 px / 18 px，否则 4K 区域上细到看不见。
  马赛克块也按 stroke 派生（`MOSAIC_BLOCK_PER_STROKE`）。

## 构建与验证

```bash
./scripts/dev.sh      # fmt --check + clippy -D warnings + test + cargo build + swift build
```

单独：

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
macos/scripts/build.sh          # Rust staticlib + Swift 可执行
macos/scripts/run.sh            # 运行
```

## 目录地图

| 需要… | 看这里 |
|---|---|
| 总体设计 / 阶段 / 风险 | `DESIGN.md` |
| C ABI（Swift ↔ Rust） | `include/ushot_host.h`、`src/native/ffi.rs` |
| 原生 host（surface / GPU / 插件 / 输入） | `src/native/` |
| 会话（冻帧 / 选区 / 合成） | `src/session.rs`、`src/capture.rs`、`src/compose.rs` |
| 视图（框选层 / 编辑窗） | `src/ui/`（`overlay.rs` / `selection.rs` / `editor.rs` / `canvas.rs` / `image.rs`） |
| 标注模型 | `src/annotate/` |
| PNG 导出 | `src/export/png.rs` |
| Swift 壳（窗口 / 事件 / 抓屏 / 输出） | `macos/Sources/UShotMac/`（`Capture.swift` / `OverlayWindows.swift` / `EditorWindow.swift` / `PinWindows.swift` / `MenuBar.swift` / `Hotkeys.swift` / `HostView.swift`） |
| 打包 | `macos/packaging/Info.plist`、`macos/scripts/` |
