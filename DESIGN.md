# ushot — 设计文档（macOS 截图工具 / igui + Swift 壳）

> 状态：**已实现并收尾（P0–P5）**（见 [`README.md`](README.md)）。工作名 `ushot`。
> 参考实现：[`../classic-game-box`](../classic-game-box) 的 Swift/macOS 壳
> （`macos/` + `src/native/` + `cgb_host.h`）。UI 栈：[`../igui`](../igui)。

---

## 1. 定位

一个常驻菜单栏、全局热键触发的 macOS 截图工具：

- **截图模式**：整屏（每显示器）、框选区域、窗口拾取。
- **框选层**：触发后先抓取所有显示器，「冻结」整个桌面；用户拖拽框选、可再调整手柄；
  Enter 确认、Esc 取消。层内带十字线、尺寸读数、放大镜。
- **编辑窗**：预览 + 标注（矩形 / 箭头 / 画笔 / 高亮 / 文字 / 马赛克 / 序号）+ 撤销重做
  + 裁剪；复制到剪贴板、保存 PNG/JPEG、钉在桌面（pin）、可选 OCR。
- **零第三方 UI**：界面完全由 `igui_*` 绘制，渲染走 `igui_backend_wgpu`。

### 1.1 非目标（MVP 不做）

- 录屏 / GIF、滚屏长图、云上传与分享链接。
- 多用户 / 账户 / 同步。
- Windows / Linux 壳（设计保留 C ABI，但只实现 Swift/macOS）。
- 用截图做**测试**验证（见 §9；igui/cgb 的硬规则禁止，产品本身截图属正常功能）。

---

## 2. 总体架构（对标 classic-game-box 的 Swift 壳）

一句话：**Swift 拥有窗口、系统能力与事件；Rust 拥有 UI、渲染与全部图像处理。FFI 边界包含 UI。**

```
AppKit / Carbon (Swift，UShotMac)                 Rust staticlib (libushot_app.a)
──────────────────────────────────────           ───────────────────────────────────────
NSStatusItem + 菜单                    ──┐         igui_app 运行时（App/Plugin/AppLogic）
Carbon RegisterEventHotKey（全局热键）   │         ├─ ui/overlay.rs   冻结屏框选层
每屏 NSPanel + CAMetalLayer（框选层）    │         ├─ ui/editor.rs    编辑窗
NSWindow + CAMetalLayer（编辑窗 / 钉图）  ├ c ABI ──├─ annotate/        标注模型 + 栅格化
ScreenCaptureKit（抓屏 / 窗列表）        │         ├─ session/         冻结帧 / 选区 / 合成
NSPasteboard（复制）/ NSSavePanel（保存）│         ├─ capture.rs       帧→纹理
CGPreflight/RequestScreenCaptureAccess  │         ├─ export/png.rs     PNG 编码
状态栏菜单 / 权限引导                    ──┘         └─ native/           surface + GPU + 插件 + ffi
```

- Swift 侧**只**做窗口 / `CAMetalLayer` / 原生事件 / 系统能力（状态栏、热键、SCK、剪贴板、保存面板、权限）。
- Rust 侧是 `staticlib`（`libushot_app.a`），SwiftPM 静态链接；Swift 通过 `ushot_host_*` C ABI 驱动。
- **帧由事件驱动**：任何输入请求一帧；只有当 app 想要更多帧（框选层动画、编辑中）时由
  `CADisplayLink` 持续驱动（照搬 cgb `AppDelegate` 的 `needs_frame` 模式）。
- **Rust → Swift 的请求用「停放 + 轮询」**，不跨 ABI 回调（照搬 cgb 的
  `cgb_host_take_fullscreen`）：如「复制剪贴板」「弹保存面板」「开编辑窗」。

与 cgb 的**唯一结构差异**：cgb 是「单窗口 + 模拟器」，ushot 是「多窗口 + 系统截图 API」。
因此 ABI 增加一节 **session（会话）** 与 **display image（冻结帧注入）**。

---

## 3. 目录布局

```
ushot/
├── Cargo.toml                 # workspace + 根包 ushot-app（lib + staticlib）
├── include/ushot_host.h        # C ABI（唯一对外契约）
├── src/
│   ├── lib.rs
│   ├── session.rs             # SessionManager：id → 冻结帧/选区/合成图/历史
│   ├── capture.rs             # RGBA 帧 → TextureId（register_texture）
│   ├── annotate/              # 标注数据模型 + 栅格化（rect/ellipse/arrow/pen/highlight/text/mosaic）
│   ├── export/png.rs          # PNG 编解码（png crate，参考 cgb src/library/png_codec.rs）
│   ├── ui/
│   │   ├── overlay.rs         # 框选层视图（OverlayApp: AppLogic）
│   │   └── editor.rs          # 编辑窗视图（EditorApp: AppLogic）
│   └── native/                # 原生 host（两个方向共用一份，照搬 cgb src/native/）
│       ├── mod.rs
│       ├── ffi.rs             # ushot_host_* 实现
│       ├── gpu.rs             # NativeGpuPlugin：surface/backend/Presenter
│       ├── plugins.rs         # text measure / clipboard / host window 请求
│       ├── surface.rs         # CAMetalLayer* → wgpu::Surface
│       └── input.rs           # NativeEvent + AppKit keyCode 映射
└── macos/
    ├── Package.swift          # UShotNative(module map) + UShotMac(executable)
    ├── Sources/
    │   ├── UShotNative/include/ushot_host.h -> ../../include/ushot_host.h  # 符号链接
    │   └── UShotMac/
    │       ├── main.swift            # NSApplication + .accessory
    │       ├── AppDelegate.swift     # 生命周期 / 帧驱动 / display link
    │       ├── StatusItem.swift      # NSStatusItem + 菜单
    │       ├── Hotkeys.swift         # Carbon RegisterEventHotKey
    │       ├── Capture.swift         # ScreenCaptureKit 封装（async → RGBA8）
    │       ├── HostView.swift        # CAMetalLayer + 原生事件转发（照搬 cgb）
    │       ├── OverlayWindows.swift  # 每屏一个 borderless NSPanel
    │       ├── EditorWindow.swift    # 编辑窗 / 钉图窗
    │       ├── Clipboard.swift       # NSPasteboard
    │       └── Permissions.swift     # 屏幕录制 TCC 引导
    ├── packaging/Info.plist          # LSUIElement=true、LSMinimumSystemVersion=14.0
    └── scripts/{build.sh,run.sh,package.sh}
```

`macos/` 复用 cgb 的 SwiftPM 结构：`UShotNative` 目标由 umbrella 目录生成 module（符号来自
Rust 静态库），`linkerSettings` 里 `-L <rust target dir> -lushot_app` +
`AppKit/Metal/QuartzCore/ScreenCaptureKit/Carbon` 框架。

---

## 4. 关键技术决策

### 4.1 抓屏：ScreenCaptureKit（macOS 14+）

- 单帧：`SCScreenshotManager.captureImage(contentFilter:configuration:)`（macOS 14，async）。
- 列表：`SCShareableContent.current`（显示器 / 窗口）、`SCContentFilter`。
- 区域/窗口：`SCStreamConfiguration.sourceRect` + `width/height`（像素）+ `scalesToFit`，
  `SCContentFilter(display:excludingApplications/Windows:)`。
- **排除自身**：filter 排除本 app 的窗口（否则框选层拍到自己）；同时 Swift 把所有本 app
  窗口 `sharingType = .none` 双保险。
- 最低系统 **macOS 14.0**，与 cgb 的 `Package.swift`（`.macOS(.v14)`）一致。
- 备选（不实现）：`SCContentSharingPicker`（系统选择器）可做「窗口拾取」的一个替代入口。

### 4.2 冻结观感

macOS 自带截图「画面冻住」是因为它**先抓后显**：抓完在覆盖层里把冻帧当背景画。
本工具同法：热键 → Swift 抓所有屏 → Rust 把冻帧注册成纹理 → 覆盖层全屏 1:1 绘制。
因为覆盖层窗口是**无边框、恰好等于显示器物理像素**，冻帧是 1:1 无缩放（不糊）。

### 4.3 多显示器与坐标系

- 内部统一 **全局逻辑点，原点左上**（= CoreGraphics 全局坐标）。每个覆盖层减去自己
  `NSScreen.frame` 的 origin 得到局部坐标。
- 冻帧按 backing scale 抓成像素；布局用逻辑尺寸、纹理用像素尺寸。
- 选择状态（矩形 + 手柄）存在**会话**里，全局坐标；任一屏的覆盖层只画它与本屏的交集，
  跨屏选择自然成立。
- 菜单栏 / 刘海 / 非均匀缩放（外接屏 1x + 内建 2x）都按「每屏自己的 scale」处理。

### 4.4 多 surface 的 GPU 策略（重要开放决策）

`igui_app` 的 `Presenter::present(&DrawList)` 一次针对**一个** surface；`WgpuBackend`
的 `from_instance` 会**各自建 device**。框选层需要 N 个窗口同时存在，于是有两个方案：

- **方案 A（MVP，与 cgb 完全一致）**：每个窗口一个 `UShotHostApp`（各自 `Instance` +
  `Device` + `WgpuBackend` + Presenter）。显示器通常 1–3 台，开销可接受，改动最小。
- **方案 B（后续优化）**：进程内共享一个 `Instance`/`Device`，自定义
  **MultiSurfacePresenter**，在 `present` 里对每个 surface 顺序
  `begin_frame_with_view → submit → end_frame → present`。不改 igui，但需要自己管
  per-surface 的 `DrawList`（`AppLogic::paint` 一次只出一份，需按 role 分别驱动）。

MVP 取 A，把 B 记为性能优化项。

### 4.5 会话（进程内共享状态）

Swift 与 Rust 同进程、同主线程，所以用进程内会话表，**大 buffer 不过 ABI**：

```
session.rs:  thread_local! { static SESSIONS: RefCell<HashMap<u64, Session>> }
Session {
    displays: Vec<DisplayImage>,   // 冻结帧 RGBA + 全局原点 + 逻辑尺寸 + scale + TextureId
    selection: Option<Rect>,        // 全局逻辑点
    mode: SessionMode,              // Overlay / Editor / Pin
    composed: Option<Image>,        // 框选裁剪后的底图（编辑器画布）
    annotations: Vec<Annotation>,   // 标注 + 撤销栈
    pending_export: Option<Export>, // Copy / Save / Pin / Ocr
}
```

Swift 只持有 `u64` session id。ABI 里所有「注入冻帧 / 取选区 / 导出 PNG」都按 id 操作。
`SessionManager` 用 `Rc<RefCell<..>>`（非 `Send`，全部主线程）——和 cgb 的
`SharedLogic`/`SharedBackend` 用法一致。

> 注：窗口上的 `UShotHostApp` 可能需要 `*mut` 句柄（wgpu 类型 `!Send`），所以
> 「会话表」与「app 句柄」分开：`ushot_host_start(..., session_id, role)` 在建 app 时把
> 会话共享进去。

---

## 5. C ABI 草案（`include/ushot_host.h`）

按 cgb 的 `cgb_host.h` 风格：值类型 + 注释 + `extern "C"`。只列代表性接口。

```c
typedef struct UShotHostApp UShotHostApp;   /* 一个窗口的 app 实例 */

/* --- 窗口 / 帧（与 cgb 同形） --- */
UShotHostApp *ushot_host_start(void *layer, uint32_t w, uint32_t h, double scale,
                             uint32_t role, uint64_t session_id);
void        ushot_host_destroy(UShotHostApp *);
void        ushot_host_frame(UShotHostApp *);
bool        ushot_host_needs_frame(const UShotHostApp *);
void        ushot_host_resize(UShotHostApp *, uint32_t w, uint32_t h, double scale);
uint32_t    ushot_host_cursor(const UShotHostApp *);          /* igui_core::Cursor 判别值 */
bool        ushot_host_caret(const UShotHostApp *, float*, float*, float*, float*);

/* --- 会话 --- */
uint64_t ushot_session_new(void);
void     ushot_session_drop(uint64_t session);
void     ushot_session_set_selection(uint64_t session, float x, float y, float w, float h);
/* 进入某角色：0 Overlay, 1 Editor, 2 Pin */

/* --- 冻结帧注入（Swift -> Rust）--- */
/* rgba 为紧凑 RGBA8（straight alpha），length = w*h*4；注册成纹理。 */
void ushot_display_image(uint64_t session, uint32_t display_id,
                        int32_t origin_x, int32_t origin_y,
                        uint32_t logical_w, uint32_t logical_h, double scale,
                        const uint8_t *rgba, size_t length);
void ushot_session_clear_displays(uint64_t session);

/* --- 覆盖层结果（Rust -> Swift，轮询）--- */
/* 1 = 确认, 0 = 取消, -1 = 无。矩形为全局逻辑点、原点左上。 */
int32_t ushot_host_take_selection(UShotHostApp *, float *x, float *y, float *w, float *h);
/* 已确认时，把裁剪合成图交回 Swift：先问长度再拷（两次调用模式）。 */
size_t  ushot_host_export_png(UShotHostApp *, uint8_t *out, size_t capacity);

/* --- 编辑窗请求（Rust -> Swift，轮询）--- */
/* 复制到剪贴板 / 钉图 / 保存 / 退出编辑。Swift 处理后回执。 */
uint32_t ushot_host_take_action(UShotHostApp *);              /* 0 none,1 copy,2 pin,3 save,4 close */
size_t   ushot_host_action_png(UShotHostApp *, uint8_t *out, size_t capacity);
void     ushot_host_action_done(UShotHostApp *, bool ok);

/* --- 模态数据（Swift -> Rust）--- */
/* 保存完成后告诉 Rust 落盘路径（用于状态栏提示 / 最近记录）。 */
void ushot_host_note_saved(const UShotHostApp *, const char *path);

/* --- 指针 / 滚轮 / 键盘 / 文本 / IME：与 cgb_host 同形（略） --- */
```

`role` 判别：`0 = 框选层`、`1 = 编辑窗`、`2 = 钉图`。同一份 `UShotHostApp` 代码按 role
选择 `AppLogic`（`OverlayApp` / `EditorApp`）。

---

## 6. igui 侧视图

### 6.1 框选层 `ui/overlay.rs`（`OverlayApp: AppLogic`）

- **背景**：`FrameImage`（参考 cgb `src/ui/frame.rs`：用 `Component` + `Spec::foreground`
  自绘 `DrawImage`），铺满窗口，1:1。
- **遮罩**：选择框外四块半透明黑（`ctx.fill_rect`），框内不打码。
- **选择框**：描边 + 8 个手柄（四角 + 四边），命中检测在 `event` 里做（可拖拽移动 / 缩放）。
- **十字线**：跟随指针的两条 1px 线。
- **尺寸读数**：`Text`（`igui_components`），显示 `宽 × 高`（逻辑点，必要时附像素）。
- **放大镜**：指针附近一个固定大小的放大窗口，源矩形取冻帧纹理的一块（`DrawImage` 的
  source rect），中心画十字 + 读当前像素 RGB。MVP 可后置。
- **提示**：底部一行 `Esc 取消 · Enter 确认 · 方向键微调`。
- **键盘**：方向键移动选区、`Shift`+方向键改尺寸、`Enter` 确认、`Esc` 取消。
- 每屏一个 `OverlayApp` 实例，共享同一 `Session`；选择结果存会话（全局坐标）。

### 6.2 编辑窗 `ui/editor.rs`（`EditorApp: AppLogic`）

- **顶栏**：工具按钮（矩形/椭圆/箭头/画笔/高亮/文字/马赛克/序号/裁剪），图标用
  `igui_svg`（Lucide）；颜色板（`igui_theme` token）；线宽；撤销/重做；动作按钮
  （复制/保存/钉图/OCR/关闭）。
- **画布**：`FrameImage` 显示会话的合成底图，叠加当前标注；缩放/平移（滚轮 + 空格拖拽）。
- **标注**：纯数据模型 + 栅格化到 `DrawList`（矢量画）；文字工具复用
  `igui_components::TextInput`（自带 caret/选区/IME，照搬 cgb 的 IME 接线）。
- **裁剪**：复用框选层的手柄逻辑。
- 撤销栈在会话里；`needs_frame` 在拖拽/动画/输入法组合时为真。

### 6.3 装配（`native/gpu.rs`、`native/ffi.rs`）

照搬 cgb：

```rust
App::new(AppConfig { title: "ushot".into(), ..Default::default() })
    .plugin(gpu_plugin)                 // NativeGpuPlugin：surface + WgpuBackend + Presenter
    .plugin(NativeTextMeasurePlugin)    // backend 字体度量 → TextMeasurer
    .plugin(NativeClipboardPlugin)      // 文本字段复制粘贴
    .plugin(NativeInputPlugin)
    .logic(LogicHandle(shared_session_and_app))
    .build();
builder.insert_service(NativeSurface { handle, width, height, scale });
```

`LogicHandle` 用 `try_borrow_mut()` 防重入（Swift 侧 `NSSavePanel` 会跑嵌套 AppKit 循环，
照搬 cgb 的处理）。

---

## 7. Swift 壳职责

| 文件 | 职责 |
|---|---|
| `main.swift` | `NSApplication` + `.accessory`（无 Dock 图标，纯菜单栏）。 |
| `AppDelegate` | 生命周期、帧驱动（事件触发一帧 + `CADisplayLink` 持续帧）、轮询 `take_*` 请求。 |
| `StatusItem` | 菜单：区域截图 / 全屏截图 / 窗口截图 / 延时 / 设置 / 权限 / 退出。 |
| `Hotkeys` | Carbon `RegisterEventHotKey`（默认 ⌘⇧A 区域、⌘⇧F 全屏）。 |
| `Capture` | ScreenCaptureKit 封装：`SCShareableContent` → `SCScreenshotManager.captureImage` → `CGImage` → RGBA8 → `ushot_display_image`。 |
| `HostView` | `NSView` + `CAMetalLayer` + 事件转发（照搬 cgb；含 IME/NSTextInputClient）。 |
| `OverlayWindows` | 每屏一个 borderless `NSPanel`（level `.screenSaver`、`canJoinAllSpaces`、`fullScreenAuxiliary`），contentView = `HostView`。 |
| `EditorWindow` | 普通窗口（透明标题栏，同 cgb），`HostView` 提供 layer。 |
| `PinWindow` | 无边框置顶小窗，显示钉住的合成图。 |
| `Clipboard` | `NSPasteboard`（从 `ushot_host_export_png` 的 PNG 建 `NSImage`）。 |
| `Permissions` | `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess` + 跳系统设置。 |

**窗口/事件映射**：与 cgb 完全一致——`keyDown` → `ushot_host_key_down`、`mouseDown` →
`ushot_host_pointer_down`……IME 走 `NSTextInputClient` → `ushot_host_ime`；拖放可选。

---

## 8. 数据流（时序）

**框选一次截图：**

```
热键 ⌘⇧A
  └─ Swift: CGPreflightScreenCaptureAccess? 否 → 引导授权
  └─ Swift: SCShareableContent + SCScreenshotManager（每屏一张，排除自身窗口）
  └─ sid = ushot_session_new()
  └─ 每屏: ushot_display_image(sid, display, origin, logical, scale, rgba)
  └─ 每屏: panel = NSPanel(screen); app = ushot_host_start(layer, w,h,scale, role=0, sid)
  └─ Rust: OverlayApp 绘制冻帧 + 遮罩；用户拖拽 → 更新 session.selection
  └─ Enter → Rust 计算全局选区 + 裁剪合成 → 停放在 session
  └─ Swift 轮询 ushot_host_take_selection() == 1，拿到矩形 → 关所有覆盖层
  └─ Swift 开 EditorWindow → ushot_host_start(..., role=1, sid)
  └─ Rust: EditorApp 画合成底图 + 工具栏
  └─ 用户点「复制」→ Rust 编码 PNG → take_action()==Copy
  └─ Swift: ushot_host_action_png() 取 PNG → NSPasteboard → ushot_host_action_done(true)
```

**Esc 取消**：`take_selection()==0` → 关覆盖层、`ushot_session_drop(sid)`。

---

## 9. 验证策略（遵守 igui / cgb 的「不写截图测试」硬规则）

产品本身能截图，与「**禁止用截图验证渲染**」不冲突——验证仍必须程序化：

1. **UI 无头自检**：`OverlayApp` / `EditorApp` 与真窗口跑**同一份 `AppLogic`**，用
   `igui_headless::HeadlessPlugin`（`RecordingBackend`）录制 DrawList，再用
   `igui_profile::inspect` 体检（NaN 几何、Save/Restore 配平、命令预算），并断言：
   - 框选层含冻帧 `DrawImage`、遮罩矩形、选择框描边、尺寸文本；
   - 编辑窗含工具栏按钮文本、画布 `DrawImage`、新增标注命令。
  `macos/scripts/run.sh --smoke-editor` / `--smoke-export` 退出码非零即失败。
2. **纯函数单测**（`cargo test`）：
   - 坐标换算：全局↔屏幕局部、逻辑点↔像素；多屏/混合 scale。
   - 裁剪 + 合成：喂合成 RGBA，断言裁剪像素、缩放、边界。
   - PNG：`encode → decode` round-trip（参考 cgb `png_codec.rs` 的测试）。
   - 标注栅格化：断言 DrawList 命令序列，而非像素外观。
3. **wgpu 离屏回读**（必要时）：`WgpuBackend::read_pixels()` 断言**我们自己**渲染出的
   像素（如选区边框颜色），这是读后端自己的像素缓冲，不是 `screencapture`。
4. **Swift 侧**：不加 UI 测试；SCK 抓屏与 TCC 手测。

Gate（每阶段）：

```bash
cargo fmt --all -- --check
cargo check --workspace
cargo clippy --workspace --all-targets -- -D warnings   # 含 undocumented_unsafe_blocks
cargo test --workspace
macos/scripts/run.sh --smoke-editor   # 开/关编辑窗
macos/scripts/run.sh --smoke-export   # 合成 → 编辑 → 复制
swift build --package-path macos
```

---

## 10. 分阶段计划

| 阶段 | 内容 | 验收 |
|---|---|---|
| **P0 骨架** ✅ | workspace + `staticlib` + `ushot_host.h` + SwiftPM + 一个 igui 面板窗口打通 | `dev` gate 绿 |
| **P1 会话 + 冻帧** ✅ 待验收 | `SessionManager`、`ushot_display_image`、`register_texture`、Swift 全屏捕获 → 冻帧覆盖层 | 单屏能看到冻帧整屏（需屏幕录制权限） |
| **P2 框选** ✅ 待验收 | 遮罩 / 选择框 / 手柄 / 十字线 / 尺寸、Enter/Esc、全局坐标换算、多显示器 | 人眼验收框选；坐标单测绿 |
| **P3 编辑窗** ✅ 待验收 | 裁剪合成、画布显示/缩放、基础标注（矩形/箭头/画笔）、撤销重做 | 人眼验收；打字机测试（命令序列）绿 |
| **P4 输出 + 壳** ✅ 待验收 | PNG、复制、保存面板、钉图、状态栏菜单、全局热键、权限引导 | 端到端人眼验收；`--smoke-export` 绿 |
| **P5 可选** ✅ 待验收 | 文字 / 马赛克 / 窗口拾取（序号 / 延时 / OCR / 滚屏 未做） | 逐项确认 |

每阶段结束出报告、等用户确认后再进入下一阶段（与 cgb / igui 的约定一致）。

---

## 11. 风险与开放问题

1. **多 surface 多 device（方案 A）**：显存/启动开销。显示器多时明显。备选方案 B。
2. **ScreenCaptureKit 版本差异**：`SCScreenshotManager`（14+）、`SCContentSharingPicker`（14+）。
   较低系统需退回 `CGDisplayCreateImage`（14 起废弃）。故建议最低 14。
3. **TCC 权限**：首次授权后**通常需要重启 app** 才能抓屏；菜单要显式提示并提供跳转。
4. **冻帧显存**：4K×2 屏 RGBA ≈ 33 MB/屏；会话结束时 `remove_texture` 释放。
5. **覆盖层窗口行为**：Mission Control / 全屏 app / 多 Space / Stage Manager / 刘海遮挡，
   需真机逐个验证（`collectionBehavior`、`level`）。
6. **色彩**：HDR / 广色域屏需指定 color space（MVP 先 sRGB，记 TODO）。
7. **上游耦合**：同 cgb——`igui` 以 git tag 固定（建议对齐 `v0.3.x`）；要改 igui 用本地
   `[patch]`，不直接改依赖 checkout。
8. **`igui` 尚无标准 Image 内容类型**：同 cgb，用本地 `FrameImage` 组件（`Component` +
   `Spec::foreground`）承载图片；上游若有 Image 组件可替换。

---

## 12. 待确认（决定后才能开工）

1. **项目名**：✅ `ushot`（二进制 `ushot-mac`、crate `ushot-app`、C ABI `ushot_host_*`、静态库
   `libushot_app.a`、Swift 包 `UShotMac`）。
2. **最低系统**：✅ macOS 14（为 ScreenCaptureKit 单帧抓屏）。
3. **MVP 标注范围**：矩形 / 箭头 / 画笔 + 撤销（P3）。
4. **MVP 包含**：钉图、保存面板；窗口拾取 / 延时 / OCR / 滚屏列为 P5 可选。
5. **igui 依赖方式**：✅ 本地 path（`../igui`，tag v0.3.1）；要锁定发布版改 git tag（一行）。
6. **放置位置**：✅ `/Users/suke/Documents/ushot/`。

> 推荐默认已生效：多 surface 策略取**方案 A**（每窗口一个 wgpu device，与 cgb 完全一致）。

---

## 附：已落地（与设计的对应）

| 设计 | P0 | P1 |
|---|---|---|
| `Cargo.toml`（workspace + `lib`/`staticlib`） | ✅ `libushot_app.a` | — |
| `include/ushot_host.h` | ✅ 窗口/帧 + 输入 + session | ✅ `display_id` 参数 + `ushot_display_image` |
| `src/native/` | ✅ `NativeGpuPlugin` / Presenter / 输入 | — |
| `src/session.rs` | ✅ 会话表 + `SessionMode` | ✅ `displays`（冻帧 + 纹理） |
| `src/ui/canvas.rs` | — | ✅ 画布 + 像素映射 |
| `src/ui/overlay.rs` | — | ✅ 冻帧铺满 + 暗色遮罩 |
| `src/ui/selection.rs` | — | ✅ 选区几何 + 拖拽状态机（单测） |
| `src/ui/image.rs` | — | ✅ `ImageFill` 叶子组件 |
| `macos/` | ✅ SwiftPM + AppKit + CAMetalLayer | ✅ `Capture.swift`（SCK）/ `OverlayWindows.swift` / 权限 |
| `--smoke-editor` / `--smoke-export` | — | ✅ 开/关编辑窗、导出到剪贴板 |

---

## 附：与 classic-game-box 的对应表

| classic-game-box | ushot |
|---|---|
| `macos/Package.swift`（`CGBNative` + `ClassicGameBoxMac`） | `macos/Package.swift`（`UShotNative` + `UShotMac`） |
| `src/native/include/cgb_host.h` | `include/ushot_host.h` |
| `src/native/{mod,ffi,gpu,plugins,input}.rs` | `src/native/{mod,ffi,gpu,plugins,input}.rs` |
| `NativeGpuPlugin`（surface+backend+Presenter） | 同名同形（每窗口一套） |
| `cgb_host_start/frame/destroy/resize` | `ushot_host_start/frame/destroy/resize` |
| `cgb_host_take_fullscreen`（停放+轮询） | `ushot_host_take_selection/action`（同法） |
| `LogicHandle::try_borrow_mut` 防重入 | 同 |
| `src/ui/frame.rs` 的 `FrameImage` | 复用到冻帧 / 画布 |
| `src/library/png_codec.rs` | `src/export/png.rs` |
| emulator / libretro | ScreenCaptureKit（在 Swift 侧） |
