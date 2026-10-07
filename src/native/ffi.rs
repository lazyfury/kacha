//! The C ABI the Swift shell calls. See `include/ushot_host.h` for the mirror.

use std::ffi::{c_char, c_void, CStr};

use igui::igui_app::{App as IguiApp, AppConfig, PlatformEvent};
use igui::igui_core::{Cursor, ImeEvent, Rect, Size, Vec2};

use super::gpu::{NativeGpu, NativeGpuPlugin};
use super::input::{
    key_from_code, modifiers_from_bits, pointer_button, NativeEvent, NativeInputPlugin,
};
use super::plugins::NativeTextMeasurePlugin;
use super::surface::NativeSurface;
use crate::capture::DisplayImage;
use crate::compose::ComposedImage;
use crate::session::{self, EditorAction};
use crate::ui::{EditorApp, OverlayApp};

/// A running embedded app. Opaque to C (`UShotHostApp`).
pub struct UShotHostApp {
    app: IguiApp,
    gpu: NativeGpu,
    /// The capture session this window belongs to (0 for a bare window).
    session_id: u64,
}

impl UShotHostApp {
    /// Route one native event through the runtime into the UI.
    fn emit(&mut self, event: &NativeEvent) {
        self.app.platform_event(PlatformEvent::new(event));
    }
}

/// Read an optional UTF-8 string.
///
/// # Safety
///
/// `ptr` must be NULL or a valid NUL-terminated string.
unsafe fn opt_string(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    // SAFETY: the caller guarantees a valid NUL-terminated string.
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .ok()
        .map(str::to_owned)
}

/// Start the app rendering into `handle`, sized in physical pixels.
///
/// `handle` is a `CAMetalLayer *`. `role` is a `USHOT_ROLE_*` value;
/// `session_id` an id from [`ushot_session_new`] (0 for a bare window); and
/// `display_id` selects which frozen frame an overlay window shows.
///
/// # Safety
///
/// `handle` must be a live window handle that outlives the returned app.
#[no_mangle]
pub unsafe extern "C" fn ushot_host_start(
    handle: *mut c_void,
    width: u32,
    height: u32,
    scale: f64,
    role: u32,
    session_id: u64,
    display_id: u32,
) -> *mut UShotHostApp {
    if handle.is_null() {
        eprintln!("ushot-host: 窗口句柄为空");
        return std::ptr::null_mut();
    }

    let (gpu_plugin, gpu) = NativeGpuPlugin::new();

    let builder = IguiApp::new(AppConfig {
        title: "ushot".to_string(),
        size: (1100.0, 760.0),
        ..Default::default()
    })
    .plugin(gpu_plugin)
    .plugin(NativeTextMeasurePlugin)
    .plugin(NativeInputPlugin);
    // The overlay is one window per display; the editor consumes the confirmed
    // selection; every other role is the placeholder for now.
    let mut builder = match role {
        0 => builder.logic(OverlayApp::new(session_id, display_id)),
        _ => builder.logic(EditorApp::new(session_id)),
    };
    builder.insert_service(NativeSurface {
        handle,
        width,
        height,
        scale,
    });

    let mut app = builder.build();
    app.resumed();

    // A missing backend means the surface or wgpu device could not be created;
    // surface it as a start failure so the shell can tell the user.
    if !gpu.is_ready() {
        eprintln!("ushot-host: GPU 初始化失败（surface / wgpu backend）");
        return std::ptr::null_mut();
    }

    Box::into_raw(Box::new(UShotHostApp {
        app,
        gpu,
        session_id,
    }))
}

/// Tear the app down.
///
/// # Safety
///
/// `app` must come from [`ushot_host_start`] and not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn ushot_host_destroy(app: *mut UShotHostApp) {
    if app.is_null() {
        return;
    }
    // SAFETY: the caller guarantees an owned, not-yet-freed pointer.
    drop(unsafe { Box::from_raw(app) });
}

/// Run one frame: update, lay out, paint and present.
///
/// # Safety
///
/// `app` must be a live pointer from [`ushot_host_start`].
#[no_mangle]
pub unsafe extern "C" fn ushot_host_frame(app: *mut UShotHostApp) {
    // SAFETY: `app` is a live pointer from `ushot_host_start` (this fn's contract).
    if let Some(app) = unsafe { app.as_mut() } {
        app.app.frame();
    }
}

/// Whether the app wants another frame.
///
/// # Safety
///
/// `app` must be a live pointer from [`ushot_host_start`].
#[no_mangle]
pub unsafe extern "C" fn ushot_host_needs_frame(app: *const UShotHostApp) -> bool {
    // SAFETY: `app` is a live pointer from `ushot_host_start` (this fn's contract).
    unsafe { app.as_ref() }.is_some_and(|app| app.app.needs_frame())
}

/// Resize the drawable (physical pixels) and update the backing scale.
///
/// # Safety
///
/// `app` must be a live pointer from [`ushot_host_start`].
#[no_mangle]
pub unsafe extern "C" fn ushot_host_resize(
    app: *mut UShotHostApp,
    width: u32,
    height: u32,
    scale: f64,
) {
    // SAFETY: `app` is a live pointer from `ushot_host_start` (this fn's contract).
    if let Some(app) = unsafe { app.as_mut() } {
        app.gpu.resize(width, height, scale);
    }
}

/// The cursor the UI wants (an `igui_core::Cursor` discriminant), or `0`.
///
/// # Safety
///
/// `app` must be a live pointer from [`ushot_host_start`].
#[no_mangle]
pub unsafe extern "C" fn ushot_host_cursor(app: *const UShotHostApp) -> u32 {
    // SAFETY: `app` is a live pointer from `ushot_host_start` (this fn's contract).
    unsafe { app.as_ref() }
        .and_then(|app| app.app.cursor())
        .map_or(0, cursor_code)
}

/// Map a core cursor to its ABI discriminant (the order of `Cursor`'s variants).
fn cursor_code(cursor: Cursor) -> u32 {
    match cursor {
        Cursor::Default => 0,
        Cursor::Pointer => 1,
        Cursor::Text => 2,
        Cursor::ColResize => 3,
        Cursor::RowResize => 4,
        Cursor::Grab => 5,
        Cursor::Grabbing => 6,
    }
}

/// The focused text caret in logical viewport points (origin top-left), for
/// placing the IME candidate window. Returns false when there is none.
///
/// # Safety
///
/// `app` must be a live pointer from [`ushot_host_start`]; the out pointers must
/// be writable `f32`s or NULL.
#[no_mangle]
pub unsafe extern "C" fn ushot_host_caret(
    app: *const UShotHostApp,
    out_x: *mut f32,
    out_y: *mut f32,
    out_width: *mut f32,
    out_height: *mut f32,
) -> bool {
    // SAFETY: `app` is a live pointer from `ushot_host_start` (this fn's contract).
    let Some(rect) = (unsafe { app.as_ref() }).and_then(|app| app.app.caret()) else {
        return false;
    };
    if !out_x.is_null() {
        // SAFETY: the out pointer is non-null and writable (checked above).
        unsafe { *out_x = rect.left() };
    }
    if !out_y.is_null() {
        // SAFETY: the out pointer is non-null and writable (checked above).
        unsafe { *out_y = rect.top() };
    }
    if !out_width.is_null() {
        // SAFETY: the out pointer is non-null and writable (checked above).
        unsafe { *out_width = rect.size.width };
    }
    if !out_height.is_null() {
        // SAFETY: the out pointer is non-null and writable (checked above).
        unsafe { *out_height = rect.size.height };
    }
    true
}

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

/// Create a new capture session and return its id.
#[no_mangle]
pub extern "C" fn ushot_session_new() -> u64 {
    session::create().0
}

/// Drop a session. A no-op for an unknown id.
#[no_mangle]
pub extern "C" fn ushot_session_drop(session_id: u64) {
    session::remove(session_id);
}

/// Set the current selection (global logical points). Used by a programmatic
/// flow; the overlay sets it through pointer events.
#[no_mangle]
pub extern "C" fn ushot_session_set_selection(
    session_id: u64,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
) {
    let Some(session) = session::get(session_id) else {
        return;
    };
    session.borrow_mut().selection = Some(Rect::from_min_size(
        Vec2::new(x, y),
        Size::new(width, height),
    ));
}

/// Set (or clear) the window under the cursor, in global logical points. The
/// shell owns the hit-test, so the overlay just renders what it is told.
#[no_mangle]
pub extern "C" fn ushot_session_set_hover(
    session_id: u64,
    has_hover: bool,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
) {
    let Some(session) = session::get(session_id) else {
        return;
    };
    session.borrow_mut().hover =
        has_hover.then(|| Rect::from_min_size(Vec2::new(x, y), Size::new(width, height)));
}

/// Enter (`on`) or leave window-pick mode: the overlay outlines windows and a
/// click selects one instead of dragging a region.
#[no_mangle]
pub extern "C" fn ushot_session_set_pick_window(session_id: u64, on: bool) {
    let Some(session) = session::get(session_id) else {
        return;
    };
    session.borrow_mut().pick_window = on;
}

/// Take the pick click: returns `1` once after a window was clicked, `-1`
/// otherwise. The shell then captures the window it is tracking.
#[no_mangle]
pub extern "C" fn ushot_session_take_pick(session_id: u64) -> i32 {
    let Some(session) = session::get(session_id) else {
        return -1;
    };
    let mut session = session.borrow_mut();
    if session.picked {
        session.picked = false;
        1
    } else {
        -1
    }
}

/// Set the composed image directly (used for a captured window, which the shell
/// rasterizes itself). The editor reads it from [`Session::composed`].
///
/// # Safety
///
/// `rgba` must point to at least `length` readable bytes, with
/// `length >= width * height * 4`.
#[no_mangle]
pub unsafe extern "C" fn ushot_session_set_composed(
    session_id: u64,
    width: u32,
    height: u32,
    rgba: *const u8,
    length: usize,
) {
    let Some(session) = session::get(session_id) else {
        return;
    };
    if rgba.is_null() || width == 0 || height == 0 {
        return;
    }
    let expected = width as usize * height as usize * 4;
    if length < expected {
        eprintln!("ushot-host: 合成图太短（{length} < {expected}）");
        return;
    }
    // SAFETY: the caller guarantees `rgba` is readable for `length` bytes, and
    // `expected <= length` (checked above).
    let pixels = unsafe { std::slice::from_raw_parts(rgba, expected) }.to_vec();
    let composed = ComposedImage {
        width,
        height,
        rgba: pixels,
    };
    session.borrow_mut().composed = Some(std::rc::Rc::new(composed));
}

/// Inject one display's frozen frame (RGBA8, tightly packed, straight alpha)
/// into a session. The overlay window for `display_id` uploads it to its own
/// backend on its next frame.
///
/// # Safety
///
/// `rgba` must point to at least `length` readable bytes, and `length` must be
/// `>= (logical_width * scale) * (logical_height * scale) * 4`.
#[no_mangle]
pub unsafe extern "C" fn ushot_display_image(
    session_id: u64,
    display_id: u32,
    origin_x: f32,
    origin_y: f32,
    logical_width: u32,
    logical_height: u32,
    scale: f64,
    rgba: *const u8,
    length: usize,
) {
    let Some(session) = session::get(session_id) else {
        eprintln!("ushot-host: 会话 {session_id} 不存在，丢弃冻帧");
        return;
    };
    if rgba.is_null() {
        eprintln!("ushot-host: 冻帧指针为空");
        return;
    }
    let mut image = DisplayImage {
        display_id,
        origin_x,
        origin_y,
        logical_width,
        logical_height,
        scale,
        rgba: Vec::new(),
    };
    let expected = image.expected_len();
    if length < expected {
        eprintln!("ushot-host: 冻帧太短（{length} < {expected}）");
        return;
    }
    // SAFETY: the caller guarantees `rgba` is readable for `length` bytes, and
    // `expected <= length` (checked above).
    image.rgba = unsafe { std::slice::from_raw_parts(rgba, expected) }.to_vec();
    session.borrow_mut().set_display(image);
}

/// Confirm the current selection (the shell calls this on Enter): crop it out
/// of the frozen frames into `Session::composed`. A no-op when there is no
/// usable selection.
#[no_mangle]
pub extern "C" fn ushot_session_confirm(session_id: u64) {
    let Some(session) = session::get(session_id) else {
        return;
    };
    let mut session = session.borrow_mut();
    session.confirm();
}

/// The confirmed selection in global logical points (origin top-left).
/// `1` when confirmed, `-1` while there is nothing to report.
///
/// # Safety
///
/// The out pointers must be writable `f32`s or NULL.
#[no_mangle]
pub unsafe extern "C" fn ushot_session_take_selection(
    session_id: u64,
    out_x: *mut f32,
    out_y: *mut f32,
    out_width: *mut f32,
    out_height: *mut f32,
) -> i32 {
    let Some(session) = session::get(session_id) else {
        return -1;
    };
    let session = session.borrow();
    if !session.confirmed {
        return -1;
    }
    let Some(rect) = session.selection else {
        return -1;
    };
    let min = rect.min();
    if !out_x.is_null() {
        // SAFETY: the out pointer is non-null and writable (checked above).
        unsafe { *out_x = min.x };
    }
    if !out_y.is_null() {
        // SAFETY: the out pointer is non-null and writable (checked above).
        unsafe { *out_y = min.y };
    }
    if !out_width.is_null() {
        // SAFETY: the out pointer is non-null and writable (checked above).
        unsafe { *out_width = rect.size.width };
    }
    if !out_height.is_null() {
        // SAFETY: the out pointer is non-null and writable (checked above).
        unsafe { *out_height = rect.size.height };
    }
    1
}

/// The composed image size in pixels. Returns false when the session has no
/// composed image (yet).
///
/// # Safety
///
/// The out pointers must be writable `u32`s or NULL.
#[no_mangle]
pub unsafe extern "C" fn ushot_session_composed_size(
    session_id: u64,
    out_width: *mut u32,
    out_height: *mut u32,
) -> bool {
    let Some(session) = session::get(session_id) else {
        return false;
    };
    let session = session.borrow();
    let Some(composed) = session.composed.as_ref() else {
        return false;
    };
    if !out_width.is_null() {
        // SAFETY: the out pointer is non-null and writable (checked above).
        unsafe { *out_width = composed.width };
    }
    if !out_height.is_null() {
        // SAFETY: the out pointer is non-null and writable (checked above).
        unsafe { *out_height = composed.height };
    }
    true
}

// ---------------------------------------------------------------------------
// Editor actions
// ---------------------------------------------------------------------------

/// Take the editor's pending action: `0` none, `1` copy, `2` save, `3` pin,
/// `4` close. The action is consumed; fetch its PNG with
/// [`ushot_host_action_png`] and then call [`ushot_host_action_done`].
///
/// # Safety
///
/// `app` must be a live pointer from [`ushot_host_start`].
#[no_mangle]
pub unsafe extern "C" fn ushot_host_take_action(app: *const UShotHostApp) -> u32 {
    // SAFETY: `app` is a live pointer from `ushot_host_start` (this fn's contract).
    let Some(app) = (unsafe { app.as_ref() }) else {
        return 0;
    };
    let Some(session) = session::get(app.session_id) else {
        return 0;
    };
    let action = session.borrow_mut().request.take();
    match action {
        Some(EditorAction::Copy) => 1,
        Some(EditorAction::Save) => 2,
        Some(EditorAction::Pin) => 3,
        Some(EditorAction::Close) => 4,
        None => 0,
    }
}

/// The PNG for the pending action: the byte length (always), and a copy into
/// `out` when it is non-NULL and `capacity` is large enough. Call with a NULL
/// `out` first to size the buffer.
///
/// # Safety
///
/// `app` must be a live pointer from [`ushot_host_start`]; when `out` is
/// non-NULL it must be writable for `capacity` bytes.
#[no_mangle]
pub unsafe extern "C" fn ushot_host_action_png(
    app: *const UShotHostApp,
    out: *mut u8,
    capacity: usize,
) -> usize {
    // SAFETY: `app` is a live pointer from `ushot_host_start` (this fn's contract).
    let Some(app) = (unsafe { app.as_ref() }) else {
        return 0;
    };
    let Some(session) = session::get(app.session_id) else {
        return 0;
    };
    let session = session.borrow();
    let Some(png) = session.export_png.as_ref() else {
        return 0;
    };
    let length = png.len();
    if !out.is_null() && capacity >= length {
        // SAFETY: the caller guarantees `out` is writable for `capacity` bytes,
        // and `length <= capacity` (checked above).
        unsafe { std::ptr::copy_nonoverlapping(png.as_ptr(), out, length) };
    }
    length
}

/// Clear the pending action's PNG. Call after the shell finished with it.
///
/// # Safety
///
/// `app` must be a live pointer from [`ushot_host_start`].
#[no_mangle]
pub unsafe extern "C" fn ushot_host_action_done(app: *mut UShotHostApp) {
    // SAFETY: `app` is a live pointer from `ushot_host_start` (this fn's contract).
    let Some(app) = (unsafe { app.as_mut() }) else {
        return;
    };
    if let Some(session) = session::get(app.session_id) {
        session.borrow_mut().export_png = None;
    }
}

/// Park an editor action programmatically (the same path a toolbar button uses,
/// for keyboard shortcuts / a scripted flow). `action` is a `USHOT_ACTION_*`
/// value; the editor rasterizes on its next update.
///
/// # Safety
///
/// `app` must be a live pointer from [`ushot_host_start`].
#[no_mangle]
pub unsafe extern "C" fn ushot_host_request_action(app: *mut UShotHostApp, action: u32) {
    // SAFETY: `app` is a live pointer from `ushot_host_start` (this fn's contract).
    let Some(app) = (unsafe { app.as_mut() }) else {
        return;
    };
    let Some(session) = session::get(app.session_id) else {
        return;
    };
    let action = match action {
        1 => EditorAction::Copy,
        2 => EditorAction::Save,
        3 => EditorAction::Pin,
        4 => EditorAction::Close,
        _ => return,
    };
    session.borrow_mut().request = Some(action);
}

// ---------------------------------------------------------------------------
// Pointer / wheel
// ---------------------------------------------------------------------------

/// A pointer move, in logical viewport points (origin top-left).
///
/// # Safety
///
/// `app` must be a live pointer from [`ushot_host_start`].
#[no_mangle]
pub unsafe extern "C" fn ushot_host_pointer_move(app: *mut UShotHostApp, x: f32, y: f32) {
    // SAFETY: `app` is a live pointer from `ushot_host_start` (this fn's contract).
    if let Some(app) = unsafe { app.as_mut() } {
        app.emit(&NativeEvent::PointerMove(Vec2::new(x, y)));
    }
}

/// A pointer button press (`button`: 0 left, 1 right, 2 middle).
///
/// # Safety
///
/// `app` must be a live pointer from [`ushot_host_start`].
#[no_mangle]
pub unsafe extern "C" fn ushot_host_pointer_down(
    app: *mut UShotHostApp,
    x: f32,
    y: f32,
    button: u32,
    click_count: u32,
) {
    // SAFETY: `app` is a live pointer from `ushot_host_start` (this fn's contract).
    if let Some(app) = unsafe { app.as_mut() } {
        app.emit(&NativeEvent::PointerDown {
            position: Vec2::new(x, y),
            button: pointer_button(button),
            click_count,
        });
    }
}

/// A pointer button release.
///
/// # Safety
///
/// `app` must be a live pointer from [`ushot_host_start`].
#[no_mangle]
pub unsafe extern "C" fn ushot_host_pointer_up(
    app: *mut UShotHostApp,
    x: f32,
    y: f32,
    button: u32,
) {
    // SAFETY: `app` is a live pointer from `ushot_host_start` (this fn's contract).
    if let Some(app) = unsafe { app.as_mut() } {
        app.emit(&NativeEvent::PointerUp {
            position: Vec2::new(x, y),
            button: pointer_button(button),
        });
    }
}

/// The pointer left the window.
///
/// # Safety
///
/// `app` must be a live pointer from [`ushot_host_start`].
#[no_mangle]
pub unsafe extern "C" fn ushot_host_pointer_leave(app: *mut UShotHostApp) {
    // SAFETY: `app` is a live pointer from `ushot_host_start` (this fn's contract).
    if let Some(app) = unsafe { app.as_mut() } {
        app.emit(&NativeEvent::PointerLeave);
    }
}

/// A scroll wheel / trackpad event. `dx` / `dy` are in logical pixels, `y > 0`
/// scrolls down.
///
/// # Safety
///
/// `app` must be a live pointer from [`ushot_host_start`].
#[no_mangle]
pub unsafe extern "C" fn ushot_host_scroll(
    app: *mut UShotHostApp,
    x: f32,
    y: f32,
    dx: f32,
    dy: f32,
) {
    // SAFETY: `app` is a live pointer from `ushot_host_start` (this fn's contract).
    if let Some(app) = unsafe { app.as_mut() } {
        app.emit(&NativeEvent::Wheel {
            position: Vec2::new(x, y),
            delta: Vec2::new(dx, dy),
        });
    }
}

// ---------------------------------------------------------------------------
// Keyboard / text / IME
// ---------------------------------------------------------------------------

/// A key press. `key_code` is an AppKit `keyCode`; `characters` is the text the
/// key produced with modifiers ignored (may be NULL). `modifiers`: 1 shift,
/// 2 ctrl, 4 alt, 8 command/meta.
///
/// # Safety
///
/// `app` must be a live pointer from [`ushot_host_start`]; `characters` a valid
/// C string or NULL.
#[no_mangle]
pub unsafe extern "C" fn ushot_host_key_down(
    app: *mut UShotHostApp,
    key_code: u32,
    characters: *const c_char,
    modifiers: u32,
) {
    // SAFETY: `app` is a live pointer from `ushot_host_start` (this fn's contract).
    let Some(app) = (unsafe { app.as_mut() }) else {
        return;
    };
    // Modifiers may change without a dedicated message.
    app.emit(&NativeEvent::Modifiers(modifiers_from_bits(modifiers)));
    // SAFETY: the C string argument is valid or NULL (this fn's contract).
    let characters = unsafe { opt_string(characters) };
    if let Some(key) = key_from_code(key_code, characters.as_deref()) {
        app.emit(&NativeEvent::KeyDown(key));
    }
}

/// A key release. Same `key_code` convention as [`ushot_host_key_down`].
///
/// # Safety
///
/// `app` must be a live pointer from [`ushot_host_start`]; `characters` a valid
/// C string or NULL.
#[no_mangle]
pub unsafe extern "C" fn ushot_host_key_up(
    app: *mut UShotHostApp,
    key_code: u32,
    characters: *const c_char,
) {
    // SAFETY: `app` is a live pointer from `ushot_host_start` (this fn's contract).
    let Some(app) = (unsafe { app.as_mut() }) else {
        return;
    };
    // SAFETY: the C string argument is valid or NULL (this fn's contract).
    let characters = unsafe { opt_string(characters) };
    if let Some(key) = key_from_code(key_code, characters.as_deref()) {
        app.emit(&NativeEvent::KeyUp(key));
    }
}

/// Committed text (AppKit `insertText:`).
///
/// # Safety
///
/// `app` must be a live pointer from [`ushot_host_start`]; `utf8` a valid C
/// string.
#[no_mangle]
pub unsafe extern "C" fn ushot_host_text(app: *mut UShotHostApp, utf8: *const c_char) {
    // SAFETY: `app` is a live pointer from `ushot_host_start` (this fn's contract).
    let Some(app) = (unsafe { app.as_mut() }) else {
        return;
    };
    // SAFETY: the C string argument is valid or NULL (this fn's contract).
    if let Some(text) = unsafe { opt_string(utf8) } {
        if !text.is_empty() {
            app.emit(&NativeEvent::Text(text));
        }
    }
}

/// A modifier-state change. Same bits as [`ushot_host_key_down`].
///
/// # Safety
///
/// `app` must be a live pointer from [`ushot_host_start`].
#[no_mangle]
pub unsafe extern "C" fn ushot_host_modifiers(app: *mut UShotHostApp, bits: u32) {
    // SAFETY: `app` is a live pointer from `ushot_host_start` (this fn's contract).
    if let Some(app) = unsafe { app.as_mut() } {
        app.emit(&NativeEvent::Modifiers(modifiers_from_bits(bits)));
    }
}

/// An input-method event. `kind`: 0 enabled, 1 disabled, 2 preedit, 3 commit.
/// For preedit, `sel_start` / `sel_end` are byte offsets, or `-1` for none.
///
/// # Safety
///
/// `app` must be a live pointer from [`ushot_host_start`]; `text` a valid C
/// string or NULL.
#[no_mangle]
pub unsafe extern "C" fn ushot_host_ime(
    app: *mut UShotHostApp,
    kind: u32,
    text: *const c_char,
    sel_start: i32,
    sel_end: i32,
) {
    // SAFETY: `app` is a live pointer from `ushot_host_start` (this fn's contract).
    let Some(app) = (unsafe { app.as_mut() }) else {
        return;
    };
    // SAFETY: the C string argument is valid or NULL (this fn's contract).
    let text = unsafe { opt_string(text) };
    let event = match kind {
        0 => ImeEvent::Enabled,
        1 => ImeEvent::Disabled,
        2 => ImeEvent::Preedit {
            text: text.unwrap_or_default(),
            cursor: (sel_start >= 0).then(|| (sel_start as usize, sel_end.max(sel_start) as usize)),
        },
        3 => ImeEvent::Commit(text.unwrap_or_default()),
        _ => return,
    };
    app.emit(&NativeEvent::Ime(event));
}
