# HSPTerm local patch to russh 0.64.1

Original package: crates.io russh 0.64.1, Apache-2.0, original crate checksum `ba61e87b9ec9a39a59a6bbed4c0b8ff7fb07073405b24a767a1f2c8560ac8f58`. Original copyright headers are retained; LICENSE-APACHE contains the standard license text. This is a local modified copy, not an unmodified upstream release. It is selected solely by Cargo's workspace path patch; the global registry cache is unchanged. Public upstream test/examples (including published, non-production cryptographic vectors) are upstream source, never HSPTerm-generated credentials. No real/local test server credentials are included.

HSPTerm changes (2026-10-26):

- Explicit `client::Handle::channel_open_direct_tcpip_flow_controlled` API. Existing channel APIs keep their prior behavior. HSPTerm's TcpConnector opts in.
- Explicit default-false `Handler::flow_control_forwarded_tcpip` for incoming forwarded TCP. HSPTerm opts in, pairing the returned Channel with the same bounded queue/credit hook held by PendingChannelOpen before accepting. Authorization/routing stays in HSPTerm, not this protocol patch; all other default channel behavior is unchanged.
- Byte-window-bounded receive FIFO, 64KiB data coalescing, at most 128 queue items. Data/EOF/CLOSE ordering preserved; overflow/poison gives a stream error rather than truncated success. No unbounded payload queue or shared-dispatch wait on a slow consumer.
- Receive window debited on input, replenished only on actual consumption; coalesced credits go through the existing priority path, at most one queued notification per channel plus the notification being processed. Rekey deferral and channel-close cleanup use original transport ownership.
- Normal PTY, SFTP, jump channel and server APIs keep their default queue/window policy; client/server default constructors initialize the new optional state to None.
- Two unrelated feature-off warnings exposed by local vendoring are corrected without changing cryptography: prefix a PKCS5 temporary name, and compile the decompression-bound constant only for compression/tests.

Changed/new production files:

- `src/session.rs`
- `src/cipher/mod.rs`
- `src/server/session.rs`
- `src/client/encrypted.rs`
- `src/client/mod.rs`
- `src/channels/channel_ref.rs`
- `src/channels/mod.rs`
- `src/channels/flow_control.rs`
- `src/keys/format/pkcs5.rs`
- `src/channels/io/rx.rs`

The exact queue source is tested against real russh ChannelMsg in HSPTerm's `tests/receive_window.rs`; OpenSSH slow-reader/PTY responsiveness and 8MiB+17 exact fragmented reads verify real per-channel flow control and repeated window grants. See PORT_FORWARDING.md/PROGRESS.md for current test results and any in-flight validation. The original shared-dispatch stall was reproduced before this patch; increasing queue sizes is not its fix.

ACK-based heartbeat opt-in: Handle::send_ping_checked preserves the existing global-request FIFO and reports a dropped oneshot sender as an error. The existing send_ping helper and default client keepalive policy are unchanged. HSPTerm can bound response waiting independently without mistaking connection teardown for a peer ACK; a timed-out receiver leaves the FIFO entry in place so late responses do not shift another request. Tests and delivery status are recorded in PROGRESS.md; this source addition alone is not a validated heartbeat feature.

2026-10-27 RSA / Agent additions:

- ring-only `keys::RingRsaSigner`, cached `PrivateKeyWithHashAlg::try_new` preparation, SHA256/SHA512 signing; no RustCrypto `rsa` feature/dependency. Existing crypto-bigint zeroize feature prepares fixed-size CRT remainders; ring validates and signs. Private 2048–4096 bits, no SHA1 fallback; source/cache buffers are bounded/redacted. Formats and RSA host-key limitations are explicit in SSH_AGENT.md. Existing feature-rsa path for other consumers is retained when ring is off.
- `best_supported_rsa_hash` now honors its documented Some(None) result when an advertised list contains no RSA method, instead of incorrectly treating it as absent EXT_INFO.
- Exact agent-forward=0 negotiation, standard agent-req request and agent-connect channel alias, optional default-false consumption-driven Agent receive window. Existing legacy APIs remain; HSPTerm's default denied routing remains in ssh-core. Channel type does not itself authorize keys.
- Controlled-peer support: server Config defaults its new advertisement off; explicit RFC9987 advertisement/standard channel-open API and request alias permit real SSH-wire tests. No production server is added to HSPTerm. Default server behavior and unrelated flow control remain unchanged.
- Changed files additionally: Cargo.toml, src/keys/{mod,key,rsa_ring}.rs, helpers.rs, parsing.rs, client/{mod,session,encrypted}.rs, channels/mod.rs, server/{mod,session,encrypted}.rs. Original license remains Apache-2.0; new local source follows this crate license. Registry cache remains untouched.

Primary protocol source: RFC9987 §7 https://www.rfc-editor.org/rfc/rfc9987.html#section-7 ; signature flags in the same RFC. RSA dependency decision: https://rustsec.org/advisories/RUSTSEC-2023-0071.html (checked 2026-10-27). Execution/known boundaries: SSH_AGENT.md, PROGRESS.md. No test-generated private material is included in these changes.

Pressure follow-up: flow-selected writer windows now add peer ACK credit instead of resetting to the wire window, preserving queued reservations. This fixes reproduced over-reservation/global-pending stalls after Agent revoke, without removing bounded outbound admission. WindowSizeRef moved unchanged except this opt-in grant method to src/channels/send_window.rs, compiled directly by the workspace regression. Five real pressure repetitions and the full 172 core suite passed; final key-decoder follow-up tests are recorded separately. OpenSSH bcrypt derives only for rounds1..=256, and base64 private parsing scratch buffers zeroize. New parser boundary test rejects excessive work before execution; no key contents are logged.

RSA compatibility follow-up: keys::verify_signature routes RSA SHA2 verification through ring (2048–8192 public bits), preserving other key backends and RFC8332 omitted-zero signature compatibility. KEX signature identifiers must match negotiation; trust callbacks also run on rekey. HSPTerm caches its originally accepted identity, so unchanged keys do not prompt again. PKCS1/PKCS8/PBES2 and legacy AES128/256 PEM imports use bounded borrowed DER, ring CRT validation/signing, zeroized plaintext and pre-KDF resource checks. No new dependencies or RustCrypto RSA feature. New sources keys/verify_ring.rs and keys/format/rsa_der.rs retain this crate's Apache-2.0 license. Exact tests and allowed format/bit/work boundaries: SSH_RSA.md and PROGRESS.md.

Session flow follow-up: explicit channel_open_session_flow_controlled uses the same bounded receive FIFO and per-channel priority consumption credits. HSPTerm now opts its PTY and SFTP sessions into it; the original session API and jump channel remain unchanged. Unread PTY head-of-line blocking of SFTP was reproduced against real OpenSSH; the new opt-in passes 8MiB exact output verification and five repeated runs. ReceiveWindowError is surfaced at product read/request boundaries. No larger unbounded queues or global pending-gate removal. Tests/results: SESSION_FLOW.md and PROGRESS.md.

2026-11-04 unified-runtime follow-up: receiving CHANNEL_CLOSE now also recognizes an existing local channel receiver whose encrypted parameters were removed by our earlier CLOSE. This delivers the peer acknowledgement and retires the receiver instead of leaving application cleanup permits held until Transport shutdown. Unknown ids, unconfirmed opens (parameters still present with confirmed=false), and duplicate acknowledgements remain rejected. Applies to both SSH client and controlled server. Actual late-open cancellation/Root-close and SFTP ownership regressions: six passed; broader regression remains in progress (UNIFIED_VALIDATION.md).
