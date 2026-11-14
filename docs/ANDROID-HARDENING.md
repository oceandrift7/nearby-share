# Android 0.2.1 hardening

Two code-review findings addressed:

1. Android JSONObject getters coerce values: a fractional size can become an integer and a text size can become a number. Incoming offers now require text name/hash fields and an actual integer size before creating an offer. Existing size, filename, hash and storage bounds remain enforced.
2. NanoHTTPD's default runner creates a thread for each accepted connection. The server now admits at most eight active handlers, with no waiting queue, and closes excess connections. This limits connection-driven thread growth before authentication. It does not guarantee availability under a sustained local-network flood: an attacker can still occupy the permitted slots. Existing socket idle timeouts apply.

New tests exercise malformed/coercible metadata, deterministic malformed-object cases, old-session authorization across all incoming endpoints, chunked/mismatched upload lengths, idle connection saturation and recovery. The coercion test demonstrates the legacy getter behavior directly. This is targeted hardening, not a claim of a completed penetration test. Broader protocol fuzzing, parser ambiguity, sustained resource attacks and physical-radio behavior remain untested.

Final hosted run [43637607105](https://github.com/oceandrift7/nearby-share/actions/runs/43637607105), code commit `28ece849e47e3bd00c7005adb3b31e419d99d302`: Android compilation/lint passed; all **23 tests passed on each API29/API31**; all **27 iOS simulator tests passed**. New Android checks include 87 malformed/coercible metadata cases and recovery after eight idle clients fill the connection cap. Existing 64 MiB verified TLS uploads passed (hosted loopback 185.9/234.1 MB/s; these are not physical Wi-Fi rates or proof of a speed improvement).

APK artifact digest/ZIP and v2 signature checks passed. Package version is 0.2.1/code8. APK SHA-256: `e007c0f78ff3eb918c7d7bc568258b328f7b3998ebcb3e449ee075dd9f9fcde5`. Keep the existing iPhone 0.2.1 installation. Physical cross-platform transfer with the new Android cap still needs testing.
 Existing iPhone 0.2.1 remains compatible. No new iPhone install is needed. Android package version is 0.2.1/code8. If a changed debug signer requires uninstall, export saved incoming files first.

Implementation reference: [NanoHTTPD 2.3.1 default runner and client handling](https://github.com/NanoHttpd/nanohttpd/blob/nanohttpd-project-2.3.1/core/src/main/java/fi/iki/elonen/NanoHTTPD.java). The cap replaces its thread-admission behavior; TLS pinning, bearer authorization and per-file acceptance still apply.


The first iOS attempt had one five-second timeout on its initial loopback HTTPS request (26 other tests passed). The iOS job alone was rerun without code changes or disabled checks; all 27 tests then passed. The intermittent first-request failure remains a test-reliability concern; its exact cause is not established. The retry measured 18.6 MB/s for the verified 64 MiB simulator download with another 0.425 s for checksum; hosted timing varies substantially.
