//! The igui views, driven by the `igui_app` runtime.
//!
//! - [`overlay`] — the freeze-frame region overlay (one window per display).
//! - [`selection`] — the region-selection geometry and drag state (pure).
//! - [`editor`] — the annotation editor for the composed selection.
//! - [`canvas`] — the editor's image/annotation canvas and pixel mapping.
//! - [`image`] — the `ImageFill` leaf the overlay draws a texture with.

pub mod canvas;
pub mod editor;
pub mod image;
pub mod overlay;
pub mod selection;

pub use editor::EditorApp;
pub use overlay::OverlayApp;
