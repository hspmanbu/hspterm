# HSPTerm patch to russh-sftp 3.0.1

Original source is the published 3.0.1 crate, retaining its license and attribution.

`File::set_read_ahead(false)` disables speculative reads for a single file handle.
The next read requests at most the caller ReadBuf length and keeps only one request
in flight. Set it before the first read; already submitted requests cannot be undone.
The default stays unchanged for existing callers. HSPTerm downloads use this mode
so their shared content-byte budget gates actual SFTP READ requests, not just
consumption of the upstream 16-packet prefetch cache. Upload writes/flush and all
other protocol behavior remain unchanged. This is not TCP/SSH packet accounting.

Keep the patch small and reassess upstream API support on upgrades. Regression:
`cargo test -p hspterm-ssh-core --test openssh real_sftp_jobs_share_a_directional_content_budget`
and the in-memory SFTP read-budget test in ssh-core's integration suite.

Rust 1.99 renamed AtomicU64::fetch_update to try_update; use the equivalent name
to keep this local dependency warning-free with the pinned toolchain.


`SftpSession::read_dir_stream` / `ReadDirStream` enumerate exactly one READDIR
response per `next_page`, without materializing an entire directory or prefetch.
EOF/explicit close awaits server acknowledgement; drop queues a best-effort CLOSE
as File does. Packet-size limits bound each response. Dot entries are returned to
the caller. The original read_dir API and its iteration order stay unchanged. Its collector
now uses VecDeque::push_front instead of copying every previous page on each
response, reducing accumulation from quadratic to amortized linear work; it
also uses the stream close guard on error/cancellation.
HSPTerm's directory-transfer scanner releases page attributes immediately and
bounds retained names by the remaining manifest/frontier capacity. Tests:
`cargo test -p hspterm-ssh-core --test sftp_directory` covers lazy consumption,
early drop, EOF close, failed close, full multi-page scan and cancellation.

`SftpSession::supports_posix_rename` / `posix_rename` expose the OpenSSH
replacement extension separately from ordinary non-overwriting `rename`.
Only an advertised version exactly `1` enables requests. Missing/unknown versions
return `Ok(false)` without an operation; an enabled request returns `Ok(true)`
only after its successful STATUS, with permission/unsupported/unexpected-packet
errors propagated. There is no implicit remove, ordinary-rename fallback or
remote shell execution. Existing rename behavior stays unchanged.
The wire payload follows the upstream [OpenSSH PROTOCOL §4.3](https://github.com/openssh/openssh-portable/blob/master/PROTOCOL):
two SSH strings, old path followed by new path. Sources retain original line
endings and licenses. Reassess upstream support before dependency upgrades.
Regression: `cargo test -p hspterm-ssh-core --test sftp_rename --locked` checks
negotiation, independently decoded special-character paths, exact STATUS errors,
unexpected responses and delayed acknowledgement; `cargo test -p hspterm-ssh-core
--test openssh posix_rename --locked` exercises actual OpenSSH replacement,
non-overwriting standard rename and failure preservation. This protocol API does
not by itself implement remote editor state, cache recovery or edit uploads.


2026-11-02 unverified source continuation: `client::lifecycle` records actual
local read/write worker retirement with drop guards. `SftpSession::close()` now
requests stop and waits within the configured request timeout for both owned
halves to release their IO. A timeout is not retirement; an already closed
sender still waits for both workers. This is NOT an SSH peer ChannelClose ACK
or a successful SFTP file CLOSE. File completion still needs its own STATUS.
Cancellation also governs an in-flight stream write/shutdown, rather than only
waiting for the next queue entry. Existing public low-level run functions keep
the same signatures; RawSftpSession uses an internal tracked runner.

`client::error::ConnectionClosed` is a typed local channel failure. It maps to
ConnectionAborted in std IO while retaining the typed source. Protocol parse or
handler errors remain UnexpectedPacket and are explicitly dispatched to pending
requests, with a shared fixed terminal classification covering late/racing
requests. EOF must not turn a malformed packet into a retryable network error.
No matching raw error strings, printing packet bodies, credentials or server
STATUS message is added. Normal request STATUS errors are preserved. The added
closing flag rejects new requests once local stop is requested.

New product lifecycle/controlled-peer tests are in
`crates/ssh-core/tests/sftp_lifecycle.rs` and `tests/openssh_sftp_ownership/`.
They have NOT been compiled or executed. Existing budget/CLOSE/rename/edit/
publish/real OpenSSH tests remain mandatory in unified validation. Original
CRLF files keep their line endings; the new lifecycle module uses LF.


- Server test ownership: retain legacy detached run/run_with_config behavior, add run_owned/run_owned_with_config awaiting the actual service loop. Controlled fault peers now abort/await this Future, not an already-finished launcher. IO/EOF ends the service; other malformed request logs use a fixed summary. This patch and amended fixtures are source-only, not yet compiled or executed.

- Add local_io_closed() as a synchronous read of the existing two local IO completion flags. Task owners can retain failed-close sessions without polling/spawning another worker, and prune only truly retired local streams. This is not peer ChannelClose acknowledgement or file-operation success. New Bridge owner tests remain unexecuted.
