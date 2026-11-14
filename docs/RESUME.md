# Android-to-iPhone pause and resume — 0.3.0

Android sends bounded HTTPS byte ranges, authenticated with the existing pairing token and exact-file SHA-256 ETag precondition. iPhone commits completed 1 MiB pieces to private Application Support storage. Checkpoint identity includes the scanned sender certificate, expected full-file hash and total size; neither credentials nor network addresses are stored. A response must have the exact 206 status, Content-Range and ETag requested. The full file is verified before being moved into Documents.

The user can Pause, Resume, Cancel and discard, discard the current checkpoint, or discard all incomplete downloads. A dropped connection retains completed pieces. A reopened client can re-pair, inspect the same file and resume. An unfinished piece is downloaded again; committed pieces are reused. If the final hash is wrong, saved progress is discarded and the file must start again. A pause arriving after verified completion keeps the completed file.

Only Android-to-iPhone downloads support resume in this release. iPhone-to-Android upload remains a one-shot transfer. Older Android senders continue using the legacy full-download path. Keep both apps open for transfers; background transfer execution is not guaranteed. Checkpoints are excluded from backup, persist across normal app restarts, and are deleted when the app is uninstalled or when the user discards them.

Connection repair is manual: rejoin the available local network and retry. If Android sharing was restarted, reselect the same unchanged file, scan its fresh pairing code and inspect again. Old pairing tokens are not reused. Automatic discovery and automatic migration between Wi-Fi networks are not implemented. Actual phone reconnection and app-restart tests remain required.

Transfer speed reports bytes sent during the current attempt divided by that attempt's elapsed time, including checkpoint writes; the final checksum is separate. Reused bytes are listed separately to avoid inflated speed claims. Partial-download checkpoints remain private and cannot be opened as completed files.

## Validation

Final source commit `9cabf18ff5341b78e5c88e3b83d173c01e612887`, [successful run 43651979691](https://github.com/oceandrift7/nearby-share/actions/runs/43651979691): Android build/lint, **26 tests on each API29/API31**, iOS device build, and **40 iOS simulator tests** passed with zero failures. Tests include production Android range reconstruction and headers, unchanged full downloads, current authorization/file preconditions, persistent checkpoint restoration, interrupted active chunk/pause/reconnect, final hash rejection, and wrong/ignored range rejection. A fresh client/session restored a checkpoint from disk after an actual truncated TLS response; no full camera-driven cross-platform or physical app-restart test is claimed.

Both downloaded package artifact SHA-256 and ZIP checks passed. APK v2 signature verifies; IPA version/entitlement inspection confirms 0.3.0/build9 and requested capability metadata. SideStore signing is still required. No paid account or automatic hotspot capability is needed for the Camera/Settings flow.

- APK SHA-256: `e15632e4fe1b59132b83d9b8ce532a0d0a040422d56940f276d8669b217a0e77`.
- IPA SHA-256: `9b09c1862b65332bd823a028475acd735c5f283d9de43073fab8929df8af4bd9`.

The final 64 MiB simulator benchmark verified the resumable path in **1.573 s / 42.662 MB/s**, plus **0.052 s** final checksum; **63 of 64 range requests reused connections**. The same hosted run's legacy path measured 0.138 s / 487.267 MB/s plus 0.060 s checksum. Checkpointing adds software/file-I/O overhead; these loopback timings are not physical phone throughput or a promise of unchanged phone speed. The initial fixture used HTTP/1.0 and forced fresh connections per piece (6.864 MB/s); it was corrected to persistent HTTP/1.1 to match the Android server. An idle/preconnected TCP client is also verified not to block the TLS fixture's listener. Physical speed, hotspot reconnection and app-restart checks remain outstanding.
