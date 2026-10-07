//! Export: the composited capture → PNG bytes (clipboard / save).
//!
//! Rust owns the composition, so the shell only has to hand the PNG to
//! `NSPasteboard` or write it to disk. Keeping the codec here means the format
//! never leaks into the UI.

pub mod png;
