//! Compose the confirmed selection into one RGBA8 image.
//!
//! The frozen frames are per display; a selection can span displays (or only
//! part of one). This module maps each display's intersection into an output
//! image sized in the selection's pixels, using the display's own scale, so a
//! Retina region comes out at full resolution.
//!
//! Pure and backend-neutral: `cargo test` covers it with hand-built frames.

use igui_core::Rect;

use crate::capture::DisplayImage;

/// The cropped result an editor shows and later exports.
#[derive(Clone, Debug)]
pub struct ComposedImage {
    pub width: u32,
    pub height: u32,
    /// Tightly packed RGBA8.
    pub rgba: Vec<u8>,
}

/// Crop `selection` (global logical points) out of `displays`.
///
/// Returns `None` when the selection is unusable or no display intersects it.
pub fn compose(displays: &[&DisplayImage], selection: Rect) -> Option<ComposedImage> {
    if !crate::ui::selection::usable(selection) {
        return None;
    }
    // The output scale follows the display under the selection's top-left, so
    // the common case is an exact 1:1 copy. A mixed-DPI span falls back to the
    // largest display scale and nearest-neighbour resampling.
    let anchor = selection.min();
    let scale = displays
        .iter()
        .find(|display| display.global_rect().contains(anchor))
        .map(|display| display.scale as f32)
        .or_else(|| {
            displays
                .iter()
                .map(|display| display.scale as f32)
                .reduce(f32::max)
        })
        .unwrap_or(1.0);

    let out_w = ((selection.size.width * scale).round() as i64).max(1) as u32;
    let out_h = ((selection.size.height * scale).round() as i64).max(1) as u32;
    let mut rgba = vec![0u8; out_w as usize * out_h as usize * 4];

    let mut any = false;
    for display in displays {
        let display_rect = display.global_rect();
        let Some(overlap) = selection.intersection(display_rect) else {
            continue;
        };
        if overlap.size.width <= 0.0 || overlap.size.height <= 0.0 {
            continue;
        }
        any = true;
        let source = (
            (overlap.min().x - display_rect.min().x) * display.scale as f32,
            (overlap.min().y - display_rect.min().y) * display.scale as f32,
            (overlap.max().x - display_rect.min().x) * display.scale as f32,
            (overlap.max().y - display_rect.min().y) * display.scale as f32,
        );
        let destination = (
            (overlap.min().x - selection.min().x) * scale,
            (overlap.min().y - selection.min().y) * scale,
            (overlap.max().x - selection.min().x) * scale,
            (overlap.max().y - selection.min().y) * scale,
        );
        let (source_w, source_h) = display.pixel_size();
        blit(
            &mut rgba,
            out_w,
            out_h,
            &display.rgba,
            source_w,
            source_h,
            destination,
            source,
        );
    }
    any.then_some(ComposedImage {
        width: out_w,
        height: out_h,
        rgba,
    })
}

/// Copy a source pixel rectangle into a destination pixel rectangle (nearest
/// neighbour). Both rectangles are `(x0, y0, x1, y1)` in pixels; the source is
/// clamped to the source image, the destination to the output.
#[allow(clippy::too_many_arguments)]
fn blit(
    dst: &mut [u8],
    dst_w: u32,
    dst_h: u32,
    src: &[u8],
    src_w: u32,
    src_h: u32,
    dst_rect: (f32, f32, f32, f32),
    src_rect: (f32, f32, f32, f32),
) {
    if src_w == 0 || src_h == 0 || src.is_empty() {
        return;
    }
    let dst_width = dst_rect.2 - dst_rect.0;
    let dst_height = dst_rect.3 - dst_rect.1;
    if dst_width <= 0.0 || dst_height <= 0.0 {
        return;
    }
    let x0 = dst_rect.0.floor().max(0.0) as i64;
    let y0 = dst_rect.1.floor().max(0.0) as i64;
    let x1 = (dst_rect.2.ceil() as i64).min(dst_w as i64);
    let y1 = (dst_rect.3.ceil() as i64).min(dst_h as i64);
    for y in y0..y1 {
        for x in x0..x1 {
            let u = (x as f32 + 0.5 - dst_rect.0) / dst_width;
            let v = (y as f32 + 0.5 - dst_rect.1) / dst_height;
            let sx = src_rect.0 + u * (src_rect.2 - src_rect.0);
            let sy = src_rect.1 + v * (src_rect.3 - src_rect.1);
            let sx = (sx as i64).clamp(0, src_w as i64 - 1) as usize;
            let sy = (sy as i64).clamp(0, src_h as i64 - 1) as usize;
            let source = (sy * src_w as usize + sx) * 4;
            let target = (y as usize * dst_w as usize + x as usize) * 4;
            if source + 4 <= src.len() && target + 4 <= dst.len() {
                dst[target..target + 4].copy_from_slice(&src[source..source + 4]);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use igui_core::{Size, Vec2};

    /// A solid-colour display frame.
    fn display(
        origin: (f32, f32),
        logical: (u32, u32),
        scale: f64,
        color: [u8; 4],
    ) -> DisplayImage {
        let pixel_w = (logical.0 as f64 * scale) as u32;
        let pixel_h = (logical.1 as f64 * scale) as u32;
        let mut rgba = Vec::with_capacity((pixel_w * pixel_h * 4) as usize);
        for _ in 0..pixel_w * pixel_h {
            rgba.extend_from_slice(&color);
        }
        DisplayImage {
            display_id: 1,
            origin_x: origin.0,
            origin_y: origin.1,
            logical_width: logical.0,
            logical_height: logical.1,
            scale,
            rgba,
        }
    }

    #[test]
    fn a_region_of_one_display_crops_at_native_scale() {
        let display = display((0.0, 0.0), (100, 50), 2.0, [10, 20, 30, 255]);
        let selection = Rect::from_min_size(Vec2::new(10.0, 10.0), Size::new(20.0, 10.0));
        let composed = compose(&[&display], selection).expect("a crop");
        assert_eq!((composed.width, composed.height), (40, 20));
        assert_eq!(composed.rgba.len(), 40 * 20 * 4);
        assert_eq!(&composed.rgba[..4], &[10, 20, 30, 255]);
    }

    #[test]
    fn a_selection_spanning_two_displays_pulls_from_both() {
        let left = display((0.0, 0.0), (100, 100), 1.0, [255, 0, 0, 255]);
        let right = display((100.0, 0.0), (100, 100), 1.0, [0, 0, 255, 255]);
        // 80..120 on x: 20 px of left (red) then 20 px of right (blue).
        let selection = Rect::from_min_size(Vec2::new(80.0, 0.0), Size::new(40.0, 10.0));
        let composed = compose(&[&left, &right], selection).expect("a crop");
        assert_eq!((composed.width, composed.height), (40, 10));
        let pixel = |x: u32| {
            let i = (x as usize) * 4;
            [composed.rgba[i], composed.rgba[i + 1], composed.rgba[i + 2]]
        };
        assert_eq!(pixel(0), [255, 0, 0], "the left half is the left display");
        assert_eq!(
            pixel(39),
            [0, 0, 255],
            "the right half is the right display"
        );
    }

    #[test]
    fn an_unusable_selection_composes_nothing() {
        let display = display((0.0, 0.0), (100, 100), 1.0, [0, 0, 0, 255]);
        let tiny = Rect::from_min_size(Vec2::new(0.0, 0.0), Size::new(1.0, 1.0));
        assert!(compose(&[&display], tiny).is_none());
    }

    #[test]
    fn a_mixed_dpi_selection_anchored_on_the_retina_display_outputs_at_2x() {
        // 2x display on the left, 1x on the right.
        let retina = display((0.0, 0.0), (200, 100), 2.0, [255, 0, 0, 255]);
        let plain = display((200.0, 0.0), (100, 100), 1.0, [0, 0, 255, 255]);
        // The selection's top-left (180) is on the 2x display, so the output is
        // at 2x: 40 logical points -> 80 px.
        let selection = Rect::from_min_size(Vec2::new(180.0, 0.0), Size::new(40.0, 10.0));
        let composed = compose(&[&retina, &plain], selection).expect("a crop");
        assert_eq!((composed.width, composed.height), (80, 20));
        let pixel = |x: u32| {
            let i = (x as usize) * 4;
            [composed.rgba[i], composed.rgba[i + 1], composed.rgba[i + 2]]
        };
        // 180..200 on the 2x display -> 40 px of red.
        assert_eq!(pixel(0), [255, 0, 0]);
        assert_eq!(pixel(39), [255, 0, 0]);
        // 200..220 on the 1x display -> 40 px (upscaled 2x) of blue.
        assert_eq!(pixel(40), [0, 0, 255]);
        assert_eq!(pixel(79), [0, 0, 255]);
    }

    #[test]
    fn a_mixed_dpi_selection_anchored_on_the_plain_display_outputs_at_1x() {
        // 1x display on the left, 2x on the right.
        let plain = display((0.0, 0.0), (200, 100), 1.0, [0, 0, 255, 255]);
        let retina = display((200.0, 0.0), (100, 100), 2.0, [255, 0, 0, 255]);
        // The selection's top-left (180) is on the 1x display, so the output is
        // at 1x: the 2x half is downsampled into the same 40 px.
        let selection = Rect::from_min_size(Vec2::new(180.0, 0.0), Size::new(40.0, 10.0));
        let composed = compose(&[&plain, &retina], selection).expect("a crop");
        assert_eq!((composed.width, composed.height), (40, 10));
        let pixel = |x: u32| {
            let i = (x as usize) * 4;
            [composed.rgba[i], composed.rgba[i + 1], composed.rgba[i + 2]]
        };
        assert_eq!(pixel(0), [0, 0, 255]);
        assert_eq!(pixel(19), [0, 0, 255]);
        assert_eq!(pixel(20), [255, 0, 0]);
        assert_eq!(pixel(39), [255, 0, 0]);
    }
}
