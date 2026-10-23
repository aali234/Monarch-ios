# Verification record · 2026-10-23

| Check | Outcome |
| --- | --- |
| Portable core, Swift 6.2 official Linux toolchain | 26 tests pass, including receipt/matching/HSA, MIME, tracking and ZIP cases |
| CSV parsing/identities, 1,000 rows | Under one second in the debug Linux runs; on-device acceptance still pending |
| FastAPI proxy, Python 3.12 with mocked Plaid/Ship24 transports | 16 tests pass |
| ZIP interoperability | Swift-produced ZIP opens with Python zipfile; contents and CRC verified |
| App, extensions, shared sources, and native-test Swift syntax | Swift compiler parse succeeds |
| Xcode project references/targets/resources | Structurally checked; five targets, all Swift sources included with target membership, all object references resolved |
| Scheme XML, app/extension Info/Privacy/entitlement plists, asset JSON | Parses successfully |
| Shell scripts / Python sources | Shell syntax and Python bytecode checks pass |
| Apple SDK build | Pass on GitHub `macos-15`, Xcode 26.3, iPhone Simulator 26.2 SDK, arm64. App, Share Extension, Live Activity extension, and both native test targets compile |
| Screenshot UI test | Pass on iPhone 17 Pro / iOS 26.2. One XCTest navigates ten example-data screens and exports ten 1206 × 2622 PNGs |
| Visual screen review | All ten PNGs inspected. Dashboard and finance cards keep their contents together and fit the iPhone width. Originals are preserved in [screenshots](screenshots/README.md) with provenance and checksums |
| Ten native unit tests and manual-account UI smoke test | Compiled by `build-for-testing`; not executed by the screenshot-only filter. Run `scripts/test-ios.sh` for these separate checks |
| GitHub macOS screenshot workflow | Pass: real native build, simulator launch/test, PNG export, and artifact uploads. Latest run: [39900373095](https://github.com/aali234/Monarch-ios/actions/runs/39900373095), commit `f921e8ad2626782e94d458078e32f25650456f9f` |
| Live Plaid APIs, Link login/update on simulator | Not run: no Plaid credentials/account available to this session |
| Gmail OAuth, IMAP, Ship24 carrier lookup | Not run: no provider credentials; mock tests are not live-provider verification |
| Camera, Share signing, iCloud, Foundation Models runtime, live ActivityKit and background task execution | Not run: signed/device verification required; compiling extensions does not exercise these capabilities |
| Plaid account creation / Render deployment / TestFlight | Not performed |

Raw portable test output is included in `swift-test-results.txt` and `proxy-test-results.txt`. The proxy suite has one dependency deprecation warning in Starlette’s TestClient; it does not affect the test results.

The screenshot run uses an in-memory ledger and synthetic example data. It exercises model creation and screen navigation, with bank/mail/carrier background calls disabled. It does not verify a live Plaid connection or durable financial data on disk. The full Xcode log and result bundles are in the run's `iOS-build-results` artifact, retained for three days; PNGs are retained for seven days.

The successful native build reports an iOS 26 window-initializer deprecation and Swift 6 concurrency migration warnings in the IMAP adapter (the project currently uses Swift 5 language mode). The UI run also records a SwiftUI/UIKit toolbar hosting diagnostic. The selected XCTest passes; these warnings remain follow-up work.

Use the README launch steps, `SANDBOX-TESTING.md`, and `RECEIPTS-HSA-SHIPMENTS.md` to complete the native/live gates. A source syntax check is not an iOS SDK build, and mock-backed proxy tests are not proof of a live Plaid or carrier connection.
