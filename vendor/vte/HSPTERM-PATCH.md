# HSPTerm local patch

Upstream: vte 0.15.0, https://github.com/alacritty/vte (MIT OR Apache-2.0).
Original license texts are retained. All upstream files were taken from the crates.io package.

The std parser's OSC Vec otherwise grows without a limit. This patch caps its raw payload at 14 MiB (enough for base64-encoded 10 MiB OSC52 content), ignores an oversized OSC as a whole, resumes at the protocol terminator, and releases oversized scratch capacity afterward. It does not rewrite valid terminal output. Non-std behavior is unchanged.

The additional unit test checks bounded memory, no partial OSC dispatch, terminator recovery and later valid dispatch. Re-evaluate/remove this patch when upgrading to upstream support for equivalent bounded OSC parsing.

The ANSI dispatcher also recognizes XTerm `CSI > 4 n` to disable modifyOtherKeys,
using the existing typed handler; set/query parsing remains upstream behavior.
The term-core protocol tests cover disable/query and subsequent legacy input.

Fix partial UTF-8 continuation consuming trailing undispatched ASCII: in the
`valid_up_to > 0` branch, only the first codepoint is emitted, so the consumed
count must be its UTF-8 length minus the saved prefix length, not the entire
valid prefix. Otherwise e.g. a split combining accent + space + emoji loses the
space. The regression compares every two-chunk split through both advance APIs.
Term-core also asserts exact logical Unicode export through cold history/reflow;
no chunk-alignment workaround or output rewriting is used.

HSPTerm passive OSC 7 uses a typed optional working-directory handler. The URI
argument preserves literal semicolons without truncation at the OSC parameter
array limit, and is bounded before allocation. Only OSC 7 defers ESC termination
until the following backslash; CAN/SUB/other escape cancellation invalidates it.
A whole oversized OSC dispatches a payload-free discard callback to invalidate
stale passive metadata; no partial URI is accepted. Other OSC dispatch behavior
is unchanged. term-core/tests/working_directory.rs exercises every split, long
URIs, cancellation, synchronized output and recovery; upstream parser tests remain.

Passive OSC 133 has a typed marker carrying only a phase or optional u8 exit
status. Command-text properties are never copied/logged. Complete ST and abort
handling is shared with OSC 7; parameter overflow discards the whole semantic
OSC rather than adopting a truncated marker. Other OSC behavior is unchanged.
See term-core/tests/shell_context.rs and SHELL_INTEGRATION.md for conservative
unsupported-property behavior and phase-only limitations.

OSC8 now also waits for complete ST or BEL, with a separate payload-free discard
callback. CAN/SUB/invalid ESC/overflow cannot commit a partial URI or silently
retain the old active target; rejected targets block label auto-detection. URI
semicolons after its two structural separators stay literal, avoiding truncation
at the 16-parameter array. ANSI dispatch validates UTF-8 and bounds URI/id before
allocating (4096/1024 bytes); the OSC52 raw budget is unchanged. Existing generic
discard and OSC7/133 context behavior is unchanged. Term-core hyperlinks tests
cover every split, 40 URI semicolons, aborted sequences and invalid UTF-8.
