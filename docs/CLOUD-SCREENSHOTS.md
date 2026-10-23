# Build and capture the iPhone UI without owning a Mac

The app can compile and run on a **GitHub-hosted Mac**. You can start the job and download its screenshots from a Windows/Linux computer or a phone. SwiftUI's iOS runtime and Apple's simulator still run on macOS; the Linux workspace cannot execute them directly.

The checked-in workflow is `.github/workflows/ios-screenshots.yml`. It is **manual only**. It selects an installed stable Xcode 26 on `macos-15`, finds an available iOS 26+ iPhone simulator, builds the app and extensions, runs the screenshot UI test, and uploads PNGs plus the build log/result bundle. No Apple Developer account, bank/email login, or Plaid proxy is needed for these unsigned simulator screenshots. GitHub Actions access and available macOS runner minutes are required.

## Run from GitHub

1. Put the **contents** of the `Monarch` source folder in a GitHub repository, with `.github` at the repository root. Include hidden files from the archive. Keep private credentials and `Local.xcconfig` out of the repository.
2. Open the repository's **Actions** tab. Choose **iOS build and screenshots**, then **Run workflow** on the branch containing it. For the workflow to appear initially, put it on the default branch.
3. After the job finishes, open the run and download **iPhone-UI-screenshots**. `manifest.json` maps exported attachment filenames to named screen captures. The **iOS-build-results** artifact includes `ios-screenshots.log`, the `.xcresult` bundle and the simulator/Xcode versions. Screenshots are retained for 7 days and the larger build results for 3 days to reduce storage use.
4. If compilation or a UI test fails, use the uploaded build log to fix the failure and rerun. Partial screenshots are exported where the result bundle permits it.

The workflow has successfully built and launched the app on **Xcode 26.3 / iOS 26.2 / iPhone 17 Pro**, producing ten real 1206 × 2622 PNGs. [View the checked-in screenshots](screenshots/README.md) or the [successful run](https://github.com/aali234/Monarch-ios/actions/runs/39900373095). Download the source and open `docs/screenshots/index.html` for an offline gallery. The [verification record](VERIFICATION.md) states which checks the run covers. Compilation took under two minutes and the screenshot test took about two minutes; simulator startup accounts for much of the remaining time.

The project repository is [aali234/Monarch-ios](https://github.com/aali234/Monarch-ios). The GitHub connection needs repository content/workflow write access and Actions write access to upload changes and start a manual run.

## Public source and credentials

The screenshot workflow uses synthetic example data and needs **no API secrets**. It does not read a bank account or mailbox. Personal account, transaction and receipt data stay out of the repository and CI artifacts.

Keep Plaid client/secret, the proxy app key and any Ship24 key in the proxy's environment, with local values in the ignored `proxy/.env`. If a future CI server-integration job needs credentials, use **Repository settings → Secrets and variables → Actions** and inject them only into that job. Never put a Plaid secret in the iOS binary, even through a build environment variable. Gmail's iOS client ID is public configuration; mail access/refresh tokens remain in the phone's Keychain.

## What the screenshots show

The screenshot test launches the real Debug app with both `--ui-testing` and `--screenshot-testing`. It uses an in-memory SwiftData ledger, and inserts explicit **example** accounts, transactions, budgets, receipts, HSA records and a delivery timeline. No live provider is contacted. These fixtures are excluded from Release builds and are never inserted during an ordinary app launch.

The ten named captures cover Dashboard, Accounts, Transactions, Budget, Cash flow, Receipts, HSA receipts, Shipments, receipt details, and the shipment timeline. Example data is for UI inspection, not proof of a live Plaid connection. Camera, signed App Group/iCloud behavior, Live Activities, email authentication and actual carrier responses retain their separate acceptance checks.

On a Mac or an already provisioned remote Mac, the equivalent command is:

```bash
./scripts/capture-ios-screenshots.sh
```

Set `MONARCH_SIMULATOR_UDID` to choose a simulator, or `MONARCH_SIMULATOR_SIGNING=adhoc` to try ad-hoc simulator signing. Before rerunning locally, move the previous `build/Screenshots` directory and the `build/Build.xcresult` / `build/Screenshots.xcresult` bundles. The script compiles before booting the simulator so SDK errors return sooner, then uses `test-without-building` to capture the UI. Existing result bundles are preserved instead of deleted.

The screenshot job runs `ScreenshotTests`. Use `./scripts/test-ios.sh` separately for the complete native unit/UI suite.

References: [GitHub macOS runner image and installed Xcode/simulator versions](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md), [manually running a workflow](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow), [downloading workflow artifacts](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts).
