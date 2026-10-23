# Sandbox acceptance checklist

Run on an iOS 26+ iPhone simulator with the local proxy configured. All real credential entry happens in your Plaid Dashboard or Plaid Link, not in the app code.

## 1. Local foundation

- Launch an empty app. Create a manual checking account with $1,000 and a card with $200 owed; net worth should be $800.
- Reconcile checking to $1,100; net worth becomes $900. Toggle its net-worth exclusion without changing its cash-flow/budget exclusion flags.
- Add a $50 groceries expense, a $10 groceries refund, $1,000 paycheck, and a $200 transfer. Posted spending should be $40 and income $1,000; the transfer is excluded.
- Edit the merchant, category, notes and tags. Review it with the trailing swipe action. Reopen the app and verify persistence.
- Split a $10.01 charge 50/50. The children should sum to $10.01, and the parent should not be counted again.
- Import a CSV twice, including identical same-day rows. The second import adds zero rows. Deliberately select a wrong date format: validation must block the entire import.
- Create a monthly category and flex plan; test a positive and negative rollover across consecutive months. Flex must not add category carryovers to its own rollover.

## 2. Normal Plaid Link

1. In Settings, save/test the local server URL and app key.
2. Add account → Banking & cards → Connect with Plaid.
3. Choose **First Platypus Bank**, sign in with `user_good` / `pass_good` (or `user_transactions_dynamic` / `pass_good`), select accounts, and finish.
4. Verify accounts and reported balances appear. Refresh until initial history finishes; no demo data should be inserted.
5. Refresh again: there should be no duplicated transactions. Restart the app and refresh to test persisted cursor/token recovery.

For non-OAuth credentials and test data, see [Plaid Sandbox test credentials](https://plaid.com/docs/sandbox/test-credentials/) and [Sandbox institutions](https://plaid.com/docs/sandbox/institutions/).

## 3. Instant Sandbox path and product screens

- On a fresh ledger, use the instant test-bank button instead of Link. This exercises Sandbox public-token creation, the same exchange function, Keychain persistence, and the normal sync writer. It does **not** exercise the Link UI.
- Use Loans & liabilities for First Gingham Credit Union and Investments for Tartan Bank. Verify returned student-loan fields and holdings. Holdings value must equal quantity × reported price.
- Bank/account data shown in the app must match the test Item’s Plaid response, with the Plaid positive-outflow sign inverted in the local ledger.

## 4. Incremental sync, duplicate prevention and re-auth

- Use a dynamic Transactions test user. In connection detail, tap **Generate the next transaction update**. Wait for Plaid to prepare it, then refresh. Confirm changes appear once.
- Edit a pending transaction’s merchant, category and notes before it posts. On the posted version, local ID and edits should survive. This transition also has a portable automated test; generated Sandbox data may need a custom scenario to force a specific pending pair.
- Run Link for an already connected institution with overlapping masks. Before exchange, the app must offer **Reconnect existing bank**, with one institution row remaining.
- In Settings → connection detail, tap **Simulate a broken bank login**. Sync should surface the reconnect state. Tap **Reconnect**, complete Link, and verify the Item ID stays unchanged. Update success must not exchange the returned public token.
- Try an incorrect app key and a stopped server. Show an actionable error; retain data/cursor. Correct the configuration and retry.
- Swift tests simulate modified/removed rows, replay, unknown accounts, and pagination mutation. Native persistence tests check that a failed commit retains the saved cursor.

## 5. Shared costs

- Add Dad with alias `ZELLE FROM DAD`; alias matching is case-insensitive.
- Mark a $180 utility charge as 100% owed by Dad. Your spending for that charge should be $0.
- Copy/share the request: record the requested date without sending anything automatically.
- Add/sync a $180 deposit with that alias; after sync it should auto-settle exactly one unambiguous receivable and be typed reimbursement, excluded from income.
- A $100 deposit against the $180 item should need confirmation; applying it leaves $80. An overpayment leaves a credit on the person. Writing off a partial item restores only the unpaid share to spending.

## 6. Security and backups

- Enable Face ID in Simulator: Features → Face ID → Enrolled. Turn on app lock in Settings; use Matching Face to authenticate.
- Background the app; app-switcher content should be obscured. Return after one minute: authenticate again.
- Export an encrypted backup to Files/iCloud Drive with a 12+ character passphrase. Inspect the file: merchant names and balances must not be visible.
- Restore with the correct passphrase into a fresh, empty installation; wrong passphrase/tampering must fail. Restore into a nonempty ledger must fail without changes.
- Reinstalling the simulator app may preserve Keychain data. Use a separate fresh simulator for a true new-device test. A fresh device has no Plaid access tokens: restoring a financial backup does not recover them.
- Inspect only proxy route/status logs: there must be no tokens, headers, financial responses, or query-string contents.

## 7. Receipts, HSA and shipments

Follow [the v0.2 setup and acceptance guide](RECEIPTS-HSA-SHIPMENTS.md). Receipt file imports, review, manual transaction attachment, HSA totals and ZIP/CSV exports can be tested without an email or carrier account. Gmail/IMAP, Share Extension signing, iCloud and Live Activities have separate setup steps. Use a physical iPhone for camera scanning.

Record the Xcode/iOS versions, native test result bundle, and live Link/update outcomes before calling these gates passed.
