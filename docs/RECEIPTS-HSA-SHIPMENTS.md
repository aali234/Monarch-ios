# Receipts, HSA, and shipments · v0.2

The updated PRD adds F45–F56. This implementation includes native screens, local data models, provider clients, the Share Extension, a delivery Live Activity extension, and the optional tracking proxy route. The Apple-platform and live-provider gates below still need a Mac/device and your own service configuration.

## Start without email or tracking services

Open **More → Receipts → +** and import an image, PDF, `.eml`, or plain text. In a transaction, **Attach a receipt** explicitly links the imported receipt to that purchase. The document camera uses VisionKit’s auto-cropping scanner on a physical iPhone; Simulator users can import images/PDFs instead.

Vision OCR and PDF text extraction happen on the device. Where available, Apple Foundation Models extracts structured fields from a bounded 2,000-UTF-8-byte order excerpt; there are no third-party model calls. A deterministic parser handles unavailable models or failed generations. Unknown amounts stay blank. Dates fall back to the email date or a clearly flagged import date for review; an estimated date cannot trigger an automatic match. Every field and line item can be edited, and new receipts enter **Needs review**. The model never decides HSA eligibility.

An exact, unique posted charge with the same amount, compatible merchant, and date within three days is linked automatically. Near/ambiguous matches are suggestions. Currency must match; pending rows and split children are excluded. Manually unlinking prevents the background matcher from relinking that receipt. Receipts are rechecked after bank sync.

Original files are retained. Images receive PDF copies, and email receipts also receive a readable PDF rendering. Repeated file hashes/message IDs are deduplicated. Matching merchant + order number merges later shipping emails into an existing order and fills missing amounts without replacing reviewed fields.

## iCloud and encryption

The default preserves the earlier PRD privacy requirement: receipt contents are AES-GCM ciphertext in iCloud Drive, with opaque filenames under `Receipts/YYYY/MM/<receipt-id>/`. Open originals and PDFs through Monarch. **Settings → Receipt email & delivery settings** can explicitly make future files ordinary documents visible directly in Files. Existing files retain their encryption mode.

If iCloud/capabilities are unavailable, imports still work: protected originals are kept locally and labeled **Saved on this iPhone**. Use **File originals in iCloud Drive** after configuring/signing in to iCloud. The app does not falsely report a local-only save as cloud filing. No receipt is automatically deleted, including HSA receipts; the seven-day archive rule affects shipment visibility only.

Enable the supplied iCloud container (`iCloud.com.aali.monarch.sandbox`) and App Group (`group.com.aali.monarch.sandbox`) for your signing team, or change those IDs consistently in the entitlements, Info.plist, and `Shared/SharedInbox.swift`. Xcode can provision the capabilities with your Apple account. iCloud filing requires an eligible signed build, an iCloud account and iCloud Drive; it is not provisioned by this Linux session.

## Share Extension

The `MonarchShare` target accepts images, PDFs, shared email files, text and URLs. It copies the supplied payload into a protected App Group inbox before the provider’s temporary URL expires. On the next app open, Monarch reads and files it. No email connection is required. An app that shares only a private webpage URL cannot supply the underlying email body; share a PDF/image or use the email connection for that case.

Unsigned simulator builds can use the app’s file importer, but App Group access requires entitlements/signing. On a Mac, try an ad-hoc simulator build:

```bash
MONARCH_SIMULATOR_SIGNING=adhoc ./scripts/run-simulator.sh
```

Verify the extension from Files’ share sheet. If the shared container is unavailable, use an Xcode-signed build with the App Group capability. The first native signing/extension run remains unverified here.

## Gmail setup

1. In Google Cloud, enable the Gmail API and create an **iOS OAuth client** for `com.aali.monarch.sandbox` (or your changed bundle ID).
2. Copy `Local.xcconfig.example` to `Local.xcconfig`, fill `GMAIL_CLIENT_ID` and `GMAIL_REVERSED_CLIENT_ID`, then rebuild. These are public client identifiers; no client secret is used in the phone app.
3. Configure the OAuth consent screen and permit your personal account to grant `https://www.googleapis.com/auth/gmail.readonly`. Follow Google’s current consent/verification requirements for your app. The PRD requests a production-status personal OAuth setup to avoid Testing-mode refresh-token expiration.
4. In **Settings → Receipt email & delivery settings**, choose **Connect Gmail (read-only)** and approve access in the system authentication browser.

The flow uses PKCE, a random state, the registered reverse-client-ID callback scheme, direct Google token exchange and refresh, and Keychain token storage. No mail or Google token passes through the Plaid proxy. Initial list queries cover matching sender/subject keywords in the last 90 days; later scans use Gmail history with a fresh bounded scan if history expires. Metadata is checked before downloading full messages. Deleted messages are skipped; checkpoints advance only after the batch has been processed safely.

References: [Google native-app OAuth](https://developers.google.com/identity/protocols/oauth2/native-app), [Gmail API scopes](https://developers.google.com/workspace/gmail/api/auth/scopes), [Gmail incremental synchronization](https://developers.google.com/workspace/gmail/api/guides/sync).

## Other mail providers

Choose **Connect another account with IMAP**. Enter the address, IMAP hostname, username, mailbox (default `INBOX`), and a provider-generated app password. The client uses TLS with certificate validation on port 993, `EXAMINE` for read-only access, server-side keyword/date searches, and `BODY.PEEK[]` so messages are not marked read. Passwords are Keychain-only and bound to the saved host/username.

UIDVALIDITY and a UID checkpoint support incremental scans and mailbox resets. Only matching messages are downloaded; MIME/plain text/HTML, base64 and quoted-printable bodies, PDF/image attachments and encoded headers are handled locally. Message/file imports are limited to 25 MB; a failed import does not advance past unfinished mail. Disconnect/reconnect after changing an app password or revoking access.

Foreground scans and `BGAppRefreshTask` scheduling are wired. iOS decides when background work runs, and protected files may be inaccessible while the device is locked; this is best effort, not continuous mailbox polling.

## HSA records and exports

Open a receipt and explicitly confirm HSA eligibility. Pharmacy/clinic/dental/vision merchants may receive a suggestion, but confirmation is always yours. Select **Unreimbursed** or **Reimbursed**, record the reimbursement date, and optionally link the HSA withdrawal. The receipt does not create or change a bank transaction.

**More → HSA receipts** shows year totals. The headline is the sum of eligible, unreimbursed USD receipts; exports retain each receipt’s currency. **Export year: ZIP + CSV** opens the system share sheet with a ZIP containing original/PDF files and a CSV summary, plus a separate CSV. Both reimbursed and unreimbursed eligible receipts are included for that year. CSV text cells are escaped and protected against spreadsheet-formula injection. ZIP creation happens locally with streaming file reads.

Readable export files are created only for the requested export in a protected temporary directory and removed after sharing. Decrypted preview files expire during subsequent cleanup. Receipt originals are retained.

## Shipment tracking

The parser detects UPS, USPS and FedEx numbers, including carrier links in HTML mail; Amazon progress-tracker links get link-only shipment cards. FedEx-shaped numbers require shipping/tracking context to avoid mistaking order IDs for packages. You can also add a tracking number/link from receipt detail.

**More → Shipments** groups label-created, in-transit, out-for-delivery, delivered and exception records, with the receipt amount, linked transaction, carrier, ETA where available, tracking link, and timeline. Delivered records archive after seven days without deleting receipt/history data.

For live lookup, put `SHIP24_API_KEY` in the proxy environment and keep the phone configured with the proxy URL/app key. `/tracking` works independently of Plaid credentials. The phone sends only `tracking_number`; the proxy calls Ship24’s fixed idempotent `POST /public/v1/trackers/track` endpoint and trims the response. The server does not persist shipment data. Ship24 is the tracking provider and receives/stores tracking data according to its service; obtain your own account/key and review the plan you choose. No Ship24 account or deployment was created here.

Each shipment’s last-check time is saved before lookup, enforcing a two-hour minimum even across relaunches and failed lookups. Missing keys, Amazon links, vendor errors, or unavailable data retain link-only behavior without invented live status. Links must be HTTPS.

Optional local out-for-delivery notifications and a delivery Live Activity are available in receipt/delivery settings. They follow observed status changes during refresh; there is no push-tracking backend, so updates depend on app/background opportunities. Starting a Live Activity also requires iOS authorization and may require the app to be active.

References: [Ship24 tracker endpoints and idempotent lookup](https://docs.ship24.com/trackers/), [tracking milestones](https://docs.ship24.com/status/), [date/field formats](https://docs.ship24.com/data-format).

## Backup and recovery

Backup archive v2 adds receipt and shipment records, email-account metadata, and the receipt vault key **inside the passphrase-encrypted archive**. It excludes mail passwords/OAuth tokens, Plaid tokens and app keys. Older v1 archives remain readable.

By default, receipt file bytes are included up to a 25 MB asset allowance (the encrypted backup file is limited to 50 MB). For larger collections, turn **Include receipt file data** off after filing all originals in iCloud; the backup then contains the vault key and file links, and export checks that every cloud file has finished uploading. A links-only restore needs the same iCloud account. HSA year exports provide a separate readable record set. Never lose both the device’s vault key and its encrypted backup.

## Native/live acceptance gate

- Import a PDF, image and `.eml`; edit fields/line items and verify originals plus image/email PDFs open.
- Share from Files/Mail into the extension without connecting email, reopen the app, and confirm no duplicate receipt after replay.
- Scan a multi-page receipt on a physical iPhone; Simulator should offer file import instead.
- Test exact/near/ambiguous matches, pending charges and manual unlinking, then refresh Plaid and confirm links survive.
- Confirm HSA eligibility, mark reimbursed with a date/withdrawal, verify year totals, and open the ZIP/CSV from Files.
- Connect Gmail and IMAP test mailboxes, verify first 90-day scan, incremental scan, interrupted batches, token/password renewal and read-only mailbox behavior.
- Exercise real tracking with your API key, missing-key/error/Amazon link-only cases, two-hour gating, timeline, delivered archive, opt-in notification and Live Activity.
- Check iCloud filing and a fresh-device encrypted backup restore, including receipt file bytes/vault key and reauthorization of email.
- Check the privacy shield while a receipt is open in Quick Look and after the app has been backgrounded for a minute.

Portable/mocked tests run in Linux. Camera, Share Extension signing, iCloud, Foundation Models runtime, OAuth/IMAP sessions, ActivityKit, background scheduling and Apple SDK type checking still require native/live verification. No live mailbox or carrier was contacted in this implementation session.
