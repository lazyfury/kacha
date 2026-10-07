//! The annotation model: what the editor can draw on top of the capture.
//!
//! Pure data (no igui, no rendering), so it is unit-testable and can be
//! serialized later. The editor rasterizes these into `DrawCommand`s; the model
//! itself must stay backend-neutral.

/// The tools the editor toolbar offers. `Select` is the default (no new shape).
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub enum Tool {
    #[default]
    Select,
    Rectangle,
    Ellipse,
    Arrow,
    Pen,
    Highlighter,
    Text,
    Mosaic,
    Counter,
    Crop,
}

impl Tool {
    /// The toolbar label.
    pub fn label(self) -> &'static str {
        match self {
            Self::Select => "选择",
            Self::Rectangle => "矩形",
            Self::Ellipse => "椭圆",
            Self::Arrow => "箭头",
            Self::Pen => "画笔",
            Self::Highlighter => "高亮",
            Self::Text => "文字",
            Self::Mosaic => "马赛克",
            Self::Counter => "序号",
            Self::Crop => "裁剪",
        }
    }
}

/// An annotation in **image pixel** coordinates (origin top-left of the
/// capture), so it survives zoom / pan and export.
#[derive(Clone, Debug, PartialEq)]
pub struct Annotation {
    pub tool: Tool,
    /// The points that define the shape: a rect is two corners, a pen a
    /// polyline, an arrow start/end, text an origin.
    pub points: Vec<(f32, f32)>,
    /// RGBA in 0..=1.
    pub color: [f32; 4],
    /// Stroke width in image pixels.
    pub stroke: f32,
    /// Text content (only for [`Tool::Text`]).
    pub text: String,
}

impl Annotation {
    /// A stroke-only annotation between two points.
    pub fn between(tool: Tool, from: (f32, f32), to: (f32, f32)) -> Self {
        Self {
            tool,
            points: vec![from, to],
            color: [1.0, 0.2, 0.2, 1.0],
            stroke: 2.0,
            text: String::new(),
        }
    }

    /// The axis-aligned bounds of the annotation's points, if any.
    pub fn bounds(&self) -> Option<(f32, f32, f32, f32)> {
        let (first, rest) = self.points.split_first()?;
        let (mut min_x, mut min_y, mut max_x, mut max_y) = (first.0, first.1, first.0, first.1);
        for (x, y) in rest {
            min_x = min_x.min(*x);
            min_y = min_y.min(*y);
            max_x = max_x.max(*x);
            max_y = max_y.max(*y);
        }
        Some((min_x, min_y, max_x, max_y))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_rect_bounds_its_two_corners() {
        let a = Annotation::between(Tool::Rectangle, (10.0, 20.0), (4.0, 30.0));
        assert_eq!(a.bounds(), Some((4.0, 20.0, 10.0, 30.0)));
    }

    #[test]
    fn an_empty_annotation_has_no_bounds() {
        let a = Annotation {
            tool: Tool::Select,
            points: Vec::new(),
            color: [0.0; 4],
            stroke: 1.0,
            text: String::new(),
        };
        assert_eq!(a.bounds(), None);
    }
}
