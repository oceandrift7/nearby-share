# Android-to-iPhone pause and resume — 0.3.0

Android sends bounded HTTPS byte ranges, authenticated with the existing pairing token and exact-file SHA-256 ETag precondition. iPhone commits completed 1 MiB pieces to private Application Support storage. Checkpoint identity includes the scanned sender certificate, expected full-file hash and total size; neither credentials nor network addresses are stored. A response must have the exact 206 status, Content-Range and ETag requested. The full file is verified before being moved into Documents.

The user can Pause, Resume, Cancel and discard, discard the current checkpoint, or discard all incomplete downloads. A dropped connection retains completed pieces. A reopened client can re-pair, inspect the same file and resume. An unfinished piece is downloaded again; committed pieces are reused. If the final hash is wrong, saved progress is discarded and the file must start again. A pause arriving after verified completion keeps the completed file.

Only Android-to-iPhone downloads support resume in this release. iPhone-to-Android upload remains a one-shot transfer. Older Android senders continue using the legacy full-download path. Keep both apps open for transfers; background transfer execution is not guaranteed. Checkpoints are excluded from backup, persist across normal app restarts, and are deleted when the app is uninstalled or when the user discards them.

Connection repair is manual: rejoin the available local network and retry. If Android sharing was restarted, reselect the same unchanged file, scan its fresh pairing code and inspect again. Old pairing tokens are not reused. Automatic discovery and automatic migration between Wi-Fi networks are not implemented. Actual phone reconnection and app-restart tests remain required.

Transfer speed reports bytes sent during the current attempt divided by that attempt's elapsed time, including checkpoint writes; the final checksum is separate. Reused bytes are listed separately to avoid inflated speed claims. Partial-download checkpoints remain private and cannot be opened as completed files.

Validation pending: production Android range reconstruction and authorization; persistent checkpoint restore/tail truncation; pause and connection loss through real TLS on an iOS simulator; wrong-range/wrong-file/ignored-range rejection; corrupted saved data and final integrity failure; legacy transfer compatibility; resumable-path speed measurement. These are component tests against the production transfer code, not a full camera-driven cross-platform UI test.
