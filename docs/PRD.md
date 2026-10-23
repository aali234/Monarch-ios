# Monarch Clone — PRD & Tech Spec

Oct 21, 2026 · @Aali

## 1. Overview

A single-user iOS app that replicates Monarch Money's core feature set. All financial data is stored on the device, all AI runs on Apple's on-device Foundation Models, and bank sync goes through Plaid via a stateless proxy. Phase 1 ships a feature-parity clone to TestFlight; Phase 2 adds personal customization.

### Goals

| # | Goal | Measure |
| --- | --- | --- |
| G1 | One place for all 5 bank logins, both student loans, and net worth | All accounts syncing daily, no manual entry needed for linked accounts |
| G2 | Budget with flex buckets and rollovers | Monthly flex number visible on the dashboard |
| G3 | Pay down MOHELA and the Nelnet Parent PLUS on a plan | Payoff date and interest projection per loan |
| G4 | No unencrypted financial data at rest off-device | Proxy has no database and no disk; logs hold status codes only; iCloud Drive backups are AES-GCM ciphertext |
| G5 | AI with no third-party model calls | In-app AI uses `FoundationModels` only; Siri access is opt-in and returns aggregates only |

### Non-goals (Phase 1)

- Multiple users, partner sharing, or an advisor portal
- Android, web, or iCloud sync
- Moving money (transfers, bill pay)
- Zillow or vehicle valuation (manual asset accounts only)
- App Store release (TestFlight internal testing only)

### Constraints

| Constraint | Detail |
| --- | --- |
| Platform | iOS 26+ minimum, SwiftUI, SwiftData. Test device: iPhone 16 on iOS 27 (Apple Intelligence-capable) |
| Bank data | Plaid Trial plan: free, up to 10 Items lifetime; removed Items do not free a slot |
| Plaid products | Transactions, Balance, Liabilities, Investments are all on the Trial plan |
| Proxy | FastAPI on Render; free tier sleeps after 15 min idle (30–60 s cold start) |
| AI model | About 3B parameters, 4,096-token context (input + output), text only |
| Distribution | TestFlight, single tester (owner) |

## 2. Feature requirements

P0 is the usable core (manual and CSV data), P1 adds live sync and analysis, and P2 adds goals, investments, and AI. Each row's acceptance criteria define done.

| ID | Module | Requirement | Pri | Acceptance criteria |
| --- | --- | --- | --- | --- |
| F1 | Accounts | Manual accounts: checking, savings, credit card, loan, investment, asset | P0 | Create, edit, archive; balance edits update net worth |
| F2 | Accounts | Hide account from budget, cash flow, or net worth | P0 | Toggled account is excluded from that calculation only |
| F3 | Import | CSV import with a column-mapping screen, saved per account | P0 | 1,000-row CSV imports in under 3 s; re-import creates no duplicates |
| F4 | Transactions | List grouped by day, with search and filters (account, category, tag, amount, date) | P0 | Search over 10k transactions returns in under 200 ms |
| F5 | Transactions | Edit merchant, category, date, notes, tags; split into multiple categories | P0 | Split amounts must sum to the original |
| F6 | Transactions | Review status (needs review / reviewed) and swipe-to-review queue | P0 | Dashboard card shows count needing review |
| F7 | Categories | Groups and categories with emoji, each typed income / expense / transfer and bucketed fixed / flex / non-monthly | P0 | Default set seeded on first launch; fully editable and reorderable |
| F8 | Rules | If-then rules: match merchant, original description, amount range, account; actions set category, rename merchant, add tag, hide, mark reviewed, split, link to loan or goal | P0 | Rules run in list order on import; preview shows matches before saving; "create rule" prompt after a manual recategorize |
| F9 | Budget | Flex mode (fixed / flex / non-monthly) and category mode | P0 | Switching modes keeps planned amounts |
| F10 | Budget | Rollover per category and for the flex bucket, with starting balance | P0 | Matches the rollover formula in section 6 |
| F11 | Plaid | Link a bank with Plaid Link; sync transactions and balances | P1 | New transactions appear within one pull-to-refresh |
| F12 | Plaid | Update mode for broken logins; duplicate-Item guard | P1 | Re-auth never creates a new Item |
| F13 | Cash flow | Income, expenses, net, savings rate by month / quarter / year; breakdown by category, merchant, tag | P1 | Totals match budget actuals for the same month |
| F14 | Cash flow | Sankey diagram of income to category groups | P1 | Renders a 12-month period on iPhone |
| F15 | Recurring | Detect bills, subscriptions, paychecks; confirm or dismiss; calendar and list views | P1 | Detected streams need user confirmation before they count |
| F16 | Net worth | Daily balance snapshot; net worth chart by 1M / 3M / 1Y / all | P1 | One snapshot per account per day |
| F17 | Dashboard | Reorderable, toggleable widgets | P1 | Layout persists across launches |
| F18 | Reports | Spending, income, cash flow reports; save custom filters as a report | P1 | Saved report reopens with the same filters |
| F19 | Loans | Loan accounts for MOHELA (borrower: me) and Nelnet Parent PLUS (borrower: dad); Plaid Liabilities when linked, manual otherwise | P1 | Payment transactions auto-link via rules; manual loans show a reconcile prompt monthly |
| F20 | Goals | Save-up goals and pay-down goals; extra-payment slider; avalanche vs snowball | P2 | Payoff date updates live as the slider moves |
| F21 | Investments | Holdings and allocation from Plaid Investments | P2 | Value = quantity × latest price |
| F22 | Apple accounts | FinanceKit for Apple Card / Cash / Savings | P2 | Requires the managed entitlement; CSV fallback until approved |
| F23 | AI | On-device categorization suggestions | P2 | Falls back to rules only when the model is unavailable |
| F24 | AI | Weekly recap card | P2 | Generated from computed aggregates, never raw transaction lists |
| F25 | AI | Assistant chat answering questions about my data | P2 | Every number in an answer comes from a tool call |
| F26 | Widgets | iOS home-screen widgets: flex remaining, cash flow this month | P2 | Reads from an App Group store |
| F27 | Security | Face ID lock; encrypted backup to iCloud Drive | P0 | App locks after 1 min in background |

### Bills and money owed to me

I pay some shared costs, like house bills on my credit card or splits with friends, and then collect with Zelle requests. The app tracks each amount I'm owed from charge to repayment, and counts only my share as spending.

| ID | Requirement | Pri | Acceptance criteria |
| --- | --- | --- | --- |
| F28 | People list with aliases (e.g. Dad = "ZELLE FROM \<dad's name>") | P0 | Alias matching is case-insensitive |
| F29 | Mark any transaction as shared: who owes, and how much (100%, a %, or a fixed amount, across one or more people) | P0 | Owed amounts can't exceed the charge |
| F30 | Vendor rules auto-create receivables (e.g. merchant is the electric or internet provider → Dad owes 100%) | P0 | Uses the existing rules engine with a new action |
| F31 | Manual IOU with no transaction (cash lent, Venmo-only splits) | P0 | Has a person, amount, note, date |
| F32 | Status flow: open → requested → partial → paid (or written off) | P0 | Partial payments keep a remaining balance |
| F33 | Auto-match incoming Zelle deposits to open receivables by person alias and amount; suggest when unsure | P1 | Exact match auto-settles; otherwise a one-tap suggestion |
| F34 | "Request" button copies a ready message (amount + itemized list) or opens the share sheet | P0 | Marks the items as requested with today's date |
| F35 | Dashboard widget "To collect": total owed, per person, oldest age | P0 | Tapping a person shows their open items |
| F36 | Reminder notification when a requested item is unpaid after N days (default 7) | P1 | Local notification only |
| F37 | Siri intent "Who owes me money?" | P2 | Returns totals per person |

### Origin-inspired: proactive advice and forecasting

From Origin: a feed of concrete actions with a dollar impact, a health score, and a forecast with life events. These turn the app from a record of what happened into what to do next. Origin's tax filing, estate planning, human advisors, and in-app investing are out of scope.

| ID | Requirement | Pri | Acceptance criteria |
| --- | --- | --- | --- |
| F38 | Action feed: "N actions worth $X/yr", each card with a category, a one-line finding, the dollar impact, and "See why" | P1 | Every card comes from a deterministic check (6.9); dismissed cards stay hidden 30 days |
| F39 | Financial health score (0–100) with pass / warn / fail per check | P1 | Score is reproducible from the same data |
| F40 | Forecast: monthly projection of net worth and cash flow for 1–10 years | P1 | Uses trailing 3-month income and spending; assumptions editable |
| F41 | Milestones on the forecast: job change / raise, move out, buy a car, extra loan payment, windfall, big purchase | P1 | Chart updates live as a milestone is added or edited |
| F42 | Scenario compare: base vs scenario lines with a plain-language trade-off summary | P2 | Summary text generated only from computed deltas |
| F43 | Ask "what if" in the assistant → creates a scenario through a tool call | P2 | The scenario is saved and opens on the forecast screen |
| F44 | Statement-close nudge: pay down a card before the statement closes to lower reported utilization | P1 | Uses the card's last statement date from Liabilities; fires 5 days before the expected close |

### Receipts, HSA, and shipments

Receipts arrive automatically from order emails or from a photo, get matched to their card transaction, and are filed in iCloud Drive. Medical receipts also land in an HSA section. Orders that ship get their own tracking view tied to the same transaction.

| ID | Requirement | Pri | Acceptance criteria |
| --- | --- | --- | --- |
| F45 | Connect an email account (Gmail API, or IMAP with an app password) and scan for order, receipt, and shipping emails | P1 | Scans the last 90 days on first connect, then new mail on each app open and background refresh |
| F46 | Share Extension: share an email, PDF, or image from any app into the app | P0 | Works without any email connection |
| F47 | Camera scan of paper receipts with the document scanner | P0 | Auto-crops; OCR runs on device |
| F48 | On-device parsing into merchant, order number, date, subtotal, tax, total, line items, tracking numbers | P1 | Fields editable before saving |
| F49 | Auto-match a receipt to its transaction (amount, date ±3 days, merchant) | P1 | Exact match links automatically; near matches become a suggestion |
| F50 | Receipt files saved to the app's iCloud Drive folder, organized by year and month | P0 | Original kept, plus a PDF copy for images |
| F51 | Transaction detail shows the attached receipt and line items | P0 | Tap opens the file |
| F52 | HSA section: mark receipts eligible; track unreimbursed vs reimbursed; totals by year | P1 | Unreimbursed total = sum of eligible, not-yet-reimbursed receipts |
| F53 | HSA export: a year's receipts as a ZIP plus a CSV summary | P1 | Exports from the Files share sheet |
| F54 | Shipments section: In transit / Out for delivery / Delivered, each card showing merchant, amount, linked transaction, carrier, ETA, and tracking link | P1 | Delivered cards archive after 7 days |
| F55 | Live tracking status and event timeline when the carrier lookup returns data; link-only otherwise | P1 | Refreshes at most every 2 hours per shipment |
| F56 | Out-for-delivery notification and Live Activity | P2 | Local notification on status change |

## 3. UX

The layout mirrors Monarch's iPhone app: five bottom tabs plus a sidebar for everything else, both user-editable.

### Navigation

| Slot | Default | Movable |
| --- | --- | --- |
| Tab 1 | Dashboard | Yes |
| Tab 2 | Accounts | Yes |
| Tab 3 | Transactions | Yes |
| Tab 4 | Budget | Yes |
| Tab 5 | Cash Flow | Yes |
| Sidebar | Recurring, Reports, Goals, Loans, Investments, Assistant, Rules, Categories, Settings | Yes |

### Screen inventory

| Screen | Key elements | Pri |
| --- | --- | --- |
| Dashboard | Widget stack; Customize button at the bottom | P0 |
| Accounts | Net worth header + chart; accounts grouped by type; + Add account (Plaid / manual / CSV) | P0 |
| Account detail | Balance history chart; that account's transactions; visibility toggles | P0 |
| Transactions | Search bar, filter chips, day-grouped list, review badge | P0 |
| Transaction detail | Merchant, amount, category picker, tags, notes, split, original description, "create rule" sheet | P0 |
| Review queue | Card stack: swipe right = reviewed, swipe left = recategorize | P0 |
| Budget | Month picker; Flex number ring; Fixed / Non-monthly / Flex sections with progress bars; rollover badges | P0 |
| Rules | Ordered list, drag to reorder; editor with conditions, actions, live preview | P0 |
| Categories | Groups → categories, emoji, type, bucket | P0 |
| Import | File picker → column mapper → preview → commit | P0 |
| Cash Flow | Period picker; income / expense / net / savings-rate tiles; bar chart; Sankey; breakdown tabs | P1 |
| Recurring | Calendar month view and list; detected-stream inbox | P1 |
| Reports | Spending / Income / Cash Flow tabs; saved reports | P1 |
| Loans | Per-loan card: balance, rate, borrower, next due, payoff date | P1 |
| Goals | Save-up and pay-down lists; goal detail with projection chart and extra-payment slider | P2 |
| Investments | Holdings list, allocation donut | P2 |
| Assistant | Chat with suggested prompts; answers show the figures used | P2 |
| Settings | Face ID, Plaid connections, proxy URL, export / import backup, navigation editor | P0 |

### Dashboard widgets

| Widget | Shows | Pri |
| --- | --- | --- |
| Needs review | Count + first 3 transactions | P0 |
| Budget | Flex remaining + top 3 categories by % spent | P0 |
| Recent transactions | Last 5 | P0 |
| Net worth | Value + 3-month sparkline | P1 |
| Upcoming recurring | Next 7 days | P1 |
| Spending trend | This month vs last month, cumulative | P1 |
| Loans | Combined balance + next payment | P1 |
| Weekly recap | AI summary card | P2 |
| Goals | Progress bars | P2 |

## 4. System architecture

The app is a single SwiftUI target plus a widget extension sharing one App Group store. Only Plaid calls leave the device, through a proxy that holds the secret and nothing else.

&#91;embedded content: system architecture · device, proxy, Plaid\]

Plaid Link's login screen talks to Plaid directly; the app only receives a public\_token, which the proxy exchanges for an access token that goes straight into the Keychain.

| Layer | Choice |
| --- | --- |
| UI | SwiftUI, Swift Charts, custom `Canvas` for Sankey |
| State | `@Observable` view models; SwiftData `@Query` for lists |
| Persistence | SwiftData in an App Group container, `NSFileProtectionComplete` |
| Concurrency | Swift concurrency; sync runs in a `@ModelActor` off the main thread |
| Background | `BGAppRefreshTask` for daily sync and snapshots (best effort) |
| Bank SDK | Plaid LinkKit for iOS via Swift Package Manager |
| AI | `FoundationModels` (iOS 26+) |
| Proxy | Python 3.12, FastAPI, `plaid-python`, uvicorn, on Render |
| CI / distribution | Xcode Cloud or local archive → TestFlight internal testing |

## 5. Data model

All entities are SwiftData `@Model` classes in one local store inside an App Group container, so widgets can read it. Money is stored as `Decimal` and dates as `Date` at local midnight for posting dates. Plaid access tokens live in the Keychain, never in SwiftData.

| Entity | Key fields | Relationships |
| --- | --- | --- |
| `Institution` | id, name, source (plaid / manual / csv / financekit), plaidItemId, cursor (sync), status, lastSyncedAt | → many `Account` |
| `Account` | id, name, type (checking, savings, credit, loan, investment, asset, other), subtype, mask, balance, currency, hideFromBudget, hideFromCashFlow, hideFromNetWorth, plaidAccountId, isArchived | → `Institution`; → many `Transaction`, `BalanceSnapshot`, `Holding`; → 0..1 `Loan` |
| `Transaction` | id, plaidTransactionId (unique), date, amount (negative = outflow), originalDescription, merchantName, notes, isPending, isHidden, reviewStatus, isSplitParent, importHash | → `Account`, `Category`, `Merchant`; → many `Tag`; → many child `Transaction` (splits); → 0..1 `Loan`, `Goal`, `RecurringStream` |
| `Merchant` | id, displayName, rawNames \[String\], logoSymbol | → many `Transaction` |
| `CategoryGroup` | id, name, kind (income / expense / transfer), order | → many `Category` |
| `Category` | id, name, emoji, bucket (fixed / flex / nonMonthly), order, isSystem | → `CategoryGroup`; → many `BudgetLine` |
| `Tag` | id, name, color | ↔ many `Transaction` |
| `Rule` | id, order, isEnabled, conditions (Codable `[RuleCondition]`), actions (Codable `[RuleAction]`), matchCount, lastAppliedAt | — |
| `BudgetMonth` | id, month (yyyy-MM), mode (flex / category), flexPlanned, flexRollover | → many `BudgetLine` |
| `BudgetLine` | id, planned, rolloverEnabled, startingBalance | → `BudgetMonth`, `Category` |
| `RecurringStream` | id, merchantKey, frequency (weekly, biweekly, monthly, quarterly, yearly), expectedAmount, amountTolerance, nextDate, status (detected / confirmed / dismissed), kind (bill, subscription, income, transfer) | → `Category`; → many `Transaction` |
| `BalanceSnapshot` | id, date, balance | → `Account` (unique per account per day) |
| `Loan` | id, servicer (MOHELA / Nelnet / other), borrower (me / dad), loanType, interestRate (APR %), principal, accruedInterest, minimumPayment, dueDay, source (plaid / manual), lastReconciledAt, expectedPayoffDate | → `Account`; → many `Transaction` (payments) |
| `Goal` | id, kind (saveUp / payDown), name, targetAmount, targetDate, monthlyContribution, strategy (avalanche / snowball / custom) | → many `Account`, `Loan`, `Transaction` |
| `Holding` | id, symbol, name, quantity, costBasis, latestPrice, priceDate, assetClass | → `Account` |
| `SavedReport` | id, name, kind, filters (Codable) | — |
| `DashboardLayout` | id, widgets \[WidgetConfig\] ordered | — |
| `ImportProfile` | id, columnMap (Codable), dateFormat, amountSign | → `Account` |

### Identity and deduplication

- Plaid transactions are unique on `plaidTransactionId`.
- CSV rows are unique on `importHash` = SHA-256 of account id + date + amount + normalized description + occurrence index for that day.
- A pending transaction that posts arrives with a new id and a `pending_transaction_id`. Update the existing row instead of inserting a new one, so edits and rules carry over.

## 6. Core logic

Every calculation is deterministic Swift. AI only suggests, and a suggestion becomes data only after a rule or the user accepts it.

### 6.1 Ingest pipeline

1. Fetch: Plaid `/transactions/sync` (added, modified, removed + next cursor), or parse CSV.
2. Normalize: trim and title-case the merchant, strip store numbers and card suffixes, map to a `Merchant` by `rawNames`.
3. Dedupe: upsert on `plaidTransactionId` or `importHash`; handle pending → posted.
4. Default category: Plaid `personal_finance_category` mapped to local categories, or the merchant's last-used category.
5. Rules: run enabled rules in order (6.2).
6. AI suggestion (P2): for transactions still uncategorized, queue an on-device suggestion; it sets `reviewStatus = needsReview`.
7. Recurring match: attach to a confirmed `RecurringStream` if merchant and amount fit.
8. Save the cursor only after the SwiftData save succeeds, so a crash re-pulls instead of dropping data.

### 6.2 Rules engine

| Part | Options |
| --- | --- |
| Conditions (all must match) | merchant contains / equals / regex; original description contains; amount equals / between / greater than; direction in / out; account in \[ids\]; category is |
| Actions | set category; rename merchant; add tags; hide; set review status; split by % or fixed amounts; link to loan; link to goal |
| Order | Rules run top to bottom; each matching rule applies its actions, and later rules can override earlier ones |
| Scope | New transactions on ingest; "apply to existing" with a preview count before commit |
| Manual edits | A field the user edited by hand is locked from rule changes |

### 6.3 Budget math

Each category's monthly result:

```latex
\text{Remaining}_m = \text{Rollover}_{m-1} + \text{Planned}_m - \text{Actual}_m
```

- `Rollover(m−1)` = the previous month's Remaining when rollover is on; otherwise 0. The first month uses `startingBalance`.
- `Actual` = the sum of non-hidden expense transactions in that category, excluding accounts with `hideFromBudget`.
- Flex mode: Flex remaining = flexPlanned + flexRollover − Σ actual over all flex-bucket categories. Category rollovers affect only category-level remaining, not the flex total.
- Left to budget = expected income − (fixed planned + non-monthly planned + flex planned + goal contributions).
- Transfers and loan payments are not expenses; they are typed `transfer` so cash flow does not double-count them.

### 6.4 Recurring detection

1. Group the last 400 days of outflows and inflows by normalized merchant.
2. For groups with 3 or more occurrences, compute the gaps between dates and their median.
3. Classify: weekly 6–8 days, biweekly 13–16, monthly 27–33, quarterly 85–95, yearly 355–375.
4. Accept when at least 70% of gaps fall in the band and amounts stay within ±10% of the median (±25% for utilities).
5. Create a `RecurringStream` with status `detected`; the user confirms or dismisses it in the Recurring inbox.
6. Next date = last date + the band's median gap; mark a stream late after nextDate + 5 days with no match.

### 6.5 Loan model

| Field | Plaid-linked loan | Manual loan |
| --- | --- | --- |
| Balance | From Liabilities, refreshed about daily | Computed locally |
| Rate, due date, payoff date | From Liabilities | Entered once |
| Payments | Bank transactions linked by a rule (e.g. merchant contains NELNET → link to Loan Nelnet) | Same |
| Reconcile | Not needed | Prompt monthly to enter the servicer's balance; store the difference as an adjustment |

Federal student loans accrue simple daily interest. Between payments:

```latex
\text{Interest} = \text{Principal} \times \frac{\text{APR}}{365} \times \text{days since last payment}
```

Each payment pays accrued interest first, then principal. Payoff projection steps month by month with the minimum payment plus any extra from the goal slider; avalanche orders loans by highest APR, snowball by lowest balance.

### 6.6 Net worth

- After every sync and at first launch each day, write one `BalanceSnapshot` per account (upsert on account + date).
- Net worth = Σ assets − Σ liabilities, excluding accounts with `hideFromNetWorth`.
- Days with no snapshot carry the last value forward on charts.

### 6.7 Cash flow

- Income = Σ inflows typed income; Expenses = Σ outflows typed expense; transfers excluded.
- Savings rate = (Income − Expenses) ÷ Income.
- Sankey: income categories → "Income" node → category groups → categories, plus a "Saved" node for the remainder. Swift Charts has no Sankey, so it is drawn with a custom `Canvas`.

### 6.8 Receivables (money owed to me)

New entities:

| Entity | Key fields | Relationships |
| --- | --- | --- |
| `Person` | id, name, aliases \[String\], isFamily | → many `Receivable` |
| `Receivable` | id, amount, amountPaid, status (open / requested / partial / paid / writtenOff), note, createdAt, requestedAt, paidAt | → `Person`; → 0..1 source `Transaction` (the charge); → many settlement `Transaction` (the repayments) |

Lifecycle:

```
CC charge "ELECTRIC CO $180"
   │  rule: merchant = electric co → Receivable(Dad, 100%)
   ▼
[open $180] ──Request button──► [requested] ──Zelle in $180──► [paid]
                                     │
                                     └─ Zelle in $100 ──► [partial, $80 left]
```

Rules and math:

- My spending for a shared charge = charge − Σ receivable amounts. Budget, cash flow, and categories use my share only.
- Incoming repayments are typed `reimbursement`: excluded from income, applied to the receivable.
- Matching: an inflow whose description contains a person's alias is matched to that person's open items. An exact amount match (one item, or the sum of several oldest-first) settles automatically; anything else goes to a suggestion card.
- Overpayment leaves a credit on the person that the next item uses first.
- Zelle has no public API, so requests go out as a copied message or share sheet; the app only records that a request was sent.
- Written-off amounts move back into my spending for that month.

### 6.9 Checks, health score, and forecast

Each check is a pure Swift function over local data that returns a status and, where possible, a yearly dollar impact. AI only writes the card's wording from that output.

| Check | Pass when | Impact estimate |
| --- | --- | --- |
| Savings rate | ≥ 10% of income (trailing 3 months) | Gap × 12 |
| Spending vs income | Expenses < income | Overspend × 12 |
| Budget pacing | Flex spent ≤ planned × (day of month ÷ days in month) + 10% | Projected overrun |
| Emergency fund | Liquid savings ≥ 3 months of fixed + flex spending | Months short |
| Idle cash | Savings APY ≥ a user-set benchmark (default 3.5%) | (benchmark − APY) × balance |
| High-rate debt vs cash | No debt above 8% APR while cash exceeds the emergency target | Interest saved by paying it down |
| Card utilization | Each card's balance < 30% of its limit before statement close | — (credit score effect, shown as a warning) |
| Loan extra payment | Shows interest saved by +$50 / +$100 per month | Interest saved over the loan's life |
| Subscription creep | Recurring subscriptions this month ≤ 3 months ago + 10% | Increase × 12 |
| Vehicle cost | Car payment + insurance + fuel or charging ≤ 20% of take-home | Overage × 12 |
| Receivables aging | No requested item older than 30 days | Amount outstanding |

Health score = weighted share of checks passing (pass = 1, warn = 0.5, fail = 0), × 100. Checks with missing data are skipped, not failed.

Forecast engine (monthly steps):

- Start: today's balances for every account.
- Each month: add income, subtract fixed + non-monthly + flex spending (trailing 3-month averages), apply loan amortization (6.5), grow savings at APY ÷ 12 and investments at the assumed return ÷ 12.
- Default assumptions: 6% investment return, 3% inflation, 3% yearly raise. All are editable.
- A milestone is a dated change to one input, such as income +$X from a date, a new car payment, rent starting, or a one-time outflow or inflow.
- P2: run 1,000 randomized return paths on device and show a 10th–90th percentile band instead of a single line.

### 6.10 Receipts, HSA, and shipments

New entities:

| Entity | Key fields | Relationships |
| --- | --- | --- |
| `Receipt` | id, source (email / scan / share), merchant, orderNumber, date, subtotal, tax, total, lineItems (Codable), fileBookmark (iCloud path), emailMessageId, hsaEligible, hsaStatus (unreimbursed / reimbursed / notApplicable), hsaReimbursedOn | → 0..1 `Transaction`; → many `Shipment` |
| `Shipment` | id, trackingNumber (unique), carrier, status (labelCreated / inTransit / outForDelivery / delivered / exception), eta, lastEvent, events (Codable), trackingURL, lastCheckedAt | → `Receipt`; → 0..1 `Transaction` |
| `EmailAccount` | id, provider (gmail / imap), address, lastHistoryId or lastUID | tokens and passwords in the Keychain |

Pipeline:

```
Email / scan / share
   │
   ▼
Clean to plain text ─► Vision OCR (images, PDFs)
   │
   ▼
Foundation Models @Generable ParsedReceipt
   │        (≤ 3,000 tokens of input; longer emails trimmed to the order section)
   ├─► Receipt ─► match Transaction ─► save file to iCloud Drive/Receipts/YYYY/MM/
   └─► tracking numbers ─► Shipment ─► carrier lookup via proxy
```

Email access:

- Gmail: the app talks to the Gmail API directly from the phone with read-only access; mail never passes through the proxy. The Google Cloud OAuth app is set to "In production" (unverified, single user) because Testing mode expires refresh tokens every 7 days.
- Other providers: IMAP over TLS with an app-specific password stored in the Keychain.
- Search filter: sender and subject keywords such as order, receipt, shipped, delivered, invoice, from the last 90 days. Only matching messages are downloaded.

Shipment tracking:

- Detect the carrier from the number pattern (UPS `1Z…`, USPS 20–22 digits starting with 9, FedEx 12 or 15 digits) or from the email's tracking link.
- Tracking link: the link from the email, or a carrier URL built from the number.
- Live status: a `/tracking` proxy route calls a tracking aggregator such as Ship24 (free plan with API access) or the carriers' own APIs, keeping the API key on the server. Only the tracking number leaves the phone.
- Amazon-delivered packages may not resolve through third-party lookups; those cards show the email's link only.

HSA:

- Eligibility is suggested for pharmacy, clinic, dental, and vision merchants and always confirmed by me; the app does not decide what is eligible.
- Receipts marked HSA-eligible are never auto-deleted.
- "Mark reimbursed" records the date and links the HSA withdrawal transaction when one exists.

## 7. On-device AI

All three AI features use Apple's `FoundationModels` framework and send nothing off the device. The 4,096-token window is the main design limit, so the model never receives raw transaction lists; it gets small typed inputs or calls tools that return pre-aggregated numbers.

### Features

| Feature | Pattern | Input | Output |
| --- | --- | --- | --- |
| Categorize | Guided generation, batched about 20 per session | Merchant, description, amount, direction, plus the category list (names only) | `@Generable struct CategorySuggestion { transactionId; categoryName; confidence }` |
| Weekly recap | Guided generation over computed facts | About 15 lines of aggregates: spend vs last week, top 3 categories, new recurring charges, net worth change | `@Generable struct Recap { headline; bullets [3–5]; callout? }` |
| Assistant | Tool calling in a `LanguageModelSession` | User question | Text answer; numbers come only from tool results |

### Assistant tools

| Tool | Arguments | Returns |
| --- | --- | --- |
| `spendingSummary` | dateRange, groupBy (category / merchant / tag), limit | Top N rows with totals |
| `findTransactions` | query, dateRange, minAmount, limit (≤ 10) | Compact rows: date, merchant, amount, category |
| `budgetStatus` | month | Planned, actual, remaining per bucket |
| `cashFlow` | dateRange | Income, expenses, net, savings rate |
| `netWorth` | dateRange | Start, end, change |
| `loanStatus` | loan (optional) | Balance, rate, next due, payoff date |
| `recurringUpcoming` | days | Upcoming charges |
| `currentDate` | — | Today's date (the model has no clock) |

### Rules for the AI layer

- Check `SystemLanguageModel.default.availability` before every feature; if unavailable (ineligible device, Apple Intelligence off, model downloading), hide the AI UI and keep rules-only behavior.
- Budget tokens with `tokenCount(for:)` and `contextSize`; start a new session when about 70% is used, carrying a one-line summary forward.
- Tool results stay under about 400 tokens each; truncate and say "top 10 of N".
- A suggested category shows a sparkle badge until the user accepts it; three accepts for one merchant offer to create a rule.
- Catch `exceededContextWindowSize` and guardrail errors and show a plain fallback message.

### Siri on iOS 27 (App Intents)

The new Siri reaches third-party apps only through App Intents, so the app exposes its data and actions as intents and entities. Siri then answers "how much flex do I have left?" or "log $12 cash for lunch" without opening the app. Siri's model is Apple's, and reporting says it is built on Gemini, so a Siri answer may be processed off-device by Apple. Siri access is therefore an opt-in setting, and intents return aggregates only.

| Entity (`AppEntity`) | Exposed fields | Indexed in Spotlight |
| --- | --- | --- |
| `AccountEntity` | name, type, balance | Yes |
| `CategoryEntity` | name, emoji, bucket | Yes |
| `LoanEntity` | servicer, borrower, balance, next due | Yes |
| `TransactionEntity` | date, merchant, amount, category | No (queried, not indexed) |
| `GoalEntity` | name, progress, target date | Yes |

| Intent | Example phrase | Kind | Guard |
| --- | --- | --- | --- |
| `GetFlexRemaining` | "How much flex budget is left?" | Read | Face ID |
| `GetSpending` (category?, period) | "What did I spend on food this month?" | Read | Face ID |
| `GetCashFlow` (period) | "What was my savings rate last month?" | Read | Face ID |
| `GetLoanStatus` (loan?) | "When is my Nelnet payment due?" | Read | Face ID |
| `GetNetWorth` | "What's my net worth?" | Read | Face ID |
| `AddManualTransaction` (amount, merchant, category?, account) | "Log $12 cash for lunch" | Write | Face ID + confirmation |
| `RecategorizeTransaction` (transaction, category) | "Move that Costco charge to groceries" | Write | Face ID + confirmation |
| `OpenScreen` (screen) | "Open my budget" | Navigate | None |
| `SyncNow` | "Refresh my accounts" | Action | Face ID |

Implementation rules:

- Every intent sets `authenticationPolicy = .requiresAuthentication`, so Siri never answers from a locked phone.
- Write intents call `requestConfirmation` showing the exact change before saving.
- Intents share query code with the in-app assistant's tools (section 7), so Siri and the assistant return the same numbers.
- Register `AppShortcutsProvider` phrases so the intents also work in Shortcuts and older Siri behavior.
- Settings toggle "Allow Siri to read my finances" (default off); when off, only `OpenScreen` is exposed.
- Build target stays iOS 26; the new Siri features light up on iOS 27 with no separate code path.

## 8. Proxy API and security

The proxy is a stateless FastAPI service on Render. It holds the Plaid client id and secret as environment variables, forwards calls, and stores nothing. Every request carries the access token from the phone's Keychain and an app key header.

### Endpoints

All routes are `POST` with JSON bodies, require the `X-App-Key` header, and return Plaid's response trimmed to the fields the app uses.

| Route | Plaid call | Request body | Response |
| --- | --- | --- | --- |
| `/link/token` | `/link/token/create` | `{ access_token? }` (present = update mode) | `{ link_token, expiration }` |
| `/item/exchange` | `/item/public_token/exchange` | `{ public_token, institution_id, account_masks[] }` | `{ access_token, item_id }` |
| `/transactions/sync` | `/transactions/sync` | `{ access_token, cursor? }` | `{ added[], modified[], removed[], next_cursor, has_more }` |
| `/accounts` | `/accounts/get` | `{ access_token }` | `{ accounts[] }` |
| `/liabilities` | `/liabilities/get` | `{ access_token }` | `{ student[], credit[] }` |
| `/investments` | `/investments/holdings/get` | `{ access_token }` | `{ holdings[], securities[] }` |
| `/item/status` | `/item/get` | `{ access_token }` | `{ error?, consent_expiration_time? }` |
| `GET /health` | — | — | `{ ok: true }` (no app key; used as a warm-up ping) |

No `/item/remove` route: on the Trial plan removal does not free a slot, so unlinking is a local-only action.

### Proxy rules

| Area | Rule |
| --- | --- |
| Secrets | `PLAID_CLIENT_ID`, `PLAID_SECRET`, `PLAID_ENV`, `APP_KEY` in Render env vars; `.env` in `.gitignore` |
| Storage | No database, no disk writes, no in-memory caching of responses |
| Logging | Method, route, status, latency only; request and response bodies never logged; uvicorn access log customized to drop query strings |
| Auth | Constant-time compare of `X-App-Key`; 401 otherwise. P2: add App Attest |
| Rate limit | 30 requests/min per IP in-process |
| Errors | Pass Plaid `error_code` through (e.g. `ITEM_LOGIN_REQUIRED` → app opens update mode) |
| Environments | Sandbox by default; Production only when `PLAID_ENV=production` |
| Cold start | App calls `/health` at launch and shows "Waking sync server…" for up to 60 s on the free tier |

### Device security

- Plaid access tokens and the app key in the Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- SwiftData store with `NSFileProtectionComplete`.
- Face ID gate on launch and after 1 minute in the background; app switcher shows a blurred snapshot.
- Encrypted backup to the app's iCloud Drive folder (iCloud Documents capability), weekly and on demand: JSON of all entities, AES-GCM with a passphrase-derived key; access tokens excluded (re-link after a restore uses update mode, so no new Items).

### Duplicate-Item guard

Before calling `/item/exchange`, the app compares the Link metadata's `institution_id` and account masks with existing `Institution` rows. On a match it aborts the exchange and opens update mode on the existing Item instead. This protects the 10-Item lifetime cap.

## 9. Milestones, risks, open questions

Build in four milestones; each ends with a gate tested on real data before the next starts. M1 needs no network at all, so the ledger is solid before Plaid is involved.

&#91;embedded content: milestones · 4 phases, 4 gates\]

Plaid work in M2 stays in Sandbox until sync, update mode, and the duplicate guard pass, and only then are the 5 real banks linked.

### Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| A wasted Plaid Item (duplicate or relink) | Permanently uses 1 of 10 slots | Duplicate guard, update mode only, Sandbox for all testing |
| MOHELA not supported by Plaid Liabilities | No auto balance for that loan | Manual loan with monthly reconcile; test via `/institutions/get` in Sandbox first |
| Parent PLUS is in dad's name | Linking needs his login and consent | Manual loan; payments still tracked from my bank |
| Render free tier sleeps | 30–60 s first sync | Warm-up ping at launch, or Starter at $7/mo |
| On-device model unavailable or weak | AI features fail or mislabel | Rules-first design; AI only suggests; availability check |
| 4,096-token context | Assistant runs out mid-chat | Tools return aggregates; reset session near 70% |
| FinanceKit entitlement not granted | No Apple Card sync | CSV import from Wallet export |
| Local data loss (phone lost) | All history gone | Weekly encrypted backup to iCloud Drive; restore from Settings |
| Proxy URL abuse | Burns Items or leaks tokens | App key header, rate limit, no storage; App Attest in P2 |

### Open questions

- [ ] Does Plaid's Trial plan support MOHELA for Liabilities?
- [ ] Will dad link the Nelnet Parent PLUS login, or stay manual?
- [ ] Render free tier or Starter ($7/mo)?
- [ ] Decided: encrypted backups go to iCloud Drive
- [ ] Decided: test device is iPhone 16 on iOS 27
- [ ] Apply for the FinanceKit entitlement now or after M3?

### Sources

- [Monarch Help: Flex budgeting](https://help.monarch.com/hc/en-us/articles/32125337244052), [Rollover budgets](https://help.monarch.com/hc/en-us/articles/4411119762196-Rollover-Budgets), [Transaction rules](https://help.monarch.com/hc/en-us/articles/360048393372), [AI features](https://help.monarch.com/hc/en-us/articles/16116906962452-About-Monarch-s-AI-Features)
- [Plaid: What is the Trial plan](https://support.plaid.com/hc/en-us/articles/39994173227159-What-is-the-Plaid-Trial-plan)
- [Plaid: Introduction to Liabilities](https://plaid.com/docs/liabilities/)
- [Apple: FinanceKit](https://developer.apple.com/financekit)
- [InfoQ: Foundation Models context window](https://infoq.com/news/2026/03/apple-foundation-models-context)
- [Render Community: free tier spin-down](https://community.render.com/t/which-paid-plan-or-option-should-i-go/23883)
