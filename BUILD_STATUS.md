# Build status — 13 November 2026

**Latest physical-device report:** The user reports a fully offline Android-to-iPhone transfer using manual hotspot joining. The supplied completion screenshot shows a 64.2 MB file, transfer time 10.47 s, 6.1 MB/s, checksum time 0.07 s, and "Verified complete". Preparation and Wi-Fi setup are excluded from the displayed speed. Exact bytes and negotiated Wi-Fi band/link rate were not captured. Automatic joining remains unresolved. This is one measured run; repeated and larger-file tests remain outstanding. See `docs/device-tests.csv`.

- Android `:app:assembleDebug`: passed on Windows, Java 17 / Gradle 8.9 / SDK 34.
- Android `:app:lintDebug`: passed, 0 errors and 28 warnings. Remaining warnings concern untranslated prototype strings and platform metadata/attributes; they are not hidden by a lint baseline.
- APK signature: verified with Android SDK apksigner (v2 signature).
- APK ZIP integrity and bundled runtime license files: checked.
- XcodeGen/workflow YAML, iOS entitlement plist, and Android manifest: parsed and checked.
- Android hosted build and lint: **passed** after correcting the CI setup's obsolete `tools` package request.
- iOS device compilation: **passed** on the GitHub macOS runner, without code signing.
- iOS pairing-validation XCTest suite: **4 tests passed, 0 failures** on a simulator. These validate QR input handling, not physical networking or certificate pinning.
- Android APK and unsigned iPhone IPA: packaged as GitHub Actions artifacts. Downloaded copies passed artifact digest and ZIP integrity checks; the iPhone bundle identifier is `org.nearbyshare.prototype`, minimum iOS 16. The IPA must be signed before installation.
- Initial device report: the A21s generated a pairing QR, but the SideStore-installed iPhone app showed a generic internal error during automatic Wi-Fi joining. This preceded the successful manual-join transfer described above.
- iPhone-to-Android, iPhone-to-iPhone, and Windows client: **not implemented in this slice**.
- No signing credential was requested or stored. Repository: https://github.com/oceandrift7/nearby-share. The checks above describe the original local build; current hosted checks appear in the repository's Actions tab.

Android APK SHA-256: `ba010f6a4f60397ff1cad8e1208da29ee99dbc3e4e3380a2907c0201df0f6360`

This is an early prototype with one measured offline transfer. Next checks: repeatability, larger files, and connection diagnostics to explain the current speed. Automatic joining remains unresolved.

Hosted evidence:

- [iPhone build and four passing tests](https://github.com/oceandrift7/nearby-share/actions/runs/43351314808/job/131642786151)
- [Android hosted build and lint](https://github.com/oceandrift7/nearby-share/actions/runs/43351554816/job/131643556869)
- [Build artifacts and current checks](https://github.com/oceandrift7/nearby-share/actions/runs/43351884679)

## Version 0.1.1 recovery work

Inspection of the original 0.1.0 IPA confirmed that its executable did not request the Hotspot Configuration entitlement, despite the entitlement being declared in the source project. SideSign reads requested entitlements from Mach-O (https://github.com/SideStore/SideSign/blob/main/Sources/Models/AppBundle.swift). This packaging gap is a plausible contributor to the automatic-join failure; the final installed signature/profile was not inspected, so it is not a confirmed sole root cause.

The updated package embeds and checks requested hotspot entitlement metadata before re-signing. It still needs valid Apple signing/provisioning for installation. The receiver adds a manual Settings Wi-Fi join path that retains TLS pinning and authorization, plus error domain/code and phase diagnostics. Automatic joining remains unresolved; manual joining subsequently enabled the reported transfer after the Android TLS repair.

Version 0.1.1 validation: device compilation passed, and six simulator tests passed with zero failures (https://github.com/oceandrift7/nearby-share/actions/runs/43357508843). The final packaging job passed its entitlement assertion; independent inspection of the downloaded IPA's Mach-O confirmed the requested capability is present (https://github.com/oceandrift7/nearby-share/actions/runs/43357708673). Artifact ZIP digest and archive integrity were checked.

## Android 0.1.2 TLS repair

The device retest with iPhone 0.1.1 showed automatic Wi-Fi joining still failing with NEHotspotConfigurationErrorDomain code 8. After taking the manual Settings route, sender inspection failed with NSURLErrorDomain -1200 (TLS). These are separate stages; the screenshot alone does not identify the TLS root cause.

Code inspection found the original Android RSA key lacked the permissions needed for pre-hashed TLS signing. The new identity uses Keystore P-256 with DIGEST_NONE and SHA256, and a key manager restricted to the new alias. This avoids accidentally reusing the old RSA key on an upgrade. The app checks pinned TLS 1.2 and 1.3 plus authenticated HTTP against its running server before issuing the QR, and closes the server if setup fails. iPhone source and the wire protocol are unchanged.

Validation for commit `38f7454f8f69119ce31cb78dde9d30d281d3dec5`:

- Local APK and instrumentation-test APK compilation passed. Local lint passed with 0 errors and 32 warnings.
- Hosted Android APK build and lint passed.
- All 6 instrumented tests passed on Android 10 / API 29, and all 6 passed on Android 12 / API 31. The tests reproduced the original RSA key's TLS 1.2/1.3 handshake failures; the corrected key completed both protocols and authenticated HTTP. A mismatched certificate was rejected, and reopening the identity with a legacy RSA alias present retained the correct certificate.
- Downloaded GitHub APK: artifact digest and ZIP integrity checked, APK v2 signature verified, package version 0.1.2-prototype / code 3 confirmed. APK SHA-256: `be14fd7bb4cd57a8934bd09dc79060e5ea4a733381e0f59f4d55b0d939720217`.
- The new hosted APK's debug signer differs from the earlier GitHub APK; uninstall the earlier prototype before installing this one. Original system-picker photos are unaffected.

Evidence: [Android 10 TLS tests](https://github.com/oceandrift7/nearby-share/actions/runs/43360128255/job/131671375044), [Android 12 TLS tests](https://github.com/oceandrift7/nearby-share/actions/runs/43360128255/job/131671375231), [hosted build](https://github.com/oceandrift7/nearby-share/actions/runs/43360128255/job/131671374958).

These tests reproduce and repair a concrete sender defect on Android emulators. Subsequent reports confirm a small JPEG transfer and the measured offline transfer recorded above. iPhone 0.1.1 remains compatible. The observed 6.1 MB/s is a single-run baseline; repeated-session reliability, larger-file performance, and automatic joining still require validation.
