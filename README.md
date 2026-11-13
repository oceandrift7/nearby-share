# Nearby Share — offline transfer prototype

Early source prototype for a free, open-source nearby file-sharing app. The name is temporary. No ads, analytics, accounts, or file-upload servers.

**Implemented slice:** Android offers one selected file over a local-only Wi-Fi hotspot and pinned HTTPS; iPhone scans a QR code, asks to join, previews the file, and downloads it to disk with SHA-256 verification. It displays download speed and verification time separately.

**Not implemented:** iPhone sending, iPhone-to-iPhone, Windows client, resume, trusted-device memory, background transfers, multiple files, or automatic discovery. This is not a SHAREit replacement yet. No throughput claims are established. Android builds and lint pass, the iPhone app compiles, and six pairing-validation/diagnostic tests passed on an iOS simulator. Real-device transfer tests remain required.

## How the first device test works

1. Install the Android debug APK on the A21s (the A6 is the next compatibility test).
2. Install a properly signed iPhone build. The iOS bundle identifier is currently `org.nearbyshare.prototype`; adapt it to an identifier registered with your Apple developer team. Enable Hotspot Configuration for that identifier/profile.
3. Disable mobile data on both phones and disconnect from the home router. Keep Wi-Fi enabled. On Android 10–12, hotspot creation may also require Location enabled and the requested permission; the app does not read coordinates.
4. On Android, choose a small, non-sensitive file. The app snapshots it in private cache and hashes it before offering it. This preparation requires additional disk space equal to the file size.
5. On iPhone, scan the code in the prototype app, choose **Join and inspect file**, approve Wi-Fi and Local Network prompts, then choose **Accept and receive file**.
6. Wait for **Verified complete**, record the speed, and use **Save or share received file**. Files also appear under On My iPhone → Nearby prototype.
7. Stop sharing on Android and disconnect on iPhone. Stop invalidates the old code and deletes the sender's private snapshot. Received files remain until manually deleted.

Keep both apps in the foreground and both screens awake. Do not share screenshots of the pairing code: it includes temporary Wi-Fi credentials and authorizes downloading the selected file. This prototype uses possession of the scanned code as sender consent, rather than a second prompt on Android. Select only the file you intend to offer. Stop sharing when finished. This is a functional test build, not a security-audited release.

### If iPhone joining fails

Version 0.1.1 shows the failing phase, error domain and code. An automatic Wi-Fi join failure happens before file inspection; it does not establish that the JPG is faulty. Automatic joining requires the Hotspot Configuration entitlement in the final signature and compatible provisioning profile, not just the source project. A generic internal error alone does not identify the cause.

Expand **Join Wi-Fi manually if automatic joining fails** on iPhone, reveal the temporary password, and join the displayed network in Settings → Wi-Fi. Stay connected despite the lack of internet, then return and tap **I joined in Settings — inspect file**. This skips the automatic join API only; certificate pinning, pairing authorization, and file-integrity verification stay enabled. Keep Android sharing throughout. If inspection still fails, record the full displayed error domain/code without sharing the QR or password.

The version 0.1.1 package preserves requested Hotspot Configuration entitlement metadata using an ad-hoc signature before packaging. SideSign reads requested entitlements from the executable, so merely declaring the capability in the source project is insufficient for a completely unsigned binary. This metadata is not an installation identity: SideStore must still re-sign with an appropriate Apple account/profile, and preservation in the final installed app remains to be verified.

## Build

Android: Java 17, Gradle 8.9, Android SDK platform/build-tools 34. From `android`, run `./gradlew :app:assembleDebug :app:lintDebug` (Windows: `.\gradlew.bat :app:assembleDebug :app:lintDebug`). The wrapper downloads Gradle on first use. The debug APK is under `app/build/outputs/apk/debug`. The local Windows build and Android lint check passed; see BUILD_STATUS.md for the remaining checks.

iOS: Swift 5 language mode, deployment target iOS 16, XcodeGen project specification under `ios/project.yml`. On macOS, run `xcodegen generate`, then open the generated project and select the developer team. Compilation without signing: `xcodebuild -project NearbyPrototype.xcodeproj -scheme NearbyPrototype -sdk iphoneos CODE_SIGNING_ALLOWED=NO build`.

The included GitHub Actions workflow builds the Android APK, compiles the iOS app, and runs pairing-validation tests on a simulator. The Actions artifacts include an **unsigned IPA that must be signed before installation** and simulator test results. Signing and installation need the developer's own certificate/profile and a separate signing setup. Never commit certificates, private keys, or provisioning profiles. xtool/WSL deployment is an alternative to evaluate; this project currently has an XcodeGen build definition, not a validated xtool build definition.

## Protocol v1

QR JSON fields: `v` (1), `ssid`, `password`, `hosts` (private IPv4 candidates), `port`, `token` (32 random bytes encoded as lowercase hex), `certificateSHA256` (SHA-256 of DER leaf certificate). The iPhone validates the QR before using it. The QR is the out-of-band trust channel.

Android serves HTTPS on port 9443 with an Android Keystore key and self-signed certificate. The receiver accepts only the certificate whose digest is in the scanned code, rejects redirects, disables URL caching, and supplies `Authorization: Bearer <token>`. The token is regenerated for each sharing session. Stopping the sender invalidates it by shutting down that server.

- `GET /manifest` → `{ "name": "example.mp4", "size": 123, "sha256": "..." }`
- `GET /file` → raw file bytes with fixed content length and `Cache-Control: no-store`.
- Other methods or missing/incorrect token → 403; unknown paths → 404.

Android's snapshot prevents changes between hashing and sending. Transfers use bounded-size buffers rather than retaining the entire file in RAM. iOS saves into its Documents folder only after verifying size and hash. Original names are sanitized and prefixed with a random ID. The HTTP server still needs profiling; this prototype is not proof that its transport reaches hardware limits.

## Measuring speed fairly

Use the same devices, file, distance, and connection conditions for this app and SHAREit. Start with a 10 MB file, then a 1 GB or larger video. Record three runs and compare medians. Do not combine sender preparation time, Wi-Fi setup, download, and checksum verification into an unexplained single number. The prototype's MB/s uses decimal megabytes (1,000,000 bytes).

Use `docs/device-tests.csv` for results. Include failure cases: reject Wi-Fi joining, deny Local Network access, cancel, stop Android during download, insufficient storage, backgrounding, and a second session after stopping. A displayed success requires matching file bytes; throughput alone is not a pass.

## License and dependencies

Prototype source is MIT licensed. NanoHTTPD 2.3.1 uses BSD-3-Clause; ZXing 3.5.3 uses Apache-2.0. Their transitive dependencies and notices must be reviewed and included before public binary distribution. There is no affiliation with SHAREit, Apple, Samsung, or LocalSend.
