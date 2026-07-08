# CIBC PDF → Money Map reconciliation

**Date:** 2026-07-07
**Branch:** money-map-2-clarity-rework
**Goal:** Replace the stale chequing snapshot with real, reconciled transaction history for both CIBC accounts, so the app can show accurate income, where money flows, and flag anything due/wrong.

## Constraint
CIBC online banking exports **PDF statements only** — no CSV. Two layouts:
- **Chequing** (`87-76733`): `Date | Description | Withdrawals | Deposits | Balance` table.
- **Aeroplan Visa** (`…8421`): sections *Your payments*, *Your interest*, *Your new charges and credits* (the last carries CIBC's own Spend Category per row).

## Pipeline
```
CIBC PDF → [Claude transcribes + nets + checksums] → canonical CSV (one per account)
         → [app: deterministic header-aware parser] → TX store (reset first)
```
High-fidelity extraction is done by the model, not in-browser. The app gets one small, safe parser addition; the existing heuristic `parseCSV` is untouched for other files.

## Extraction rules (model-side, per statement)
- **Chequing:** read Date/Description/Withdrawals/Deposits; **ignore Balance**. Withdrawal→`out`, Deposit→`in`. Join multi-line descriptions.
- **Visa:** new charges → `out` (returns/credits → `in`) + capture CIBC Spend Category; interest → `out` (desc keeps "INTEREST"); payments ("PAYMENT THANK YOU") → `in`, account `credit`.
- **Reversal netting:** drop matched net-zero pairs — purchase ↔ `CORRECTION`, `SERVICE CHARGE` ↔ `SERVICE CHARGE DISCOUNT` — matched by amount + proximity.
- **Checksum (order matters):** transcribe ALL rows first, verify raw withdrawal/deposit sums equal the statement's printed summary totals (Visa: Purchases / interest / payments), THEN drop reversal pairs. A mismatch means a misread row.

## Canonical CSV schema
```
date,description,amount,direction,account,category
2026-05-06,TIM HORTONS #0892 MONTREAL QC,5.51,out,credit,Restaurants
2026-05-14,PAY 00000000029 132 Flex Depot,936.12,in,chequing,
```
- `description` **verbatim** — drives `special()` and `categorize()`.
- `amount` positive; `direction` explicit `in`/`out` (no sign-guessing).
- `category` filled for Visa rows only.

## App changes (`index.html`)
1. **Canonical parser branch:** if first line matches the canonical header, parse by column (deterministic). Else fall back to existing heuristic `parseCSV`.
2. **Per-row account:** honored from the CSV (`t.acct || acct`), bypassing `guessAcct`.
3. **Category seeding (fallback-only):** for a row carrying a CIBC category, apply it via `OVR[txKey]` **only if** `categorize(desc).c === 'Other'`. Known merchants keep the app's precise category. Mapping: Restaurants→Dining, Transportation→Transit, Retail and Grocery→Groceries, Health and Education→Health, Hotel/Entertainment/Recreation→Entertainment. Transient `.cat` field stripped after seeding.
4. **Transfers:** no new code — existing `special()` already excludes `INTERNET TRANSFER`/`TO CARD`/`PAYMENT THANK YOU`/`PAIEMENT MERCI`/`E-TRANSFER` from spend & income.

## Reset & load
Use existing **Wipe** (clears TX/trips/budgets, keeps bills), then import `cibc_chequing_2026.csv` + `cibc_visa_2026.csv`.

## Scope
- **In:** chequing Jan–May 2026, Visa Feb–Jun 2026.
- **Out:** in-app PDF parsing (future), the 2021 PDF, automated future-month flow.
- **Privacy:** generated CSVs hold personal financial data — **not committed to git**.

## Known behavior relied upon
All e-transfers (incl. person-to-person deposits) are excluded from income & spend by `special()`. Accepted as-is; revisit only if real incoming e-transfers should count as income.

## Verification
Per-statement raw checksums → `bash scripts/check.sh` → after import confirm spend/income exclude transfers and safe-to-spend is sane.
