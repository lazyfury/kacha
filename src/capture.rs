//! Frozen display frames and their conversion into GPU textures.
//!
//! Swift captures each display with ScreenCaptureKit and hands Rust a tightly
//! packed RGBA8 buffer plus the frame's geometry (see `ushot_host.h`). This
//! module owns the value type and the small amount of arithmetic that must be
//! right: the buffer length, and the display-local → global coordinate mapping.
//!
//! The actual `register_texture` call happens where the wgpu backend is in
//! scope (the app's `init`), so this module stays backend-neutral and testable.

/// One display's frozen frame.
#[derive(Clone, Debug)]
pub struct DisplayImage {
    /// The display's id (the shell's own index; stable for one capture).
    pub display_id: u32,
    /// The display's top-left corner in **global logical points**, origin
    /// top-left (CoreGraphics global coordinates).
    pub origin_x: f32,
    pub origin_y: f32,
    /// The display's size in logical points.
    pub logical_width: u32,
    pub logical_height: u32,
    /// The backing scale the pixels were captured at (2.0 on Retina).
    pub scale: f64,
    /// Tightly packed RGBA8, row-major, straight alpha.
    pub rgba: Vec<u8>,
}

impl DisplayImage {
    /// The pixel width/height of the captured buffer.
    pub fn pixel_size(&self) -> (u32, u32) {
        (
            (self.logical_width as f64 * self.scale).round().max(1.0) as u32,
            (self.logical_height as f64 * self.scale).round().max(1.0) as u32,
        )
    }

    /// The exact number of bytes `rgba` must hold.
    pub fn expected_len(&self) -> usize {
        let (w, h) = self.pixel_size();
        w as usize * h as usize * 4
    }

    /// Whether the buffer matches the declared geometry.
    pub fn is_consistent(&self) -> bool {
        self.rgba.len() == self.expected_len()
    }

    /// This display's rectangle in global logical points.
    pub fn global_rect(&self) -> igui_core::Rect {
        igui_core::Rect::from_min_size(
            igui_core::Vec2::new(self.origin_x, self.origin_y),
            igui_core::Size::new(self.logical_width as f32, self.logical_height as f32),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn image(scale: f64) -> DisplayImage {
        DisplayImage {
            display_id: 1,
            origin_x: 0.0,
            origin_y: 0.0,
            logical_width: 100,
            logical_height: 50,
            scale,
            rgba: Vec::new(),
        }
    }

    #[test]
    fn pixel_size_follows_the_scale() {
        assert_eq!(image(1.0).pixel_size(), (100, 50));
        assert_eq!(image(2.0).pixel_size(), (200, 100));
    }

    #[test]
    fn the_buffer_must_match_the_geometry() {
        let mut display = image(2.0);
        assert!(!display.is_consistent());
        display.rgba = vec![0; 200 * 100 * 4];
        assert!(display.is_consistent());
    }
}
