# 终端可点击链接（Cmd+点击打开 / Cmd+悬停高亮）设计

日期：2026-05-31
状态：已批准，待实现

## 目标

让终端里的 URL 支持 Cmd+点击跳转，并在 Cmd+悬停时显示下划线高亮与手型光标，体验对齐 VS Code 终端。

## 背景

libghostty 内部已实现完整的链接基础设施：链接正则识别、Cmd+点击判定、下划线高亮渲染都在引擎内部完成。mux0 当前未接入相关的 action 回调，所以：

- Cmd+点击链接没有反应（`GHOSTTY_ACTION_OPEN_URL` 落到 `actionCallback` 的 `default` 分支返回 `false`）
- 悬停链接光标不变手型（`GHOSTTY_ACTION_MOUSE_SHAPE` 未处理）
- 悬停无下划线高亮（`mouseMoved` 故意不转发 hover 位置，见 `GhosttyTerminalView.swift:686`）

`mouseDown` 已带修饰键转发（`modsFromEvent` 含 `GHOSTTY_MODS_SUPER`），所以缺的只是宿主侧的三处接线。

改动集中在两个文件，不新增文件，不改目录结构。

## 改动

### 1. 打开 URL — `GhosttyBridge.swift`

在 `actionCallback` 新增 `case GHOSTTY_ACTION_OPEN_URL`：

- 从 `action.action.open_url` 读 `url` 指针与 `len`，按字节长度构造 `String`（不依赖 NUL 结尾，避免截断）。
- bounce 到主线程，调用 `NSWorkspace.shared.open(url)`。
- **scheme 白名单**：仅放行 `http` / `https` / `mailto` / `file`，其余 scheme 忽略，防止终端输出注入自定义 scheme 触发意外行为。
- 返回 `true`（已处理）。

为可测性，把解析与过滤抽成纯静态函数：

```
static func resolveOpenURL(_ raw: String) -> URL?
```

- 输入原始字符串，返回通过白名单校验的 `URL`，否则 `nil`。
- `actionCallback` 调它，拿到非 nil 才 `NSWorkspace.shared.open`。

### 2. 手型光标 — `GHOSTTY_ACTION_MOUSE_SHAPE`

在 `actionCallback` 新增 `case GHOSTTY_ACTION_MOUSE_SHAPE`：

- 读 `action.action.mouse_shape`，映射到 `NSCursor`：
  - `GHOSTTY_MOUSE_SHAPE_POINTER → .pointingHand`
  - `GHOSTTY_MOUSE_SHAPE_TEXT → .iBeam`
  - 其余 → `.arrow`
- bounce 到主线程，经 `GhosttyTerminalView.view(forSurface:)` 找到 view，写入其 `currentCursor` 并立即生效。

`GhosttyTerminalView` 侧：

- 新增 `private var currentCursor: NSCursor`（默认 `.iBeam`）。
- tracking area 选项追加 `.cursorUpdate`。
- override `cursorUpdate(with:)` → `currentCursor.set()`。
- action 写入 `currentCursor` 时若鼠标在自身上，立即 `currentCursor.set()`。

注意：这会让终端区域默认光标从当前的箭头变为更标准的 iBeam，与 VS Code 一致（已确认可接受）。

### 3. 重新开启 hover 转发 — `mouseMoved`

将 `GhosttyTerminalView.mouseMoved(with:)` 由空实现改为转发：

```
guard isCursorOverSelf(event) else { return }
guard let s = surface else { return }
let pt = flippedPoint(event.locationInWindow)
ghostty_surface_mouse_pos(s, pt.x, pt.y, modsFromEvent(event))
```

安全性论证：

- tracking area 为 `.activeWhenFirstResponder`，`mouseMoved` 仅在本 view 是 first responder（即焦点 pane）时触发，再加 `isCursorOverSelf` 守卫。
- 旧注释担心的"选区跟随鼠标"只在鼠标按键按下时才扩选；无按键的纯 hover 不会画选区。
- 后台 pane 的 ghostty `mouseLocation` 轮询问题已被现有 frontmost gate 拦住，不受本改动影响。

### 不做

- `GHOSTTY_ACTION_MOUSE_OVER_LINK`：下划线由 ghostty 渲染器自行绘制，此 action 仅为宿主可选地显示 URL 状态栏，YAGNI，不接。
- 无需改 ghostty config，`link-url` 默认开启。

## 测试

- **单元测试**：`resolveOpenURL` 的白名单逻辑——放行 http/https/mailto/file，拒绝 javascript/自定义 scheme/空串/非法 URL。
- **手动验证**：`xcodebuild build` 编译通过；用户重启 app 后实测 Cmd+悬停看下划线与手型光标、Cmd+点击打开 http 链接，普通点击不误触发。

## 影响文件

- `mux0/Ghostty/GhosttyBridge.swift` — 两个新 case + `resolveOpenURL`
- `mux0/Ghostty/GhosttyTerminalView.swift` — `currentCursor` + `cursorUpdate` + `mouseMoved` 转发
- `mux0Tests/` — 新增 `resolveOpenURL` 测试
- `docs/ghostty-integration.md` — 补充新接入的 action 回调
