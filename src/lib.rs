//! ushot — the app library embedded by the native (Swift/macOS) host.
//!
//! The product is a Swift/macOS screenshot tool (`macos/`); this crate owns the
//! igui UI, the wgpu renderer and all image work, and is linked into the shell
//! as a static library through the [`native`] `ushot_host_*` C ABI.
//!
//! ```text
//! AppKit / ScreenCaptureKit (Swift) ── ushot_host_* ──▶ ushot-app (UI + images)
//! ```
//!
//! Modules:
//! - [`session`] — the in-process capture session shared by the shell's windows.
//! - [`capture`] — captured frames and their conversion into GPU textures.
//! - [`annotate`] — the annotation model (tools, shapes, colours).
//! - [`export`] — PNG encoding for the clipboard / save path.
//! - [`ui`] — the igui views (overlay, editor).
//! - [`native`] — the embedded host: surface, GPU plugin, input and the FFI.

/// Crate name, kept for lightweight smoke checks.
pub const CRATE: &str = "ushot_app";

pub mod annotate;
pub mod capture;
pub mod compose;
pub mod export;
pub mod native;
pub mod session;
pub mod ui;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crate_identity() {
        assert_eq!(CRATE, "ushot_app");
    }
}
