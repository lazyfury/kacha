//! The editor window: shows the composed selection and lets the user annotate
//! it (P3: rectangle, arrow, pen/highlighter, with undo/redo).
//!
//! Layout is the tested shape `Column` root → a `Flex` whose children are the
//! toolbar and a growing [`Canvas`]. The canvas draws the image; this module
//! turns pointer events into image-space annotations and wire the toolbar
//! buttons to the shared [`EditorState`].

use std::cell::RefCell;
use std::rc::Rc;

use igui::igui_app::{AppLogic, EventContext, EventResult, FrameContext, InitContext};
use igui::igui_backend_wgpu::{TextureFilter, WgpuBackend};
use igui::igui_components::{Button, Column, Component, Flex, Row};
use igui::igui_core::{
    Color, Cursor, ImeEvent, InputEvent, Key, Modifiers, PointerButton, Rect, Size, Vec2,
    ViewportSize,
};
use igui::igui_render::{Paint, PaintContext, RenderBackend, TextureId};
use igui::igui_scene::{SceneChild, SceneTree};
use igui::igui_theme::{default_theme, space, Mode, SurfaceLevel, Theme};
use igui::igui_ui::{self, Align, MouseFilter, SurfaceStyle, TextMeasurer};

use crate::annotate::{Annotation, Tool};
use crate::native::SharedBackend;
use crate::session::SessionHandle;
use crate::session::{self, EditorAction};

use super::canvas::{
    clamp_to_image, default_stroke, default_text_size, draw_annotation, to_image, to_screen,
    Canvas, EditorState, TextDraft,
};

/// The texture slot the composed image is uploaded to (each window has its own
/// backend, so the id only has to be unique here).
const COMPOSED_TEXTURE: TextureId = TextureId::new(0x2000);

/// The editor view for one composed image.
pub struct EditorApp {
    session_id: u64,
    /// The shared session (for the parked action and the composed image).
    session_handle: Option<SessionHandle>,
    backend: Option<SharedBackend>,
    measurer: Option<Rc<dyn TextMeasurer>>,
    state: Rc<RefCell<EditorState>>,
    tree: Option<SceneTree>,
    theme: &'static dyn Theme,
    dragging: bool,
    modifiers: Modifiers,
    /// Cached offscreen backend for exports: creating a fresh wgpu device per
    /// copy / save / pin is wasteful, and re-registering a texture id replaces
    /// it (see `WgpuBackend::register_texture`). `None` until first use, or
    /// permanently if the GPU could not be created.
    export_backend: RefCell<Option<WgpuBackend>>,
}

impl EditorApp {
    /// The editor for the session's composed image.
    pub fn new(session_id: u64) -> Self {
        Self {
            session_id,
            session_handle: None,
            backend: None,
            measurer: None,
            state: Rc::new(RefCell::new(EditorState::new(TextureId::INVALID, 0, 0))),
            tree: None,
            theme: default_theme(Mode::Dark),
            dragging: false,
            modifiers: Modifiers::NONE,
            export_backend: RefCell::new(None),
        }
    }

    /// Upload the composed image into this window's backend and build the view,
    /// once the session has one.
    fn ensure_composed(&mut self) {
        if self.tree.is_some() {
            return;
        }
        let Some(backend) = self.backend.clone() else {
            return;
        };
        let Some(session) = session::get(self.session_id) else {
            return;
        };
        let Some(composed) = session.borrow().composed.clone() else {
            return;
        };
        let (width, height) = (composed.width, composed.height);
        let uploaded = backend.borrow_mut().register_texture_with_filter(
            COMPOSED_TEXTURE,
            width,
            height,
            &composed.rgba,
            TextureFilter::Nearest,
        );
        if let Err(error) = uploaded {
            eprintln!("ushot-host: 上传截图失败：{error}");
            return;
        }
        {
            let mut state = self.state.borrow_mut();
            state.texture = COMPOSED_TEXTURE;
            state.image = (width, height);
            // Shared, not copied: the canvas samples it for the mosaic tool.
            state.composed = Some(composed);
            // Defaults that read the same regardless of the capture resolution.
            state.stroke = default_stroke((width, height));
            state.text_size = default_text_size((width, height));
        }
        self.tree = Some(self.build_tree());
    }

    fn build_tree(&self) -> SceneTree {
        let toolbar = self.toolbar(self.theme);
        let canvas = Canvas::new(self.state.clone(), self.measurer.clone()).grow(1.0);
        let content = Flex::column()
            .gap(space::SM)
            .mouse_filter(MouseFilter::Ignore)
            .child(toolbar)
            .child(canvas);
        let mut tree = Column::new()
            .mouse_filter(MouseFilter::Ignore)
            .child(content)
            .into_tree();
        if let Some(measurer) = &self.measurer {
            igui_ui::set_text_measurer(&mut tree, measurer.clone());
        }
        tree
    }

    fn toolbar(&self, theme: &'static dyn Theme) -> Row {
        let mut row = Row::new().gap(space::SM).align(Align::Center);
        for tool in [
            Tool::Rectangle,
            Tool::Arrow,
            Tool::Pen,
            Tool::Highlighter,
            Tool::Text,
            Tool::Mosaic,
        ] {
            row = row.child(self.tool_button(theme, tool));
        }
        let undo = self.state.clone();
        row = row.child(
            Button::ghost("撤销", theme).on_click(move |_tree, _id| undo.borrow_mut().undo()),
        );
        let redo = self.state.clone();
        row = row.child(
            Button::ghost("重做", theme).on_click(move |_tree, _id| redo.borrow_mut().redo()),
        );
        row = row.child(self.action_button(theme, "复制", EditorAction::Copy));
        row = row.child(self.action_button(theme, "保存", EditorAction::Save));
        row = row.child(self.action_button(theme, "钉图", EditorAction::Pin));
        row = row.child(self.action_button(theme, "关闭", EditorAction::Close));
        row
    }

    fn action_button(
        &self,
        theme: &'static dyn Theme,
        label: &'static str,
        action: EditorAction,
    ) -> Button {
        let session = self.session_handle.clone();
        Button::ghost(label, theme).on_click(move |_tree, _id| {
            if let Some(session) = &session {
                session.borrow_mut().request = Some(action);
            }
        })
    }

    /// Rasterize the composed image and the annotations at native pixel size
    /// into a PNG, reusing a cached offscreen backend across exports.
    fn render_export(&self) -> Option<Vec<u8>> {
        let session = session::get(self.session_id)?;
        let session = session.borrow();
        let composed = session.composed.as_ref()?;
        let (width, height) = (composed.width, composed.height);
        if width == 0 || height == 0 {
            return None;
        }

        let mut cached = self.export_backend.borrow_mut();
        if cached.is_none() {
            *cached = WgpuBackend::new().ok();
        }
        let backend = cached.as_mut()?;

        const EXPORT_TEXTURE: TextureId = TextureId::new(1);
        backend
            .register_texture_with_filter(
                EXPORT_TEXTURE,
                width,
                height,
                &composed.rgba,
                TextureFilter::Nearest,
            )
            .ok()?;

        let viewport = ViewportSize::new(Size::new(width as f32, height as f32));
        let full = Rect::from_min_size(Vec2::ZERO, Size::new(width as f32, height as f32));
        let mut ctx = PaintContext::new();
        ctx.draw_image(EXPORT_TEXTURE, full, None, Paint::default());
        {
            let state = self.state.borrow();
            for annotation in &state.annotations {
                draw_annotation(
                    &mut ctx,
                    annotation,
                    full,
                    (width, height),
                    Some(&composed.rgba),
                );
            }
        }
        backend.begin_frame(viewport).ok()?;
        backend.submit(&ctx.into_draw_list()).ok()?;
        backend.end_frame().ok()?;
        let pixels = backend.read_pixels().ok()?;
        crate::export::png::encode_rgba(width, height, &pixels.data).ok()
    }

    fn tool_button(&self, theme: &'static dyn Theme, tool: Tool) -> Button {
        let click = self.state.clone();
        let active = self.state.clone();
        Button::ghost(tool.label(), theme)
            .dynamic_background(move |_| {
                if active.borrow().tool == tool {
                    SurfaceStyle::new(theme.surface(SurfaceLevel::Raised))
                } else {
                    SurfaceStyle::new(Color::TRANSPARENT)
                }
            })
            .on_click(move |_tree, _id| click.borrow_mut().tool = tool)
    }

    /// Turn a pointer event into annotation editing.
    fn handle_canvas(&mut self, event: &InputEvent) -> EventResult {
        let (image_rect, image, tool, color, stroke, text_size) = {
            let state = self.state.borrow();
            (
                state.image_rect,
                state.image,
                state.tool,
                state.color,
                state.stroke,
                state.text_size,
            )
        };
        let Some(image_rect) = image_rect else {
            return EventResult::Ignored;
        };
        match event {
            InputEvent::PointerDown { position, button } if *button == PointerButton::Left => {
                if !image_rect.contains(*position) {
                    return EventResult::Ignored;
                }
                let start = clamp_to_image(to_image(image_rect, image, *position), image);
                if tool == Tool::Text {
                    self.state.borrow_mut().editing_text = Some(TextDraft {
                        position: start,
                        text: String::new(),
                        preedit: String::new(),
                        size: text_size,
                        color,
                    });
                    return EventResult::Handled;
                }
                self.state.borrow_mut().draft = Some(Annotation {
                    tool,
                    points: vec![(start.x, start.y)],
                    color,
                    stroke,
                    text: String::new(),
                });
                self.dragging = true;
                EventResult::Handled
            }
            InputEvent::PointerMove { position } => {
                if !self.dragging {
                    return EventResult::Ignored;
                }
                let point = clamp_to_image(to_image(image_rect, image, *position), image);
                let mut state = self.state.borrow_mut();
                if let Some(draft) = state.draft.as_mut() {
                    match draft.tool {
                        Tool::Pen | Tool::Highlighter => draft.points.push((point.x, point.y)),
                        _ => {
                            if draft.points.len() < 2 {
                                draft.points.push((point.x, point.y));
                            } else {
                                draft.points[1] = (point.x, point.y);
                            }
                        }
                    }
                }
                EventResult::Handled
            }
            InputEvent::PointerUp { button, .. } if *button == PointerButton::Left => {
                if !self.dragging {
                    return EventResult::Ignored;
                }
                self.dragging = false;
                let mut state = self.state.borrow_mut();
                if let Some(draft) = state.draft.take() {
                    if renderable(&draft) {
                        state.annotations.push(draft);
                        state.redo.clear();
                    }
                }
                EventResult::Handled
            }
            _ => EventResult::Ignored,
        }
    }

    /// Editing the text box owns typing before anything else.
    fn handle_text_edit(&mut self, event: &InputEvent) -> Option<EventResult> {
        self.state.borrow().editing_text.as_ref()?;
        match event {
            InputEvent::TextInput { text } => {
                if let Some(draft) = self.state.borrow_mut().editing_text.as_mut() {
                    draft.text.push_str(text);
                    draft.preedit.clear();
                }
                Some(EventResult::Handled)
            }
            InputEvent::Ime(ImeEvent::Preedit { text, .. }) => {
                if let Some(draft) = self.state.borrow_mut().editing_text.as_mut() {
                    draft.preedit = text.clone();
                }
                Some(EventResult::Handled)
            }
            InputEvent::Ime(ImeEvent::Commit(text)) => {
                if let Some(draft) = self.state.borrow_mut().editing_text.as_mut() {
                    draft.text.push_str(text);
                    draft.preedit.clear();
                }
                Some(EventResult::Handled)
            }
            InputEvent::Ime(ImeEvent::Disabled | ImeEvent::Enabled) => {
                if let Some(draft) = self.state.borrow_mut().editing_text.as_mut() {
                    draft.preedit.clear();
                }
                Some(EventResult::Handled)
            }
            InputEvent::KeyDown { key } => match key {
                Key::Backspace => {
                    if let Some(draft) = self.state.borrow_mut().editing_text.as_mut() {
                        draft.text.pop();
                    }
                    Some(EventResult::Handled)
                }
                Key::Enter => {
                    self.state.borrow_mut().commit_text();
                    Some(EventResult::Handled)
                }
                Key::Escape => {
                    self.state.borrow_mut().editing_text = None;
                    Some(EventResult::Handled)
                }
                _ => Some(EventResult::Ignored),
            },
            _ => None,
        }
    }
}

/// Whether a draft is big enough to keep (filters out stray clicks).
fn renderable(annotation: &Annotation) -> bool {
    if annotation.points.len() < 2 {
        return false;
    }
    match annotation.tool {
        Tool::Pen | Tool::Highlighter => true,
        _ => {
            let (a, b) = (annotation.points[0], annotation.points[1]);
            (a.0 - b.0).abs() + (a.1 - b.1).abs() >= 2.0
        }
    }
}

impl AppLogic for EditorApp {
    fn init(&mut self, ctx: &InitContext<'_>) {
        self.backend = ctx.service::<SharedBackend>().cloned();
        self.measurer = ctx.service::<Rc<dyn TextMeasurer>>().cloned();
        self.session_handle = session::get(self.session_id);
        if let Some(backend) = &self.backend {
            backend
                .borrow_mut()
                .set_clear_color(Color::new(0.08, 0.08, 0.08, 1.0));
        }
        self.ensure_composed();
    }

    fn event(&mut self, _ctx: &EventContext<'_>, event: &InputEvent) -> EventResult {
        if let InputEvent::ModifiersChanged(modifiers) = event {
            self.modifiers = *modifiers;
        }
        // A click anywhere commits an in-progress text box.
        if matches!(event, InputEvent::PointerDown { .. }) {
            self.state.borrow_mut().commit_text();
        }
        if let Some(result) = self.handle_text_edit(event) {
            return result;
        }
        // A drag owns the pointer even over the toolbar, so it runs first.
        if self.dragging {
            let result = self.handle_canvas(event);
            if result.is_handled() {
                return result;
            }
        }
        if let Some(tree) = self.tree.as_mut() {
            if igui_ui::route_input(tree, event).is_handled() {
                return EventResult::Handled;
            }
        }
        self.handle_canvas(event)
    }

    fn update(&mut self, _ctx: &FrameContext<'_>) {
        self.ensure_composed();
        if self.session_handle.is_none() {
            self.session_handle = session::get(self.session_id);
        }
        // A parked action (toolbar button or a keyboard shortcut): rasterize it
        // once and leave the PNG for the shell to collect.
        let Some(session) = self.session_handle.clone() else {
            return;
        };
        let pending = {
            let session = session.borrow();
            session.request.is_some() && session.export_png.is_none()
        };
        if pending {
            let png = self.render_export();
            session.borrow_mut().export_png = png;
        }
    }

    fn layout(&mut self, ctx: &FrameContext<'_>) {
        if let Some(tree) = self.tree.as_mut() {
            igui_ui::layout(tree, ctx.viewport());
            let _ = tree.update();
        }
    }

    fn paint(&mut self, _ctx: &FrameContext<'_>, paint: &mut PaintContext) {
        if let Some(tree) = self.tree.as_ref() {
            igui_ui::paint(tree, paint);
        }
    }

    fn cursor(&self) -> Option<Cursor> {
        if self.state.borrow().image_rect.is_some() {
            Some(Cursor::Pointer)
        } else {
            Some(Cursor::Default)
        }
    }

    fn caret(&self) -> Option<igui::igui_core::Rect> {
        // Only while the text tool is placing text. The caret is the insertion
        // point after the typed run, so the IME candidate window lands just
        // below the text instead of at the window origin.
        let state = self.state.borrow();
        let draft = state.editing_text.as_ref()?;
        let image_rect = state.image_rect?;
        let image = state.image;
        if image.0 == 0 || image.1 == 0 {
            return None;
        }
        let font_size = (draft.size * image_rect.size.width / image.0 as f32).max(8.0);
        let run = format!("{}{}", draft.text, draft.preedit);
        let (advance, line_height) = match &self.measurer {
            Some(measurer) => (
                measurer.measure_run(&run, font_size),
                measurer.line_height(font_size),
            ),
            None => (
                run.chars().count() as f32 * font_size * 0.55,
                font_size * 1.3,
            ),
        };
        let origin = to_screen(image_rect, image, draft.position);
        Some(Rect::from_min_size(
            Vec2::new(origin.x + advance, origin.y),
            Size::new(1.0, line_height),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::compose::ComposedImage;
    use igui::igui_backend_recording::RecordingBackend;
    use igui::igui_core::{Size, ViewportSize};
    use igui::igui_render::{DrawCommand, RenderBackend};

    #[test]
    fn render_export_writes_a_png_of_the_composed_image() {
        let (id, handle) = session::create();
        {
            let mut session = handle.borrow_mut();
            session.composed = Some(std::rc::Rc::new(ComposedImage {
                width: 2,
                height: 2,
                rgba: vec![
                    255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 0, 255,
                ],
            }));
        }
        let app = EditorApp::new(id);
        // Skips when the machine has no usable GPU adapter.
        if let Some(png) = app.render_export() {
            let (width, height, rgba) = crate::export::png::decode_rgba(&png).expect("decode");
            assert_eq!((width, height), (2, 2));
            assert_eq!(&rgba[..4], &[255, 0, 0, 255], "the top-left pixel is red");
        }
        session::remove(id);
    }

    #[test]
    fn a_stray_click_is_not_kept() {
        let stray = Annotation {
            tool: Tool::Rectangle,
            points: vec![(10.0, 10.0), (10.5, 10.2)],
            color: [1.0; 4],
            stroke: 2.0,
            text: String::new(),
        };
        assert!(!renderable(&stray));
    }

    #[test]
    fn a_drag_is_kept() {
        let drag = Annotation::between(Tool::Arrow, (10.0, 10.0), (60.0, 40.0));
        assert!(renderable(&drag));
        let pen = Annotation {
            tool: Tool::Pen,
            points: vec![(1.0, 1.0), (2.0, 2.0)],
            color: [1.0; 4],
            stroke: 2.0,
            text: String::new(),
        };
        assert!(renderable(&pen));
    }

    #[test]
    fn the_editor_draws_the_composed_image_and_toolbar() {
        let app = EditorApp::new(0);
        {
            let mut state = app.state.borrow_mut();
            state.texture = COMPOSED_TEXTURE;
            state.image = (200, 100);
        }
        let mut tree = app.build_tree();
        let viewport = ViewportSize::new(Size::new(600.0, 400.0));
        igui_ui::layout(&mut tree, viewport);
        let _ = tree.update();

        let mut backend = RecordingBackend::new();
        backend.begin_frame(viewport).expect("begin frame");
        let mut ctx = PaintContext::new();
        igui_ui::paint(&tree, &mut ctx);
        backend.submit(&ctx.into_draw_list()).expect("submit");
        backend.end_frame().expect("end frame");
        let frame = backend.last_frame().expect("a frame was recorded");

        let image = frame
            .commands()
            .iter()
            .find_map(|command| match command {
                DrawCommand::DrawImage {
                    texture,
                    destination,
                    ..
                } => Some((*texture, *destination)),
                _ => None,
            })
            .expect("the composed image is drawn");
        assert_eq!(image.0, COMPOSED_TEXTURE);
        assert!(image.1.size.width > 0.0 && image.1.size.height > 0.0);

        let texts: Vec<&str> = frame
            .commands()
            .iter()
            .filter_map(|command| match command {
                DrawCommand::DrawText { text, .. } => Some(text.as_str()),
                _ => None,
            })
            .collect();
        assert!(
            texts.iter().any(|text| text.contains("矩形")),
            "toolbar tool missing: {texts:?}"
        );
        assert!(
            texts.iter().any(|text| text.contains("撤销")),
            "toolbar undo missing: {texts:?}"
        );
    }
}
