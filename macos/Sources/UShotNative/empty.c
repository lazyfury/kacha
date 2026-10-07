/*
 * UShotNative — the SwiftPM C target that exposes the Rust `ushot_host_*` ABI.
 *
 * The public header is the symlink beside this file (`include/ushot_host.h`),
 * which points at the one source of truth: `<repo>/include/ushot_host.h`. The
 * symbols live in the Rust static library (`libushot_app.a`) linked by the
 * executable target.
 *
 * This `.c` file only exists so SwiftPM treats the directory as a C target; it
 * defines nothing.
 */
