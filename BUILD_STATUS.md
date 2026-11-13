# Build status — 13 November 2026

- Android `:app:assembleDebug`: passed on Windows, Java 17 / Gradle 8.9 / SDK 34.
- Android `:app:lintDebug`: passed, 0 errors and 28 warnings. Remaining warnings concern untranslated prototype strings and platform metadata/attributes; they are not hidden by a lint baseline.
- APK signature: verified with Android SDK apksigner (v2 signature).
- APK ZIP integrity and bundled runtime license files: checked.
- XcodeGen/workflow YAML, iOS entitlement plist, and Android manifest: parsed and checked.
- Android hosted build and lint: **passed** after correcting the CI setup's obsolete `tools` package request.
- iOS device compilation: **passed** on the GitHub macOS runner, without code signing.
- iOS pairing-validation XCTest suite: **4 tests passed, 0 failures** on a simulator. These validate QR input handling, not physical networking or certificate pinning.
- Android APK and unsigned iPhone IPA: packaged as GitHub Actions artifacts. Downloaded copies passed artifact digest and ZIP integrity checks; the iPhone bundle identifier is `org.nearbyshare.prototype`, minimum iOS 16. The IPA must be signed before installation.
- Installation, local hotspot interoperability, certificate pinning on physical devices, received-file verification, and speed benchmarks: **not run**. No physical Android device was connected.
- iPhone-to-Android, iPhone-to-iPhone, and Windows client: **not implemented in this slice**.
- No signing credential was requested or stored. Repository: https://github.com/oceandrift7/nearby-share. The checks above describe the original local build; current hosted checks appear in the repository's Actions tab.

Android APK SHA-256: `ba010f6a4f60397ff1cad8e1208da29ee99dbc3e4e3380a2907c0201df0f6360`

This is a compiled source prototype, not a validated cross-platform release. Build success does not establish radio interoperability or performance. Next step: configure iPhone signing, install the apps, then test A21s → iPhone offline.

Hosted evidence:

- [iPhone build and four passing tests](https://github.com/oceandrift7/nearby-share/actions/runs/43351314808/job/131642786151)
- [Android hosted build and lint](https://github.com/oceandrift7/nearby-share/actions/runs/43351554816/job/131643556869)
- [Build artifacts and current checks](https://github.com/oceandrift7/nearby-share/actions/runs/43351884679)
