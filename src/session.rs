//! The capture session: the one place the shell's windows share state.
//!
//! A *session* is created before the freeze-frame overlay windows and dropped
//! when the capture is finished. It holds the frozen display frames, the
//! current selection and (later) the composed image and annotation stack. The
//! Swift shell only ever holds the `u64` id; none of the pixels cross the ABI
//! beyond the initial upload.
//!
//! Everything runs on the main thread (the app's UI thread), so the registry is
//! a `thread_local!` map of `Rc<RefCell<Session>>` — the same non-`Send` shape
//! classic-game-box uses for its shared logic.

use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::rc::Rc;

use igui::igui_render::TextureId;
use igui_core::Rect;

use crate::capture::DisplayImage;
use crate::compose::{self, ComposedImage};
use crate::ui::selection;

/// What a session's window is for. Mirrors the `USHOT_ROLE_*` ABI values.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub enum SessionMode {
    /// The freeze-frame region overlay (one window per display).
    #[default]
    Overlay,
    /// The editor window.
    Editor,
    /// A pinned, always-on-top window.
    Pin,
}

impl SessionMode {
    /// The ABI value for this mode (`USHOT_ROLE_*`).
    pub fn from_role(role: u32) -> Self {
        match role {
            1 => Self::Editor,
            2 => Self::Pin,
            _ => Self::Overlay,
        }
    }

    /// A short label, for the debug view and logs.
    pub fn label(self) -> &'static str {
        match self {
            Self::Overlay => "框选层",
            Self::Editor => "编辑窗",
            Self::Pin => "钉图",
        }
    }
}

/// One display's frozen frame plus the texture it was uploaded to.
pub struct DisplayEntry {
    /// The captured frame (RGBA8 + geometry).
    pub image: DisplayImage,
    /// The GPU texture within the window that shows this display. `None` until
    /// the overlay window has uploaded it.
    pub texture: Option<TextureId>,
}

/// What the editor asks the shell to do with the finished image.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum EditorAction {
    Copy,
    Save,
    Pin,
    Close,
}

/// One capture session's shared state.
#[derive(Default)]
pub struct Session {
    /// The mode of the most recently opened window; informational for now.
    pub mode: SessionMode,
    /// The current selection in global logical points (origin top-left), if any.
    pub selection: Option<Rect>,
    /// Set when the user confirms the selection (Enter); the shell polls it via
    /// `ushot_session_take_selection` and opens the editor.
    pub confirmed: bool,
    /// The cropped selection, filled by [`Session::confirm`].
    pub composed: Option<Rc<ComposedImage>>,
    /// A pending editor action (the shell polls it via `ushot_host_take_action`).
    pub request: Option<EditorAction>,
    /// The PNG the editor rendered for the pending action.
    pub export_png: Option<Vec<u8>>,
    /// On-screen window rectangles (global logical points), for window picking.
    /// The window under the cursor, in global logical points. The shell owns the
    /// hit-test (`NSWindow.windowNumber(at:belowWindowWithWindowNumber:)`) and
    /// pushes it here, so the overlay never has to guess from rectangles.
    pub hover: Option<Rect>,
    /// Whether the overlay is in window-pick mode (click a window) instead of
    /// drag-a-region mode.
    pub pick_window: bool,
    /// Set when a window was clicked; the shell captures that window itself
    /// (ScreenCaptureKit `desktopIndependentWindow`), so occlusion is handled.
    pub picked: bool,
    /// Frozen frames, keyed by display id.
    displays: BTreeMap<u32, DisplayEntry>,
}

impl Session {
    /// Store (or replace) a display's frozen frame.
    pub fn set_display(&mut self, image: DisplayImage) {
        let display_id = image.display_id;
        self.displays.insert(
            display_id,
            DisplayEntry {
                image,
                texture: None,
            },
        );
    }

    /// The entry for `display_id`, if it was injected.
    pub fn display(&self, display_id: u32) -> Option<&DisplayEntry> {
        self.displays.get(&display_id)
    }

    /// The mutable entry for `display_id`.
    pub fn display_mut(&mut self, display_id: u32) -> Option<&mut DisplayEntry> {
        self.displays.get_mut(&display_id)
    }

    /// The displays, in ascending id order.
    pub fn displays(&self) -> impl Iterator<Item = &DisplayEntry> {
        self.displays.values()
    }

    /// How many displays were injected.
    pub fn display_count(&self) -> usize {
        self.displays.len()
    }

    /// Confirm the current selection: crop it out of the frozen frames into
    /// [`Session::composed`]. A no-op when the selection is unusable or no
    /// display intersects it.
    pub fn confirm(&mut self) {
        let Some(selection) = self.selection.filter(|rect| selection::usable(*rect)) else {
            return;
        };
        let composed = {
            let images: Vec<&DisplayImage> =
                self.displays.values().map(|entry| &entry.image).collect();
            compose::compose(&images, selection)
        };
        if let Some(composed) = composed {
            self.composed = Some(Rc::new(composed));
            self.confirmed = true;
        }
    }
}

/// A shared handle to one session.
pub type SessionHandle = Rc<RefCell<Session>>;

thread_local! {
    static SESSIONS: RefCell<BTreeMap<u64, SessionHandle>> =
        const { RefCell::new(BTreeMap::new()) };
    static NEXT_ID: Cell<u64> = const { Cell::new(1) };
}

/// Create a new, empty session and return its id and shared handle.
pub fn create() -> (u64, SessionHandle) {
    let id = NEXT_ID.with(|next| {
        let id = next.get();
        next.set(id.wrapping_add(1).max(1));
        id
    });
    let handle: SessionHandle = Rc::new(RefCell::new(Session::default()));
    SESSIONS.with(|map| map.borrow_mut().insert(id, handle.clone()));
    (id, handle)
}

/// The shared handle for `id`, if the session is still alive.
pub fn get(id: u64) -> Option<SessionHandle> {
    SESSIONS.with(|map| map.borrow().get(&id).cloned())
}

/// Drop the session `id`. A no-op for an unknown id.
pub fn remove(id: u64) {
    SESSIONS.with(|map| {
        map.borrow_mut().remove(&id);
    });
}

/// How many sessions are currently live (for tests / diagnostics).
pub fn live_count() -> usize {
    SESSIONS.with(|map| map.borrow().len())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::capture::DisplayImage;

    fn frame(display_id: u32) -> DisplayImage {
        DisplayImage {
            display_id,
            origin_x: 0.0,
            origin_y: 0.0,
            logical_width: 8,
            logical_height: 8,
            scale: 1.0,
            rgba: vec![0; 8 * 8 * 4],
        }
    }

    #[test]
    fn sessions_are_created_and_dropped_by_id() {
        let before = live_count();
        let (id, handle) = create();
        assert_ne!(id, 0);
        assert_eq!(live_count(), before + 1);
        assert!(Rc::ptr_eq(
            &handle,
            &get(id).expect("session must be alive")
        ));
        remove(id);
        assert!(get(id).is_none());
        assert_eq!(live_count(), before);
    }

    #[test]
    fn a_dropped_session_leaves_the_handle_alive_but_unregistered() {
        let (id, handle) = create();
        remove(id);
        // The shell may still hold the `Rc`; it stays valid, just unregistered.
        assert!(handle.borrow().selection.is_none());
    }

    #[test]
    fn roles_map_from_the_abi() {
        assert_eq!(SessionMode::from_role(0), SessionMode::Overlay);
        assert_eq!(SessionMode::from_role(1), SessionMode::Editor);
        assert_eq!(SessionMode::from_role(2), SessionMode::Pin);
        assert_eq!(SessionMode::from_role(99), SessionMode::Overlay);
    }

    #[test]
    fn displays_are_stored_by_id() {
        let (id, handle) = create();
        {
            let mut session = handle.borrow_mut();
            session.set_display(frame(1));
            session.set_display(frame(2));
            assert_eq!(session.display_count(), 2);
            assert!(session.display(1).is_some());
            assert!(session.display(9).is_none());
        }
        remove(id);
    }

    #[test]
    fn confirm_composes_the_selection() {
        use igui_core::{Size, Vec2};
        let (id, handle) = create();
        {
            let mut session = handle.borrow_mut();
            session.set_display(frame(1));
            session.selection = Some(Rect::from_min_size(Vec2::ZERO, Size::new(8.0, 8.0)));
            session.confirm();
            assert!(session.confirmed);
            let composed = session.composed.as_ref().expect("a composed image");
            assert_eq!((composed.width, composed.height), (8, 8));
        }
        remove(id);
    }

    #[test]
    fn hover_and_pick_are_stored() {
        use igui_core::{Size, Vec2};
        let (id, handle) = create();
        {
            let mut session = handle.borrow_mut();
            let window = Rect::from_min_size(Vec2::new(10.0, 10.0), Size::new(20.0, 20.0));
            session.hover = Some(window);
            session.pick_window = true;
            assert_eq!(session.hover, Some(window));
            assert!(session.pick_window);
            session.picked = true;
            assert!(session.picked);
        }
        remove(id);
    }
}
