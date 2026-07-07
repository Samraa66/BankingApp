# Money Map 2.0 — Clarity Rework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework Money Map so a user can answer "how much did I spend, how much came in, is this month high or low, how much can I safely spend" within seconds of opening the app.

**Architecture:** Single `index.html`, vanilla JS, no build, no deps. Add a reusable inline-SVG bar-chart helper, a redesigned Overview dashboard, a new Income tab, persistent merchant categorization rules, and a "Sort the rest" fixer. All existing state, keys, dedupe, CSV/Gmail flows preserved; `catOf()` is extended (not replaced) to consult a new additive rules store.

**Tech Stack:** HTML + vanilla JS + inline `<style>` + inline SVG. localStorage persistence. Verified with `node --check` and browser driving of the built-in `SAMPLE` dataset.

## Global Constraints

- **One file only.** All work lands in `index.html`. No build step, no frameworks, no runtime deps.
- **Privacy absolute.** No analytics, no external network calls beyond the existing Gmail feed fetch. Never log or transmit transaction data.
- **Do NOT rename existing localStorage keys:** `mm_tx_v1`, `mm_bills_v1`, `mm_budgets_v1`, `mm_settings_v1`, `mm_trips_v1`, `mm_catov_v1`. New keys must be additive only.
- **All spend aggregation uses `catOf(t)`, never `categorize()` directly** for category totals.
- **Do not modify** `special()`, `txKey()`, `addTxs()` dedupe, `parseCSV()`, or the Gmail `syncFeed()` logic.
- **Every JS change verified with `node --check`** on the extracted script before commit (extraction command in Task 0).
- **Dark mode + `prefers-reduced-motion` + accessibility:** all new UI must honor the existing dark-mode CSS variables, disable animation under reduced-motion, and not rely on color alone (use text/labels/aria).
- **Deploys as a static site on Render** (publish dir `./`, no build command). Nothing may require a build.
- Commit message trailer on every commit: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

## File Structure

- **Modify:** `index.html` — the entire app. New code slots into the existing sections:
  - `/* ===== storage =====*/` — add `KEY_RULES`.
  - `/* ===== categorization =====*/` — add `merchantToken()`, `incomeSource()`.
  - `/* ===== state =====*/` — add `RULESU` (user rules), `saveRules()`, extend `catOf()`.
  - `/* ===== views =====*/` — add `chartBars()` helper, rewrite `vHome()`→Overview, add `vIncome()`, add "Sort the rest" into `vWhere()`.
  - `nav.tabs` markup + `render()` switch — swap Alerts tab for Income; fold alerts into Overview.
- **Delete:** `index_3.html` (byte-identical stray duplicate).
- Reference spec: `docs/superpowers/specs/2026-07-07-money-map-2-clarity-rework-design.md`.

Note on "tests": this repo has no test runner. Each task's verification = (1) `node --check` on the extracted `<script>` and (2) explicit browser observations after loading `SAMPLE` (via the "Load sample" button in the Import dialog). The `SAMPLE` income rows are all `PAY Flex Depot` (payroll) across Jan–May 2026; spend rows span multiple categories and months — use these known facts as assertions.

---

### Task 0: Verification harness (extraction command)

**Files:**
- Create: `scripts/check.sh` (dev-only helper; not shipped to users but committed for repeatability)

**Interfaces:**
- Produces: a repeatable `node --check` command all later tasks reuse.

- [ ] **Step 1: Create the extraction + syntax-check script**

```bash
# scripts/check.sh — extract the inline <script> from index.html and syntax-check it
mkdir -p scripts
cat > scripts/check.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# Pull the contents of the LAST <script>…</script> block out of index.html and node --check it.
node -e '
const fs=require("fs");
const html=fs.readFileSync("index.html","utf8");
const m=[...html.matchAll(/<script>([\s\S]*?)<\/script>/g)];
if(!m.length){console.error("no <script> block found");process.exit(2);}
fs.writeFileSync("/tmp/mm_check.js", m[m.length-1][1]);
'
node --check /tmp/mm_check.js && echo "node --check: OK"
SH
chmod +x scripts/check.sh
```

- [ ] **Step 2: Run it against the current file**

Run: `bash scripts/check.sh`
Expected: `node --check: OK`

- [ ] **Step 3: Commit**

```bash
git add scripts/check.sh
git commit -m "chore: add node --check extraction harness for index.html"
```

---

### Task 1: Persistent merchant rules + extend `catOf()`

Foundation for trustworthy categories. Adds an additive `mm_rules_v1` store of `{ TOKEN: category }`, matched by substring against the uppercased description (mirroring how built-in `RULES` already match), consulted after per-transaction overrides but before built-in rules.

**Files:**
- Modify: `index.html` — storage keys block (~line 272), state block (~lines 390–404).

**Interfaces:**
- Produces:
  - `KEY_RULES = 'mm_rules_v1'`
  - `RULESU` — object `{ TOKEN: categoryName }` loaded from storage.
  - `saveRules()` — persists `RULESU`.
  - `merchantToken(desc): string` — suggested stable token for a description.
  - `catOf(t)` extended precedence: `OVR[txKey] → user rule (RULESU substring) → categorize(desc).c`.

- [ ] **Step 1: Add the storage key**

In the `const KEY_TX=…` line (~line 272), append `, KEY_RULES='mm_rules_v1'`.

- [ ] **Step 2: Add user-rules state + saver + token helper**

After `let OVR = JSON.parse(store.get(KEY_CATOV)||'{}');` (~line 390) add:

```js
let RULESU = JSON.parse(store.get(KEY_RULES)||'{}');   // { TOKEN(uppercase): category }
const saveRules=()=>store.set(KEY_RULES,JSON.stringify(RULESU));
// Suggest a stable, human-readable token for a raw description so a rule can match all
// charges from the same merchant. Strips processor prefixes, store numbers, and geography noise.
function merchantToken(desc){
  let u=upper(desc).replace(/[*#]/g,' ');
  u=u.replace(/\b(SQ|TST|TST-|POS|IC|SP|PAYPAL|PP|Q|AMZN|MKTP)\b/g,' '); // processor/prefix noise
  u=u.replace(/\b[A-Z]{2}\b$/,' ');                                       // trailing province code
  const words=u.split(/\s+/).filter(w=>w.length>1 && !/\d/.test(w));      // drop numbers/store IDs
  return words.slice(0,2).join(' ').trim() || upper(desc).trim().slice(0,18);
}
```

- [ ] **Step 3: Extend `catOf()` to consult user rules**

Replace the existing `function catOf(t){ return OVR[txKey(t)]||categorize(t.desc).c; }` (~line 399) with:

```js
function userRuleCat(desc){
  const u=upper(desc);
  for(const [tok,cat] of Object.entries(RULESU)){ if(tok && u.includes(tok)) return cat; }
  return null;
}
function catOf(t){ return OVR[txKey(t)] || userRuleCat(t.desc) || categorize(t.desc).c; }
```

- [ ] **Step 4: Syntax check**

Run: `bash scripts/check.sh`
Expected: `node --check: OK`

- [ ] **Step 5: Browser verification**

Load the app, open Import → "Load sample". In the browser console run:
```js
RULESU={'PETRO':'Transit'}; saveRules(); render();
```
Expected: the `Q PETRO-CANADA` charge now counts under **Transit** in Spending (not Gas & convenience), proving the rule takes precedence over built-in `RULES` but that a per-tx override would still win. Reset with `RULESU={};saveRules();render();`.

- [ ] **Step 6: Commit**

```bash
git add index.html
git commit -m "feat: persistent merchant rules (mm_rules_v1) consulted by catOf"
```

---

### Task 2: Reusable inline-SVG bar-chart helper

A single `chartBars()` used by both Overview and Income. **Before writing it, load the `dataviz` skill** and apply its guidance (accessible, consistent, dark-mode, no color-only encoding).

**Files:**
- Modify: `index.html` — views section, near the other helpers (after `scopeLabel()`, ~line 457). Add matching CSS in `<style>`.

**Interfaces:**
- Consumes: `CAD`, existing CSS variables.
- Produces:
  - `chartBars(series, opts): string` where `series` = `[{key:'2026-01', label:'Jan', spend:Number, income:Number}]`, `opts` = `{selected?:'2026-01', onbar?:'data-m'}`. Returns an SVG string. Bars encode `spend`; `income` is drawn as a horizontal marker line per bar. Selected bar gets a distinct outline + bold label (not color-only). Each bar carries `data-m="<key>"` for tap-to-select wiring by the caller.

- [ ] **Step 1: Add chart CSS**

In `<style>` (after the `.strip` block, ~line 144) add:
```css
  .chart{width:100%;margin:6px 0 2px}
  .chart .bar{cursor:pointer}
  .chart .bar rect{transition:opacity .2s}
  .chart .bar:hover rect{opacity:.85}
  .chart .lbl{font-family:var(--mono);font-size:9px;fill:var(--faint)}
  .chart .lbl.on{fill:var(--ink);font-weight:700}
  .chart .inc{stroke:var(--money);stroke-width:2;stroke-linecap:round}
  .chart .sel{fill:none;stroke:var(--ink);stroke-width:1.5}
  @media (prefers-reduced-motion:reduce){.chart .bar rect{transition:none}}
```

- [ ] **Step 2: Add `chartBars()`**

After `function scopeLabel(){…}` add:
```js
// Inline SVG monthly bars. spend = bar height; income = green marker line. Accessible + dark-mode.
function chartBars(series, opts){
  opts=opts||{};
  if(!series.length) return '<div class="empty">No months loaded yet.</div>';
  const W=Math.max(series.length*46,120), H=132, pad=18, bw=26, gap=(W-pad*2-bw*series.length)/Math.max(1,series.length-1||1);
  const max=Math.max(1,...series.map(s=>Math.max(s.spend,s.income||0)));
  const y=v=>pad + (H-pad*2) * (1 - v/max);
  const bars=series.map((s,i)=>{
    const x=pad + i*(bw+gap);
    const sel=opts.selected===s.key;
    const col=CAT_COLORS.Rent, spendCol='var(--pine)';
    const bh=(H-pad*2)*(s.spend/max);
    const incY=s.income?y(s.income):null;
    return `<g class="bar" data-m="${s.key}" role="button" tabindex="0"
        aria-label="${s.label}: spent ${CAD(s.spend)}${s.income?', in '+CAD(s.income):''}">
      <rect x="${x}" y="${H-pad-bh}" width="${bw}" height="${Math.max(bh,1)}" rx="4"
        fill="${sel?'var(--money)':'var(--faint)'}"></rect>
      ${sel?`<rect class="sel" x="${x-1.5}" y="${H-pad-bh-1.5}" width="${bw+3}" height="${bh+3}" rx="5"></rect>`:''}
      ${incY!=null?`<line class="inc" x1="${x-2}" y1="${incY}" x2="${x+bw+2}" y2="${incY}"></line>`:''}
      <text class="lbl ${sel?'on':''}" x="${x+bw/2}" y="${H-5}" text-anchor="middle">${s.label}</text>
    </g>`;
  }).join('');
  return `<svg class="chart" viewBox="0 0 ${W} ${H}" preserveAspectRatio="xMidYMid meet"
      role="img" aria-label="Monthly spending${series.some(s=>s.income)?' and income':''} by month">
    ${bars}</svg>`;
}
```

- [ ] **Step 3: Syntax check**

Run: `bash scripts/check.sh` → Expected `node --check: OK`.

- [ ] **Step 4: Commit**

```bash
git add index.html
git commit -m "feat: reusable inline-SVG monthly bar chart helper (dataviz-guided)"
```

---

### Task 3: Income tab + income-source classifier

Adds the new Income view and swaps it into the nav (Alerts leaves nav in Task 4).

**Files:**
- Modify: `index.html` — categorization section (add `incomeSource`), views (add `vIncome`), nav markup, `render()` switch, `wire()`.

**Interfaces:**
- Consumes: `incomeAll()`, `incomeF()`, `chartBars()`, `monthsAvailable()`, `CAD`, `fmtDate`.
- Produces: `incomeSource(desc): string` (one of `Payroll`, `Government credit`, `E-transfer in`, `Other`); `vIncome(): string`.

- [ ] **Step 1: Add income-source classifier**

After `function special(desc){…}` (~line 332) add:
```js
function incomeSource(desc){
  const u=upper(desc);
  if(u.includes('FLEX DEPOT')||u.includes('PAYROLL')||u.startsWith('PAY ')) return 'Payroll';
  if(u.includes('SOLIDARITY')||u.includes('SOLIDARITE')||u.includes('CREDIT')||u.includes('CANADA')||u.includes('GST')||u.includes('GOUV')) return 'Government credit';
  if(u.includes('E-TRANSFER')||u.includes('VIREMENT')||u.includes('DEPOSIT')) return 'E-transfer in';
  return 'Other';
}
```

- [ ] **Step 2: Add `vIncome()` view**

After `vHome()` add (uses month-scoped `incomeF()` unless MONTH==='all'):
```js
function vIncome(){
  const inc=incomeAll();                                   // all income, transfers already excluded
  const ms=monthsAvailable().slice().reverse();
  const byMonth={}, spendByMonth={};
  for(const t of inc){ const mo=t.date.slice(0,7); byMonth[mo]=(byMonth[mo]||0)+t.amt; }
  for(const t of spendAll()){ const mo=t.date.slice(0,7); spendByMonth[mo]=(spendByMonth[mo]||0)+t.amt; }
  const series=ms.map(m=>({key:m,label:new Date(m+'-15T00:00').toLocaleDateString('en-CA',{month:'short'}),
    spend:byMonth[m]||0, income:0}));  // here bars encode income; no marker
  const totalIn=incomeF().reduce((s,t)=>s+t.amt,0);
  const avg=ms.length?Object.values(byMonth).reduce((a,b)=>a+b,0)/ms.length:0;
  const bySrc={};
  for(const t of incomeF()){ const s=incomeSource(t.desc); bySrc[s]=(bySrc[s]||{total:0,n:0}); bySrc[s].total+=t.amt; bySrc[s].n++; }
  const srcRows=Object.entries(bySrc).sort((a,b)=>b[1].total-a[1].total)
    .map(([s,v])=>`<div class="brow"><span class="bn">${s} <span class="bc">${v.n}×</span></span><span class="ba mono">${CAD(v.total)}</span></div>`).join('')
    || '<div class="empty">No income in this period.</div>';
  return `
  <div class="receipt">
    <div class="eyebrow">Money in · ${scopeLabel()}</div>
    <div class="line"><span>${MONTH==='all'?'Average / month':'This month'}</span><b class="mono">${CAD(MONTH==='all'?avg:totalIn)}</b></div>
    <hr class="tear">
    <div class="total"><span class="lbl">${MONTH==='all'?'total in, all months':monthName(MONTH)}</span>
      <span class="big mono pos">${CAD(MONTH==='all'?Object.values(byMonth).reduce((a,b)=>a+b,0):totalIn)}</span></div>
  </div>
  <div class="card">
    <div class="chead"><h2>What comes in, by month</h2><span class="cap">bars = income</span></div>
    ${chartBars(series,{selected:MONTH!=='all'?MONTH:null})}
  </div>
  <div class="card">
    <div class="chead"><h2>Where it comes from</h2><span class="cap">${scopeLabel()}</span></div>
    ${srcRows}
  </div>
  <div class="card">
    <div class="chead"><h2>Heads up</h2></div>
    <div class="flag"><div class="ft">Is anything missing?</div><div class="fb">If you earn from sources that don't hit your CIBC chequing (e.g. <b>Mercor</b>), they won't show here. This view only sees deposits in your imported data.</div></div>
  </div>`;
}
```

- [ ] **Step 3: Swap the Alerts tab button for Income**

In `<nav class="tabs">` replace the `data-t="heads"` button with an Income button (keep an SVG; use a downward-arrow-into-tray glyph):
```html
    <button class="tab" data-t="income"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v12M7 10l5 5 5-5"/><path d="M4 21h16"/></svg>Income</button>
```
Move this button to sit right after the "Spending" tab so order reads Home · Spending · Income · Going out · Recurring · Trips.

- [ ] **Step 4: Route the new tab in `render()`**

In the `view.innerHTML = TAB==='home'?…` chain add `:TAB==='income'?vIncome()` and remove the trailing `:vHeads()` fallback for `heads` only after Task 4 folds alerts in. For now, keep `heads` reachable via `TAB==='heads'?vHeads()` so nothing breaks:
```js
  view.innerHTML = TAB==='home'?vHome():TAB==='where'?vWhere():TAB==='income'?vIncome():TAB==='goingout'?vGoingOut():TAB==='recurring'?vRecurring():TAB==='trips'?vTrips():vHeads();
```
Also allow the empty-state guard to render Income: change `if(!TX.length && TAB!=='recurring')` to `if(!TX.length && TAB!=='recurring' && TAB!=='income')`.

- [ ] **Step 5: Wire chart bar taps (shared wiring)**

In `wire()` add near the top:
```js
  view.querySelectorAll('.chart .bar[data-m]').forEach(b=>{
    const go=()=>{MONTH=b.dataset.m;render();};
    b.onclick=go; b.onkeydown=e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();go();}};
  });
```

- [ ] **Step 6: Syntax check + browser verify**

Run: `bash scripts/check.sh` → `node --check: OK`.
Browser: Load sample → tap **Income**. Expect: bars per month Jan–May; "Where it comes from" shows **Payroll** (all SAMPLE income is Flex Depot); tapping a bar selects that month in the rail and re-scopes the numbers; Mercor note present.

- [ ] **Step 7: Commit**

```bash
git add index.html
git commit -m "feat: Income tab with by-month chart and source breakdown"
```

---

### Task 4: Overview dashboard rework + fold Alerts in

Rewrites `vHome()` into the dashboard: safe-to-spend hero, monthly trend chart (spend bars + income markers, tap-to-select), trend sentence, on-track projection, "actually needed / month", top categories, and the alerts summary (Alerts leaves the nav).

**Files:**
- Modify: `index.html` — `vHome()` (~lines 459–493), nav (remove leftover heads tab if any), `render()` switch.

**Interfaces:**
- Consumes: `sumOutF`, `sumInF`, `byCategoryF`, `billMonthly`, `detectRecurring`, `headsData`, `chartBars`, `monthsAvailable`, `SETTINGS`, `spendAll`.
- Produces: rewritten `vHome()`; helpers `monthlySpendSeries()`, `neededPerMonth()`.

- [ ] **Step 1: Add dashboard helper functions**

Before `vHome()` add:
```js
function monthlySpendSeries(){
  const ms=monthsAvailable().slice().reverse();
  const sp={}, ic={};
  for(const t of spendAll()) sp[t.date.slice(0,7)]=(sp[t.date.slice(0,7)]||0)+t.amt;
  for(const t of incomeAll()) ic[t.date.slice(0,7)]=(ic[t.date.slice(0,7)]||0)+t.amt;
  return ms.map(m=>({key:m,label:new Date(m+'-15T00:00').toLocaleDateString('en-CA',{month:'short'}),
    spend:sp[m]||0, income:ic[m]||0}));
}
function neededPerMonth(){
  const bm=billMonthly();
  const rec=detectRecurring().reduce((s,r)=>s+r.perMonth,0);
  // typical discretionary = median monthly spend minus bills, floored at 0
  const series=monthlySpendSeries().map(s=>s.spend).sort((a,b)=>a-b);
  const med=series.length?series[Math.floor(series.length/2)]:0;
  const disc=Math.max(0, med-bm-rec);
  return bm+rec+disc;
}
```

- [ ] **Step 2: Rewrite `vHome()`**

Replace the whole `vHome()` body with:
```js
function vHome(){
  const out=sumOutF(), inc=sumInF();
  const cats=byCategoryF();
  const sorted=Object.entries(cats).sort((a,b)=>b[1].total-a[1].total);
  const bm=billMonthly(), safe=SETTINGS.income-bm-SETTINGS.savings;
  const series=monthlySpendSeries();
  const avg=series.length?series.reduce((s,x)=>s+x.spend,0)/series.length:0;
  // current-month figures for hero + on-track
  const curKey=(MONTH==='all')?(series.length?series[series.length-1].key:null):MONTH;
  const curSpend=curKey?(series.find(s=>s.key===curKey)||{spend:out}).spend:out;
  const left=safe-curSpend;
  // on-track projection only when curKey is the latest (current) month
  const isLatest=curKey && series.length && curKey===series[series.length-1].key;
  const d=new Date(curKey+'-15T00:00'); const dim=new Date(d.getFullYear(),d.getMonth()+1,0).getDate();
  const dayNow=(MONTH==='all')?dim:Math.min(dim, new Date().getDate());
  const proj=isLatest && dayNow>0 ? curSpend/dayNow*dim : null;
  const diffPct=avg?Math.round((curSpend-avg)/avg*100):0;
  const go=sorted.filter(([c])=>GOING_OUT.has(c)).reduce((s,[,d])=>s+d.total,0);
  const flags=headsFlagsCount();
  const needed=neededPerMonth();
  return `
  <div class="receipt">
    <div class="eyebrow">${MONTH==='all'?'This month · safe to spend':monthName(MONTH)+' · safe to spend'}</div>
    <div class="line"><span>Money in</span><b class="mono">${CAD(inc)}</b></div>
    <div class="line"><span>Money out</span><b class="mono">${CAD(out)}</b></div>
    <hr class="tear">
    <div class="total"><span class="lbl">${left>=0?'Left to spend':'Over your plan by'}</span>
      <span class="big mono ${left>=0?'pos':'neg'}">${CAD(Math.abs(left))}</span></div>
    <div class="plan">Plan: <b class="mono">${CAD(safe)}</b>/mo after bills &amp; savings${proj!=null?` · at this pace you'll reach <b class="mono">${CAD(proj)}</b> by month-end`:''}</div>
  </div>
  <div class="card">
    <div class="chead"><h2>Which months you spend more</h2><span class="cap">tap a bar</span></div>
    ${chartBars(series,{selected:MONTH!=='all'?MONTH:(curKey||null)})}
    <p class="cap" style="margin:8px 0 0">${avg?`${MONTH==='all'?'Latest month':monthName(MONTH)} spend <b>${CAD(curSpend)}</b> — ${diffPct===0?'right at':Math.abs(diffPct)+'% '+(diffPct>0?'above':'below')} your ${series.length}-month average of <b>${CAD(avg)}</b>.`:'Load a few months to see your trend.'}</p>
  </div>
  <div class="strip">
    <div class="stat"><div class="k">Going out</div><div class="v mono">${CAD(go)}</div></div>
    <div class="stat"><div class="k">Bills / mo</div><div class="v mono">${CAD(bm)}</div></div>
    <div class="stat"><div class="k">Needed / mo</div><div class="v mono">${CAD(needed)}</div></div>
  </div>
  ${flags?`<div class="card" style="cursor:pointer" id="goHeads"><div class="chead" style="margin:0"><h2>⚠ ${flags} thing${flags>1?'s':''} worth a look</h2><span class="link">Review →</span></div></div>`:''}
  <div class="card">
    <div class="chead"><h2>Top spending</h2><button class="link" id="goWhere">All categories →</button></div>
    ${sorted.slice(0,5).map(([c,dd])=>catRow(c,dd,out,{max:4})).join('')||'<div class="empty">No spending in this period.</div>'}
  </div>
  <div class="card">
    <div class="chead"><h2>Monthly plan</h2><span class="cap">saved automatically</span></div>
    <div class="plan-row"><span class="pl">Take-home income / month</span><input class="pin mono" id="setIncome" value="${SETTINGS.income}" inputmode="decimal"></div>
    <div class="plan-row"><span class="pl">Savings goal / month</span><input class="pin mono" id="setSavings" value="${SETTINGS.savings}" inputmode="decimal"></div>
  </div>`;
}
```

- [ ] **Step 3: Keep the alerts view reachable, remove `heads` from nav only**

`vHeads()` stays defined and `TAB==='heads'` still routes to it (the Overview `#goHeads` card sets `TAB='heads'`). Confirm the nav no longer has a `data-t="heads"` button (removed in Task 3). The `render()` fallback already ends in `:vHeads()` so `TAB='heads'` works without a nav button.

- [ ] **Step 4: Syntax check + browser verify**

Run: `bash scripts/check.sh` → OK.
Browser: Load sample. On **Home/Overview** expect: hero shows "Left to spend"; a bar per month Jan–May with the latest highlighted and a green income marker on each; trend sentence names the % vs average; "Needed / mo" stat present; tapping the ⚠ card opens the alerts view; tapping a bar re-scopes. Toggle OS dark mode — chart stays legible.

- [ ] **Step 5: Commit**

```bash
git add index.html
git commit -m "feat: Overview dashboard — safe-to-spend, trend chart, on-track, needed/mo"
```

---

### Task 5: "Sort the rest" fixer on Spending

Surfaces uncategorized/`Other` spend and lets the user assign a category once and apply it to all like charges via a saved merchant rule (Task 1 store).

**Files:**
- Modify: `index.html` — `vWhere()` (~lines 494–508), `wire()`.

**Interfaces:**
- Consumes: `catOf`, `merchantToken`, `RULESU`, `saveRules`, `CAT_COLORS`, `CAD`.
- Produces: `vSortRest(): string` (a card), wiring for its selects/buttons.

- [ ] **Step 1: Add `vSortRest()`**

Before `vWhere()` add:
```js
function vSortRest(){
  const groups={};
  for(const t of spendF()){ if(catOf(t)!=='Other') continue; const tok=merchantToken(t.desc);
    groups[tok]=groups[tok]||{total:0,n:0,desc:t.desc}; groups[tok].total+=t.amt; groups[tok].n++; }
  const rows=Object.entries(groups).sort((a,b)=>b[1].total-a[1].total).slice(0,12);
  if(!rows.length) return '';
  const cats=Object.keys(CAT_COLORS).filter(c=>c!=='Other');
  const total=rows.reduce((s,[,v])=>s+v.total,0);
  return `<div class="card">
    <div class="chead"><h2>Sort the rest</h2><span class="cap">${CAD(total)} uncategorized</span></div>
    <p class="cap" style="margin:0 0 8px">Pick a bucket for each — it sticks for every charge from that place, past and future.</p>
    ${rows.map(([tok,v])=>`<div class="txrow"><span class="dot" style="background:#93A096"></span>
      <div class="txl"><b>${tok}</b><span class="txd">${v.n}× · ${v.desc.slice(0,38)}</span></div>
      <select class="catsel" data-tok="${encodeURIComponent(tok)}" aria-label="Category for ${tok}">
        <option value="" selected>choose…</option>${cats.map(c=>`<option>${c}</option>`).join('')}</select>
      <span class="txa mono">${CAD(v.total)}</span></div>`).join('')}
  </div>`;
}
```

- [ ] **Step 2: Inject it at the top of the Categories sub-view**

In `vWhere()`, in the `cats` branch (the `return seg+...` at ~line 503), prepend `vSortRest()`:
```js
  return seg+vSortRest()+`<div class="card">
    <div class="chead"><h2>Where every dollar went</h2><span class="cap">${scopeLabel()}</span></div>
```

- [ ] **Step 3: Wire the Sort-the-rest selects**

In `wire()` add:
```js
  view.querySelectorAll('.catsel[data-tok]').forEach(sel=>sel.onchange=()=>{
    const tok=decodeURIComponent(sel.dataset.tok), v=sel.value; if(!v) return;
    RULESU[tok]=v; saveRules(); toast(`“${tok}” → ${v}`); render();
  });
```

- [ ] **Step 4: Syntax check + browser verify**

Run: `bash scripts/check.sh` → OK.
Browser: Load sample → Spending → Categories. If any charges are in Other, they appear under "Sort the rest"; choosing a bucket makes the row leave Other and the category totals update immediately; reloading the page keeps the assignment (persisted in `mm_rules_v1`). If SAMPLE has no Other items, add one via console: `TX.push({date:'2026-05-09',desc:'ZZZ MYSTERY SHOP MTL QC',amt:40,dir:'out'});saveTX();render();` then verify it appears and can be sorted.

- [ ] **Step 5: Commit**

```bash
git add index.html
git commit -m "feat: Sort the rest — one-tap categorize uncategorized via saved rules"
```

---

### Task 6: Polish, cleanup, and full smoke test

**Files:**
- Delete: `index_3.html`
- Modify: `index.html` (only if smoke test surfaces issues)

- [ ] **Step 1: Delete the stray duplicate**

```bash
git rm index_3.html
```

- [ ] **Step 2: Accessibility + reduced-motion pass**

Confirm in the browser with `prefers-reduced-motion` enabled (macOS: System Settings → Accessibility → Display → Reduce motion) that bar hover/opacity transitions are disabled and nothing animates. Confirm each chart bar is keyboard-focusable (Tab) and Enter selects the month. Confirm chart `aria-label`s read spend/income values.

- [ ] **Step 3: Full smoke test (all tabs, both themes)**

Load sample, then walk: Overview (hero, chart, trend sentence, needed/mo, alerts card), Spending (Sort the rest, categories, Sheet, Transactions + re-categorize), Income (chart, sources, Mercor note), Going out, Recurring, Trips (add a trip), Import dialog (CSV drop still parses, Gmail feed field persists, Reset works). Repeat in dark mode. Confirm no console errors and no network calls except an optional Gmail fetch.

- [ ] **Step 4: Final syntax check**

Run: `bash scripts/check.sh` → `node --check: OK`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: remove stray index_3.html; final polish + smoke test"
```

---

## Self-Review (author)

**Spec coverage:**
- Tab restructure (6 tabs, Alerts→Overview, +Income) → Tasks 3, 4. ✓
- Overview dashboard: safe-to-spend, trend chart, trend sentence, on-track, needed/mo, top cats, alerts summary → Task 4. ✓
- Income tab: by-month trend, by-source, avg, Mercor note → Task 3. ✓
- Trustworthy categories: Sort the rest + persistent merchant rules + `catOf` precedence → Tasks 1, 5. ✓
- Chart follows dataviz, dark-mode, reduced-motion, a11y → Tasks 2, 6. ✓
- Guardrails: additive `mm_rules_v1`, no key renames, `special`/`txKey`/dedupe/CSV/Gmail untouched, one file → Global Constraints + honored per task. ✓
- Delete `index_3.html` → Task 6. ✓
- Open decisions settled: month window = all loaded months (chart scrolls via SVG width); income marker = per-bar green line; discretionary stat = median; merchant token = strip prefixes/store#/province, first 2 words. ✓

**Placeholder scan:** No TBD/TODO; every code step shows real code. ✓

**Type consistency:** `chartBars(series,opts)` series shape `{key,label,spend,income}` used identically in Tasks 2/3/4. `merchantToken`/`RULESU`/`saveRules`/`userRuleCat`/`catOf` names consistent across Tasks 1/5. `incomeSource` returns the four labels used in Task 3. ✓
