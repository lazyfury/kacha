//! The embedded native host, shared by the Swift shell.
//!
//! The shell owns the window and its `CAMetalLayer`, hands Rust an opaque
//! handle, asks for frames and forwards native events. Everything else — the
//! igui UI, the wgpu renderer and the C ABI the shell talks to — is here.
//!
//! ```text
//! macOS: AppKit + CAMetalLayer + NSEvent ── ushot_host_* ─▶ ushot-app (UI + images)
//! ```
//!
//! The only platform-specific piece is [`surface::create_surface`] (the wgpu
//! surface target). This mirrors classic-game-box's `src/native/`.

use std::cell::RefCell;
use std::rc::Rc;

use igui::igui_backend_wgpu::WgpuBackend;

pub mod input;

mod ffi;
mod gpu;
mod plugins;
mod surface;

/// The wgpu backend a graphics plugin publishes as a service.
pub type SharedBackend = Rc<RefCell<WgpuBackend>>;

pub use ffi::*;
pub use gpu::{NativeGpu, NativeGpuPlugin};
pub use input::{NativeEvent, NativeInputPlugin};
pub use plugins::{NativeTextMeasurePlugin, NativeTextMeasurer};
pub use surface::NativeSurface;
