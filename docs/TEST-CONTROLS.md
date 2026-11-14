# Running transfer checks yourself

Open https://github.com/oceandrift7/nearby-share/actions/workflows/build.yml while signed into a GitHub account with permission to run this repository's workflows. Select **Run workflow**, choose **main**, select **8**, **64**, or **256 MiB**, and run it. Push-triggered checks use 64 MiB.

Open the resulting run to see live job logs and pass/fail results. You can cancel a run from that page. When it finishes, download `android-transfer-benchmark-api-29`, `android-transfer-benchmark-api-31`, and `iphone-transfer-benchmark`. The iOS XCTest result bundle also retains its JSON measurement as an attachment. APK and IPA artifacts are build outputs, not proof of a device transfer.

Enable **capture_ui** only when you also need an initial native iPhone screenshot. It defaults off so a separate preview boot does not delay transfer-test results. The iPhone benchmark artifact includes both legacy and resumable download measurements in 0.3.0; both use hosted loopback, not physical Wi-Fi.

## What this exercises

- Android: real Keystore-pinned TLS upload into the production Android receive server, explicit acceptance, streaming hashing, disk save and verified acknowledgement. Reports time and MB/s including TLS connection and verification.
- iPhone simulator: real HTTPS download from a local Python fixture through the production iPhone download/pinning/disk-verification delegate. Reports transfer MB/s and checksum time separately. This is not an end-to-end Android-to-iPhone connection.
- Existing tests cover wrong certificates, unauthorized requests, rejection, stale approvals, corrupt/truncated files, cancellation cleanup, storage checks and bounded metadata. Benchmark completion does not replace these checks or a broader security assessment.

These are software-path measurements over loopback on shared hosted machines. They do not measure hotspot radio speed, distance, interference, battery use, mobile-network outages or switching between actual Wi-Fi networks. They cannot establish SHAREit-level physical throughput. Comparisons between the Android upload and iOS download timers are not directly equivalent.

The controls start automated runs; they do not provide an interactive remote phone or access to the user's physical devices. Real-phone baseline remains approximately 6.3 MB/s for the reported Android-to-iPhone hotspot transfer. Android-to-iPhone resume is implemented in 0.3.0; reverse-direction resume and automatic network migration remain unimplemented.
