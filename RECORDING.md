# kacha 录屏 —— 规划设计（提案，未确认）

> 状态：**Phase 1 已实现**。录屏已从 `DESIGN.md` 的非目标移入范围。
> 已按推荐决策：方案 A（`SCRecordingOutput`，macOS 15+ 门控）、MVP 无暂停、
> 支持区域 / 窗口 / 整屏、MVP 纯视频、窗口列表（支持被遮挡窗口）、自动运镜放 Phase 4。
> 本文保留为录屏的总体设计；Phase 2+ 仍未实现。
>
> 所有 API 可用性均用本机 `MacOSX27.0.sdk` 头文件核实（系统 macOS 26.7.1）。

---

## 1. 结论

**可行，而且比想象中简单。** macOS 15 起 ScreenCaptureKit 自带
`SCRecordingOutput`，能把 SCStream 的画面 + 系统声音 + 麦克风直接写成一个
mp4/mov，不用自己接 `AVAssetWriter`。kacha 现有的
「冻结 → 覆盖层选区 → 确认」流程可以几乎原样复用，只需要在确认后
**把「裁剪出静态图」换成「启动一路 SCStream 录制」**。

主要代价 / 约束：

- `SCRecordingOutput` 是 **macOS 15.0+**；14.0 上要么降级不可用，要么另写
  `AVAssetWriter` 路径。
- `SCRecordingOutput` **没有暂停**（只有开始 / 停止 / 结束写文件）。暂停要么不做，
  要么用「分段录制 + 导出拼接」，成本明显上升。
- 区域录制受 `sourceRect` 限制，**只能落在一块显示器内**（跨屏区域录不了单文件）。
- 麦克风需要新的 `NSMicrophoneUsageDescription` + 麦克风 TCC。

---

## 2. 与现有硬规则的冲突

| 规则 | 影响 |
|---|---|
| `DESIGN.md §1.1` 把「录屏 / GIF」列为非目标 | 需要先改产品范围（把录屏移出非目标） |
| 只写 Swift、无第三方 | ✅ AVFoundation / ScreenCaptureKit 都是系统框架，合规 |
| 部署目标保持 14.0 | ✅ 保持；录屏入口用 `if #available(macOS 15.0, *)` 门控，14 上隐藏 / 禁用 |
| 不写录屏测试 | ✅ 只测纯逻辑（时长格式化、文件名、配置映射）和开 / 关控制栏窗口 |
| AppKit 管窗口、SwiftUI 管 chrome | ✅ 控制栏走 SwiftUI + `NSHostingView`，沿用 `WindowChrome` |

---

## 3. API 调研（已核实）

| API | 可用性 | 用途 |
|---|---|---|
| `SCStream` / `SCStreamConfiguration` / `SCContentFilter` | macOS 12.3+ | 已在截图里用，直接复用 |
| `SCStreamConfiguration.sourceRect` | 12.3+ | 区域录制（**点**，显示器逻辑坐标） |
| `minimumFrameInterval` / `queueDepth` / `showsCursor` / `colorSpaceName` / `pixelFormat` | 12.3+ | 帧率 / 缓冲 / 光标 / 画质 |
| `capturesAudio` / `excludesCurrentProcessAudio` | 13.0+ | 系统声音 |
| `preservesAspectRatio` / `capturesShadowsOnly` | 14.0+ | 比例 / 窗口阴影 |
| `SCContentSharingPicker` | 14.0+ | 系统选择器（display / window / app，**无区域**） |
| `showMouseClicks` | 15.0+ | 点击高亮圆圈 |
| `SCRecordingOutput` / `SCRecordingOutputConfiguration` | **15.0+** | 直接录成文件（H264/HEVC，mp4/mov） |
| `SCStreamConfiguration.captureMicrophone` / `.microphone` 输出 | **15.0+** | 麦克风 |
| `SCRecordingEditor`（系统裁剪 UI） | macOS 27（未来） | 以后可白嫖裁剪 |

`SCRecordingOutput` 关键点：

- `SCRecordingOutputConfiguration`：`outputURL`、`videoCodecType`（默认 H264）、
  `outputFileType`；`availableVideoCodecTypes` / `availableOutputFileTypes` 可查询。
- `stream.addRecordingOutput(_:)` 后 `startCapture()`；录的是**当前 stream 配置里的
  画面 / 系统声 / 麦克风**。
- `recordingOutput.recordedDuration` / `recordedFileSize` 可实时读，正好喂控制栏计时。
- delegate：`recordingOutputDidStartRecording` / `didFailWithError` /
  `didFinishRecording`。
- 注释明确：`stopCapture` 但不移除 recordingOutput 会**结束并写完文件**；录制中改
  stream 配置会中断录制。

---

## 4. 方案选择

### 方案 A（推荐）：`SCRecordingOutput`，录屏门控到 macOS 15+

- 优点：代码量最小、Apple 官方路径、自动封装音视频、实时时长 / 体积、低内存。
- 缺点：14.0 不可用；**无暂停**；画质 / 码率可调项比自建 writer 少。
- 结论：**MVP 用这个**。14.0 上录屏入口隐藏（其余功能不受影响）。

### 方案 B：`SCStream` + `AVAssetWriter`（自建）

- 优点：14.0 也能用；可暂停（PTS 扣掉暂停时长）；码率 / 关键帧 / 可变帧率全控。
- 缺点：要自己接 `CMSampleBuffer` → `AVAssetWriterInput`、音视频混合、麦克风
  （14 上还得另接 `AVCaptureSession`）、写失败处理。代码量大约是 A 的 3–4 倍。
- 结论：**只有「必须支持 14」或「必须有暂停」时才走**。

### 方案 C：`SCContentSharingPicker`（系统选择器）

- 优点：选择 UI 完全免写。
- 缺点：**不支持区域**；UI 是 Apple 的，和 kacha 自绘覆盖层不一致。
- 结论：可作为「录窗口 / 整屏」的快捷入口，但不作为主路径。

**推荐组合：A 为主路径 + 复用现有覆盖层做 区域 / 窗口 / 整屏 选择。**

---

## 5. 推荐架构与数据流

```
热键 ⌘⇧R / 菜单「录制屏幕」
  └─ AppDelegate.startRecording()
       ├─ ScreenPermission.request()（已有）
       ├─ Capture.freezeAllDisplays()（复用：只为选区，录完即弃）
       ├─ CaptureSession(mode: .record) + 每屏 OverlayWindow
       └─ 用户：拖拽选区 / 点窗口 / 点桌面
            └─ 确认 → OverlayController.onRecord(session, target)
                 ├─ 可选：CountdownHUD 倒数 3s（复用）
                 ├─ ScreenRecorder.start(target, config)
                 │     ├─ 建 SCContentFilter（display / window）
                 │     ├─ 配 SCStreamConfiguration（sourceRect / 尺寸 / fps / 音频）
                 │     ├─ 挂 SCRecordingOutput(outputURL)
                 │     └─ stream.startCapture()
                 └─ RecordingBar.show()   ← 悬浮控制栏（停止 / 取消 / 计时 / 静音）

停止 → stream.stopCapture() → 文件写完
  └─ 存到保存目录（复用 Preferences.saveDirectory）或弹保存面板
       └─ 结果 sheet：路径 +「在 Finder 显示」/「复制路径」
```

要点：

- **录制目标抽象**：`enum RecordingTarget { case display(CapturedDisplay),
  region(CapturedDisplay, CGRect), window(SCWindow) }`。纯逻辑负责把它映射成
  `sourceRect` + 输出像素尺寸（可自检）。
- **排除自身**：display filter 用 `SCContentFilter(display:excludingWindows: ownWindows)`；
  控制栏窗口 `sharingType = .none`，保证控制栏不进画面。
- **区域单屏**：选区若跨屏，确认时拒绝并提示（或自动取交集所在的主屏）。
- **Retina**：`config.width/height = 选区点尺寸 × display.scale`（沿用现有 scale 逻辑），
  `sourceRect` 用点。
- **控制栏**：`NSPanel`（`.nonactivatingPanel`、`.floating`、`orderFrontRegardless`、
  `isReleasedWhenClosed = false`、`sharingType = .none`），里面放 SwiftUI。
  计时用 `Timer`（和 `CountdownHUD` 同款，每秒刷一次）。

### 5.1 窗口录制：按列表选（**不依赖顶层窗口**）

- 截图 / 取窗口那套思路（`NSWindow.windowNumber(at:below:)` 命中测试，只能取鼠标下
  **最顶层**）**不适用于录制**：录屏经常要录一个被挡住的背景窗口，甚至不在最前的窗口。
- `SCContentFilter(desktopIndependentWindow:)` 录的是**窗口自己的内容**，被遮挡、不在最前
  也能录（截图单窗口已经是这个思路，`Capture.captureWindow` 直接复用）。
- 所以录制的窗口选择要有两个入口：
  1. **覆盖层点选**：鼠标下最顶层，快速；
  2. **窗口列表**：从 `SCShareableContent.windows` 枚举，带 `owningApplication`（app 名 /
     bundle id）、`title`、`isOnScreen`、`isActive`，可选到被遮挡 / 不在最前的窗口，再按 app
     分组（`SCWindow` 的这些属性都已核实存在）。
- 枚举用 `onScreenWindowsOnly: false` 还能拿到最小化 / 其他 Space 的窗口；`SCWindow.frame`
  是全局逻辑点。

### 5.2 自动运镜 / 焦点缩放（hero 动画）

- **能做，但这是后处理**：录制时 `SCRecordingOutput` 只能原样写帧，不能边录边缩放；
  而且文档明确「录制中改 stream 配置会中断录制」，所以实时改 `sourceRect` 缩放不可行。
- 素材：录制时额外记一条**光标轨迹**——`NSEvent.mouseLocation` 每秒 30–60 次采样，
  加**点击 / Ctrl 手势**（`NSEvent.addGlobalMonitorForEvents(matching:
  [.leftMouseDown, .rightMouseDown, .leftMouseDragged, …])`；鼠标事件不需要辅助功能权限）。
  按住 `⌃` 点 / 拖 = 显式标注一个焦点（点）或焦点区域（矩形）。
- 渲染（纯系统框架，无第三方）：
  - **简单**：`AVMutableVideoComposition` + `AVMutableVideoCompositionLayerInstruction` 的
    `setTransformRamp(fromStart:toEnd:timeRange:)` / `setTransform(_:at:)`（关键帧间由 Core
    Animation 插值）+ `AVAssetExportSession` 重编码。
  - **平滑**：自定义 `AVVideoCompositing`（`AVMutableVideoComposition.customVideoCompositorClass`），
    逐帧用 Core Image / Core Graphics 按当前时间算 `CGAffineTransform`，缓动完全可控，
    还能叠光标高亮。
- 焦点来源可组合：显式 Ctrl 手势 → 自动点击检测 → 光标跟随；合并相邻焦点、设最短停留、
  进出缓动（hero 感来自 ease-in-out + 适度放大 + 居中）。
- 光标：`showsCursor = false` 录，再用轨迹画一个平滑合成光标（Screen Studio 那种）；
  或保留系统光标、只做缩放（简单）。
- **成本**：这是整个录屏里最大的一块，建议独立阶段 + 独立设计，别塞进 MVP。

---

## 6. 改动清单（预估）

新增：

```
Sources/KachaMac/Core/
  Recording.swift          # RecordingSession：状态机 + 计时 + 配置快照（纯逻辑可测）
  RecordingTarget.swift    # 目标 → sourceRect / 像素尺寸 的纯映射（可测）
  CursorTrack.swift        # 光标 / 点击 / Ctrl 手势轨迹（Phase 3，纯数据）
  AutoZoom.swift           # 焦点 → 变焦关键帧（Phase 3，纯逻辑可测）
Sources/KachaMac/Helper/
  ScreenRecorder.swift     # SCStream + SCRecordingOutput 后端（15+）
  VideoCompositor.swift    # AVVideoComposition / 自定义 AVVideoCompositing（Phase 3）
Sources/KachaMac/UI/
  AppKit/RecordingBar.swift        # 控制栏 NSPanel
  SwiftUI/RecordingBarView.swift   # 控制栏 SwiftUI（计时 / 停止 / 取消 / 静音）
  SwiftUI/WindowPickerView.swift   # 录制窗口列表（按 app 分组，含被遮挡窗口）
```

改动：

- `Core/Session.swift`：`OverlayMode` 加 `.record`。
- `UI/AppKit/OverlayWindow.swift`：`.record` 模式下确认 / 点窗口 / 点桌面走录制回调。
- `App/AppDelegate.swift`：`startRecording()`、`ScreenRecorder` 生命周期、保存 / 结果。
- `App/MenuBar.swift`：加「录制屏幕」条目。
- `Helper/Hotkeys.swift` + `Helper/Preferences.swift`：第 4 个全局热键 + 录制偏好。
- `Helper/Export.swift`：`movieName()` / 保存 movie（复用 `deduplicatedName`）。
- `UI/SwiftUI/SettingsRootView.swift`：新增「录制」分组。
- `Helper/SelfCheck.swift` + `App/LaunchOptions.swift` + `scripts/dev.sh`：断言 + smoke。
- `packaging/Info.plist`：`NSMicrophoneUsageDescription`（若做麦克风）。
- `Package.swift`：显式链接 `AVFoundation`（writer 路径或读 `AVFileType` 才需要）。
- `DESIGN.md` §1.1 / §3 / §8、`README.md`、`AGENTS.md`：文档同步。

---

## 7. 交互设计

- **入口**：菜单栏「录制屏幕」+ 全局热键（默认 `⌘⇧R`，可改）。
- **选择**：复用覆盖层（区域 / 窗口 / 整屏），底部提示文案改成录制语境。
- **开始前**：可选 3 秒倒数（复用 `CountdownHUD`），方便摆好窗口。
- **控制栏**（悬浮、可拖动、不进画面）：
  - 红点 + 计时 `00:12`（>1h 显示 `1:02:03`）
  - ⏸ 暂停（**MVP 不做**，见决策点）
  - ⏹ 停止（保存）
  - ✕ 取消（丢弃文件）
  - 系统声 / 麦克风开关（可做成开始前设置、录制中只读）
- **结束后**：存到 `Preferences.saveDirectory`，否则弹保存面板；结果 sheet 给
  「在 Finder 显示」/「复制路径」。
- 录制中菜单栏图标可加红点（可选）。

---

## 8. 权限

- **屏幕录制**：已有 `ScreenPermission`，复用；未授权先引导。
- **系统声音**：无需单独 TCC，随屏幕录制权限。
- **麦克风**（15+）：需要 `NSMicrophoneUsageDescription` + `AVCaptureDevice.requestAccess(for: .audio)`。
  - ⚠️ 从 `.build` 直接跑裸二进制没有 usage description，请求麦克风会**崩溃**；
    必须在打包 `.app` 里才启用麦克风，或用 `Bundle.main.object(forInfoDictionaryKey:)`
    检查后再决定是否暴露开关。

---

## 9. 设置项（新增「录制」分组）

- 帧率：30 / 60 fps（`minimumFrameInterval`）
- 编码：H.264 / HEVC（`videoCodecType`，用 `availableVideoCodecTypes` 过滤）
- 容器：MP4 / MOV（`outputFileType`）
- 系统声音：开 / 关（`capturesAudio`）
- 麦克风：开 / 关（15+，`captureMicrophone`）
- 显示光标：开 / 关（`showsCursor`）
- 点击高亮：开 / 关（15+，`showMouseClicks`）
- 开始前倒数：关 / 3 / 5 秒
- 保存目录：复用现有 `Preferences.saveDirectory`

---

## 10. 测试策略（遵守「不写录屏测试」）

- **`--selfcheck`（纯逻辑）**：
  - `RecordingSession` 计时格式化（`00:00` / `59:59` / `1:00:00`）
  - `RecordingTarget` → `sourceRect` / 像素尺寸（含 Retina、区域裁剪、跨屏拒绝）
  - 编码 / 容器 / 帧率 → `SCRecordingOutputConfiguration` 字段映射
  - 文件名 `kacha-<时间戳>.mp4` + 去重（复用 `Export.deduplicatedName`）
- **`--smoke-record`（真实窗口路径）**：开控制栏 → 计时跳几秒 → 关闭，回归
  `isReleasedWhenClosed` / 编辑窗同款生命周期；**不真的录屏**、不需要权限。
- **不做**：录出来的视频像素断言（硬规则 6）。

---

## 11. 风险与缓解

| 风险 | 缓解 |
|---|---|
| `SCRecordingOutput` 无暂停 | MVP 不做暂停；后续「分段文件 + `AVAssetExportSession` 拼接」或转 B |
| 14.0 不可用 | 入口 `#available(macOS 15.0, *)` 门控，14 上隐藏并给说明 |
| 区域跨屏 | 确认时校验必须落在单屏，否则提示 |
| 控制栏被录进去 | 窗口 `sharingType = .none` + filter 排除自身窗口 |
| 磁盘满 / 写失败 | `didFailWithError` → 弹窗，保留已写部分并告知路径 |
| 锁屏 / 显示器休眠中断流 | `stream(_:didStopWithError:)` → 收尾、提示 |
| 长录制内存 | `SCRecordingOutput` 增量写盘，内存压力小 |
| 裸二进制请求麦克风崩溃 | 仅打包 `.app` 且 Info.plist 有 usage 时才开放麦克风开关 |
| 自动运镜重编码慢 | 输出降分辨率 / 硬件编码；后处理放后台并给进度 |
| 光标轨迹体积 | 30–60Hz 点序列，量级很小；按时间分桶存 |

---

## 12. 分期与待确认决策点

### 决策点（需要你拍板）

1. **14.0 是否必须支持录屏？**
   - 否（推荐）→ 走方案 A，`SCRecordingOutput`，15+ 门控。
   - 是 → 走方案 B，多写一个 `AVAssetWriter` 后端。
2. **MVP 是否要暂停？**（方案 A 没有）推荐 MVP 不做。
3. **区域录制是否必须？** 推荐要（复用覆盖层即可）；只录窗口 / 整屏可更快。
4. **音频是否进 MVP？** 推荐：MVP 先视频，系统声 + 麦克风放二期。
5. **GIF 导出？** 建议后续单独做（AVAssetImageGenerator 抽帧 + ImageIO）。
6. **窗口选择要不要列表（录被遮挡 / 不在最前的窗口）？** 推荐要（`SCWindow` 列表）。
7. **自动运镜 / 焦点缩放（hero 动画）做不做、放哪期？** 推荐 Phase 3+ 独立设计；
   需要先定「显式 Ctrl 手势 / 自动点击 / 光标跟随」三种焦点来源各要哪些。

### 分期

- **Phase 1（MVP）**：区域 / 窗口 / 整屏 **视频**录制（H.264 mp4）、控制栏
  （停止 / 取消 / 计时）、菜单 + 热键、复用保存目录、`--selfcheck` + `--smoke-record`。
- **Phase 2**：系统声 + 麦克风、帧率 / 编码 / 容器设置、开始前倒数、光标 / 点击高亮。
- **Phase 3**：暂停（分段拼接或转 writer）、GIF、未来 OS 的 `SCRecordingEditor` 裁剪。
- **Phase 4（自动运镜）**：录制时记光标 / 点击 / Ctrl 手势轨迹，后处理用
  `AVMutableVideoComposition`（或自定义 `AVVideoCompositing`）做焦点缩放 + 平滑光标；
  单独设计、单独分期。
- **非目标**：摄像头 PiP、直播推流、云上传、时间线剪辑。

---

## 13. 工作量粗估

| 阶段 | 相对量级 | 主要不确定性 |
|---|---|---|
| Phase 1 | 中 | 覆盖层 `.record` 分支 + 控制栏窗口生命周期 |
| Phase 2 | 中 | 麦克风 TCC / 裸二进制崩溃边界、设置项 |
| Phase 3 | 大 | 暂停拼接 / writer 重写 |

---

## 14. 参考

- 现有抓屏：`Sources/KachaMac/Core/Capture.swift`
- 覆盖层与确认流：`Sources/KachaMac/UI/AppKit/OverlayWindow.swift`
- 会话：`Sources/KachaMac/Core/Session.swift`
- 倒数面板（可复用）：`Sources/KachaMac/UI/AppKit/CountdownHUD.swift`
- 保存 / 命名：`Sources/KachaMac/Helper/Export.swift`
- 设计总览：`DESIGN.md`
