# Build status — 12 November 2026

- Android `:app:assembleDebug`: passed on Windows, Java 17 / Gradle 8.9 / SDK 34.
- Android `:app:lintDebug`: passed, 0 errors and 28 warnings. Remaining warnings concern untranslated prototype strings and platform metadata/attributes; they are not hidden by a lint baseline.
- APK signature: verified with Android SDK apksigner (v2 signature).
- APK ZIP integrity and bundled runtime license files: checked.
- XcodeGen/workflow YAML, iOS entitlement plist, and Android manifest: parsed and checked.
- iOS compilation: **not run**; requires the configured GitHub macOS build or an Apple toolchain.
- iOS pairing-security XCTest suite: written, **not run**; included in GitHub workflow.
- Installation, local hotspot interoperability, certificate pinning on physical devices, received-file verification, and speed benchmarks: **not run**. No physical Android device was connected.
- iPhone-to-Android, iPhone-to-iPhone, and Windows client: **not implemented in this slice**.
- No signing credential was requested or stored. Repository: https://github.com/oceandrift7/nearby-share. The checks above describe the original local build; current hosted checks appear in the repository's Actions tab.

Android APK SHA-256: `ba010f6a4f60397ff1cad8e1208da29ee99dbc3e4e3380a2907c0201df0f6360`

This is a source prototype with a compiled Android sender, not a validated cross-platform release. Build success does not establish radio interoperability or performance. Next step: run the GitHub iOS compilation/test job, configure signing, then test A21s → iPhone offline.
