//! The region-selection geometry and drag state — pure, backend-neutral and
//! unit-testable.
//!
//! All coordinates here are **global logical points** (origin top-left, the
//! CoreGraphics global space). The only conversion an overlay view needs is
//! [`to_local`] (subtract its display's origin) for drawing.
//!
//! `igui_ui` already has drag/resize helpers for controls, but the overlay is
//! drawn directly into the `PaintContext` (a frozen bitmap with a live mask),
//! so the hit-testing lives here where it can be tested without a tree.

use igui_core::{Rect, Size, Vec2};

/// The eight resize handles, named by compass direction.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Handle {
    NW,
    N,
    NE,
    E,
    SE,
    S,
    SW,
    W,
}

/// Drawn size of a handle, in logical pixels.
pub const HANDLE_SIZE: f32 = 8.0;
/// Half-extent of a handle's hit area; a little larger than the drawn square.
const HANDLE_HIT: f32 = 5.0;
/// A selection smaller than this is treated as a stray click, not a region.
pub const MIN_SIZE: f32 = 4.0;

/// What a pointer drag is currently doing.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub enum Drag {
    #[default]
    None,
    /// Creating a fresh selection from `anchor`.
    New { anchor: Vec2 },
    /// Moving the whole selection.
    Move { grab: Vec2, start: Rect },
    /// Dragging one handle.
    Resize { handle: Handle, start: Rect },
}

/// Begin a drag at global point `p`, given the current selection.
///
/// Returns the drag to remember and the selection to store now (a fresh empty
/// rect when this is a new selection).
pub fn begin(current: Option<Rect>, p: Vec2) -> (Drag, Option<Rect>) {
    if let Some(rect) = current {
        if let Some(handle) = handle_at(rect, p) {
            return (
                Drag::Resize {
                    handle,
                    start: rect,
                },
                Some(rect),
            );
        }
        if rect.contains(p) {
            return (
                Drag::Move {
                    grab: p,
                    start: rect,
                },
                Some(rect),
            );
        }
    }
    (
        Drag::New { anchor: p },
        Some(Rect::from_min_size(p, Size::ZERO)),
    )
}

/// Advance a drag to global point `p`.
pub fn update(drag: Drag, p: Vec2, current: Option<Rect>) -> Option<Rect> {
    match drag {
        Drag::None => current,
        Drag::New { anchor } => Some(rect_between(anchor, p)),
        Drag::Move { grab, start } => Some(start.translate(p - grab)),
        Drag::Resize { handle, start } => Some(resize(start, handle, p)),
    }
}

/// Finish a drag. A new selection that never grew past [`MIN_SIZE`] is cleared
/// (a plain click on the desktop).
pub fn finish(drag: Drag, current: Option<Rect>) -> Option<Rect> {
    if matches!(drag, Drag::New { .. }) {
        return current.filter(|rect| usable(*rect));
    }
    current
}

/// Whether `rect` is large enough to keep / confirm.
pub fn usable(rect: Rect) -> bool {
    rect.size.width >= MIN_SIZE && rect.size.height >= MIN_SIZE
}

/// The handle under global point `p`, if any.
pub fn handle_at(rect: Rect, p: Vec2) -> Option<Handle> {
    let min = rect.min();
    let max = rect.max();
    let mid = Vec2::new((min.x + max.x) * 0.5, (min.y + max.y) * 0.5);
    let candidates = [
        (Handle::NW, Vec2::new(min.x, min.y)),
        (Handle::N, Vec2::new(mid.x, min.y)),
        (Handle::NE, Vec2::new(max.x, min.y)),
        (Handle::E, Vec2::new(max.x, mid.y)),
        (Handle::SE, Vec2::new(max.x, max.y)),
        (Handle::S, Vec2::new(mid.x, max.y)),
        (Handle::SW, Vec2::new(min.x, max.y)),
        (Handle::W, Vec2::new(min.x, mid.y)),
    ];
    candidates
        .iter()
        .find(|(_, center)| {
            (p.x - center.x).abs() <= HANDLE_HIT && (p.y - center.y).abs() <= HANDLE_HIT
        })
        .map(|(handle, _)| *handle)
}

/// The handle centres of `rect`, for drawing.
pub fn handle_centers(rect: Rect) -> [(Handle, Vec2); 8] {
    let min = rect.min();
    let max = rect.max();
    let mid = Vec2::new((min.x + max.x) * 0.5, (min.y + max.y) * 0.5);
    [
        (Handle::NW, Vec2::new(min.x, min.y)),
        (Handle::N, Vec2::new(mid.x, min.y)),
        (Handle::NE, Vec2::new(max.x, min.y)),
        (Handle::E, Vec2::new(max.x, mid.y)),
        (Handle::SE, Vec2::new(max.x, max.y)),
        (Handle::S, Vec2::new(mid.x, max.y)),
        (Handle::SW, Vec2::new(min.x, max.y)),
        (Handle::W, Vec2::new(min.x, mid.y)),
    ]
}

/// The rectangle between two corners (order-independent).
pub fn rect_between(a: Vec2, b: Vec2) -> Rect {
    rect_from_corners(a.x, a.y, b.x, b.y)
}

/// Resize `start` by moving `handle` to global point `p`.
pub fn resize(start: Rect, handle: Handle, p: Vec2) -> Rect {
    let min = start.min();
    let max = start.max();
    let (mut x0, mut y0, mut x1, mut y1) = (min.x, min.y, max.x, max.y);
    match handle {
        Handle::NW => {
            x0 = p.x;
            y0 = p.y;
        }
        Handle::N => y0 = p.y,
        Handle::NE => {
            x1 = p.x;
            y0 = p.y;
        }
        Handle::E => x1 = p.x,
        Handle::SE => {
            x1 = p.x;
            y1 = p.y;
        }
        Handle::S => y1 = p.y,
        Handle::SW => {
            x0 = p.x;
            y1 = p.y;
        }
        Handle::W => x0 = p.x,
    }
    rect_from_corners(x0, y0, x1, y1)
}

fn rect_from_corners(x0: f32, y0: f32, x1: f32, y1: f32) -> Rect {
    Rect::from_min_max(
        Vec2::new(x0.min(x1), y0.min(y1)),
        Vec2::new(x0.max(x1), y0.max(y1)),
    )
}

/// Global logical rectangle → a display's local coordinates.
pub fn to_local(global: Rect, origin: Vec2) -> Rect {
    global.translate(Vec2::new(-origin.x, -origin.y))
}

/// The four dim-wash rectangles around `selection` within `viewport`.
///
/// With no selection the whole viewport is returned as one rectangle (the
/// screen dims uniformly before a drag starts).
pub fn mask_rects(viewport: Rect, selection: Option<Rect>) -> [Rect; 4] {
    let Some(selection) = selection.and_then(|sel| sel.intersection(viewport)) else {
        return [viewport, Rect::ZERO, Rect::ZERO, Rect::ZERO];
    };
    let vmin = viewport.min();
    let vmax = viewport.max();
    let smin = selection.min();
    let smax = selection.max();
    [
        // above
        Rect::from_min_max(vmin, Vec2::new(vmax.x, smin.y)),
        // below
        Rect::from_min_max(Vec2::new(vmin.x, smax.y), vmax),
        // left
        Rect::from_min_max(Vec2::new(vmin.x, smin.y), Vec2::new(smin.x, smax.y)),
        // right
        Rect::from_min_max(Vec2::new(smax.x, smin.y), Vec2::new(vmax.x, smax.y)),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rect(x: f32, y: f32, w: f32, h: f32) -> Rect {
        Rect::from_min_size(Vec2::new(x, y), Size::new(w, h))
    }

    #[test]
    fn a_drag_creates_a_normalized_rectangle_in_either_direction() {
        for (from, to) in [
            (Vec2::new(10.0, 20.0), Vec2::new(50.0, 80.0)),
            (Vec2::new(50.0, 80.0), Vec2::new(10.0, 20.0)),
        ] {
            let (drag, _) = begin(None, from);
            assert!(matches!(drag, Drag::New { .. }));
            assert_eq!(update(drag, to, None), Some(rect(10.0, 20.0, 40.0, 60.0)));
        }
    }

    #[test]
    fn a_click_without_a_drag_clears_the_selection() {
        let (drag, rect0) = begin(None, Vec2::new(5.0, 5.0));
        assert_eq!(rect0, Some(rect(5.0, 5.0, 0.0, 0.0)));
        assert_eq!(finish(drag, rect0), None);
    }

    #[test]
    fn dragging_inside_moves_and_dragging_a_handle_resizes() {
        let start = rect(100.0, 100.0, 200.0, 100.0);

        // Inside the body → move.
        let (drag, _) = begin(Some(start), Vec2::new(200.0, 150.0));
        assert_eq!(
            drag,
            Drag::Move {
                grab: Vec2::new(200.0, 150.0),
                start
            }
        );
        assert_eq!(
            update(drag, Vec2::new(230.0, 160.0), Some(start)),
            Some(rect(130.0, 110.0, 200.0, 100.0))
        );

        // On the SE handle → resize, the NW corner stays put.
        let (drag, _) = begin(Some(start), Vec2::new(300.0, 200.0));
        assert_eq!(
            drag,
            Drag::Resize {
                handle: Handle::SE,
                start
            }
        );
        assert_eq!(
            update(drag, Vec2::new(250.0, 260.0), Some(start)),
            Some(rect(100.0, 100.0, 150.0, 160.0))
        );

        // On the N edge → only y changes.
        let (drag, _) = begin(Some(start), Vec2::new(200.0, 100.0));
        assert_eq!(
            drag,
            Drag::Resize {
                handle: Handle::N,
                start
            }
        );
        assert_eq!(
            update(drag, Vec2::new(999.0, 130.0), Some(start)),
            Some(rect(100.0, 130.0, 200.0, 70.0))
        );
    }

    #[test]
    fn resizing_across_the_opposite_edge_stays_normalized() {
        let start = rect(100.0, 100.0, 200.0, 100.0);
        // Drag the SE handle far up-left, past the NW corner.
        let resized = resize(start, Handle::SE, Vec2::new(50.0, 40.0));
        assert_eq!(resized, rect(50.0, 40.0, 50.0, 60.0));
    }

    #[test]
    fn the_mask_leaves_a_hole_for_the_selection() {
        let viewport = rect(0.0, 0.0, 100.0, 100.0);
        let holes = mask_rects(viewport, Some(rect(20.0, 30.0, 40.0, 50.0)));
        assert_eq!(holes[0], rect(0.0, 0.0, 100.0, 30.0)); // above
        assert_eq!(holes[1], rect(0.0, 80.0, 100.0, 20.0)); // below
        assert_eq!(holes[2], rect(0.0, 30.0, 20.0, 50.0)); // left
        assert_eq!(holes[3], rect(60.0, 30.0, 40.0, 50.0)); // right
    }

    #[test]
    fn no_selection_dims_the_whole_viewport() {
        let viewport = rect(0.0, 0.0, 100.0, 100.0);
        let holes = mask_rects(viewport, None);
        assert_eq!(holes[0], viewport);
        assert!(holes[1].is_empty() && holes[2].is_empty() && holes[3].is_empty());
    }

    #[test]
    fn a_selection_on_another_display_is_clipped_away_here() {
        let viewport = rect(0.0, 0.0, 100.0, 100.0);
        let elsewhere = rect(500.0, 500.0, 50.0, 50.0);
        let holes = mask_rects(viewport, Some(elsewhere));
        assert_eq!(holes[0], viewport, "the whole screen dims");
    }

    #[test]
    fn local_coordinates_subtract_the_display_origin() {
        let global = rect(500.0, 300.0, 100.0, 50.0);
        assert_eq!(
            to_local(global, Vec2::new(400.0, 200.0)),
            rect(100.0, 100.0, 100.0, 50.0)
        );
    }
}
