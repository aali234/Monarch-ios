# Implementation notes and remaining PRD scope

## Architecture

The SwiftUI app uses SwiftData records for accounts, transactions, categories, connections, snapshots, loans, holdings, people, receivables, rules, budgets, import profiles, recurring confirmations, planning configuration, receipts, shipments and email metadata/checkpoints. Relationships are explicit stable foreign IDs rather than SwiftData relationship objects. The ledger remains local (`CloudKit.none`). The portable `MonarchCore` package owns money calculations, deduplication, rules, CSV identities and parsing, recurring detection, projections, receipt/matching/HSA logic, MIME parsing, tracking detection, streaming ZIP creation, DTOs, and the proxy client.

Network fetches use async URLSession. A `@ModelActor` owns sync/import writes. Sync accumulates all pages before merging; transactions, balances, snapshots, and cursor are committed in the same save. Mutations during pagination discard the partial batch and restart. A complete failure rolls back the writer context. An Item’s selected product determines which APIs are initialized and fetched; new primary products are tested using separate Sandbox connections.

The proxy uses `httpx` directly against fixed Plaid endpoints instead of `plaid-python`. This keeps async calls and response-field allowlists small and testable, without generated SDK models or arbitrary path forwarding. It never stores financial data or tokens. Its in-memory rate limiter stores only client IPs and timestamps. These limits are per process; the launcher uses one worker and does not trust forwarded headers by default. On Render this may conservatively share the limit across clients behind the platform proxy, which is acceptable for a single-user testing build.

Tokens/app keys are Keychain-only and scoped to a SHA-256 fingerprint of the proxy URL. The URL/app key cannot be changed while sync is running. Redirects are refused by the Swift client and proxy client. Access tokens must match the proxy’s Plaid environment. The app itself rejects production health responses. A successful exchange is immediately written as one recoverable Keychain record containing the token and metadata, then materialized into SwiftData; the temporary record is removed only after saving. The permanent access-token key has this-device-only accessibility.

Backups exclude Plaid/email credentials and proxy app keys. Archive v2 deliberately includes the receipt vault's encryption key inside the passphrase-encrypted archive, along with receipt files or verified uploaded iCloud links; v1 archives remain readable. Restored Item IDs are metadata, not sufficient to authorize Plaid calls. **The PRD’s suggestion that a fresh-device restore can use update mode without the access token is not possible with this stateless architecture.** A secure token recovery mechanism or a newly authorized Item is required on a new device. Production linking stays blocked pending that design decision. Same-device existing Keychain tokens can still be used.

Receipt OCR, document parsing, matching, medical suggestions and export run on the device. The default iCloud receipt vault encrypts file contents; users can opt into ordinary documents for future imports. A protected local copy supports imports without iCloud. The Share Extension uses a protected App Group queue. Gmail OAuth/refresh and certificate-validated IMAP connect directly to the provider and keep credentials in Keychain. Background mail/tracking refresh is scheduled with `BGAppRefreshTask`; iOS controls execution.

The optional `/tracking` proxy route uses a fixed Ship24 endpoint and sends only a tracking number. It works without Plaid credentials but requires the app key; missing provider configuration and lookup failures fall back to carrier links. The phone persists its two-hour per-shipment gate before lookup. Local notifications and ActivityKit follow observed status changes. Setup, privacy choices and native acceptance steps are in [Receipts, HSA, and shipments](RECEIPTS-HSA-SHIPMENTS.md).

## Deliberate Sandbox milestone limits

| Area | Present | Remaining |
| --- | --- | --- |
| Accounts/import | Manual/Plaid, CSV, visibility, archive, snapshots | FinanceKit, currency conversion, CSV bank-overlap reconciliation |
| Transactions | Search/filter, day list, swipe review, edits, exact splits, locked fields | Dedicated swipe-card review queue, explicit merge editor for unrelated duplicate imports |
| Rules/categories | Common editor actions, ordered preview/apply, fully local categories | Editing existing rules in place; UI for every core-supported condition/action; full group hierarchy editor |
| Budget | Flex/category modes, plans, starting balances and separate rollovers | Expected-income/goal allocation and left-to-budget workflow |
| Shared costs | People/aliases, split cost, IOUs, requests, settlement, write-off, credits | Scheduled local reminders, richer allocation editor and auditable settlement reversals |
| Cash flow/reports | Month/quarter/year, breakdowns, six-month chart, Canvas flow diagram | Saved report filters and full multi-screen reports UI |
| Recurring | Local detection, explicit confirm/dismiss, calendar/list | Utility-specific 25% tolerance, advanced stream editing and late-stream logic |
| Loans/investments | Manual/Plaid student fields, payoff slider, holdings/allocation | Full card statement-close nudges, payment-to-principal ledger application, multi-loan avalanche/snowball and goals |
| Insights/forecast | Four checks, averaged cash-flow projection, milestones/base comparison | All eleven PRD checks, 30-day dismissals, account-level APY/loan amortization forecast and randomized returns |
| Receipts/HSA | Imports/scan/share/email, local extraction, matching, iCloud vault, HSA records and ZIP/CSV | Apple-platform and live-mail/iCloud validation; provider credentials/signing |
| Shipments | Detection, cards/timelines, optional tracking route, archive, notification and Live Activity | Live-carrier and ActivityKit runtime validation; optional provider key |
| Security | Keychain, local protection, lock above presented previews, encrypted v2 export/restore | Weekly automatic iCloud backup and signed capability validation |
| Distribution/platform | Reproducible five-target Xcode project, shared scheme, App Group Share Extension, Activity extension, background mail/tracking task, native tests and Mac scripts | Apple-platform build/run gate, TestFlight signing/upload, home-screen budget widgets and scheduled bank sync |
| AI/Siri | Foundation Models availability checks and structured receipt extraction; no external AI calls | Categorization/recap/tool assistant, opt-in Siri/App Intents |
| Navigation/dashboard | Five tabs, persistent dashboard widget ordering/toggles | Editable tab/sidebar destinations and the remaining widget types |

No production readiness or complete PRD acceptance is implied by the portable test results. The iOS SDK, LinkKit runtime, SwiftData macro/type checking, file protection behavior, Face ID, crypto round trips, native UI tests, and live Sandbox credentials must be checked on a Mac/simulator.

## Verification commands

`scripts/test.sh` runs the portable Swift and mocked proxy suites. `scripts/test-ios.sh` runs native persistence/backup tests and a UI smoke test in a simulator. `proxy/sandbox_smoke.py` is an optional live proxy integration check with your Sandbox credentials and never prints/stores tokens. The live script creates test Items; it does not test the iOS Link screens or remove Items.

The app package is pinned to LinkKit 7.2.3 and uses its `PlaidLinkSession.sheet()` API. Review [Plaid’s current iOS SDK docs](https://plaid.com/docs/link/ios/) when upgrading. OAuth Universal Link capabilities must be provisioned on a signed app before OAuth institution testing.
