# Hosted transfer checks — 14 November 2026

Run: https://github.com/oceandrift7/nearby-share/actions/runs/43635973419

Source commit: ad0a7c7c85764de0b026d900bc3249bf046d649b

Android build/lint passed. All 19 tests passed on each Android 10/API29 and Android 12/API31 emulator. All 27 iOS simulator tests passed. Downloaded measurement artifacts passed their published SHA-256 digest and ZIP integrity checks.

Each benchmark transferred 67,108,864 bytes (64 MiB), with real TLS and verified file saving. These are one-run loopback measurements on hosted machines, not phone-to-phone Wi-Fi results or an end-to-end Android/iPhone pairing test.

| Tested path | Seconds | MB/s | Verification |
|---|---:|---:|---|
| Android 10 production receive server | 0.460 | 145.9 | Complete size/hash verified; saved to disk |
| Android 12 production receive server | 0.394 | 170.5 | Complete size/hash verified; saved to disk |
| iPhone simulator production download delegate | 1.024 | 65.6 | Complete size/hash verified; checksum took another 0.052 s |

Android timing includes TLS connection, streaming hash, disk save and acknowledgement. iOS reports transfer and subsequent checksum separately. Timers and hardware differ, so rows are not a platform performance ranking. Results do not imply that these rates are achievable on the user's phones or explain their exact radio bottleneck.

## Functional checks

- Explicit Android acceptance and rejection, stale approval isolation and completed-offer replay rejection.
- Wrong pairing authorization and wrong certificate rejection.
- Corrupt hashes, truncated uploads, cancelled uploads and low-storage rejection.
- Real HTTPS corrupt/truncated downloads through the production iPhone delegate leave no completed file.
- Metadata size bounds, pairing destination validation, snapshot integrity and receipt verification.

This is a functional and targeted security regression pass, not a comprehensive penetration test. Broad malformed-request fuzzing, concurrency/resource-exhaustion tests, dependency review and other attack classes remain outstanding. Camera-driven pairing UI, hotspot behavior, distance, internet outages, backgrounding and physical network switching are outside these hosted checks. Resume and network migration remain unimplemented.

The user separately reported iPhone0.2.1/Android0.2.0 verified physical transfers: 64,184,769 bytes in 10.178 s (6.306 MB/s), plus 34,770,027 bytes in 158.422 s (0.219 MB/s) on distant home Wi-Fi. Those real-phone observations remain the relevant physical baseline; no speed increase is claimed here.

## Controls

See [TEST-CONTROLS.md](TEST-CONTROLS.md). From the repository's Actions workflow page, choose Run workflow, main, and 8/64/256 MiB. Watch logs, cancel runs, and download benchmark artifacts. Only the default 64 MiB option was executed in this pass; the other sizes are selectable but not yet measured. No phone reinstall is required for these tests.
