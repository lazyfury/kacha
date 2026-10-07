//! A leaf component that paints a registered texture over its whole rect.
//!
//! `igui` has no image widget yet (as classic-game-box notes), so this builds
//! one on the public extension points: a [`Component`] whose `foreground`
//! decorator emits one `DrawImage`. Unlike cgb's `FrameImage` (which letterboxes
//! a game frame) this *fills* the rect — the freeze-frame overlay draws the
//! captured display 1:1 over its window.

use igui::igui_components::{Component, Spec};
use igui::igui_render::{Paint, TextureId};
use igui::igui_ui::MouseFilter;

/// A leaf that paints `texture` over the rectangle layout assigns it.
pub struct ImageFill {
    spec: Spec,
    texture: TextureId,
}

impl ImageFill {
    /// Paint `texture`, filling whatever rect the layout gives this node.
    pub fn new(texture: TextureId) -> Self {
        Self {
            spec: Spec::default(),
            texture,
        }
    }
}

impl Component for ImageFill {
    fn spec(&mut self) -> &mut Spec {
        &mut self.spec
    }

    fn name(&self) -> &'static str {
        "ImageFill"
    }

    fn prepare(&mut self) {
        let texture = self.texture;
        // The image is scenery, not a hit target.
        self.spec.data.mouse_filter = MouseFilter::Ignore;
        self.spec.foreground = Some(Box::new(move |ctx, rect, _state| {
            ctx.draw_image(texture, rect, None, Paint::default());
        }));
    }
}
