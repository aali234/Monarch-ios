# Verification record · 2026-10-22

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
| Apple SDK build, 10 native unit tests, UI smoke test and screenshot test | Not run: this environment is Linux with no Xcode or iPhone simulator |
| GitHub macOS screenshot workflow | Prepared: manual Xcode 26 build, simulator test, ten example-data captures, PNG/log/result uploads. YAML/shell/Swift syntax checked; no GitHub run or actual screenshots yet |
| Live Plaid APIs, Link login/update on simulator | Not run: no Plaid credentials/account available to this session |
| Gmail OAuth, IMAP, Ship24 carrier lookup | Not run: no provider credentials; mock tests are not live-provider verification |
| Camera, Share signing, iCloud, Foundation Models runtime, ActivityKit, background task execution | Not run: native/device verification required |
| Plaid account creation / Render deployment / TestFlight | Not performed |

Raw portable test output is included in `swift-test-results.txt` and `proxy-test-results.txt`. The proxy suite has one dependency deprecation warning in Starlette’s TestClient; it does not affect the test results.

Use the README launch steps, `SANDBOX-TESTING.md`, and `RECEIPTS-HSA-SHIPMENTS.md` to complete the native/live gates. A source syntax check is not an iOS SDK build, and mock-backed proxy tests are not proof of a live Plaid or carrier connection.
