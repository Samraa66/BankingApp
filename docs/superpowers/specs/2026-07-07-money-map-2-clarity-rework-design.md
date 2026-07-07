# Money Map 2.0 — clarity rework (design)

Date: 2026-07-07
Status: approved by user, ready for implementation planning

## Problem
Money Map already has the data and most features, but the owner (Sameer) reports
that when he opens the app he cannot quickly answer four questions:

1. Which months did I spend more vs. less? (no readable trend — the Sheet table is too dense)
2. Is this month normal / am I on track / how much can I actually spend?
3. Are the category totals trustworthy? (too much lands in "Other" or the wrong bucket)
4. What comes into my account? (income is a single number, no breakdown)

He selected all four as pain points and chose the most ambitious scope: rework the
whole experience. Constraints unchanged: single `index.html`, no backend, no
frameworks/deps, privacy-first (no analytics/external calls beyond the existing
Gmail feed), auto-deploys on Render.

## Goal
Make those four questions answerable within the first few seconds of opening the
app, without adding a 7th bottom-tab (mobile must stay usable) and without
breaking any existing data, keys, or flows.

## Non-goals
- No backend, no external services, no new runtime dependencies.
- No renaming of existing localStorage keys.
- No rewrite of the CSV parser, Gmail feed, dedupe, `special()`, or `txKey()`.
- Not splitting into modules/build step (stays one file per project convention).

## Design

### Tab structure (stays 6 tabs)
| Before | After |
|---|---|
| Home | **Overview** (redesigned dashboard) |
| Spending | **Spending** (polished + "Sort the rest" fixer) |
| Going out | **Income** (new) |
| Recurring | Going out |
| Trips | Recurring |
| Alerts | Trips |

`Alerts` folds into the Overview dashboard (Overview already surfaces a flags
summary card). This frees a slot for the new `Income` tab while keeping 6 tabs so
the mobile bottom bar stays uncluttered. Going out / Recurring / Trips are kept
and only lightly polished. The full alerts detail remains reachable from the
Overview flags card (tap → alerts view), so no functionality is lost.

### 1. Overview dashboard (addresses gaps #1, #2, #4)
Ordered top to bottom:

- **Safe-to-spend hero.** Headline number = `income − billsMonthly − savingsGoal −
  spentThisMonth`, framed as "$X left to spend this month". When the selected
  month is not the current calendar month, fall back to the existing kept/overspent
  framing so the number stays meaningful for historical months.
- **Monthly trend chart.** Inline SVG bar chart, one bar per loaded month (cap to a
  sensible recent window, e.g. last 12, with older rolled into scroll or omitted —
  decide in plan). Bar height = spend; income shown as a per-bar marker/line so
  in-vs-out is comparable at a glance. The selected month is highlighted. **Tapping
  a bar selects that month** (drives the existing month rail / `MONTH` state).
  Follows the `dataviz` skill: accessible (aria labels, not color-only), dark-mode
  aware, respects `prefers-reduced-motion`, tabular-num alignment.
- **Trend sentence.** One plain-language line under the chart:
  "You're spending $Y this month — N% below/above your K-month average of $Z."
- **On-track line.** For the current partial month: "At this pace you'll reach ~$X
  by month-end" using days elapsed vs. days in month.
- **"$X actually needed / month."** billsMonthly + detected-recurring + typical
  discretionary (median or trimmed average of non-committed months) = the real
  monthly cost of living. Answers "how much do I actually need".
- **Top 5 categories** (reuse existing `catRow`).
- **Alerts summary card** (existing behavior), tap → full alerts view.

### 2. Income tab (addresses gap #4)
- Money-in trend by month + running/average monthly income.
- **By source**: classify each income transaction into Payroll (Flex Depot),
  Government credit (QC solidarity), E-transfer in, Other — via a small
  income-source classifier (income is currently only run through the spend-oriented
  `categorize()`; add a light income classifier that does not disturb spend logic).
- Surface the **Mercor open item** as a gentle note ("income you mentioned that
  isn't showing in CIBC — where does it land?") so it is visible rather than silently
  excluded.
- Uses `incomeAll()` / `incomeF()` which already exclude transfers and card
  payments via `special()`, so no double-counting.

### 3. Trustworthy categories (addresses gap #3)
Two prongs:

- **"Sort the rest" card** on the Spending tab: surfaces everything currently in
  `Other` / uncategorized, largest first, with a one-tap category picker per merchant.
- **Persistent merchant rules.** New additive localStorage key `mm_rules_v1`
  mapping a merchant token → category. When the user categorizes an uncategorized
  charge, offer "apply to all like this", which derives a stable merchant token
  (strip trailing store numbers, city, province noise) and saves a rule so that
  merchant is categorized correctly for all past and future transactions.
- **Precedence in `catOf(t)`** (extended, not replaced):
  per-transaction override (`OVR`, `mm_catov_v1`) → user merchant rule
  (`mm_rules_v1`) → built-in `RULES` via `categorize()`. All aggregations continue
  to use `catOf`, never `categorize()` directly for totals.

### 4. Guardrails / things not touched
- No renamed keys; `mm_rules_v1` is purely additive.
- `special()`, `txKey()`, dedupe (`addTxs`), CSV parser, Gmail feed sync unchanged.
- `catOf()` extended to consult `mm_rules_v1`; its existing `OVR` and `categorize()`
  behavior preserved.
- Still one file, no build, no new external calls; auto-deploys on Render.
- Delete the stray byte-identical `index_3.html`.

## Data / storage
- New: `mm_rules_v1` = `{ merchantToken: categoryName }`.
- Unchanged: `mm_tx_v1`, `mm_bills_v1`, `mm_budgets_v1`, `mm_settings_v1`,
  `mm_trips_v1`, `mm_catov_v1`.

## Testing / verification
- `node --check` on the extracted script (project convention) before shipping.
- Drive the app in a browser with the built-in `SAMPLE` data to confirm: trend
  chart renders and is tappable, safe-to-spend math is correct, Income tab groups
  sources, "Sort the rest" assigns and persists a rule, dark mode + reduced motion
  OK, existing tabs still work.
- Never log or transmit transaction data.

## Open decisions to settle in the plan
- Trend chart month window (all vs. last 12) and how income marker is drawn.
- Exact "typical discretionary" statistic (median vs. trimmed mean).
- Merchant-token derivation rules for `mm_rules_v1` (how aggressively to strip
  store numbers / geography).
