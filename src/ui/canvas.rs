//! The editor canvas: draws the composed image and the annotations over it, and
//! maps between image pixels and screen points.
//!
//! The mapping is pure and unit-tested; the [`Canvas`] component only reads the
//! shared [`EditorState`] at paint time and records the image's on-screen rect
//! back into it, so `EditorApp::event` can turn pointer positions into image
//! coordinates.
//!
//! The mosaic tool samples the **composed pixels** (shared as an `Rc`), so the
//! pixelation on screen is exactly what `render_export` bakes.

use std::cell::RefCell;
use std::rc::Rc;

use igui::igui_components::{Component, Spec};
use igui::igui_core::{Color, Rect, Size, Vec2};
use igui::igui_render::{Paint, PaintContext, TextAlign, TextureId};
use igui::igui_ui::{MouseFilter, TextMeasurer};

use crate::annotate::{Annotation, Tool};
use crate::compose::ComposedImage;

/// Side of one mosaic block, as a multiple of the stroke width, so the
/// pixelation scales with the image like the other marks do.
const MOSAIC_BLOCK_PER_STROKE: f32 = 6.0;
/// Smallest mosaic block, in image pixels.
const MOSAIC_BLOCK_MIN: f32 = 4.0;

/// Fallback ascent for a font size, matching `TextMeasurer`'s default (0.8 em).
///
/// `PaintContext::draw_text` positions by **baseline**, so a text annotation's
/// click point is its line-box top and the baseline sits `ascent` below it.
fn text_ascent(font_size: f32) -> f32 {
    font_size * 0.8
}

/// Default annotation stroke for an image, in image pixels.
///
/// Scales with the image diagonal so a mark reads about the same on a small
/// crop and a 4K region (a 1600×1000 capture lands at ~3.8 px).
pub fn default_stroke(image: (u32, u32)) -> f32 {
    (image_diagonal(image) / 500.0).clamp(3.0, 10.0)
}

/// Default text size for an image, in image pixels (a 1600×1000 capture lands
/// at ~38 px).
pub fn default_text_size(image: (u32, u32)) -> f32 {
    (image_diagonal(image) / 50.0).clamp(14.0, 96.0)
}

fn image_diagonal(image: (u32, u32)) -> f32 {
    let (w, h) = (image.0 as f32, image.1 as f32);
    (w * w + h * h).sqrt()
}

/// The editor's shared state. External to the tree (per the workspace rule), so
/// callbacks and the canvas decorator can read/write it.
pub struct EditorState {
    pub tool: Tool,
    /// RGBA in 0..=1.
    pub color: [f32; 4],
    /// Stroke width in **image** pixels, for the shape tools.
    pub stroke: f32,
    /// Font size in **image** pixels, for the text tool.
    pub text_size: f32,
    pub annotations: Vec<Annotation>,
    pub redo: Vec<Annotation>,
    /// The in-progress shape.
    pub draft: Option<Annotation>,
    /// The text being typed (the text tool).
    pub editing_text: Option<TextDraft>,
    /// The composed image's texture handle.
    pub texture: TextureId,
    /// The composed image's pixel size.
    pub image: (u32, u32),
    /// The composed pixels, shared with the session (mosaic sampling).
    pub composed: Option<Rc<ComposedImage>>,
    /// The image's on-screen rect, recorded by the last paint.
    pub image_rect: Option<Rect>,
}

/// Text the user is placing on the canvas.
#[derive(Clone)]
pub struct TextDraft {
    /// Top-left, in image pixels.
    pub position: Vec2,
    /// Committed text typed so far.
    pub text: String,
    /// IME preedit (marked text) not yet committed; drawn after `text`.
    pub preedit: String,
    /// Font size in image pixels.
    pub size: f32,
    pub color: [f32; 4],
}

impl EditorState {
    /// A fresh state for a `width`x`height` image on `texture`.
    pub fn new(texture: TextureId, width: u32, height: u32) -> Self {
        Self {
            tool: Tool::Rectangle,
            color: [1.0, 0.2, 0.2, 1.0],
            stroke: 2.0,
            text_size: 18.0,
            annotations: Vec::new(),
            redo: Vec::new(),
            draft: None,
            editing_text: None,
            texture,
            image: (width, height),
            composed: None,
            image_rect: None,
        }
    }

    /// Undo the last annotation.
    pub fn undo(&mut self) {
        if let Some(annotation) = self.annotations.pop() {
            self.redo.push(annotation);
        }
    }

    /// Redo the last undone annotation.
    pub fn redo(&mut self) {
        if let Some(annotation) = self.redo.pop() {
            self.annotations.push(annotation);
        }
    }

    /// Commit the text being typed, if any.
    pub fn commit_text(&mut self) {
        if let Some(draft) = self.editing_text.take() {
            if !draft.text.is_empty() {
                self.annotations.push(Annotation {
                    tool: Tool::Text,
                    points: vec![(draft.position.x, draft.position.y)],
                    color: draft.color,
                    stroke: draft.size,
                    text: draft.text,
                });
                self.redo.clear();
            }
        }
    }
}

/// The largest rectangle of `image`'s aspect ratio that fits centred in `area`.
pub fn contain_fit(image: (u32, u32), area: Rect) -> Option<Rect> {
    if image.0 == 0 || image.1 == 0 || area.size.width <= 0.0 || area.size.height <= 0.0 {
        return None;
    }
    let scale = (area.size.width / image.0 as f32).min(area.size.height / image.1 as f32);
    let size = Size::new(image.0 as f32 * scale, image.1 as f32 * scale);
    let origin = Vec2::new(
        area.left() + (area.size.width - size.width) * 0.5,
        area.top() + (area.size.height - size.height) * 0.5,
    );
    Some(Rect::from_min_size(origin, size))
}

/// Screen point → image pixel.
pub fn to_image(rect: Rect, image: (u32, u32), p: Vec2) -> Vec2 {
    Vec2::new(
        (p.x - rect.left()) / rect.size.width * image.0 as f32,
        (p.y - rect.top()) / rect.size.height * image.1 as f32,
    )
}

/// Image pixel → screen point.
pub fn to_screen(rect: Rect, image: (u32, u32), p: Vec2) -> Vec2 {
    Vec2::new(
        rect.left() + p.x / image.0 as f32 * rect.size.width,
        rect.top() + p.y / image.1 as f32 * rect.size.height,
    )
}

/// Clamp an image-space point to the image bounds.
pub fn clamp_to_image(p: Vec2, image: (u32, u32)) -> Vec2 {
    Vec2::new(
        p.x.clamp(0.0, image.0 as f32),
        p.y.clamp(0.0, image.1 as f32),
    )
}

/// The screen rectangle an annotation's image-space points map to.
fn annotation_rect(annotation: &Annotation, image_rect: Rect, image: (u32, u32)) -> Option<Rect> {
    let (a, b) = (annotation.points.first()?, annotation.points.get(1)?);
    let a = to_screen(image_rect, image, Vec2::new(a.0, a.1));
    let b = to_screen(image_rect, image, Vec2::new(b.0, b.1));
    Some(Rect::from_min_max(
        Vec2::new(a.x.min(b.x), a.y.min(b.y)),
        Vec2::new(a.x.max(b.x), a.y.max(b.y)),
    ))
}

/// A leaf that paints the composed image and the annotations over its rect.
pub struct Canvas {
    spec: Spec,
    state: Rc<RefCell<EditorState>>,
    /// Real font metrics, so the text caret matches the shaped glyph run.
    measurer: Option<Rc<dyn TextMeasurer>>,
}

impl Canvas {
    /// The canvas reading `state`.
    pub fn new(state: Rc<RefCell<EditorState>>, measurer: Option<Rc<dyn TextMeasurer>>) -> Self {
        Self {
            spec: Spec::default(),
            state,
            measurer,
        }
    }
}

impl Component for Canvas {
    fn spec(&mut self) -> &mut Spec {
        &mut self.spec
    }

    fn name(&self) -> &'static str {
        "Canvas"
    }

    fn prepare(&mut self) {
        let shared = self.state.clone();
        let measurer = self.measurer.clone();
        self.spec.data.mouse_filter = MouseFilter::Ignore;
        self.spec.foreground = Some(Box::new(move |ctx, rect, _state| {
            let (image, texture, annotations, editing, composed) = {
                let mut state = shared.borrow_mut();
                let Some(image_rect) = contain_fit(state.image, rect) else {
                    state.image_rect = None;
                    return;
                };
                state.image_rect = Some(image_rect);
                let annotations: Vec<Annotation> = state
                    .annotations
                    .iter()
                    .chain(state.draft.iter())
                    .cloned()
                    .collect();
                let editing = state.editing_text.clone();
                (
                    state.image,
                    state.texture,
                    annotations,
                    editing,
                    state.composed.clone(),
                )
            };
            let Some(image_rect) = contain_fit(image, rect) else {
                return;
            };
            if texture.is_valid() {
                ctx.draw_image(texture, image_rect, None, Paint::default());
            }
            let mosaic = composed.as_ref().map(|composed| composed.rgba.as_slice());
            for annotation in &annotations {
                draw_annotation(ctx, annotation, image_rect, image, mosaic);
            }
            if let Some(draft) = &editing {
                draw_text_draft(ctx, draft, image_rect, image, measurer.as_deref());
            }
        }));
    }
}

/// Draw one annotation, mapping its image-space points to `image_rect`.
///
/// `mosaic` is the composed RGBA (needed by [`Tool::Mosaic`]).
pub fn draw_annotation(
    ctx: &mut PaintContext,
    annotation: &Annotation,
    image_rect: Rect,
    image: (u32, u32),
    mosaic: Option<&[u8]>,
) {
    let color = Color::new(
        annotation.color[0],
        annotation.color[1],
        annotation.color[2],
        annotation.color[3],
    );
    let scale = image_rect.size.width / image.0.max(1) as f32;
    let width = (annotation.stroke * scale).max(1.0);
    let points: Vec<Vec2> = annotation
        .points
        .iter()
        .map(|(x, y)| to_screen(image_rect, image, Vec2::new(*x, *y)))
        .collect();

    match annotation.tool {
        Tool::Rectangle | Tool::Ellipse => {
            if let (Some(a), Some(b)) = (points.first(), points.get(1)) {
                let min = Vec2::new(a.x.min(b.x), a.y.min(b.y));
                let max = Vec2::new(a.x.max(b.x), a.y.max(b.y));
                ctx.stroke_rect(Rect::from_min_max(min, max), width, color);
            }
        }
        Tool::Arrow => {
            if let (Some(&a), Some(&b)) = (points.first(), points.get(1)) {
                ctx.draw_line(a, b, width, color);
                let direction = b - a;
                let length = (direction.x * direction.x + direction.y * direction.y).sqrt();
                if length > 1.0 {
                    let unit = Vec2::new(direction.x / length, direction.y / length);
                    let head = 12.0f32.max(width * 4.0);
                    for angle in [150.0f32.to_radians(), -150.0f32.to_radians()] {
                        let (sin, cos) = angle.sin_cos();
                        let barb =
                            Vec2::new(unit.x * cos - unit.y * sin, unit.x * sin + unit.y * cos);
                        ctx.draw_line(
                            b,
                            Vec2::new(b.x + barb.x * head, b.y + barb.y * head),
                            width,
                            color,
                        );
                    }
                }
            }
        }
        Tool::Pen | Tool::Highlighter => {
            for pair in points.windows(2) {
                ctx.draw_line(pair[0], pair[1], width, color);
            }
        }
        Tool::Text => {
            if let Some(&position) = points.first() {
                let size = (annotation.stroke * scale).max(8.0);
                ctx.draw_text(
                    annotation.text.clone(),
                    Vec2::new(position.x, position.y + text_ascent(size)),
                    size,
                    TextAlign::Left,
                    color,
                );
            }
        }
        Tool::Mosaic => draw_mosaic(
            ctx,
            annotation,
            image_rect,
            image,
            mosaic.unwrap_or_default(),
        ),
        _ => {}
    }
}

/// Pixelate an image-space rectangle, sampling the composed pixels.
fn draw_mosaic(
    ctx: &mut PaintContext,
    annotation: &Annotation,
    image_rect: Rect,
    image: (u32, u32),
    source: &[u8],
) {
    let (width, height) = image;
    if width == 0 || height == 0 || source.len() < (width as usize * height as usize * 4) {
        return;
    }
    let Some(rect) = annotation_rect(annotation, image_rect, image) else {
        return;
    };
    let (min_x, min_y, max_x, max_y) = (
        rect.left().max(image_rect.left()),
        rect.top().max(image_rect.top()),
        rect.right().min(image_rect.right()),
        rect.bottom().min(image_rect.bottom()),
    );
    if max_x <= min_x || max_y <= min_y {
        return;
    }
    // Walk the image-space rectangle in blocks; each block becomes one flat
    // colour on screen. The block side follows the stroke so the pixelation
    // stays in proportion to the other marks.
    let block_size = (annotation.stroke * MOSAIC_BLOCK_PER_STROKE).max(MOSAIC_BLOCK_MIN);
    let start = to_image(image_rect, image, Vec2::new(min_x, min_y));
    let end = to_image(image_rect, image, Vec2::new(max_x, max_y));
    let mut y = start.y.max(0.0);
    while y < end.y.min(height as f32) {
        let mut x = start.x.max(0.0);
        while x < end.x.min(width as f32) {
            let block = Rect::from_min_max(
                Vec2::new(x, y),
                Vec2::new(
                    (x + block_size).min(width as f32),
                    (y + block_size).min(height as f32),
                ),
            );
            if let Some(color) = average(source, width, height, block) {
                let dest = Rect::from_min_max(
                    to_screen(image_rect, image, block.min()),
                    to_screen(image_rect, image, block.max()),
                );
                if dest.size.width > 0.0 && dest.size.height > 0.0 {
                    ctx.fill_rect(dest, color);
                }
            }
            x += block_size;
        }
        y += block_size;
    }
}

/// The average colour of a pixel rectangle in an RGBA8 image.
fn average(source: &[u8], width: u32, height: u32, rect: Rect) -> Option<Color> {
    let x0 = rect.left().floor().max(0.0) as u32;
    let y0 = rect.top().floor().max(0.0) as u32;
    let x1 = (rect.right().ceil() as u32).min(width);
    let y1 = (rect.bottom().ceil() as u32).min(height);
    if x1 <= x0 || y1 <= y0 {
        return None;
    }
    let (mut r, mut g, mut b, mut n) = (0u64, 0u64, 0u64, 0u64);
    for y in y0..y1 {
        for x in x0..x1 {
            let index = ((y * width + x) * 4) as usize;
            if index + 4 <= source.len() {
                r += source[index] as u64;
                g += source[index + 1] as u64;
                b += source[index + 2] as u64;
                n += 1;
            }
        }
    }
    if n == 0 {
        return None;
    }
    Some(Color::new(
        r as f32 / n as f32 / 255.0,
        g as f32 / n as f32 / 255.0,
        b as f32 / n as f32 / 255.0,
        1.0,
    ))
}

/// Draw the text being typed, the IME preedit and a caret.
fn draw_text_draft(
    ctx: &mut PaintContext,
    draft: &TextDraft,
    image_rect: Rect,
    image: (u32, u32),
    measurer: Option<&dyn TextMeasurer>,
) {
    let size = (draft.size * image_rect.size.width / image.0.max(1) as f32).max(8.0);
    let origin = to_screen(image_rect, image, draft.position);
    let baseline = origin.y + text_ascent(size);
    let color = Color::new(
        draft.color[0],
        draft.color[1],
        draft.color[2],
        draft.color[3],
    );

    // Real metrics keep the caret aligned with the shaped glyphs (a 0.55 em
    // estimate is too narrow for CJK).
    let measure = |text: &str| match measurer {
        Some(measurer) => measurer.measure_run(text, size),
        None => text.chars().count() as f32 * size * 0.55,
    };
    let line_height = match measurer {
        Some(measurer) => measurer.line_height(size),
        None => size * 1.3,
    };

    if !draft.text.is_empty() {
        ctx.draw_text(
            draft.text.clone(),
            Vec2::new(origin.x, baseline),
            size,
            TextAlign::Left,
            color,
        );
    }
    let mut caret_x = origin.x + measure(&draft.text);

    // The composing (marked) text, underlined like the system input method.
    if !draft.preedit.is_empty() {
        let preedit_width = measure(&draft.preedit);
        ctx.draw_text(
            draft.preedit.clone(),
            Vec2::new(caret_x, baseline),
            size,
            TextAlign::Left,
            color,
        );
        ctx.fill_rect(
            Rect::from_min_size(
                Vec2::new(caret_x, origin.y + line_height - 1.0),
                Size::new(preedit_width, 1.0),
            ),
            color,
        );
        caret_x += preedit_width;
    }

    ctx.fill_rect(
        Rect::from_min_size(Vec2::new(caret_x, origin.y), Size::new(1.0, line_height)),
        color,
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use igui::igui_core::Size;

    #[test]
    fn contain_fit_letterboxes_a_wide_image() {
        let area = Rect::from_min_size(Vec2::ZERO, Size::new(100.0, 100.0));
        let fitted = contain_fit((200, 100), area).expect("a fit");
        assert_eq!(fitted.size, Size::new(100.0, 50.0));
        assert_eq!(fitted.origin, Vec2::new(0.0, 25.0));
    }

    #[test]
    fn image_and_screen_points_round_trip() {
        let rect = Rect::from_min_size(Vec2::new(10.0, 20.0), Size::new(400.0, 200.0));
        let image = (800u32, 400u32);
        let pixel = Vec2::new(200.0, 100.0);
        let screen = to_screen(rect, image, pixel);
        assert_eq!(screen, Vec2::new(110.0, 70.0));
        let back = to_image(rect, image, screen);
        assert!((back.x - pixel.x).abs() < 1e-3 && (back.y - pixel.y).abs() < 1e-3);
    }

    #[test]
    fn clamping_keeps_points_inside_the_image() {
        assert_eq!(
            clamp_to_image(Vec2::new(-5.0, 999.0), (100, 50)),
            Vec2::new(0.0, 50.0)
        );
    }

    #[test]
    fn the_average_of_a_solid_block_is_that_colour() {
        let source = [
            10u8, 20, 30, 255, 10, 20, 30, 255, 10, 20, 30, 255, 10, 20, 30, 255,
        ];
        let color = average(
            &source,
            2,
            2,
            Rect::from_min_size(Vec2::ZERO, Size::new(2.0, 2.0)),
        )
        .expect("an average");
        assert!((color.r - 10.0 / 255.0).abs() < 1e-4);
        assert!((color.g - 20.0 / 255.0).abs() < 1e-4);
        assert!((color.b - 30.0 / 255.0).abs() < 1e-4);
    }

    #[test]
    fn a_text_annotation_puts_the_baseline_below_the_click_point() {
        use igui::igui_backend_recording::RecordingBackend;
        use igui::igui_render::{DrawCommand, RenderBackend};

        let image = (100u32, 100u32);
        let image_rect = Rect::from_min_size(Vec2::ZERO, Size::new(100.0, 100.0));
        let annotation = Annotation {
            tool: Tool::Text,
            points: vec![(10.0, 20.0)],
            color: [1.0; 4],
            stroke: 18.0,
            text: "hi".into(),
        };
        let mut ctx = PaintContext::new();
        draw_annotation(&mut ctx, &annotation, image_rect, image, None);

        let mut backend = RecordingBackend::new();
        let viewport = igui::igui_core::ViewportSize::new(Size::new(100.0, 100.0));
        backend.begin_frame(viewport).expect("begin frame");
        backend.submit(&ctx.into_draw_list()).expect("submit");
        backend.end_frame().expect("end frame");
        let frame = backend.last_frame().expect("a frame was recorded");
        let baseline = frame
            .commands()
            .iter()
            .find_map(|command| match command {
                DrawCommand::DrawText { position, .. } => Some(position.y),
                _ => None,
            })
            .expect("the text is drawn");
        // Click at y = 20, line-box top = 20, baseline = 20 + 0.8 * 18.
        assert!((baseline - 34.4).abs() < 0.01, "baseline {baseline}");
    }

    #[test]
    fn default_mark_sizes_scale_with_the_image() {
        // Monotonic in the image size, so a 4K region gets thicker marks.
        assert!(default_stroke((3840, 2160)) > default_stroke((1600, 1000)));
        assert!(default_text_size((3840, 2160)) > default_text_size((1600, 1000)));
        // A normal capture lands in a usable range, a tiny crop is clamped up
        // so the mark is still visible.
        assert!(default_stroke((1600, 1000)) > 2.0);
        assert!(default_text_size((1600, 1000)) > 18.0);
        assert!(default_stroke((100, 100)) >= 3.0);
        assert!(default_text_size((100, 100)) >= 14.0);
    }

    #[test]
    fn the_ime_preedit_is_drawn_after_the_committed_text() {
        use igui::igui_backend_recording::RecordingBackend;
        use igui::igui_render::{DrawCommand, RenderBackend};

        let image = (100u32, 100u32);
        let image_rect = Rect::from_min_size(Vec2::ZERO, Size::new(100.0, 100.0));
        let draft = TextDraft {
            position: Vec2::new(10.0, 20.0),
            text: "ab".into(),
            preedit: "你".into(),
            size: 18.0,
            color: [1.0; 4],
        };
        let mut ctx = PaintContext::new();
        draw_text_draft(&mut ctx, &draft, image_rect, image, None);

        let mut backend = RecordingBackend::new();
        let viewport = igui::igui_core::ViewportSize::new(Size::new(100.0, 100.0));
        backend.begin_frame(viewport).expect("begin frame");
        backend.submit(&ctx.into_draw_list()).expect("submit");
        backend.end_frame().expect("end frame");
        let frame = backend.last_frame().expect("a frame was recorded");
        let texts: Vec<(&str, f32)> = frame
            .commands()
            .iter()
            .filter_map(|command| match command {
                DrawCommand::DrawText { text, position, .. } => Some((text.as_str(), position.x)),
                _ => None,
            })
            .collect();
        assert_eq!(texts.len(), 2, "committed text + preedit");
        assert_eq!(texts[0].0, "ab");
        assert_eq!(texts[1].0, "你");
        assert!(
            texts[1].1 > texts[0].1,
            "the preedit follows the committed run"
        );
    }
}
