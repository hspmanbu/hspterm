# HSPTerm history paging extension

Upstream alacritty_terminal 0.26.0, Apache-2.0, retained with its license and tests.

The opt-in `hspterm-history` feature adds immutable application-owned `RowBacking`
objects and a bounded decoded viewport cache. The application supplies compression,
authenticated encryption, temporary file lifecycle and checked I/O fault handling.
Rows are materialized when edited; ring resets avoid reading discarded cold rows.
Serialization includes the actual cells, not page references. The original ANSI,
Unicode width, grid rotation and Reflow algorithms remain in use. Storage::swap
uses the safe Vec swap instead of an unsafe assumption about Row's byte layout.

Application checkpoints occur outside parser/grid borrows. Index cannot return an
I/O error: the backing latches faults, and HSPTerm checks them before publishing a
frame or accepting more output. Placeholder cells from a failed read must never
be published as a valid frame. Search/export read owned rows without filling the
terminal's viewport cache. Search snapshots share immutable cold records and do
not retain SSH credentials. Old encrypted segments disappear when their final
row reference is released; only the runtime key can decrypt them.

Tests: `cargo test --manifest-path vendor/alacritty_terminal/Cargo.toml --features
hspterm-history --lib --target-dir target --locked` plus term-core tests comparing
paged and memory-only Unicode/wide/combining Reflow, scrolling and plain export.
Reassess this extension when upgrading upstream; do not edit the Cargo registry.

The resize observer pages completed rows incrementally; it does not change the
original reflow/cursor/wrap decisions. Full-screen output scroll counters support
the new-output indicator even at the retention cap. XTerm modifyOtherKeys state
and queries are exposed to HSPTerm's input encoder. Kitty stack overflow evicts
its own oldest entry (upstream incorrectly removed a window title).

Passive OSC 7 is forwarded as WorkingDirectory(Option<String>), redacted in Debug.
Alternate-screen transitions, RIS and reports inside alternate screen invalidate
this context. swap_alt requires EventListener for this typed notification.
term-core consumes the event into session-local bounded metadata, never text or
platform side effects; the upstream terminal tests are retained.

Passive ShellMarker events contain no command text. Reports in alternate screen
and alternate transitions/RIS invalidate the passive context; term-core consumes
these events locally, without a platform request or a change to terminal cells.

OSC8 URI/id are bounded before retention (4096/1024 UTF-8 bytes). An oversized
URI retains an empty non-None hyperlink attribute to suppress unsafe activation
of a deceptive label; the real OSC8 close remains None. Oversized id is ignored
in favor of the normal generated identity. No URI is emitted to trace logs. The
text/grid geometry and raw SSH output are unchanged; term-core hyperlinks tests
cover cold history, reflow, chunk boundaries, overwrite/reset and rejected targets.

Scroll::Delta and PageUp use saturating offset arithmetic. Repeated i32::MAX
scroll deltas from an already-scrolled viewport previously overflowed in debug
and wrapped incorrectly in release. Term-core cold-link/reflow tests exercise
both extreme directions without reducing the requested delta.
