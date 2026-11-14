# Native interface release requirements

User requirement confirmed 14 November 2026: the supplied Opus demo remains the reference for the complete interface, including its tabs, screen layouts and navigation. The current prototype is a test interface and does not fulfill that requirement. Transfer-engine work must not erase or indefinitely defer the frontend work. A usable interface is required before public release.

Implement with SwiftUI on iPhone and native Kotlin UI on Android. The demo's React Native implementation is a visual reference, not a required runtime. Keep the project's current name unless the user chooses another.

## Required flow

- Persistent Nearby, Files and Activity tabs, following the demonstrated layout and navigation.
- Nearby home with the demonstrated connection card and clear Send/Receive entry points.
- Guided connection and pairing screens that clearly distinguish the system Wi-Fi QR from the secure Nearby pairing QR.
- File selection and incoming-file review with clear acceptance, rejection and cancellation actions.
- Dedicated transfer screen with actual byte progress, speed, completion and actionable failure/recovery states.
- Files view for opening, exporting and managing real received files.
- Activity view showing real transfer history and outcomes.
- The demo's pale surfaces, blue accents, rounded cards, spacing and typography, adapted to native platform behavior and dark mode.

Sample peers, sample codes and simulated transfers in the demo must be replaced by actual state. Unsupported features must not appear to work.

## Release review

Compare the complete native flow against the supplied recording, including tabs and intermediate screens, rather than reviewing only the first screen. Test on the user's small Android screens and iPhones, with large text, dark mode, long and multilingual filenames, keyboard/system prompts, interruptions and failed pairing. Content must respect safe areas and remain clear while scrolling. Public readiness requires both dependable transfers and a usable complete interface.
