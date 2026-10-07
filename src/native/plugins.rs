//! The non-graphics host plugins: the backend's real font metrics as the layout
//! measurer.
//!
//! ushot's editor has text fields (added in a later phase), and even the shell
//! view needs real metrics so layout matches rendering. This plugin publishes
//! the backend's `FontMetrics` as the `TextMeasurer` service.

use std::rc::Rc;

use igui::igui_app::{App, AppBuilder, LifecycleObserver, Plugin};
use igui::igui_backend_wgpu::FontMetrics;
use igui::igui_core::FontWeight;
use igui::igui_ui::TextMeasurer;

use super::SharedBackend;

/// Registers the backend's real font metrics as the layout measurer.
#[derive(Default)]
pub struct NativeTextMeasurePlugin;

impl Plugin for NativeTextMeasurePlugin {
    fn name(&self) -> &'static str {
        "ushot-host-text-measure"
    }

    fn build(&self, app: &mut AppBuilder) {
        app.add_lifecycle_observer(NativeTextMeasureLifecycle);
    }
}

struct NativeTextMeasureLifecycle;

impl LifecycleObserver for NativeTextMeasureLifecycle {
    fn resumed(&mut self, app: &mut App) {
        if app.services().get::<Rc<dyn TextMeasurer>>().is_some() {
            return;
        }
        let Some(backend) = app.services().get::<SharedBackend>().cloned() else {
            return;
        };
        let metrics = backend.borrow().text_metrics();
        let measurer: Rc<dyn TextMeasurer> = Rc::new(NativeTextMeasurer { metrics });
        app.services_mut().insert(measurer);
    }
}

/// The backend's `FontMetrics` behind the [`TextMeasurer`] trait.
pub struct NativeTextMeasurer {
    metrics: FontMetrics,
}

impl TextMeasurer for NativeTextMeasurer {
    fn advance(&self, ch: char, font_size: f32) -> f32 {
        self.metrics.advance(ch, font_size)
    }

    fn advance_weighted(&self, ch: char, font_size: f32, weight: FontWeight) -> f32 {
        self.metrics.advance_weighted(ch, font_size, weight)
    }

    fn line_height(&self, font_size: f32) -> f32 {
        self.metrics.line_height(font_size)
    }

    fn ascent(&self, font_size: f32) -> f32 {
        self.metrics.ascent(font_size)
    }

    fn measure_run(&self, text: &str, font_size: f32) -> f32 {
        self.metrics.measure_run(text, font_size)
    }

    fn measure_run_weighted(&self, text: &str, font_size: f32, weight: FontWeight) -> f32 {
        self.metrics.measure_run_weighted(text, font_size, weight)
    }
}
