/*
 * ushot_host.h — C ABI over the embedded ushot app (`ushot-app`).
 *
 * The Swift/macOS shell owns the window, its `CAMetalLayer` and the native
 * events; Rust owns the igui UI, the wgpu renderer and all image work. Nothing
 * about the UI crosses this boundary — the shell never paints it, it only
 * translates AppKit events into the calls below and presents the frames Rust
 * asks for.
 *
 * This is the mirror of classic-game-box's `cgb_host.h`, extended with a
 * *session* so several windows (one overlay per display, the editor, a pinned
 * window) can share one in-process capture. The shell only ever holds the
 * session's `uint64_t` id; the frozen pixels, selection and annotation live in
 * Rust.
 */
#ifndef USHOT_HOST_H
#define USHOT_HOST_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque embedded app: one instance per native window. */
typedef struct UShotHostApp UShotHostApp;

/*
 * What a window is for. The same Rust code selects the matching view.
 *   0 = the freeze-frame region overlay (one per display)
 *   1 = the editor window
 *   2 = a pinned, always-on-top window
 */
enum {
    USHOT_ROLE_OVERLAY = 0,
    USHOT_ROLE_EDITOR = 1,
    USHOT_ROLE_PIN = 2
};

/*
 * Start an app rendering into `handle`, sized in physical pixels.
 *
 * `handle` is a `CAMetalLayer *`. `role` is one of the `USHOT_ROLE_*` values;
 * `session` is an id from `ushot_session_new` (0 is allowed for a bare window
 * that is not part of a capture); `display_id` selects the frozen frame an
 * overlay window shows (ignored by other roles). Returns NULL when `handle` is
 * NULL or the GPU backend could not be created.
 */
UShotHostApp *ushot_host_start(void *handle, uint32_t width, uint32_t height,
                               double scale, uint32_t role, uint64_t session,
                               uint32_t display_id);

/* Tear the app down. The window and its layer must outlive this call. */
void ushot_host_destroy(UShotHostApp *app);

/* Run one frame: update, lay out, paint and present. */
void ushot_host_frame(UShotHostApp *app);

/*
 * Whether the app wants another frame (a drag, an animation, an IME
 * composition). A host may skip `ushot_host_frame` while this is false, but
 * must still present once after any input or resize.
 */
bool ushot_host_needs_frame(const UShotHostApp *app);

/* Resize the drawable (physical pixels) and update the backing scale. */
void ushot_host_resize(UShotHostApp *app, uint32_t width, uint32_t height,
                       double scale);

/*
 * The cursor the UI wants: an `igui_core::Cursor` discriminant (0 default,
 * 1 pointer, 2 text, 3 col-resize, 4 row-resize, 5 grab, 6 grabbing).
 */
uint32_t ushot_host_cursor(const UShotHostApp *app);

/*
 * The focused text caret in logical viewport points (origin top-left), for
 * placing the IME candidate window. Returns false when there is none.
 */
bool ushot_host_caret(const UShotHostApp *app, float *out_x, float *out_y,
                      float *out_width, float *out_height);

/* -------------------------------------------------------------------------
 * Session. Created before the overlay windows, dropped when the capture is
 * finished. Shared state (frozen frames, selection, composed image, annotation)
 * lives in Rust under this id.
 * ------------------------------------------------------------------------- */

uint64_t ushot_session_new(void);
void ushot_session_drop(uint64_t session);

/* Set the current selection (global logical points) for a programmatic flow. */
void ushot_session_set_selection(uint64_t session, float x, float y, float w,
                                 float h);

/* Set (or clear) the window under the cursor, in global logical points. The
 * shell owns the hit-test; the overlay just renders what it is told. */
void ushot_session_set_hover(uint64_t session, bool has_hover, float x,
                             float y, float width, float height);

/* Enter (`on`) or leave window-pick mode. */
void ushot_session_set_pick_window(uint64_t session, bool on);

/* Take the pick click: 1 once after a window was clicked, -1 otherwise. The
 * shell then captures the window it is tracking. */
int32_t ushot_session_take_pick(uint64_t session);

/* Set the composed image directly (a captured window the shell rasterized). */
void ushot_session_set_composed(uint64_t session, uint32_t width,
                                uint32_t height, const uint8_t *rgba,
                                size_t length);

/* Inject one display's frozen frame: tightly packed RGBA8 (straight alpha), at
 * the display's pixel resolution. `origin_x` / `origin_y` are the display's
 * top-left in global logical points (origin top-left); `length` must be at least
 * `(logical_width * scale) * (logical_height * scale) * 4` bytes. */
void ushot_display_image(uint64_t session, uint32_t display_id,
                         float origin_x, float origin_y,
                         uint32_t logical_width, uint32_t logical_height,
                         double scale, const uint8_t *rgba, size_t length);

/* Confirm the current selection (the shell calls this on Enter). A no-op when
 * there is no usable selection. */
void ushot_session_confirm(uint64_t session);

/* The confirmed selection in global logical points (origin top-left): fills the
 * out rect and returns 1 when confirmed, -1 otherwise (nothing to report). */
int32_t ushot_session_take_selection(uint64_t session, float *x, float *y,
                                     float *w, float *h);

/* The composed image size in pixels; false when the session has none yet. */
bool ushot_session_composed_size(uint64_t session, uint32_t *width,
                                 uint32_t *height);

/* -------------------------------------------------------------------------
 * Editor actions. The toolbar parks an action in Rust; the shell polls it,
 * fetches the PNG, and acknowledges.
 * ------------------------------------------------------------------------- */

/* Action codes returned by `ushot_host_take_action` and consumed on read. */
enum {
    USHOT_ACTION_NONE = 0,
    USHOT_ACTION_COPY = 1,
    USHOT_ACTION_SAVE = 2,
    USHOT_ACTION_PIN = 3,
    USHOT_ACTION_CLOSE = 4
};

uint32_t ushot_host_take_action(const UShotHostApp *app);

/* The pending action's PNG: returns the byte length, and copies into `out` when
 * it is non-NULL and `capacity` is large enough (call with NULL first). */
size_t ushot_host_action_png(const UShotHostApp *app, uint8_t *out,
                             size_t capacity);

/* Acknowledge the pending action so its PNG is released. */
void ushot_host_action_done(UShotHostApp *app);

/* Park an action programmatically (same path as a toolbar button). */
void ushot_host_request_action(UShotHostApp *app, uint32_t action);

/* -------------------------------------------------------------------------
 * Native events. Coordinates are logical viewport points, origin top-left.
 * Modifier bits: 1 shift, 2 ctrl, 4 alt, 8 command/meta.
 * Pointer button tags: 0 left, 1 right, 2 middle.
 * ------------------------------------------------------------------------- */

void ushot_host_pointer_move(UShotHostApp *app, float x, float y);
void ushot_host_pointer_down(UShotHostApp *app, float x, float y, uint32_t button,
                             uint32_t click_count);
void ushot_host_pointer_up(UShotHostApp *app, float x, float y, uint32_t button);
void ushot_host_pointer_leave(UShotHostApp *app);
void ushot_host_scroll(UShotHostApp *app, float x, float y, float dx, float dy);

/* `key_code` is the shell's own key code (AppKit `keyCode`); `characters` is
 * the text the key produced with modifiers ignored (may be NULL). */
void ushot_host_key_down(UShotHostApp *app, uint32_t key_code,
                         const char *characters, uint32_t modifiers);
void ushot_host_key_up(UShotHostApp *app, uint32_t key_code,
                       const char *characters);
void ushot_host_text(UShotHostApp *app, const char *utf8);
void ushot_host_modifiers(UShotHostApp *app, uint32_t bits);

/* Input-method event. kind: 0 enabled, 1 disabled, 2 preedit, 3 commit.
 * For preedit, sel_start / sel_end are byte offsets, or -1 for none. */
void ushot_host_ime(UShotHostApp *app, uint32_t kind, const char *text,
                    int32_t sel_start, int32_t sel_end);

#ifdef __cplusplus
}
#endif

#endif /* USHOT_HOST_H */
