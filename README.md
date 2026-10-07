# ushot

macOS 截图工具。**菜单栏常驻，无常驻主窗**；界面完全用 [`igui`](../igui) 的 UI 栈绘制
（`igui_core` / `igui_scene` / `igui_ui` / `igui_theme` / `igui_components` +
`igui_backend_wgpu`），壳是 Swift（AppKit + `CAMetalLayer` + 原生事件 + ScreenCaptureKit），
参考 [`classic-game-box`](../classic-game-box) 的 Swift 壳方案。完整设计见 [`DESIGN.md`](DESIGN.md)。

## 功能

- **区域截图**（⌘⇧A）：冻结所有显示器 → 每屏一个无边框覆盖层，拖拽/手柄调整选区，
  十字线 + 尺寸读数，方向键微调；Enter 确认，Esc 取消。**开始时不压暗**，矩形画好后才在
  选区外出现暗色蒙版。
- **窗口截图**（⌘⇧W）：AppKit 命中测试确定鼠标下的窗口（考虑真实 z-order / 遮挡），
  悬停到窗口才压暗并高亮那一个；点击后用 ScreenCaptureKit 的
  `desktopIndependentWindow` 抓**该窗口自身的内容**（被遮挡也正确）。
- **编辑窗**：矩形 / 箭头 / 画笔 / 高亮 / 文字（支持 IME）/ 马赛克 + 撤销重做；
  复制到剪贴板、保存 PNG、钉到桌面（悬浮窗）。
- 截图与导出都是原生像素（Retina 2x），区域与窗口一致清晰。

## 架构

```
AppKit / ScreenCaptureKit (Swift, macos/)          Rust staticlib (libushot_app.a)
────────────────────────────────────────           ────────────────────────────────
NSStatusItem / Carbon 全局热键（⌘⇧A / ⌘⇧W） ──┐     igui_app 运行时 + 视图
覆盖层 / 编辑窗 / 钉图窗口 + CAMetalLayer      ├ c ABI ┤ wgpu 后端 + Presenter
ScreenCaptureKit 抓屏 / 单窗口捕获             │     capture / compose / annotate / export
NSPasteboard / NSSavePanel / 权限引导          ─┘     session（冻帧 / 选区 / 合成 / 动作）
```

- Swift 只拥有**窗口、`CAMetalLayer`、原生事件与系统能力**；UI、渲染与全部图像处理在 Rust。
- Rust 产出 `libushot_app.a`（`crate-type = ["lib", "staticlib"]`），SwiftPM 静态链接。
- 唯一契约是 [`include/ushot_host.h`](include/ushot_host.h)（`ushot_host_*` C ABI）。
- 窗口只在需要时开（覆盖层 / 编辑窗 / 钉图），所以不会有常驻窗挡住要截的目标。

## 构建 / 运行

```bash
macos/scripts/build.sh              # Rust staticlib + Swift 可执行
macos/scripts/run.sh                # 构建并运行（菜单栏，无窗口）
USHOT_RUST_PROFILE=release macos/scripts/build.sh
```

首次截图需在「系统设置 › 隐私与安全性 › 屏幕录制」里授予权限并重启。

`igui` 目前用**本地 checkout**（`../igui`，tag `v0.3.1`）。要锁定发布版，把 `Cargo.toml`
里的 path 换成 classic-game-box 用的 git 依赖即可。

## 自检（无需屏幕录制权限）

```bash
./scripts/dev.sh                    # fmt --check + clippy -D warnings + test + cargo build + swift build
macos/scripts/run.sh --smoke-editor # 开/关编辑窗，走 AppKit 真实关闭路径
macos/scripts/run.sh --smoke-export # 注入合成图 → 编辑 → 复制到剪贴板
```

**不写截图 / 录屏测试**（igui / cgb 的硬规则）：渲染用 `igui_backend_recording` 录 `DrawList`
+ `igui_profile::inspect` + 断言命令序列；图像处理（裁剪合成、马赛克取样、PNG、坐标换算）
用纯函数单测；导出用离屏 `WgpuBackend` 渲染后读回像素验证。

## 目录

```
src/
  native/        surface / GPU 插件 / 输入 / ushot_host_* C ABI
  session.rs     会话：冻帧、选区、合成图、动作、悬停窗口
  capture.rs     冻帧值类型     compose.rs  选区 → RGBA（跨屏拼接）
  annotate/      标注模型       export/png   PNG 编解码
  ui/            overlay（框选层）/ selection（几何）/ editor / canvas / image
macos/
  Package.swift  ShotNative（C module）+ ShotMac（可执行）
  Sources/UShotMac/  Capture / OverlayWindows / EditorWindow / PinWindows /
                     MenuBar / Hotkeys / HostView / Permissions / AppDelegate
  packaging/Info.plist（LSUIElement）   scripts/{build,run,package}.sh
```

## 已知缺口

- 无颜色 / 线宽选择（固定红 2px；文字固定 18px）；马赛克块固定 12px。
- 文字提交后不能二次编辑（可撤销）。
- 窗口拾取不做 app 级分组 / 子窗口选择。
- 序号 / 延时 / OCR / 滚屏长图未做。
