# Android 0.2.1 hardening

Two code-review findings addressed:

1. Android JSONObject getters coerce values: a fractional size can become an integer and a text size can become a number. Incoming offers now require text name/hash fields and an actual integer size before creating an offer. Existing size, filename, hash and storage bounds remain enforced.
2. NanoHTTPD's default runner creates a thread for each accepted connection. The server now admits at most eight active handlers, with no waiting queue, and closes excess connections. This limits connection-driven thread growth before authentication. It does not guarantee availability under a sustained local-network flood: an attacker can still occupy the permitted slots. Existing socket idle timeouts apply.

New tests exercise malformed/coercible metadata, deterministic malformed-object cases, old-session authorization across all incoming endpoints, chunked/mismatched upload lengths, idle connection saturation and recovery. The coercion test demonstrates the legacy getter behavior directly. This is targeted hardening, not a claim of a completed penetration test. Broader protocol fuzzing, parser ambiguity, sustained resource attacks and physical-radio behavior remain untested.

Validation pending. Existing iPhone 0.2.1 remains compatible. No new iPhone install is needed. Android package version is 0.2.1/code8. If a changed debug signer requires uninstall, export saved incoming files first.

Implementation reference: [NanoHTTPD 2.3.1 default runner and client handling](https://github.com/NanoHttpd/nanohttpd/blob/nanohttpd-project-2.3.1/core/src/main/java/fi/iki/elonen/NanoHTTPD.java). The cap replaces its thread-admission behavior; TLS pinning, bearer authorization and per-file acceptance still apply.
