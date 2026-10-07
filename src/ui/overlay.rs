//! The freeze-frame region overlay: one window per display.
//!
//! Each window draws its captured display 1:1 and a live selection on top:
//! a dim mask outside the region, the border and eight handles, a crosshair and
//! a size readout. The selection itself lives in the shared [`Session`] in
//! **global logical points**, so a drag that crosses displays shows up on every
//! panel and the confirmed result is a single desktop-wide rectangle.
//!
//! P2 confirms the selection (Enter, handled by the shell) and parks it in the
//! session; the editor that consumes it arrives in P3.

use std::rc::Rc;

use igui::igui_app::{AppLogic, EventContext, EventResult, FrameContext, InitContext};
use igui::igui_backend_wgpu::TextureFilter;
use igui::igui_components::{Component, Flex};
use igui::igui_core::{Color, Cursor, InputEvent, Key, Modifiers, PointerButton, Rect, Size, Vec2};
use igui::igui_render::{PaintContext, TextAlign, TextureId};
use igui::igui_scene::{SceneChild, SceneTree};
use igui::igui_ui::{self, TextMeasurer};

use crate::native::SharedBackend;
use crate::session;

use super::image::ImageFill;
use super::selection::{self, Drag};

/// The texture slot this window uploads its frozen frame to. Each window has
/// its own backend, so the id only has to be unique within one window.
const FROZEN_TEXTURE: TextureId = TextureId::new(1);

/// The wash drawn over everything outside the selection.
const DIM: Color = Color::new(0.0, 0.0, 0.0, 0.45);
/// The selection border and handles.
const ACCENT: Color = Color::new(0.16, 0.55, 1.0, 1.0);
/// The pointer crosshair.
const CROSSHAIR: Color = Color::new(1.0, 1.0, 1.0, 0.55);
const LABEL_BG: Color = Color::new(0.0, 0.0, 0.0, 0.78);
const LABEL_FG: Color = Color::new(1.0, 1.0, 1.0, 1.0);

/// The overlay view for one display.
pub struct OverlayApp {
    session_id: u64,
    display_id: u32,
    backend: Option<SharedBackend>,
    /// The backend's metrics, so the size readout lays out against the same
    /// font it draws with.
    measurer: Option<Rc<dyn TextMeasurer>>,
    texture: Option<TextureId>,
    tree: Option<SceneTree>,
    /// This display's top-left in global logical points.
    origin: Vec2,
    /// The in-progress pointer drag (global coordinates).
    drag: Drag,
    /// The pointer in this window's local logical points.
    pointer: Option<Vec2>,
    modifiers: Modifiers,
}

impl OverlayApp {
    /// The overlay for `display_id` in `session_id`.
    pub fn new(session_id: u64, display_id: u32) -> Self {
        Self {
            session_id,
            display_id,
            backend: None,
            measurer: None,
            texture: None,
            tree: None,
            origin: Vec2::ZERO,
            drag: Drag::None,
            pointer: None,
            modifiers: Modifiers::NONE,
        }
    }

    /// Read this display's origin out of the session.
    fn sync_display(&mut self) {
        if let Some(session) = session::get(self.session_id) {
            if let Some(entry) = session.borrow().display(self.display_id) {
                self.origin = Vec2::new(entry.image.origin_x, entry.image.origin_y);
            }
        }
    }

    /// Upload this display's frozen frame into the window's backend, once.
    ///
    /// The CPU copy is **kept** for the life of the session, not dropped after
    /// the upload: [`crate::session::Session::confirm`] composes the selection
    /// from the owner's pixels (`compose::compose`), and the window that
    /// uploaded a frame is not necessarily the one that confirms. A 4K frame is
    /// ~33 MB, so a multi-display session holds that much per display until it
    /// is dropped (see the session's lifecycle).
    fn ensure_texture(&mut self) {
        if self.texture.is_some() {
            return;
        }
        let Some(backend) = self.backend.clone() else {
            return;
        };
        let Some(session) = session::get(self.session_id) else {
            return;
        };
        let mut session = session.borrow_mut();
        let Some(entry) = session.display_mut(self.display_id) else {
            return;
        };
        if let Some(texture) = entry.texture {
            self.texture = Some(texture);
            return;
        }
        if !entry.image.is_consistent() {
            eprintln!(
                "ushot-host: display {} frame size mismatch ({} bytes)",
                self.display_id,
                entry.image.rgba.len()
            );
            return;
        }
        let (width, height) = entry.image.pixel_size();
        let uploaded = {
            let rgba = &entry.image.rgba;
            backend.borrow_mut().register_texture_with_filter(
                FROZEN_TEXTURE,
                width,
                height,
                rgba,
                TextureFilter::Nearest,
            )
        };
        match uploaded {
            Ok(()) => {
                entry.texture = Some(FROZEN_TEXTURE);
                self.texture = Some(FROZEN_TEXTURE);
            }
            Err(error) => eprintln!("ushot-host: 上传冻帧失败：{error}"),
        }
    }

    /// The overlay tree: the frozen frame filling the window.
    ///
    /// The mounted component is the flex itself — wrapping it in an extra
    /// container and putting `grow` on the intermediate collapses it (the
    /// layout root's single child must be the flex).
    fn build_tree(texture: TextureId) -> SceneTree {
        Flex::column()
            .grow(1.0)
            .child(ImageFill::new(texture).grow(1.0))
            .into_tree()
    }

    /// Build the tree and install the backend's metrics on it.
    fn make_tree(&self, texture: TextureId) -> SceneTree {
        let mut tree = Self::build_tree(texture);
        if let Some(measurer) = &self.measurer {
            igui_ui::set_text_measurer(&mut tree, measurer.clone());
        }
        tree
    }

    /// The selection, as stored (global logical points).
    fn session_selection(&self) -> Option<Rect> {
        session::get(self.session_id).and_then(|session| session.borrow().selection)
    }

    /// Whether the session is in window-pick mode.
    fn pick_mode(&self) -> bool {
        session::get(self.session_id).is_some_and(|session| session.borrow().pick_window)
    }

    /// The window under the cursor, as pushed by the shell.
    fn hovered_window(&self) -> Option<Rect> {
        session::get(self.session_id).and_then(|session| session.borrow().hover)
    }

    /// Mark the hovered window picked (the shell captures the one it tracks).
    fn pick_at(&self) {
        let Some(session) = session::get(self.session_id) else {
            return;
        };
        let mut session = session.borrow_mut();
        if session.hover.is_some() {
            // The shell captures the window itself (occlusion-safe), not the
            // frozen desktop; it already knows which one it is tracking.
            session.picked = true;
        }
    }

    /// Replace the selection in the shared session.
    fn set_session_selection(&self, selection: Option<Rect>) {
        if let Some(session) = session::get(self.session_id) {
            session.borrow_mut().selection = selection;
        }
    }

    /// The size readout, above the selection (or below when there is no room).
    ///
    /// `PaintContext::draw_text` takes the text **baseline**, not the top-left,
    /// so the label offsets by the font's ascent. Drawing at the box top (the
    /// old code) put the glyphs above the background — the upward overflow.
    fn paint_label(&self, paint: &mut PaintContext, text: &str, sel: Rect, viewport: Rect) {
        let font = 12.0;
        let (width, line_height, ascent) = match &self.measurer {
            Some(measurer) => (
                measurer.measure_run(text, font),
                measurer.line_height(font),
                measurer.ascent(font),
            ),
            None => (
                text.chars().count() as f32 * font * 0.55,
                font * 1.3,
                font * 0.8,
            ),
        };
        let pad_x = 6.0;
        let pad_y = 3.0;
        let box_w = width + pad_x * 2.0;
        let box_h = line_height + pad_y * 2.0;
        let above = sel.min().y - box_h - 2.0 >= viewport.min().y;
        let y = if above {
            sel.min().y - box_h - 2.0
        } else {
            sel.max().y + 2.0
        };
        let x = (sel.min().x)
            .min(viewport.max().x - box_w)
            .max(viewport.min().x);
        let background = Rect::from_min_size(Vec2::new(x, y), Size::new(box_w, box_h));
        paint.fill_rounded_rect(background, 3.0, LABEL_BG);
        paint.draw_text(
            text,
            Vec2::new(x + pad_x, y + pad_y + ascent),
            font,
            TextAlign::Left,
            LABEL_FG,
        );
    }

    /// The pick-mode overlay: only the window under the cursor is bright.
    fn paint_pick(&self, paint: &mut PaintContext, viewport: Rect) {
        // Dim only once a window is under the cursor: the screen stays bright
        // until the user has something selected.
        if let Some(window) = self.hovered_window() {
            let local = selection::to_local(window, self.origin);
            for rect in selection::mask_rects(viewport, Some(local)) {
                if rect.size.width > 0.0 && rect.size.height > 0.0 {
                    paint.fill_rect(rect, DIM);
                }
            }
            if let Some(visible) = local.intersection(viewport) {
                paint.stroke_rect(visible, 2.0, ACCENT);
            }
            let label = format!("{:.0} × {:.0}", window.size.width, window.size.height);
            self.paint_label(paint, &label, local, viewport);
        }

        if let Some(p) = self.pointer {
            paint.fill_rect(
                Rect::from_min_size(Vec2::new(p.x, 0.0), Size::new(1.0, viewport.size.height)),
                CROSSHAIR,
            );
            paint.fill_rect(
                Rect::from_min_size(Vec2::new(0.0, p.y), Size::new(viewport.size.width, 1.0)),
                CROSSHAIR,
            );
        }
    }
}

impl AppLogic for OverlayApp {
    fn init(&mut self, ctx: &InitContext<'_>) {
        self.backend = ctx.service::<SharedBackend>().cloned();
        self.measurer = ctx.service::<Rc<dyn TextMeasurer>>().cloned();
        if let Some(backend) = &self.backend {
            backend
                .borrow_mut()
                .set_clear_color(Color::new(0.0, 0.0, 0.0, 1.0));
        }
        self.sync_display();
        self.ensure_texture();
        if let Some(texture) = self.texture {
            self.tree = Some(self.make_tree(texture));
        }
    }

    fn event(&mut self, _ctx: &EventContext<'_>, event: &InputEvent) -> EventResult {
        // Window-pick mode: hover highlights, a click selects the window.
        if self.pick_mode() {
            match event {
                InputEvent::PointerMove { position } => {
                    self.pointer = Some(*position);
                    return EventResult::Ignored;
                }
                InputEvent::PointerDown { position, button } if *button == PointerButton::Left => {
                    self.pointer = Some(*position);
                    self.pick_at();
                    return EventResult::Handled;
                }
                InputEvent::PointerLeave => {
                    self.pointer = None;
                    return EventResult::Ignored;
                }
                InputEvent::ModifiersChanged(modifiers) => {
                    self.modifiers = *modifiers;
                    return EventResult::Ignored;
                }
                _ => {}
            }
        }
        match event {
            InputEvent::ModifiersChanged(modifiers) => {
                self.modifiers = *modifiers;
                EventResult::Ignored
            }
            InputEvent::PointerDown { position, button } if *button == PointerButton::Left => {
                self.pointer = Some(*position);
                let global = *position + self.origin;
                let (drag, selection) = selection::begin(self.session_selection(), global);
                self.drag = drag;
                self.set_session_selection(selection);
                EventResult::Handled
            }
            InputEvent::PointerMove { position } => {
                self.pointer = Some(*position);
                if !matches!(self.drag, Drag::None) {
                    let global = *position + self.origin;
                    let selection = selection::update(self.drag, global, self.session_selection());
                    self.set_session_selection(selection);
                }
                EventResult::Ignored
            }
            InputEvent::PointerUp { button, .. } if *button == PointerButton::Left => {
                let selection = selection::finish(self.drag, self.session_selection());
                self.set_session_selection(selection);
                self.drag = Drag::None;
                EventResult::Handled
            }
            InputEvent::PointerLeave => {
                self.pointer = None;
                EventResult::Ignored
            }
            InputEvent::KeyDown { key } => {
                let step = if self.modifiers.shift { 10.0 } else { 1.0 };
                let delta = match key {
                    Key::ArrowLeft => Some(Vec2::new(-step, 0.0)),
                    Key::ArrowRight => Some(Vec2::new(step, 0.0)),
                    Key::ArrowUp => Some(Vec2::new(0.0, -step)),
                    Key::ArrowDown => Some(Vec2::new(0.0, step)),
                    _ => None,
                };
                if let Some(delta) = delta {
                    if let Some(rect) = self.session_selection() {
                        self.set_session_selection(Some(rect.translate(delta)));
                        return EventResult::Handled;
                    }
                }
                EventResult::Ignored
            }
            _ => EventResult::Ignored,
        }
    }

    fn update(&mut self, _ctx: &FrameContext<'_>) {
        self.sync_display();
        self.ensure_texture();
        if self.tree.is_none() {
            if let Some(texture) = self.texture {
                self.tree = Some(self.make_tree(texture));
            }
        }
    }

    fn layout(&mut self, ctx: &FrameContext<'_>) {
        if let Some(tree) = self.tree.as_mut() {
            igui_ui::layout(tree, ctx.viewport());
            let _ = tree.update();
        }
    }

    fn paint(&mut self, ctx: &FrameContext<'_>, paint: &mut PaintContext) {
        if let Some(tree) = self.tree.as_ref() {
            igui_ui::paint(tree, paint);
        }
        let viewport = ctx.viewport().logical_rect();
        if self.pick_mode() {
            self.paint_pick(paint, viewport);
            return;
        }
        let selection = self
            .session_selection()
            .map(|rect| selection::to_local(rect, self.origin));

        // Dim only once the region is settled: not before the first drag starts,
        // and not while a new region is still being drawn — pressing ⌘⇧A must
        // not darken the whole screen immediately.
        let settled = selection.is_some() && !matches!(self.drag, Drag::New { .. });
        if settled {
            for rect in selection::mask_rects(viewport, selection) {
                if rect.size.width > 0.0 && rect.size.height > 0.0 {
                    paint.fill_rect(rect, DIM);
                }
            }
        }

        if let Some(sel) = selection {
            paint.stroke_rect(sel, 1.0, ACCENT);
            for (_, center) in selection::handle_centers(sel) {
                let handle = Rect::from_center_size(center, Size::splat(selection::HANDLE_SIZE));
                if handle.intersects(viewport) {
                    paint.fill_rect(handle, ACCENT);
                }
            }
            let label = format!("{:.0} × {:.0}", sel.size.width, sel.size.height);
            self.paint_label(paint, &label, sel, viewport);
        }

        if let Some(p) = self.pointer {
            paint.fill_rect(
                Rect::from_min_size(Vec2::new(p.x, 0.0), Size::new(1.0, viewport.size.height)),
                CROSSHAIR,
            );
            paint.fill_rect(
                Rect::from_min_size(Vec2::new(0.0, p.y), Size::new(viewport.size.width, 1.0)),
                CROSSHAIR,
            );
        }
    }

    fn cursor(&self) -> Option<Cursor> {
        let local = self
            .session_selection()
            .map(|rect| selection::to_local(rect, self.origin));
        if let (Some(sel), Some(p)) = (local, self.pointer) {
            if selection::handle_at(sel, p).is_some() {
                return Some(Cursor::Pointer);
            }
            if sel.contains(p) {
                return Some(Cursor::Grab);
            }
        }
        Some(Cursor::Default)
    }

    fn caret(&self) -> Option<Rect> {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use igui::igui_backend_recording::RecordingBackend;
    use igui::igui_core::Size;
    use igui::igui_render::{DrawCommand, RenderBackend};

    #[test]
    fn the_overlay_fills_the_window_with_the_frozen_texture() {
        let texture = TextureId::new(1);
        let mut tree = OverlayApp::build_tree(texture);
        let viewport = igui::igui_core::ViewportSize::new(Size::new(100.0, 50.0));
        igui_ui::layout(&mut tree, viewport);
        let _ = tree.update();

        let mut backend = RecordingBackend::new();
        backend.begin_frame(viewport).expect("begin frame");
        let mut ctx = PaintContext::new();
        igui_ui::paint(&tree, &mut ctx);
        backend.submit(&ctx.into_draw_list()).expect("submit");
        backend.end_frame().expect("end frame");

        let frame = backend.last_frame().expect("a frame was recorded");
        let image = frame.commands().iter().find_map(|command| match command {
            DrawCommand::DrawImage {
                texture: drawn,
                destination,
                ..
            } => Some((*drawn, *destination)),
            _ => None,
        });
        let (drawn, destination) = image.expect("the frozen texture is drawn");
        assert_eq!(drawn, texture);
        assert_eq!(
            destination.size,
            Size::new(100.0, 50.0),
            "the frozen frame fills the window"
        );
    }

    #[test]
    fn the_size_label_text_stays_inside_its_background() {
        let app = OverlayApp::new(0, 0);
        let selection = Rect::from_min_size(Vec2::new(40.0, 40.0), Size::new(100.0, 50.0));
        let viewport = Rect::from_min_size(Vec2::ZERO, Size::new(400.0, 400.0));
        let mut ctx = PaintContext::new();
        app.paint_label(&mut ctx, "100 × 50", selection, viewport);

        let mut backend = RecordingBackend::new();
        let viewport_size = igui::igui_core::ViewportSize::new(Size::new(400.0, 400.0));
        backend.begin_frame(viewport_size).expect("begin frame");
        backend.submit(&ctx.into_draw_list()).expect("submit");
        backend.end_frame().expect("end frame");
        let frame = backend.last_frame().expect("a frame was recorded");

        let mut background = None;
        let mut baseline = None;
        for command in frame.commands() {
            match command {
                DrawCommand::FillRoundedRect { rect, .. } => background = Some(*rect),
                DrawCommand::DrawText { position, .. } => baseline = Some(position.y),
                _ => {}
            }
        }
        let background = background.expect("the label background");
        let baseline = baseline.expect("the label text");
        assert!(
            baseline > background.top() && baseline < background.bottom(),
            "baseline {baseline} must sit between {} and {}",
            background.top(),
            background.bottom()
        );
    }
}
