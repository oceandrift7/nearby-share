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
- Initial device report: the A21s generated a pairing QR, but the SideStore-installed iPhone app showed a generic internal error during automatic Wi-Fi joining. No completed file transfer or speed measurement has been demonstrated.
- iPhone-to-Android, iPhone-to-iPhone, and Windows client: **not implemented in this slice**.
- No signing credential was requested or stored. Repository: https://github.com/oceandrift7/nearby-share. The checks above describe the original local build; current hosted checks appear in the repository's Actions tab.

Android APK SHA-256: `ba010f6a4f60397ff1cad8e1208da29ee99dbc3e4e3380a2907c0201df0f6360`

This is a compiled source prototype, not a validated cross-platform release. Build success does not establish radio interoperability or performance. Next step: configure iPhone signing, install the apps, then test A21s → iPhone offline.

Hosted evidence:

- [iPhone build and four passing tests](https://github.com/oceandrift7/nearby-share/actions/runs/43351314808/job/131642786151)
- [Android hosted build and lint](https://github.com/oceandrift7/nearby-share/actions/runs/43351554816/job/131643556869)
- [Build artifacts and current checks](https://github.com/oceandrift7/nearby-share/actions/runs/43351884679)

## Version 0.1.1 recovery work

Inspection of the original 0.1.0 IPA confirmed that its executable did not request the Hotspot Configuration entitlement, despite the entitlement being declared in the source project. SideSign reads requested entitlements from Mach-O (https://github.com/SideStore/SideSign/blob/main/Sources/Models/AppBundle.swift). This packaging gap is a plausible contributor to the automatic-join failure; the final installed signature/profile was not inspected, so it is not a confirmed sole root cause.

The updated package embeds and checks requested hotspot entitlement metadata before re-signing. It still needs valid Apple signing/provisioning for installation. The receiver adds a manual Settings Wi-Fi join path that retains TLS pinning and authorization, plus error domain/code and phase diagnostics. Hardware validation of either recovery path is pending.

Version 0.1.1 validation: device compilation passed, and six simulator tests passed with zero failures (https://github.com/oceandrift7/nearby-share/actions/runs/43357508843). The final packaging job passed its entitlement assertion; independent inspection of the downloaded IPA's Mach-O confirmed the requested capability is present (https://github.com/oceandrift7/nearby-share/actions/runs/43357708673). Artifact ZIP digest and archive integrity were checked. The user can keep the existing Android sender for this retry.
