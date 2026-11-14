# Build status — 14 November 2026

## Version 0.2.0 — approved iPhone-to-Android transfers

Adds native iPhone file selection/snapshot preparation and disk-backed HTTPS upload; Android receive mode, per-file acceptance/rejection, streaming size/hash verification, final acknowledgement, and persistent verified-file export. Existing Android-to-iPhone flow remains available. Also adds free-space checks, cancellation during snapshot/hash loops, bounded iOS metadata reads, a shorter repeated-address probe budget, and Android rotation handling. Background survival and stable release signing remain outstanding.

Build/test validation is in progress. Automated checks are not a physical device test and establish no new throughput result. The last physical hotspot measurement remains 6.380 MB/s in the Android-to-iPhone direction. Keep both apps in the foreground; restart interrupted transfers from the beginning. Export Android received files before uninstalling any prototype.


## Version 0.1.5 — native visual update

Adapted the supplied visual reference to SwiftUI and native Android widgets: blue connection card, pale background, rounded surfaces and clearer file/progress typography. No sample peer devices or simulated transfers are shown. Transport behavior is unchanged. Hosted Android compilation/lint and iOS device compilation/packaging passed. All **10 Android tests passed on each of Android 10/API29 and Android 12/API31**; all **17 iOS simulator tests passed with zero failures**. Final workflow commit `a8635d87306dfa20efd8812d1c578046dd78784b`: [build, test and preview evidence](https://github.com/oceandrift7/nearby-share/actions/runs/43526869013). Native first-screen captures from both platforms were inspected. The first preview attempts exposed automation issues (Android test uninstall and a shutdown iOS simulator), corrected by installing/booting explicitly. Earlier screenshot failures were not failed functional tests.

The current Windows-local Gradle attempt could not connect to its daemon; validation uses the hosted builds above. Downloaded APK/IPA artifacts passed SHA-256/ZIP checks, APK signature verification and IPA version/entitlement inspection. Version is 0.1.5/build 6. Requested entitlement metadata still requires SideStore re-signing and does not enable an absent capability. The APK debug signer differs from the preceding build, requiring uninstall of the older Android prototype.

This is a first visual adaptation, not a complete reproduction of the demo or a throughput optimization. Android uses native platform widgets; iPhone uses SwiftUI. The preview shows actual initial UI, not physical transfers. Physical-device review, large text, dark mode and mid-transfer visual review remain outstanding. No new throughput measurement is claimed.


- Android package SHA-256: `8354e2de84f93f46ee79e53d7f303b65cdc49bd4aa998140f4a28df8455760a6`.

- iPhone package SHA-256: `224e6a31135c44a45a30e16b674521ec17bf39f83df9b243d108471118758525`.

## Version 0.1.4 — Camera/Settings connection and sender read measurements

Implemented two Android QR steps (system Wi-Fi code, secure Nearby pairing code), current-connection-first iPhone flow, and suppression of automatic join when the embedded profile reports the capability missing. The Settings fallback remains available. Added bounded per-download sender read timing and optional receiver collection after file verification. TLS pinning, authorization, and SHA-256 verification remain enabled. No physical speed improvement is claimed.

Validation at commit `94f8313fb6fa6a0c54740ae713c5559e11f70bae`: local Android app/test compilation and lint passed (0 errors, 34 warnings). Hosted Android build/lint and iPhone device compilation/packaging passed. All **10 Android tests passed on each of API 29 and API 31**, and all **17 iOS simulator tests passed with zero failures**. [Build/test evidence](https://github.com/oceandrift7/nearby-share/actions/runs/43476994887).

The new tests exercise QR image decoding with escaped credentials, partial/bounded stream measurement, production HTTP response lifecycle and authorization, missing-capability policy, wrong-code guidance, and invalid/partial timing reports. The new Camera route still requires a physical iPhone test; the previous manual Settings route has device evidence below.

Downloaded artifacts passed their GitHub SHA-256 digest and ZIP integrity checks. The APK v2 signature verifies; package version is 0.1.4-prototype/code 5. IPA inspection confirms version 0.1.4/build 5 and requested entitlement metadata, which does not grant the capability after SideStore re-signing. Continue with the free-account Camera/Settings flow.

- Android APK SHA-256: `821ebc041f7f0a056b87109bd6548362a395bef16860a767d7b6c6bcde841b24`.
- iPhone IPA SHA-256: `eec3303a30595b1f36511326c53a4ed6b8697f3afe13721141518055a205d950`.

The downloaded GitHub APK signer differs from 0.1.3; uninstall the previous Android prototype before installing this build. Original selected files are unaffected. No phone throughput result is available for 0.1.4, so no speed increase is claimed.


## Version 0.1.3 physical comparison and signing diagnosis

User screenshots show verified completion of the same 105,575,757-byte file on Samsung SM-A217F (Android API 31) to iPhone (iOS 27.0.1, build 24A446), both apps 0.1.3. This corrects the earlier approximate iOS version report.

| User-reported connection | Transfer | Throughput | First byte | Response body | TLS | Checksum |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Home Wi-Fi | 246.975 s | 0.427 MB/s | 0.161 s | 246.812 s | 0.110 s | 0.094 s |
| Android hotspot, manual join | 16.547 s | 6.380 MB/s | 0.151 s | 16.392 s | 0.040 s | 0.090 s |

The hotspot run was approximately 14.9 times faster. The difference is in response-body delivery; TLS setup and checksum time are small. This does not isolate radio interference, router behavior, sender I/O, or other causes within body delivery. Actual hotspot band/channel and link speed remain unknown. No improvement over the earlier 6.1 MB/s baseline is established by this small sample. The user did not explicitly reconfirm internet availability for these two runs.

Both reports say Hotspot Configuration is missing from the embedded provisioning profile. The user confirms SideStore uses a free Apple account and explicitly clarifies there is no paid developer membership or paid signing certificate; the earlier paid-signing assumption was incorrect. Automatic joining returned code 8. On home Wi-Fi the receiver's pinned probe reached the sender through an already available private-LAN address; that is not evidence of a successful Wi-Fi switch. When not connected to the hotspot, inspection returned URL error -1009. This does not mean internet is required.

Continue with free SideStore signing and manual hotspot joining. Payment is not required to continue the demonstrated transfer workflow. Improve that connection flow and investigate throughput; do not assume paid signing resources exist. The app's XML inspection is diagnostic; the full installed signature has not been inspected. Changing joinOnce cannot grant a capability omitted by signing. Sources: [Apple entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.hotspotconfiguration), [profile/signature verification](https://help.apple.com/xcode/mac/current/en.lproj/dev298d7b2cb.html).

## Version 0.1.3 — connection flow and diagnostics

Both platform packages built successfully at commit `58719318ed3d2c114efc7b62970fbeef593bcdec`. Hosted Android lint passed; iOS device compilation and packaging passed. All **14 iOS simulator tests** passed with zero failures, and all **6 Android TLS tests** passed on each of API 29 and API 31. [Build and test evidence](https://github.com/oceandrift7/nearby-share/actions/runs/43366348363).

Downloaded artifacts passed SHA-256 and ZIP integrity checks. Android APK v2 signature verified. IPA inspection confirmed version 0.1.3/build 4 and requested Hotspot Configuration entitlement metadata; SideStore still must re-sign it for installation.

- Android APK SHA-256: `cdc4f519584ba82ba2bf2de7737c76bc08238881f3d767576ae5f6519caa43b9`.
- iPhone IPA SHA-256: `b457d787ed4f97228beebe0ea844c80625855550de317c48dafd81abda733666`.

Physical testing now confirms verified transfers, timing reports, and the missing profile capability; automatic joining remains blocked in the reported installation. Return-from-Settings and repeat-download interactions were not individually confirmed. This revision does not establish a throughput improvement. The measured 6.1 MB/s below remains the baseline. Android reports 5 GHz hardware support; its actual hotspot channel is unavailable through the public APIs on the target Android 10/12 versions. The diagnostic report marks this unknown. The hosted debug APK has a different signer from 0.1.2, so uninstall the older Android prototype before installation. Existing original files remain unaffected.

## Earlier validation and physical-device baseline

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
