/**
 * ============================================================================
 * S4K ORDER LIFECYCLE + STATUS CHECKER  v3.6.0  (2026-10-27)
 * Bump VERSIONV3 + the CHANGELOG below on every change; runAllV3 logs the version.
 * ============================================================================
 *
 * ONE project, ONE lock, ONE cascade. Replaces:
 *   - Lifecycle.gs        (email-driven bought / filled + daily triage)
 *   - Unified checker     (API pollers, filled sweep, Supabase sync)
 *
 * CASCADE ORDER (runAllV3, every CHECKER_INTERVAL_MINV3)
 *   0. VIP tagging          -> vip_order on new sales with total > VIP_THRESHOLDV3
 *   1. AutoBuy POC emails   -> bought           (label _POC, unread)
 *   2. Final SUCCESS emails -> bought | filled  (label SUCCESS, unread)
 *   3. Stale A_Today        -> bought           (prior-day A_Today + Step 2 confirmation, every 12h)
 *   (3a/3b moved to Supabase + S4K_GmailRelay.gs in v3.6.0; kept here as manual one-offs)
 *   3a. need2Buy confirmed  -> bought           (need2Buy sale + Step 2+ SUCCESS email, 30 min)
 *   3b. need2Buy passed     -> drop Need2Buy/WaitToBuy + need2Buy + triage once the event is 24h+
 *                              past (hourly) — the rule Supabase uses to close the N2B row
 *   4. CRM status           -> filled/cancel/ISSUE (Supabase crm_order_status_lookup; see below)
 *   5. Sweeps: bought+need2Buy -> drop need2Buy;
 *              filled -> drop need2Buy + triage, read, archive (10 threads/run)
 *   6. Triage refresh
 *
 * CRM STATUS (replaces the per-site API pollers in the cascade)
 *   The open sale threads in the inbox (per site, same query the pollers used) are read
 *   for their Site Order #, and ONLY those order #s are sent — batched, one HTTP call per
 *   CRM_CHUNKV3 orders — to the Supabase RPC crm_order_status_lookup. It answers from:
 *     - s4kcs_orders   the CRM open-orders feed (crm.s4kcs.com, refreshed every 10 min)
 *     - evo/seatgeek/gotickets/vivid/tickpick order tables (terminal states only)
 *     - n2s_items / n2s_profitable_cover (fail reason, delivery timer, cover found)
 *   Verdicts:
 *     filled     marketplace says delivered/completed     -> filled label, read, archive
 *     closed     off the CRM open-orders feed >= 3 pulls  -> same as filled (CRM_CLOSED_IS_FILLEDV3)
 *     cancelled  marketplace/CRM says cancelled/rejected  -> cancel label, drop need2Buy + triage, read
 *     open       still owed -> ISSUE + unread ONLY when the CRM shows a problem:
 *                substitution / issue / under review / re-transfer, unconfirmed,
 *                past in-hand date, or N2S timer expired with no cover bought.
 *                CRM "subbed" (cover bought) -> bought.
 *     feed_stale / not_found -> no action (logged).
 *   TickPick, Gametime and Viagogo are covered too, with no marketplace API creds.
 *   The old API pollers (_checkTevoV3 etc.) are kept as manual entry points only.
 *
 * EMAIL RULES (source-agnostic, keyed on INTERNAL order #)
 *   - "[SUCCESS] AutoBuy POC ... for Order #N"          -> bought
 *   - "Final SUCCESS | <Site> <site#> | N | <acct>"
 *        body has [Step 8]   -> filled (per-site label under "Filled Sent")
 *        body has no [Step 8]-> bought (ped-sg lane: Step 3 invoice only)
 *   - bought: add `bought`, remove `need2Buy`, strip triage, mark sale + trigger read.
 *     ped-sg lane also marks the matching **SGBUY SeatGeek purchase email read
 *     (matched on the Final SUCCESS "Rowing Order#" = SeatGeek order number).
 *     `bought` is permanent. Sale thread stays in inbox for the CRM status step.
 *   - filled: add site filled label, remove `need2Buy`, strip triage, mark read,
 *     archive; trigger read.
 *   - no matching sale thread / unmapped site -> trigger stays UNREAD, retried next run.
 *
 * STALE A_TODAY (every 12h)
 *   A_Today sale threads whose sale email is from a prior calendar day: if a
 *   "Order #N | [SUCCESS] [Step 2+/8]" email (Order Confirmed, Downloaded Invoice, ...) exists with the same
 *   Site Order#, mark bought (drops A_Today + need2Buy) and mark both read.
 *
 * VIP
 *   New sale threads with order total > $1,500 get `vip_order`. Permanent label.
 *   Run backfillVipOrdersV3() once to tag the last 30 days.
 *
 * TRIAGE (inside the cascade; runTriageRefreshV3 kept as manual entry point)
 *   Sets exactly one of A_Today / A_Tomorrow / A_Soon on unread sale threads
 *   by event date. Skips bought/filled threads and past events.
 *
 * MIGRATION
 *   All globals carry a V3 suffix so this can sit beside the old M2 file.
 *   Saved state uses its own keys (v3_lastRun_*, v3_vipLastScan, v3_crmOffset_*), so the
 *   two builds never share timers. installAllTriggersV3() removes the M2 triggers,
 *   so only one build runs at a time.
 *   1. Back up. Add this file to the project.
 *   2. diagnoseLabelsV3() + checkLabelsV3() -> fix any MISSING names in LABELSV3/SITESV3.
 *   3. diagnoseSetupV3() -> SUPABASE_PROJECT_URL, SUPABASE_ANON_KEY, APPSCRIPT_INGEST_SECRET
 *      must be SET (the CRM step needs only these). testCrmLookupV3('vivid','<site order #>').
 *   4. TEST_MODEV3 = true, run runAllV3() manually, read logs, flip to false.
 *   5. installAllTriggersV3().
 *   6. need2Buy subs: add Terminal-2's scripts/apps_script/n2b_sync.gs to this project as a
 *      second file (same Script Properties) and run installN2bSyncTrigger(). Subs show on
 *      the Terminal SUBS page.
 *   TickPick API: set TICKPICK_USERNAME + TICKPICK_PASSWORD; tokens are then fetched and
 *   renewed automatically (testTickPickAuthV3). A pasted TICKPICK_API_TOKEN expires ~14 days.
 *   Project time zone must be America/New_York (stale A_Today uses local midnight).
 *
 * CHANGELOG
 *   3.6.0  2026-10-27  need2Buy confirmed (3a) and need2Buy passed (3b) leave the cascade:
 *                      Supabase decides them now and S4K_GmailRelay.gs applies the labels
 *                      every minute. Both functions stay as manual one-offs.
 *   3.5.2  2026-10-27  Gmail quota: need2Buy confirmed caches each sale's Order # / Site
 *                      Order # and finds Step 2+ SUCCESS emails in batched searches (20 per
 *                      search) instead of one search per thread; cadence 15 -> 30 min.
 *   3.5.1  2026-10-27  need2Buy confirmed / stale A_Today accept any "[SUCCESS] [Step k/x]"
 *                      email with k >= 2 (e.g. Step 3 Downloaded Invoice), not only Step 2.
 *   3.5.0  2026-10-27  need2Buy confirmed: a need2Buy sale whose "[SUCCESS] [Step 2/x] Order
 *                      Confirmed" email exists (same Order # + Site Order #) -> bought,
 *                      dropping Need2Buy/WaitToBuy. Any age, not just stale A_Today.
 *   3.4.0  2026-10-26  Bought / filled / cancelled also drop Need2Buy/WaitToBuy, so the
 *                      PED row in Supabase closes (sweeps search both need2Buy labels).
 *   3.3.0  2026-10-26  need2Buy passed: drop the need2Buy labels once the event is 24h+ past.
 *   3.2.0  2026-10-26  need2Buy subs board retired; Terminal-2's n2b_sync.gs feeds the SUBS page.
 *   3.1.0  2026-10-26  CRM status lookup (crm_order_status_lookup) replaces the marketplace
 *                      API pollers; TickPick OAuth token auto-renew.
 *   3.0.0  2026-08     Merged build (Lifecycle.gs + unified checker).
 * ============================================================================
 */

const VERSIONV3 = '3.6.0';

/* ───────────────────────────── SWITCHES ───────────────────────────── */

const TEST_MODEV3  = false;   // true => log intended actions, touch nothing
const DEBUG_DUMPV3 = false;   // true => dump API response keys

const CHECKER_INTERVAL_MINV3 = 10;   // how often the single runAllV3 trigger fires

// Per-step cadence (minutes). A step only runs when at least this long has
// passed since it last ran (tracked in Script Properties). 0 = every fire.
// Sized for the consumer 90 min/day trigger budget — see quota notes.
const CADENCE_MINV3 = {
  vip:        0,     // tag new sales over VIP_THRESHOLDV3 (cheap, only scans new mail)
  autobuy:    0,     // AutoBuy POC emails    (cheap, time-sensitive)
  finalsucc:  0,     // Final SUCCESS emails  (cheap, time-sensitive)
  n2bconfirm: 30,    // need2Buy sale + Step 2+ SUCCESS email -> bought
  staletoday: 720,   // stale A_Today -> bought via Step 2 confirmation (every 12h)
  n2bpassed:  60,    // event passed -> drop need2Buy labels (Supabase closes these as 'event passed')
  crm:        30,    // CRM status — one batched RPC; CRM feed itself refreshes every 10 min
  sweep:      0,     // filled cleanup        (cheap)
  triage:     0,     // A_Today/Tomorrow/Soon tagging of new + stale sale threads
  tevo:       120,   // API pollers — manual entry points only (no longer in the cascade)
  vivid:      120,
  seatgeek:   120,
  tickpick:   120,
  gotickets:  120,
};
const SYNC_INTERVAL_MINV3    = 30;
const SYNC_TICKPICK_ENABLEDV3 = false; // TickPick API returns 401; the CRM covers TickPick now
const TRIAGE_HOURV3          = 5;
const LOCK_WAIT_MSV3         = 60000;
const SWEEP_ARCHIVEV3        = true;
const SWEEP_MAX_PER_RUNV3    = 10;
const EMAIL_MAX_PER_RUNV3    = 50;
const STALE_TODAY_MAXV3      = 50;

const VIP_THRESHOLDV3      = 1500;  // total strictly above this -> vip_order
const VIP_LOOKBACK_HOURSV3 = 24;    // first run only
const VIP_BACKFILL_DAYSV3  = 30;    // used by backfillVipOrdersV3()

// CRM status step
const CRM_SITESV3            = ['tevo', 'vivid', 'seatgeek', 'tickpick', 'gotickets', 'gametime', 'viagogo'];
const CRM_MAX_PER_SITEV3     = 60;    // threads per site per run; rotates through larger backlogs
const CRM_CHUNKV3            = 200;   // orders per RPC call (server max 500)
const CRM_CLOSED_IS_FILLEDV3 = true;  // off the CRM open-orders feed => treat as filled
const CRM_CANCEL_FALLBACKV3  = 'ISSUE/Cancelled'; // for sites whose SITESV3.canceled is null

const TICKPICK_API_BASEV3 = 'https://api.tickpick.com/1.0';

// need2Buy labels (Terminal-2's n2b_sync.gs reads Need2Buy/WaitToBuy). When the event is
// more than N2B_PASSED_HOURSV3 past — the rule n2b_ingest_from_apps_script uses to close a
// row as 'event passed' — these are removed so the thread leaves the N2B book.
const N2B_LABELSV3       = ['Need2Buy/WaitToBuy', 'need2Buy'];
const N2B_PASSED_HOURSV3 = 24;
const N2B_PASSED_MAXV3   = 200;

/* ───────────────────────────── LABELSV3 ───────────────────────────── */

const LABELSV3 = {
  success:  'SUCCESS',
  poc:      '_POC',
  sgbuy:    '**SGBUY',   // SeatGeek "Your tickets are available" purchase emails
  need2buy: 'need2Buy',
  bought:   'bought',
  order:    'Order',
  issue:    'ISSUE',
  vip:      'vip_order',
  filledParent: 'Filled Sent',
  today:    'A_Today',
  tomorrow: 'A_Tomorrow',
  soon:     'A_Soon',
};
LABELSV3.triage = [LABELSV3.today, LABELSV3.tomorrow, LABELSV3.soon];

const SITESV3 = {
  tevo:      { name: 'Ticket Evolution', siteLabel: '*TEVO', filled: 'Filled Sent/Filled-Evo',      canceled: 'Issue/cancelled' },
  vivid:     { name: 'Vivid Seats',      siteLabel: '*VS',   filled: 'Filled Sent/Filled-Vivid',    canceled: null },
  seatgeek:  { name: 'SeatGeek',         siteLabel: '*SG',   filled: 'Filled Sent/Filled-SeatGeek', canceled: null },
  tickpick:  { name: 'TickPick',         siteLabel: '*TP',   filled: 'Filled Sent/Filled-TickPick', canceled: 'ISSUE/Cancelled' },
  gotickets: { name: 'GoTickets',        siteLabel: '*go',   filled: 'Filled Sent/Filled-Go',       canceled: 'ISSUE/Cancelled' },
  viagogo:   { name: 'Viagogo',          siteLabel: '*VG',   filled: 'Filled Sent/Filled-Viagogo',  canceled: null },
  gametime:  { name: 'Gametime',         siteLabel: '*GT',   filled: 'Filled Sent/Filled-Gametime', canceled: null },
};

// Site Order # in the PEDDLING SALE RECEIVED body, per site (first match wins).
const CRM_ORDER_PATTERNSV3 = {
  tevo:      [/Site Order\s*#\s*([a-zA-Z0-9\-]+)/i],
  vivid:     [/Site Order\s*#\s*(\d+)/i],
  seatgeek:  [/Site Order\s*#\s*([a-zA-Z0-9]+)/i],
  tickpick:  [/Site Order\s*#\s*([a-zA-Z0-9]+)/i, /Order\s*Number\s*:?\s*([a-zA-Z0-9]+)/i,
              /Order\s*#\s*([a-zA-Z0-9]+)/i, /TickPick\s*Order\s*:?\s*([a-zA-Z0-9]+)/i],
  gotickets: [/Site Order\s*#\s*(\d+)/i, /Order\s*Number\s*:?\s*(\d+)/i, /Order\s*#\s*(\d+)/i,
              /GoTickets\s*Order\s*:?\s*(\d+)/i, /Sale\s*ID\s*:?\s*(\d+)/i],
  _default:  [/Site Order\s*#\s*([a-zA-Z0-9\-]+)/i],
};

// Site string as it appears in "Final SUCCESS | <Site> <site#> | ..." / body "Site:" -> SITESV3 key
const SITE_ALIASESV3 = {
  'vivid seats': 'vivid', 'vivid': 'vivid', 'vividseats': 'vivid',
  'viagogo': 'viagogo',
  'seatgeek': 'seatgeek', 'seat geek': 'seatgeek',
  'tickpick': 'tickpick', 'tick pick': 'tickpick',
  'gotickets': 'gotickets', 'go tickets': 'gotickets', 'go': 'gotickets',
  'ticket evolution': 'tevo', 'tevo': 'tevo', 'evo': 'tevo',
  'gametime': 'gametime', 'gametime.co': 'gametime', 'game time': 'gametime',
};

const TRIAGEV3 = { soonWindowDays: 5, bufferDays: 0, maxThreads: 500 };

/* ═════════════════════════ ORCHESTRATOR + LOCK ═════════════════════════ */

function runAllV3() {
  withScriptLockV3_('runAll', function () {
    console.log('S4K Order Lifecycle v' + VERSIONV3 + (TEST_MODEV3 ? ' (TEST MODE)' : ''));
    const cascade = [
      ['VIP tagging',      'vip',        _tagVipOrdersV3],
      ['AutoBuy bought',   'autobuy',    _processAutoBuyBoughtV3],
      ['Final SUCCESS',    'finalsucc',  _processFinalSuccessV3],
      ['Stale A_Today',    'staletoday', _processStaleTodayV3],
      // need2Buy confirmed / passed moved to Supabase (S4K_GmailRelay.gs, v3.6.0);
      // _processNeed2BuyConfirmedV3 / _clearPassedNeed2BuyV3 stay as manual one-offs.
      ['CRM status',       'crm',        _checkCrmStatusV3],
      ['Filled sweep',     'sweep',      _sweepFilledThreadsV3],
      ['Triage refresh',   'triage',     _processTriageRefreshV3],
    ];
    const props = PropertiesService.getScriptProperties();
    const now = Date.now();
    cascade.forEach(function (entry) {
      const label = entry[0], key = entry[1], fn = entry[2];
      const cadence = CADENCE_MINV3[key] || 0;
      const last = Number(props.getProperty('v3_lastRun_' + key) || 0);
      const dueIn = Math.round((last + cadence * 60000 - now) / 60000);
      if (cadence > 0 && dueIn > 0) {
        console.log('⏭️  ' + label + ': skipped, next in ~' + dueIn + ' min');
        return;
      }
      const t0 = Date.now();
      try {
        console.log('\n========== ' + label + ' ==========');
        fn();
      } catch (e) {
        console.error('❌ [' + label + '] aborted: ' + e.message);
      }
      props.setProperty('v3_lastRun_' + key, String(now));
      console.log('(' + label + ' took ' + Math.round((Date.now() - t0) / 1000) + 's)');
    });
    console.log('\n=== CASCADE COMPLETE ===');
  });
}

/** Force every step to run on the next runAllV3 (clears cadence timers). */
function resetCadenceV3() {
  const props = PropertiesService.getScriptProperties();
  Object.keys(CADENCE_MINV3).forEach(function (k) { props.deleteProperty('v3_lastRun_' + k); });
  console.log('Cadence timers cleared.');
}

function runTriageRefreshV3() { withScriptLockV3_('Triage', _processTriageRefreshV3); }
function syncTickPickToSupabaseV3() { withScriptLockV3_('Supabase sync', _syncTickPickToSupabaseV3); }

// Manual / legacy entry points
function tagVipOrdersV3()              { withScriptLockV3_('VIP',        _tagVipOrdersV3); }
function processAutoBuyBoughtV3()      { withScriptLockV3_('AutoBuy',    _processAutoBuyBoughtV3); }
function processFinalSuccessV3()       { withScriptLockV3_('FinalSucc',  _processFinalSuccessV3); }
function processStaleTodayV3()         { withScriptLockV3_('StaleToday', _processStaleTodayV3); }
function clearPassedNeed2BuyV3()       { withScriptLockV3_('N2BPassed',  _clearPassedNeed2BuyV3); }
function checkCrmStatusV3()            { withScriptLockV3_('CRM',        _checkCrmStatusV3); }
function checkTevoOrderStatusV3()      { withScriptLockV3_('TEVO',       _checkTevoV3); }
function checkVividOrderStatusV3()     { withScriptLockV3_('Vivid',      _checkVividV3); }
function checkSeatGeekOrderStatusV3()  { withScriptLockV3_('SeatGeek',   _checkSeatGeekV3); }
function checkTickPickOrderStatusV3()  { withScriptLockV3_('TickPick',   _checkTickPickV3); }
function checkGoTicketsOrderStatusV3() { withScriptLockV3_('GoTickets',  _checkGoTicketsV3); }
function sweepFilledThreadsV3()        { withScriptLockV3_('Sweep',      _sweepFilledThreadsV3); }

function withScriptLockV3_(taskName, fn) {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(LOCK_WAIT_MSV3)) {
    console.log('⏭️  [' + taskName + '] lock held; skipping (next trigger catches up).');
    return;
  }
  try { fn(); } finally { try { lock.releaseLock(); } catch (e) {} }
}

/* ═════════════════════════ VIP ORDERS ═════════════════════════ */

/** Re-scan the last VIP_BACKFILL_DAYSV3 days once (run manually after install). */
function backfillVipOrdersV3() {
  PropertiesService.getScriptProperties().setProperty('v3_vipLastScan',
    String(Math.floor(Date.now() / 1000) - VIP_BACKFILL_DAYSV3 * 86400));
  tagVipOrdersV3();
}

/** Tags sale threads with a total above VIP_THRESHOLDV3 as vip_order. Only looks at
 *  sales since the last scan (10-min overlap), so each run stays cheap. The label is
 *  never removed by the lifecycle — it survives bought / filled / archive. */
function _tagVipOrdersV3() {
  const props = PropertiesService.getScriptProperties();
  const nowSec = Math.floor(Date.now() / 1000);
  const last = Number(props.getProperty('v3_vipLastScan') || (nowSec - VIP_LOOKBACK_HOURSV3 * 3600));
  const since = last - 600;
  const q = 'subject:"PEDDLING SALE RECEIVED" -label:"' + LABELSV3.vip + '" after:' + since;

  let start = 0, scanned = 0, tagged = 0, batch;
  do {
    batch = GmailApp.search(q, start, 100);
    batch.forEach(function (thread) {
      scanned++;
      const msg = thread.getMessages()[0];
      const total = parseSaleTotalV3_(msg.getSubject(), msg.getPlainBody());
      if (total === null) { console.log('VIP: no total in "' + msg.getSubject() + '"'); return; }
      if (total <= VIP_THRESHOLDV3) return;
      if (TEST_MODEV3) { console.log('🧪 VIP: would tag $' + total + ' "' + msg.getSubject() + '"'); return; }
      if (applyLabelV3_(thread, LABELSV3.vip)) { tagged++; console.log('⭐ VIP $' + total + ': ' + msg.getSubject()); }
    });
    start += batch.length;
  } while (batch.length === 100 && start < 500);

  if (!TEST_MODEV3) props.setProperty('v3_vipLastScan', String(nowSec));
  console.log('VIP: scanned ' + scanned + ', tagged ' + tagged);
}

/** "$360.00" from the subject, falling back to the body "Total $360.00" row. */
function parseSaleTotalV3_(subject, body) {
  let m = subject.match(/PEDDLING SALE RECEIVED\s+\d+\s+\$([\d,]+(?:\.\d{1,2})?)/i);
  if (!m) m = body.match(/^\s*Total\s*\$([\d,]+(?:\.\d{1,2})?)/im);
  return m ? parseFloat(m[1].replace(/,/g, '')) : null;
}

/* ═════════════════════════ EMAIL-DRIVEN LIFECYCLE ═════════════════════════ */

/** "[SUCCESS] AutoBuy POC - B2B Order #X created for Order #N (Ticket #T) | STA-PROD-05" */
function _processAutoBuyBoughtV3() {
  const threads = GmailApp.search(
    'label:' + LABELSV3.poc + ' is:unread subject:"AutoBuy POC"', 0, EMAIL_MAX_PER_RUNV3);
  console.log('AutoBuy: ' + threads.length + ' unread');

  threads.forEach(function (trigger) {
    const msg = trigger.getMessages()[0];
    const subject = msg.getSubject();
    // Only the [SUCCESS] verdict means bought. [FAILED] etc. are left untouched
    // (and unread) for manual handling — their body still carries a TU Order #,
    // so without this gate the fallback parser would wrongly mark them bought.
    if (!/^\[SUCCESS\]/i.test(subject)) {
      console.log('AutoBuy: non-success verdict, skipping "' + subject + '"');
      return;
    }
    const orderNo = parseAutoBuyOrderV3_(subject, msg.getPlainBody());
    if (!orderNo) { console.log('AutoBuy: no order # in "' + subject + '"'); return; }

    const sales = findSaleThreadsV3_(orderNo);
    if (!sales.length) { console.log('AutoBuy ' + orderNo + ': no SALE RECEIVED thread, leaving unread'); return; }

    if (TEST_MODEV3) { console.log('🧪 AutoBuy ' + orderNo + ': would mark BOUGHT on ' + sales.length + ' thread(s).'); return; }
    if (sales.every(markBoughtV3_)) {
      trigger.markRead();
      console.log('✅ AutoBuy ' + orderNo + ' -> bought (' + sales.length + ' thread(s))');
    }
  });
}

/** "Final SUCCESS | <Site> <site#> | N | <acct>"  (optional "[TA-...]" prefix) */
function _processFinalSuccessV3() {
  const threads = GmailApp.search(
    'label:' + LABELSV3.success + ' is:unread subject:"Final SUCCESS"', 0, EMAIL_MAX_PER_RUNV3);
  console.log('FinalSuccess: ' + threads.length + ' unread');

  threads.forEach(function (trigger) {
    const msg = trigger.getMessages()[0];
    const subject = msg.getSubject();
    const body = msg.getPlainBody();
    const p = parseFinalSuccessV3_(subject, body);
    if (!p.orderNo) { console.log('FinalSuccess: no order # in "' + subject + '"'); return; }

    const sales = findSaleThreadsV3_(p.orderNo);
    if (!sales.length) { console.log('FinalSuccess ' + p.orderNo + ': no SALE RECEIVED thread, leaving unread'); return; }

    const isFilled = /\[Step 8\]/i.test(body);
    if (isFilled) {
      const cfg = siteConfigForV3_(p.site);
      if (!cfg) { console.log('FinalSuccess ' + p.orderNo + ': unmapped site "' + p.site + '", leaving unread'); return; }
      if (TEST_MODEV3) { console.log('🧪 FinalSuccess ' + p.orderNo + ': would FILL ' + sales.length + ' thread(s) as ' + cfg.filled); return; }
      if (sales.every(function (t) { return markFilledV3_(t, cfg.filled); })) {
        trigger.markRead();
        console.log('✅ FinalSuccess ' + p.orderNo + ' -> ' + cfg.filled + ' (' + sales.length + ' thread(s))');
      }
    } else {
      if (TEST_MODEV3) { console.log('🧪 FinalSuccess ' + p.orderNo + ': would mark BOUGHT on ' + sales.length + ' thread(s) (no Step 8).'); return; }
      if (sales.every(markBoughtV3_)) {
        trigger.markRead();
        console.log('✅ FinalSuccess ' + p.orderNo + ' -> bought (' + sales.length + ' thread(s), ped-sg)');
        if (p.rowingOrder) markSgBuyReadV3_(p.rowingOrder, p.orderNo);
      }
    }
  });
}

function parseAutoBuyOrderV3_(subject, body) {
  let m = subject.match(/for Order #(\d+)/i);
  if (m) return m[1];
  m = body.match(/TU Order #\s*(\d+)/i);
  return m ? m[1] : null;
}

function parseFinalSuccessV3_(subject, body) {
  const out = { orderNo: null, site: null, rowingOrder: null };
  const m = subject.match(/Final SUCCESS\s*\|\s*(.+?)\s+([A-Za-z0-9\-]+)\s*\|\s*(\d+)\s*\|/i);
  if (m) { out.site = m[1].trim(); out.orderNo = m[3]; }
  if (!out.orderNo) { const b = body.match(/Order#:\s*(\d+)/i); if (b) out.orderNo = b[1]; }
  if (!out.site)    { const s = body.match(/^Site:\s*(.+)$/im);  if (s) out.site = s[1].trim(); }
  // SG B2B order id — matches the "Order number" in the SeatGeek purchase email
  const r = body.match(/Rowing Order#:\s*([A-Za-z0-9]+)/i);
  out.rowingOrder = r ? r[1].trim() : null;
  return out;
}

function siteConfigForV3_(site) {
  if (!site) return null;
  const key = SITE_ALIASESV3[site.trim().toLowerCase()];
  return key ? SITESV3[key] : null;
}

/** All PEDDLING SALE RECEIVED threads for an internal order # — the original
 *  plus any "Re:" replies that split into their own thread. Read or unread,
 *  inbox or archive. Returns [] if none. */
function findSaleThreadsV3_(orderNo) {
  const threads = GmailApp.search('subject:"PEDDLING SALE RECEIVED ' + orderNo + '"', 0, 10);
  const re = new RegExp('PEDDLING SALE RECEIVED\\s+' + orderNo + '\\b', 'i');
  return threads.filter(function (t) { return re.test(thread_subjectV3_(t)); });
}
function thread_subjectV3_(t) { try { return t.getFirstMessageSubject() || ''; } catch (e) { return ''; } }

/** SeatGeek purchase emails ("Your tickets are available on SeatGeek!", label
 *  **SGBUY) carry the SG order number = the Final SUCCESS "Rowing Order#".
 *  Mark every unread one for this order as read. Labels untouched. */
function markSgBuyReadV3_(rowingOrder, orderNo) {
  const q = 'label:"' + LABELSV3.sgbuy + '" is:unread "' + rowingOrder + '"';
  const threads = GmailApp.search(q, 0, 10);
  if (!threads.length) { console.log('  SGBUY ' + rowingOrder + ': no unread SeatGeek email (ok)'); return; }
  const re = new RegExp('\\b' + rowingOrder + '\\b', 'i');
  let n = 0;
  threads.forEach(function (t) {
    const hit = t.getMessages().some(function (m) { return re.test(m.getPlainBody()); });
    if (hit) { t.markRead(); n++; }
  });
  console.log('  SGBUY ' + rowingOrder + ': marked ' + n + ' SeatGeek email(s) read for order ' + orderNo);
}

/* ═════════════════════════ STALE A_TODAY -> BOUGHT ═════════════════════════ */

/** A_Today sale threads from a prior day: if a "[SUCCESS] [Step 2+/8]" (Order Confirmed, Invoice, ...)
 *  email exists for the same Order # + Site Order #, mark bought (drops A_Today +
 *  need2Buy, marks sale read) and mark the confirmation read. Otherwise leave alone. */
function _processStaleTodayV3() {
  const threads = GmailApp.search(
    'label:"' + LABELSV3.today + '" subject:"PEDDLING SALE RECEIVED"', 0, STALE_TODAY_MAXV3);
  console.log('Stale A_Today: ' + threads.length + ' labeled thread(s)');
  if (!threads.length) return;

  const startOfToday = new Date(); startOfToday.setHours(0, 0, 0, 0);
  const stats = { fresh: 0, noIds: 0, noConfirm: 0, bought: 0, failed: 0 };

  threads.forEach(function (thread) {
    const msg = thread.getMessages()[0];
    if (msg.getDate() >= startOfToday) { stats.fresh++; return; }

    const subject = msg.getSubject();
    const o = subject.match(/PEDDLING SALE RECEIVED\s+(\d+)/i);
    const s = msg.getPlainBody().match(/Site Order\s*#\s*([A-Za-z0-9\-]+)/i);
    if (!o || !s) { stats.noIds++; console.log('Stale A_Today: missing order/site # in "' + subject + '"'); return; }
    const orderNo = o[1], siteOrder = s[1].trim();

    const confirm = findOrderConfirmedV3_(orderNo, siteOrder);
    if (!confirm) {
      stats.noConfirm++;
      console.log('Stale A_Today ' + orderNo + ' (' + siteOrder + '): no Step 2 confirmation, leaving as is');
      return;
    }

    let sales = findSaleThreadsV3_(orderNo);   // catches split "Re:" threads too
    if (!sales.length) sales = [thread];

    if (TEST_MODEV3) { console.log('🧪 Stale A_Today ' + orderNo + ' (' + siteOrder + '): would mark BOUGHT on ' + sales.length + ' thread(s)'); return; }
    if (sales.every(markBoughtV3_)) {
      confirm.markRead();
      stats.bought++;
      console.log('✅ Stale A_Today ' + orderNo + ' (' + siteOrder + ') -> bought');
    } else stats.failed++;
  });
  console.log('Stale A_Today summary: ' + JSON.stringify(stats));
}

/** Returns the thread holding an "Order #N | [SUCCESS] [Step k/x] ..." email for
 *  any step k >= 2 (Step 2 Order Confirmed, Step 3 Downloaded Invoice, ...) whose
 *  body has "Site Order#: <siteOrder>", or null. Step 2+ succeeding means the
 *  order was bought and accepted (Step 1 is the purchase itself). */
function findOrderConfirmedV3_(orderNo, siteOrder) {
  const threads = GmailApp.search('"' + siteOrder + '" subject:SUCCESS subject:Step', 0, 10);
  const subjRe = new RegExp('Order #' + orderNo + '\\b.*\\[SUCCESS\\]\\s*\\[Step [2-8]/\\d+\\]', 'i');
  const siteRe = new RegExp('Site Order#:\\s*' + escapeRegexV3_(siteOrder) + '(?![A-Za-z0-9])', 'i');
  for (let i = 0; i < threads.length; i++) {
    const hit = threads[i].getMessages().some(function (m) {
      return subjRe.test(m.getSubject()) && siteRe.test(m.getPlainBody());
    });
    if (hit) return threads[i];
  }
  return null;
}

function escapeRegexV3_(s) { return String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

/* ═════════════════════════ NEED2BUY: STEP 2 CONFIRMED -> BOUGHT ═════════════════════════ */

const N2B_CONFIRM_MAXV3 = 100;   // need2Buy threads checked per run

/** need2Buy sale threads (Need2Buy/WaitToBuy or need2Buy, not yet bought): if a
 *  "Order #N | [SUCCESS] [Step k/x]" email (k >= 2) exists for the same
 *  Order # + Site Order #, mark bought (adds `bought`, drops the need2Buy labels,
 *  so the PED row in Supabase closes) and mark the confirmation read. Same rule
 *  as stale A_Today, but for need2Buy sales of any age. */
function _processNeed2BuyConfirmedV3() {
  const threads = GmailApp.search(
    need2BuySearchV3_() + ' -label:' + LABELSV3.bought + ' subject:"PEDDLING SALE RECEIVED"',
    0, N2B_CONFIRM_MAXV3);
  console.log('need2Buy confirmed: ' + threads.length + ' open need2Buy thread(s)');
  const stats = { noIds: 0, noConfirm: 0, bought: 0, failed: 0 };
  if (!threads.length) return;

  // Order # + Site Order # per thread, cached: a sale email never changes, and
  // re-reading every body each run is what exhausts the daily Gmail quota.
  const cache = CacheService.getScriptCache();
  const hits = cache.getAll(threads.map(function (t) { return 'v3n2bc_' + t.getId(); }));
  const fresh = {};
  const pending = {};   // orderNo -> { siteOrder, thread }
  threads.forEach(function (thread) {
    const ck = 'v3n2bc_' + thread.getId();
    let ids = null;
    if (hits[ck]) { try { ids = JSON.parse(hits[ck]); } catch (e) { ids = null; } }
    if (!ids) {
      const msg = thread.getMessages().filter(function (m) { return /PEDDLING SALE RECEIVED/i.test(m.getSubject()); })[0]
               || thread.getMessages()[0];
      const o = msg.getSubject().match(/PEDDLING SALE RECEIVED\s+(\d+)/i);
      const s = msg.getPlainBody().match(/Site Order\s*#\s*([A-Za-z0-9\-]+)/i);
      ids = (o && s) ? { o: o[1], s: s[1].trim() } : { o: null };
      fresh[ck] = JSON.stringify(ids);
    }
    if (!ids.o) { stats.noIds++; return; }
    if (!pending[ids.o]) pending[ids.o] = { siteOrder: ids.s, thread: thread };
  });
  if (Object.keys(fresh).length) cache.putAll(fresh, 21600);

  // One search per batch of site order #s, instead of one per thread.
  const confirmed = findStepSuccessBatchV3_(pending);

  Object.keys(pending).forEach(function (orderNo) {
    const p = pending[orderNo];
    const confirm = confirmed[orderNo];
    if (!confirm) { stats.noConfirm++; return; }

    let sales = findSaleThreadsV3_(orderNo);   // catches split "Re:" threads too
    if (!sales.length) sales = [p.thread];

    if (TEST_MODEV3) { console.log('🧪 need2Buy ' + orderNo + ' (' + p.siteOrder + '): Step 2+ SUCCESS, would mark BOUGHT on ' + sales.length + ' thread(s)'); return; }
    if (sales.every(markBoughtV3_)) {
      confirm.markRead();
      stats.bought++;
      console.log('✅ need2Buy ' + orderNo + ' (' + p.siteOrder + '): Step 2+ SUCCESS -> bought');
    } else stats.failed++;
  });
  console.log('need2Buy confirmed summary: ' + JSON.stringify(stats));
}

/** For { orderNo: { siteOrder } }, find "Order #N | [SUCCESS] [Step k/x]" emails
 *  (k >= 2) whose body has the matching Site Order#. Searches in batches of 20
 *  site order #s. Returns { orderNo: thread }. */
function findStepSuccessBatchV3_(pending) {
  const out = {};
  const orders = Object.keys(pending);
  const subjRe = /Order #(\d+)\b.*\[SUCCESS\]\s*\[Step [2-8]\/\d+\]/i;
  for (let i = 0; i < orders.length; i += 20) {
    const chunk = orders.slice(i, i + 20);
    const q = 'subject:SUCCESS subject:Step (' +
      chunk.map(function (o) { return '"' + pending[o].siteOrder + '"'; }).join(' OR ') + ')';
    GmailApp.search(q, 0, 100).forEach(function (t) {
      t.getMessages().forEach(function (m) {
        const hit = m.getSubject().match(subjRe);
        if (!hit || out[hit[1]] || !pending[hit[1]]) return;
        const siteRe = new RegExp('Site Order#:\\s*' + escapeRegexV3_(pending[hit[1]].siteOrder) + '(?![A-Za-z0-9])', 'i');
        if (siteRe.test(m.getPlainBody())) out[hit[1]] = t;
      });
    });
  }
  return out;
}

/* ═════════════════════════ NEED2BUY: EVENT PASSED -> DROP LABEL ═════════════════════════ */

/** Sale threads still carrying a need2Buy label whose event started more than
 *  N2B_PASSED_HOURSV3 ago lose the need2Buy labels (and triage). Same rule Supabase uses to
 *  close an N2B row as 'event passed', so the Gmail book and the Terminal SUBS page agree.
 *  Nothing else on the thread changes (not marked read, not archived). */
function _clearPassedNeed2BuyV3() {
  const cutoffMs = Date.now() - N2B_PASSED_HOURSV3 * 3600000;
  const q = need2BuySearchV3_() +
            ' subject:"PEDDLING SALE RECEIVED" before:' + Math.floor(cutoffMs / 1000);
  const stats = { scanned: 0, cleared: 0, upcoming: 0, noDate: 0 };
  let start = 0, batch;
  do {
    batch = GmailApp.search(q, start, 100);
    batch.forEach(function (thread) {
      stats.scanned++;
      const evMs = eventStartMsForThreadV3_(thread);
      if (!evMs) { stats.noDate++; return; }
      if (evMs >= cutoffMs) { stats.upcoming++; return; }
      const when = Utilities.formatDate(new Date(evMs), Session.getScriptTimeZone(), 'yyyy-MM-dd HH:mm');
      if (TEST_MODEV3) { console.log('🧪 need2Buy passed: would drop labels on "' + thread_subjectV3_(thread) + '" (event ' + when + ')'); return; }
      const removed = dropNeed2BuyV3_(thread);
      removeTriageLabelsV3_(thread);
      if (removed.length) { stats.cleared++; console.log('🧹 event ' + when + ' passed: removed ' + removed.join(', ') + ' from "' + thread_subjectV3_(thread) + '"'); }
    });
    start += batch.length;
  } while (batch.length === 100 && start < N2B_PASSED_MAXV3);
  console.log('need2Buy passed summary: ' + JSON.stringify(stats));
}

/** Event start from the sale email ("Event Date 8/6/2026 1:20 PM"), read in the script's
 *  time zone (America/New_York) as Supabase does. Cached per thread for 6h. */
function eventStartMsForThreadV3_(thread) {
  const cache = CacheService.getScriptCache();
  const ck = 'v3evt_' + thread.getId();
  const hit = cache.get(ck);
  if (hit !== null) return hit === '' ? null : Number(hit);
  const msg = thread.getMessages().filter(function (m) { return /PEDDLING SALE RECEIVED/i.test(m.getSubject()); })[0]
           || thread.getMessages()[0];
  const t = msg.getPlainBody().replace(/[|\t\r\n]+/g, ' ');
  const m = t.match(/Event Date\s+(\d{1,2})\/(\d{1,2})\/(\d{4})(?:\s+(\d{1,2}):(\d{2})\s*([AP]M))?/i);
  let ms = null;
  if (m) {
    let h = m[4] ? parseInt(m[4], 10) % 12 : 0;
    if (m[6] && /PM/i.test(m[6])) h += 12;
    ms = new Date(parseInt(m[3], 10), parseInt(m[1], 10) - 1, parseInt(m[2], 10), h, m[5] ? parseInt(m[5], 10) : 0).getTime();
  }
  cache.put(ck, ms === null ? '' : String(ms), 21600);
  return ms;
}

/** Drop every need2Buy label (need2Buy and Need2Buy/WaitToBuy). Removing WaitToBuy is what
 *  closes a PED order in Supabase (n2b_sync stops sending it), so bought / filled /
 *  cancelled / event-passed all go through here. */
function dropNeed2BuyV3_(thread) { return removeLabelsCIV3_(thread, N2B_LABELSV3); }

/** Gmail search clause matching any need2Buy label. Gmail spells a nested label with '-':
 *  Need2Buy/WaitToBuy -> need2buy-waittobuy (as n2b_sync.gs does). */
function need2BuySearchV3_() {
  return '(' + N2B_LABELSV3.map(function (l) { return 'label:' + l.toLowerCase().replace(/[\/ ]/g, '-'); }).join(' OR ') + ')';
}

/** Remove labels by name, case-insensitively, straight off the thread's own labels. */
function removeLabelsCIV3_(thread, names) {
  const want = names.map(function (n) { return n.toLowerCase(); });
  const removed = [];
  thread.getLabels().forEach(function (l) {
    if (want.indexOf(l.getName().toLowerCase()) === -1) return;
    try { thread.removeLabel(l); removed.push(l.getName()); }
    catch (e) { console.log('removeLabel("' + l.getName() + '") failed: ' + e.message); }
  });
  return removed;
}

/* ═════════════════════════ TRANSITIONS (single definitions) ═════════════════════════ */

/** bought: add `bought`, drop `need2Buy`, strip triage, mark read. Stays in inbox. */
function markBoughtV3_(thread) {
  if (!applyLabelV3_(thread, LABELSV3.bought)) return false;
  dropNeed2BuyV3_(thread);
  removeTriageLabelsV3_(thread);
  thread.markRead();
  return true;
}

/** filled: add site filled label; only if verified, drop need2Buy + triage, mark read, archive. `bought` untouched. */
function markFilledV3_(thread, filledLabel) {
  if (!applyLabelV3_(thread, filledLabel)) return false;
  dropNeed2BuyV3_(thread);
  removeTriageLabelsV3_(thread);
  thread.markRead();
  thread.moveToArchive();
  return true;
}

function removeTriageLabelsV3_(thread) {
  LABELSV3.triage.forEach(function (n) { removeLabelV3_(thread, n); });
}

/* ═════════════════════════ CRM STATUS (replaces API pollers) ═════════════════════════ */

/** Open sale threads per site -> Site Order # -> crm_order_status_lookup (only those
 *  order #s, batched) -> act on each verdict. See header for the verdict table. */
function _checkCrmStatusV3() {
  const props = PropertiesService.getScriptProperties();
  const sbUrl  = (props.getProperty('SUPABASE_PROJECT_URL')    || '').trim();
  const sbAnon = (props.getProperty('SUPABASE_ANON_KEY')       || '').trim();
  const secret = (props.getProperty('APPSCRIPT_INGEST_SECRET') || '').trim();
  if (!sbUrl || !sbAnon || !secret) { console.log('CRM: missing Supabase properties, skipping.'); return; }

  const items = [];
  CRM_SITESV3.forEach(function (k) {
    const threads = crmThreadsForSiteV3_(props, k, SITESV3[k]);
    threads.forEach(function (thread) {
      const so = siteOrderForThreadV3_(thread, k);
      if (!so) { console.log('CRM ' + k + ': no Site Order # in "' + thread_subjectV3_(thread) + '"'); return; }
      items.push({ site: k, id: so.id, eventDate: so.ev, thread: thread });
    });
  });
  console.log('CRM: looking up ' + items.length + ' open order(s)');
  if (!items.length) return;

  const stats = { filled: 0, closed: 0, cancelled: 0, open: 0, flagged: 0, bought: 0, feed_stale: 0, not_found: 0, failed: 0 };
  for (let i = 0; i < items.length; i += CRM_CHUNKV3) {
    const chunk = items.slice(i, i + CRM_CHUNKV3);
    const results = sbRpcV3_(sbUrl, sbAnon, 'crm_order_status_lookup', {
      p_orders: chunk.map(function (it) { return { site: it.site, id: it.id }; }),
      p_shared_secret: secret,
    });
    if (!Array.isArray(results) || results.length !== chunk.length) {
      throw new Error('crm_order_status_lookup returned ' + (Array.isArray(results) ? results.length : typeof results) + ' rows for ' + chunk.length);
    }
    chunk.forEach(function (it, j) { applyCrmVerdictV3_(it, results[j], stats); });
  }
  console.log('CRM summary: ' + JSON.stringify(stats));
}

/** Rotating window over the site's open sale threads so a backlog larger than
 *  CRM_MAX_PER_SITEV3 is covered across runs instead of only ever the newest. */
function crmThreadsForSiteV3_(props, k, cfg) {
  const key = 'v3_crmOffset_' + k;
  let start = Number(props.getProperty(key) || 0);
  let threads = GmailApp.search(pollerQueryV3_(cfg), start, CRM_MAX_PER_SITEV3);
  if (!threads.length && start > 0) { start = 0; threads = GmailApp.search(pollerQueryV3_(cfg), 0, CRM_MAX_PER_SITEV3); }
  const next = threads.length === CRM_MAX_PER_SITEV3 ? start + CRM_MAX_PER_SITEV3 : 0;
  if (!TEST_MODEV3) props.setProperty(key, String(next));
  return threads;
}

/** Site Order # (+ event date, sale date) from the sale email, cached per thread for 6h
 *  so repeat runs don't re-read every body. */
function siteOrderForThreadV3_(thread, k) {
  const cache = CacheService.getScriptCache();
  const ck = 'v3so2_' + thread.getId();
  const hit = cache.get(ck);
  if (hit) { try { return JSON.parse(hit); } catch (e) {} }
  const msg = thread.getMessages()[0];
  const body = msg.getPlainBody();
  const id = extractOrderIdV3_(body, CRM_ORDER_PATTERNSV3[k] || CRM_ORDER_PATTERNSV3._default);
  if (!id) return null;
  const ev = parseEventDateV3_(body);
  const so = { id: id, ev: ev ? ev.getTime() : null, at: msg.getDate().getTime() };
  cache.put(ck, JSON.stringify(so), 21600);
  return so;
}

function applyCrmVerdictV3_(it, r, stats) {
  const cfg = SITESV3[it.site], thread = it.thread;
  const tag = 'CRM ' + it.site + ' ' + it.id;
  const detail = crmDetailV3_(r);
  const v = r && r.verdict;
  try {
    if (v === 'filled' || (v === 'closed' && CRM_CLOSED_IS_FILLEDV3)) {
      const why = v === 'filled'
        ? 'marketplace ' + (r.market_status || r.crm_status || 'completed')
        : 'off CRM open list since ' + (r.crm_last_seen_at || '?');
      if (TEST_MODEV3) { console.log('🧪 ' + tag + ': would FILL (' + why + ')' + detail); return; }
      if (markFilledV3_(thread, cfg.filled)) { stats[v]++; console.log('✅ ' + tag + ' filled (' + why + ')' + detail); }
      else stats.failed++;
    } else if (v === 'closed') {
      stats.closed++;
      console.log(tag + ': off CRM open list since ' + r.crm_last_seen_at + ' (CRM_CLOSED_IS_FILLEDV3 off)');
    } else if (v === 'cancelled') {
      const lbl = cancelLabelForV3_(cfg);
      if (TEST_MODEV3) { console.log('🧪 ' + tag + ': would CANCEL -> ' + lbl + detail); return; }
      if (applyLabelV3_(thread, lbl)) {
        dropNeed2BuyV3_(thread);   // nothing left to buy
        removeTriageLabelsV3_(thread);
        thread.markRead(); stats.cancelled++;
        console.log('🚨 ' + tag + ' cancelled (' + (r.market_status || r.crm_status) + ')' + detail);
      } else stats.failed++;
    } else if (v === 'open') {
      stats.open++;
      if (r.n2s && r.n2s.subbed_at && !threadHasLabelV3_(thread, LABELSV3.bought)) {
        if (TEST_MODEV3) console.log('🧪 ' + tag + ': CRM subbed ' + r.n2s.subbed_at + ' -> would mark BOUGHT');
        else if (markBoughtV3_(thread)) { stats.bought++; console.log('✅ ' + tag + ' -> bought (CRM subbed ' + r.n2s.subbed_at + ')'); }
      }
      const reason = crmIssueReasonV3_(r);
      if (reason) {
        const ev = r.event_date ? new Date(r.event_date + 'T12:00:00') : (it.eventDate ? new Date(it.eventDate) : null);
        if (flagCrmIssueV3_(thread, ev, tag, reason + detail)) stats.flagged++;
      } else console.log(tag + ': open ' + (r.crm_status || r.market_status) + detail);
    } else if (v === 'feed_stale') {
      stats.feed_stale++;
      console.log('⚠️ ' + tag + ': CRM feed stale (last pull ' + r.crm_feed_pulled_at + '), no action');
    } else {
      stats.not_found++;
      console.log(tag + ': not in CRM' + (r && r.market_status ? ' (marketplace: ' + r.market_status + ')' : ''));
    }
  } catch (e) { stats.failed++; console.log(tag + ': ' + e.message); }
}

/** Why an OPEN order needs a human, or null. */
function crmIssueReasonV3_(r) {
  const today = Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy-MM-dd');
  const status = r.crm_status || r.market_status || '';
  if (r.canonical_status === 'substitution') return 'substitution: ' + status;
  if (/issue|review|re-?transfer|re-?enter/i.test(status)) return 'CRM status ' + status;
  if (r.canonical_status === 'pending') return 'unconfirmed: ' + status;
  if (r.inhand_date && r.inhand_date < today) return 'past in-hand date ' + r.inhand_date + ', still ' + status;
  if (r.n2s && r.n2s.timer_expired && !r.n2s.subbed_at) return 'N2S timer expired' + (r.n2s.fail_reason ? ' (' + r.n2s.fail_reason + ')' : '');
  return null;
}

function crmDetailV3_(r) {
  if (!r) return '';
  const bits = [];
  if (r.inhand_date) bits.push('in-hand ' + r.inhand_date);
  if (r.n2s && r.n2s.fail_reason) bits.push('n2s: ' + r.n2s.fail_reason);
  if (r.cover && r.cover.label) bits.push('cover ' + r.cover.label + (r.cover.profit != null ? ' +$' + r.cover.profit : ''));
  return bits.length ? ' [' + bits.join('; ') + ']' : '';
}

/** ISSUE + unread unless the event has passed or the thread already carries ISSUE
 *  (so a thread you've read isn't flipped back to unread on every run). */
function flagCrmIssueV3_(thread, eventDate, tag, reason) {
  if (eventDate && !isNaN(eventDate.getTime()) && daysFromTodayV3_(eventDate) < 0) {
    console.log(tag + ': ' + reason + ', event passed — not flagging.');
    return false;
  }
  if (threadHasLabelV3_(thread, LABELSV3.issue)) { console.log(tag + ': ' + reason + ' (already ISSUE)'); return false; }
  if (TEST_MODEV3) { console.log('🧪 ' + tag + ': ' + reason + ' -> would label ISSUE + mark unread.'); return false; }
  if (applyLabelV3_(thread, LABELSV3.issue)) {
    thread.markUnread();
    console.log('⚠️ ' + tag + ': ' + reason + ' -> ISSUE + unread.');
    return true;
  }
  return false;
}

function threadHasLabelV3_(thread, name) {
  const lower = name.toLowerCase();
  return thread.getLabels().some(function (l) { return l.getName().toLowerCase() === lower; });
}

function cancelLabelForV3_(cfg) { return cfg.canceled || CRM_CANCEL_FALLBACKV3; }

function sbRpcV3_(sbUrl, sbAnon, fn, payload) {
  const resp = UrlFetchApp.fetch(sbUrl + '/rest/v1/rpc/' + fn, {
    method: 'post',
    headers: { 'apikey': sbAnon, 'Authorization': 'Bearer ' + sbAnon, 'Content-Type': 'application/json' },
    payload: JSON.stringify(payload),
    muteHttpExceptions: true });
  const code = resp.getResponseCode();
  if (code !== 200) throw new Error('Supabase ' + fn + ' HTTP ' + code + ' ' + resp.getContentText().substring(0, 400));
  return JSON.parse(resp.getContentText());
}

/** Read-only CRM check; changes no labels.
 *  From the editor's Run button (no arguments): looks up the newest 3 open sale threads
 *  per site and prints each verdict. From code: testCrmLookupV3('vivid', '80937492'). */
function testCrmLookupV3(site, id) {
  const props = PropertiesService.getScriptProperties();
  let orders;
  if (site && id) {
    orders = [{ site: site, id: String(id) }];
  } else {
    orders = [];
    CRM_SITESV3.forEach(function (k) {
      GmailApp.search(pollerQueryV3_(SITESV3[k]), 0, 3).forEach(function (t) {
        const so = siteOrderForThreadV3_(t, k);
        if (so) orders.push({ site: k, id: so.id, subject: thread_subjectV3_(t) });
      });
    });
    if (!orders.length) { console.log('No open sale threads found.'); return; }
  }
  const r = sbRpcV3_(
    (props.getProperty('SUPABASE_PROJECT_URL') || '').trim(),
    (props.getProperty('SUPABASE_ANON_KEY') || '').trim(),
    'crm_order_status_lookup',
    { p_orders: orders.map(function (o) { return { site: o.site, id: o.id }; }),
      p_shared_secret: (props.getProperty('APPSCRIPT_INGEST_SECRET') || '').trim() });
  if (orders.length === 1) { console.log(JSON.stringify(r, null, 2)); return; }
  r.forEach(function (x, i) {
    console.log(x.site + ' ' + x.id + ' -> ' + x.verdict +
      (x.crm_status ? ' (' + x.crm_status + ')' : '') + crmDetailV3_(x) +
      ' | ' + String(orders[i].subject).substring(0, 70));
  });
}

/* ═════════════════════════ API POLLERS (manual entry points only) ═════════════════════════ */

function pollerQueryV3_(cfg) {
  return 'label:' + cfg.siteLabel +
    ' -label:"' + cfg.filled + '" -label:"' + LABELSV3.filledParent + '"' +
    ' -label:"' + cancelLabelForV3_(cfg) + '"' +
    ' subject:"PEDDLING SALE RECEIVED" label:inbox';
}

/** Seller-side statuses that mean the order is still owed to the buyer
 *  (Vivid PENDING_SHIPMENT, GoTickets PENDING_FULFILLMENT, ...).
 *  Statuses in PENDING_EXCLUDEV3 are never flagged. */
const PENDING_EXCLUDEV3 = ['PENDING_TRANSFER_PROOF'];
function isPendingStatusV3_(status) {
  const s = String(status || '').trim().toUpperCase();
  if (PENDING_EXCLUDEV3.indexOf(s) !== -1) return false;
  return /PENDING/.test(s);
}

/** Pending order: label ISSUE + mark unread so it surfaces in the inbox — unless the
 *  event date has passed. Threads already labeled ISSUE are left alone, so a thread
 *  you've read isn't flipped back to unread on every poll. */
function flagPendingV3_(thread, body, site, orderId, status) {
  const eventDate = parseEventDateV3_(body);
  if (eventDate && daysFromTodayV3_(eventDate) < 0) {
    console.log(site + ' ' + orderId + ': ' + status + ', event passed — not flagging.');
    return;
  }
  const issueLower = LABELSV3.issue.toLowerCase();
  if (thread.getLabels().some(function (l) { return l.getName().toLowerCase() === issueLower; })) return;
  if (TEST_MODEV3) { console.log('🧪 ' + site + ' ' + orderId + ': ' + status + ' -> would label ISSUE + mark unread.'); return; }
  if (applyLabelV3_(thread, LABELSV3.issue)) {
    thread.markUnread();
    console.log('⚠️ ' + site + ' ' + orderId + ': ' + status + ' -> ISSUE + unread.');
  }
}

function _checkTevoV3() {
  const cfg = SITESV3.tevo;
  const props = PropertiesService.getScriptProperties();
  let token  = props.getProperty('TEVO_API_TOKEN');
  let secret = props.getProperty('TEVO_API_SECRET');
  if (!token || !secret) { console.log('TEVO: missing creds, skipping.'); return; }
  token = token.replace('Bearer ', '').trim(); secret = secret.trim();

  const threads = GmailApp.search(pollerQueryV3_(cfg), 0, 20);
  if (!threads.length) { console.log('TEVO: inbox clear.'); return; }

  threads.forEach(function (thread) {
    const body = thread.getMessages()[0].getPlainBody();
    const m = body.match(/Site Order\s*#\s*([a-zA-Z0-9\-]+)/i);
    if (!m) { console.log('TEVO: no Site Order # in body.'); return; }
    const raw = m[1].trim();
    const orderId = raw.indexOf('-') !== -1 ? raw.split('-').pop() : raw;
    try {
      const host = 'api.ticketevolution.com', path = '/v9/orders/' + orderId;
      const sig = Utilities.base64Encode(Utilities.computeHmacSha256Signature('GET ' + host + path + '?', secret));
      const resp = UrlFetchApp.fetch('https://' + host + path, {
        method: 'get', headers: { 'X-Token': token, 'X-Signature': sig, 'Accept': 'application/json' }, muteHttpExceptions: true });
      const code = resp.getResponseCode();
      if (code === 200) {
        const data = JSON.parse(resp.getContentText());
        const status = String(data.state || (data.order ? data.order.state : '') || '').toLowerCase();
        if (!status) { console.log('TEVO ' + orderId + ': no state field.'); return; }
        console.log('TEVO ' + orderId + ': ' + status);
        if (['complete', 'completed', 'shipped', 'delivered'].indexOf(status) !== -1) {
          if (TEST_MODEV3) { console.log('🧪 TEVO ' + orderId + ': would FILL.'); return; }
          if (markFilledV3_(thread, cfg.filled)) console.log('✅ TEVO ' + orderId + ' filled.');
        } else if (status.indexOf('cancel') !== -1 || status.indexOf('reject') !== -1) {
          if (TEST_MODEV3) { console.log('🧪 TEVO ' + orderId + ': would CANCEL.'); return; }
          if (applyLabelV3_(thread, cfg.canceled)) console.log('🚨 TEVO ' + orderId + ' cancelled.');
        } else if (isPendingStatusV3_(status)) {
          flagPendingV3_(thread, body, 'TEVO', orderId, status);
        }
      } else if (code === 401 || code === 403) {
        throw new Error('Auth failure ' + code + ' — halting TEVO.');
      } else console.log('TEVO ' + orderId + ': HTTP ' + code);
    } catch (e) {
      console.log('TEVO ' + orderId + ': ' + e.message);
      if (e.message.indexOf('Auth failure') !== -1) throw e;
    }
  });
}

function _checkVividV3() {
  const cfg = SITESV3.vivid;
  const props = PropertiesService.getScriptProperties();
  const apiToken = props.getProperty('VIVID_API_TOKEN'), autoToken = props.getProperty('VIVID_AUTOMATOR_TOKEN');
  if (!apiToken || !autoToken) { console.log('Vivid: missing creds, skipping.'); return; }

  const threads = GmailApp.search(pollerQueryV3_(cfg), 0, 20);
  if (!threads.length) { console.log('Vivid: inbox clear.'); return; }

  threads.forEach(function (thread) {
    const body = thread.getMessages()[0].getPlainBody();
    const m = body.match(/Site Order\s*#\s*(\d+)/i);
    if (!m) { console.log('Vivid: no Site Order # in body.'); return; }
    const orderId = m[1].trim();
    try {
      const resp = UrlFetchApp.fetch(
        'https://brokers.vividseats.com/webservices/v1/getOrder?apiToken=' + apiToken + '&orderId=' + orderId,
        { method: 'get', headers: { 'Accept': 'application/xml', 'X-Automator-Token': autoToken }, muteHttpExceptions: true });
      const code = resp.getResponseCode();
      if (code === 200) {
        const sm = resp.getContentText().match(/<status>([^<]+)<\/status>/i);
        if (!sm) { console.log('Vivid ' + orderId + ': no <status>.'); return; }
        const status = sm[1].trim();
        console.log('Vivid ' + orderId + ': ' + status);
        if (status === 'COMPLETED') {
          if (TEST_MODEV3) { console.log('🧪 Vivid ' + orderId + ': would FILL.'); return; }
          if (markFilledV3_(thread, cfg.filled)) console.log('✅ Vivid ' + orderId + ' filled.');
        } else if (isPendingStatusV3_(status)) {
          flagPendingV3_(thread, body, 'Vivid', orderId, status);
        }
      } else if (code === 404) {
        console.log('Vivid ' + orderId + ': 404 → ISSUE.');
        if (!TEST_MODEV3) applyLabelV3_(thread, LABELSV3.issue);
      } else if (code === 401 || code === 403) {
        throw new Error('Auth failure ' + code + ' — halting Vivid.');
      } else console.log('Vivid ' + orderId + ': HTTP ' + code);
    } catch (e) {
      console.log('Vivid ' + orderId + ': ' + e.message);
      if (e.message.indexOf('Auth failure') !== -1) throw e;
    }
  });
}

function _checkSeatGeekV3() {
  const cfg = SITESV3.seatgeek;
  let token = PropertiesService.getScriptProperties().getProperty('SEATGEEK_API_TOKEN');
  if (!token) { console.log('SeatGeek: missing creds, skipping.'); return; }
  token = token.trim();

  const threads = GmailApp.search(pollerQueryV3_(cfg), 0, 20);
  if (!threads.length) { console.log('SeatGeek: inbox clear.'); return; }

  threads.forEach(function (thread) {
    const body = thread.getMessages()[0].getPlainBody();
    const m = body.match(/Site Order\s*#\s*([a-zA-Z0-9]+)/i);
    if (!m) { console.log('SeatGeek: no Site Order # in body.'); return; }
    const orderId = m[1].trim();
    try {
      const resp = UrlFetchApp.fetch(
        'https://sellerdirect-api.seatgeek.com/order?order_id=' + orderId + '&token=' + token,
        { method: 'get', headers: { 'Accept': 'application/json' }, muteHttpExceptions: true });
      const code = resp.getResponseCode(), text = resp.getContentText();
      if (code === 200) {
        const status = JSON.parse(text).status;
        if (!status) { console.log('SeatGeek ' + orderId + ': no status.'); return; }
        const s = String(status).toLowerCase();
        console.log('SeatGeek ' + orderId + ': ' + status);
        if (s === 'completed' || s === 'fulfilled' || s === 'delivered') {
          if (TEST_MODEV3) { console.log('🧪 SeatGeek ' + orderId + ': would FILL.'); return; }
          if (markFilledV3_(thread, cfg.filled)) console.log('✅ SeatGeek ' + orderId + ' filled.');
        } else if (isPendingStatusV3_(status)) {
          flagPendingV3_(thread, body, 'SeatGeek', orderId, status);
        }
      } else if (code === 404) {
        console.log('SeatGeek ' + orderId + ': 404 → ISSUE.');
        if (!TEST_MODEV3) applyLabelV3_(thread, LABELSV3.issue);
      } else if (code === 401 || code === 403) {
        throw new Error('Auth failure ' + code + ' — halting SeatGeek.');
      } else console.log('SeatGeek ' + orderId + ': HTTP ' + code + ' ' + text.substring(0, 200));
    } catch (e) {
      console.log('SeatGeek ' + orderId + ': ' + e.message);
      if (e.message.indexOf('Auth failure') !== -1) throw e;
    }
  });
}

function _checkTickPickV3() {
  const cfg = SITESV3.tickpick;
  if (!tickPickTokenV3_()) { console.log('TickPick: missing creds, skipping.'); return; }

  const threads = GmailApp.search(pollerQueryV3_(cfg), 0, 20);
  if (!threads.length) { console.log('TickPick: inbox clear.'); return; }

  threads.forEach(function (thread) {
    const body = thread.getMessages()[0].getPlainBody();
    const orderId = extractOrderIdV3_(body, CRM_ORDER_PATTERNSV3.tickpick);
    if (!orderId) { console.log('TickPick: no Order # in body.'); return; }
    try {
      const resp = tickPickGetV3_('/orders/' + orderId + '/details');
      const code = resp.getResponseCode(), text = resp.getContentText();
      if (code === 200) {
        const json = JSON.parse(text);
        if (DEBUG_DUMPV3) console.log('TickPick keys: ' + Object.keys(json).join(', '));
        console.log('TickPick ' + orderId + ': order_status=' + json.order_status + ', event=' + json.status);
        if (json.status && String(json.status).toLowerCase() === 'canceled') {
          if (TEST_MODEV3) { console.log('🧪 TickPick ' + orderId + ': would CANCEL.'); return; }
          applyLabelV3_(thread, cfg.canceled); thread.markRead();
          console.log('🚨 TickPick ' + orderId + ' event canceled.'); return;
        }
        if (json.order_status && String(json.order_status).toUpperCase() === 'COMPLETED') {
          if (TEST_MODEV3) { console.log('🧪 TickPick ' + orderId + ': would FILL.'); return; }
          if (markFilledV3_(thread, cfg.filled)) console.log('✅ TickPick ' + orderId + ' filled.');
        } else if (isPendingStatusV3_(json.order_status)) {
          flagPendingV3_(thread, body, 'TickPick', orderId, json.order_status);
        }
      } else if (code === 404) {
        console.log('TickPick ' + orderId + ': 404 → ISSUE.');
        if (!TEST_MODEV3) applyLabelV3_(thread, LABELSV3.issue);
      } else if (code === 401 || code === 403) {
        throw new Error('Auth failure ' + code + ' — halting TickPick.');
      } else console.log('TickPick ' + orderId + ': HTTP ' + code + ' ' + text.substring(0, 200));
    } catch (e) {
      console.log('TickPick ' + orderId + ': ' + e.message);
      if (e.message.indexOf('Auth failure') !== -1) throw e;
    }
  });
}

function _checkGoTicketsV3() {
  const cfg = SITESV3.gotickets;
  const props = PropertiesService.getScriptProperties();
  const accessId = props.getProperty('GOTICKETS_ACCESS_ID'), secret = props.getProperty('GOTICKETS_API_SECRET');
  if (!accessId || !secret) { console.log('GoTickets: missing creds, skipping.'); return; }

  const threads = GmailApp.search(pollerQueryV3_(cfg), 0, 20);
  if (!threads.length) { console.log('GoTickets: inbox clear.'); return; }

  threads.forEach(function (thread) {
    const body = thread.getMessages()[0].getPlainBody();
    const orderId = extractOrderIdV3_(body, CRM_ORDER_PATTERNSV3.gotickets);
    if (!orderId) { console.log('GoTickets: no Order # in body.'); return; }
    try {
      const resp = UrlFetchApp.fetch('https://sc.gotickets.com/rest/sales/' + orderId,
        { method: 'get', headers: { 'X-Api-Access-Id': accessId, 'X-Api-Access-Secret': secret, 'Accept': 'application/json' }, muteHttpExceptions: true });
      const code = resp.getResponseCode(), text = resp.getContentText();
      if (code === 200) {
        const json = JSON.parse(text);
        if (DEBUG_DUMPV3) console.log('GoTickets keys: ' + Object.keys(json).join(', '));
        const fulfilled = json.fulfilled === true, cancelReason = json.cancelReason, sellerStatus = json.sellerStatus;
        console.log('GoTickets ' + orderId + ': fulfilled=' + fulfilled + ', sellerStatus=' + sellerStatus + ', cancel=' + (cancelReason || 'none'));
        const isCanceled =
          (cancelReason && String(cancelReason).trim() !== '' && String(cancelReason).toLowerCase() !== 'null') ||
          (sellerStatus && ['CANCELED', 'CANCELLED', 'REJECTED'].indexOf(String(sellerStatus).toUpperCase()) !== -1);
        if (isCanceled && !fulfilled) {
          if (TEST_MODEV3) { console.log('🧪 GoTickets ' + orderId + ': would CANCEL.'); return; }
          applyLabelV3_(thread, cfg.canceled); thread.markRead();
          console.log('🚨 GoTickets ' + orderId + ' canceled.'); return;
        }
        if (fulfilled) {
          if (TEST_MODEV3) { console.log('🧪 GoTickets ' + orderId + ': would FILL.'); return; }
          if (markFilledV3_(thread, cfg.filled)) console.log('✅ GoTickets ' + orderId + ' filled.');
        } else if (isPendingStatusV3_(sellerStatus)) {
          flagPendingV3_(thread, body, 'GoTickets', orderId, sellerStatus);
        }
      } else if (code === 404) {
        console.log('GoTickets ' + orderId + ': 404 → ISSUE.');
        if (!TEST_MODEV3) applyLabelV3_(thread, LABELSV3.issue);
      } else if (code === 401 || code === 403) {
        throw new Error('Auth failure ' + code + ' — halting GoTickets.');
      } else if (code === 429) {
        throw new Error('Rate limited — halting GoTickets.');
      } else console.log('GoTickets ' + orderId + ': HTTP ' + code + ' ' + text.substring(0, 200));
    } catch (e) {
      console.log('GoTickets ' + orderId + ': ' + e.message);
      if (/Auth failure|Rate limited/.test(e.message)) throw e;
    }
  });
}

/* ═════════════════════════ FILLED SWEEP ═════════════════════════ */

function _sweepFilledThreadsV3() {
  _sweepBoughtThreadsV3();
  _sweepFilledOnlyV3();
}

/** Any thread carrying BOTH bought and need2Buy (e.g. a "Re:" reply that landed
 *  as its own thread, or a manual label) loses need2Buy + triage. bought stays. */
function _sweepBoughtThreadsV3() {
  const q = 'label:"' + LABELSV3.bought + '" ' + need2BuySearchV3_();
  const threads = GmailApp.search(q, 0, 100);
  if (!threads.length) { console.log('Bought sweep: nothing to clean.'); return; }
  console.log('Bought sweep: ' + threads.length + ' thread(s) still need2Buy.');
  threads.forEach(function (thread) {
    if (TEST_MODEV3) { console.log('🧪 Bought sweep: would clean "' + thread_subjectV3_(thread) + '"'); return; }
    dropNeed2BuyV3_(thread);
    removeTriageLabelsV3_(thread);
  });
}

/** Any thread with a filled label (parent or any SITESV3 filled label, manual or
 *  automatic) that is still unread, need2Buy, or triaged: drop need2Buy + triage,
 *  mark read, archive. SWEEP_MAX_PER_RUNV3 threads per run. */
function _sweepFilledOnlyV3() {
  const filled = [LABELSV3.filledParent];
  Object.keys(SITESV3).forEach(function (k) { if (filled.indexOf(SITESV3[k].filled) === -1) filled.push(SITESV3[k].filled); });
  const filledClause = filled.map(function (l) { return 'label:"' + l + '"'; }).join(' OR ');
  const needsClause  = 'is:unread OR ' + need2BuySearchV3_() + ' OR ' +
    LABELSV3.triage.map(function (l) { return 'label:"' + l + '"'; }).join(' OR ');
  const threads = GmailApp.search('(' + filledClause + ') (' + needsClause + ')', 0, SWEEP_MAX_PER_RUNV3);
  if (!threads.length) { console.log('Sweep: nothing to clean.'); return; }
  console.log('Sweep: ' + threads.length + ' thread(s).');
  threads.forEach(function (thread) {
    if (TEST_MODEV3) { console.log('🧪 Sweep: would clean "' + thread_subjectV3_(thread) + '"'); return; }
    dropNeed2BuyV3_(thread);
    removeTriageLabelsV3_(thread);
    thread.markRead();
    if (SWEEP_ARCHIVEV3) thread.moveToArchive();
  });
}

/* ═════════════════════════ TRIAGEV3 REFRESH ═════════════════════════ */

function _processTriageRefreshV3() {
  const query = 'label:' + LABELSV3.order + ' subject:"PEDDLING SALE RECEIVED" is:unread label:inbox';
  const threads = GmailApp.search(query, 0, TRIAGEV3.maxThreads);
  console.log('Triage: scanning ' + threads.length);

  const filledNames = {};
  filledNames[LABELSV3.filledParent.toLowerCase()] = true;
  Object.keys(SITESV3).forEach(function (k) { filledNames[SITESV3[k].filled.toLowerCase()] = true; });
  const stats = { unchanged: 0, added: 0, changed: 0, expired: 0, past: 0, noDate: 0, done: 0, err: 0 };

  threads.forEach(function (thread) {
    let names;
    try { names = thread.getLabels().map(function (l) { return l.getName(); }); }
    catch (e) { stats.err++; return; }

    const lower = names.map(function (n) { return n.toLowerCase(); });
    if (lower.indexOf(LABELSV3.bought.toLowerCase()) !== -1 || lower.some(function (n) { return filledNames[n]; })) { stats.done++; return; }

    const eventDate = parseEventDateV3_(thread.getMessages()[0].getPlainBody());
    if (!eventDate) { stats.noDate++; return; }
    const daysOut = daysFromTodayV3_(eventDate);
    if (daysOut < 0) { stats.past++; return; }

    const correct = triageLabelForV3_(daysOut);
    const existing = LABELSV3.triage.filter(function (n) { return lower.indexOf(n.toLowerCase()) !== -1; });
    if (existing.length === 1 && existing[0] === correct) { stats.unchanged++; return; }
    if (!existing.length && !correct) { stats.unchanged++; return; }   // nothing to add or remove

    if (TEST_MODEV3) { console.log('🧪 Triage: ' + eventDate.toDateString() + ' ' + (existing.join(',') || 'none') + ' -> ' + correct); return; }
    existing.forEach(function (n) { removeLabelV3_(thread, n); });
    if (correct) {
      applyLabelV3_(thread, correct);
      existing.length ? stats.changed++ : stats.added++;
    } else if (existing.length) stats.expired++;
  });
  console.log('Triage summary: ' + JSON.stringify(stats));
}

function parseEventDateV3_(body) {
  const m = body.match(/Event Date\s*(\d{1,2}\/\d{1,2}\/\d{4})/);
  if (!m) return null;
  const d = new Date(m[1]);
  return isNaN(d.getTime()) ? null : d;
}
function daysFromTodayV3_(date) {
  const t = new Date(); t.setHours(0, 0, 0, 0);
  const d = new Date(date); d.setHours(0, 0, 0, 0);
  return Math.round((d - t) / 86400000);
}
function triageLabelForV3_(daysOut) {
  const d = daysOut - TRIAGEV3.bufferDays;
  if (d <= 0) return LABELSV3.today;
  if (d === 1) return LABELSV3.tomorrow;
  if (d <= TRIAGEV3.soonWindowDays) return LABELSV3.soon;
  return null;
}

/* ═════════════════════════ SHARED LABEL HELPERS ═════════════════════════ */

let _labelCacheV3 = null;

function extractOrderIdV3_(body, patterns) {
  for (let i = 0; i < patterns.length; i++) { const m = body.match(patterns[i]); if (m) return m[1].trim(); }
  return null;
}

/** Exact-name lookup; falls back to iterating getUserLabels() (nested labels sometimes miss). */
function getLabelV3_(name) {
  if (!name) return null;
  try { const d = GmailApp.getUserLabelByName(name); if (d) return d; } catch (e) {}
  try {
    if (!_labelCacheV3) _labelCacheV3 = GmailApp.getUserLabels();
    for (let i = 0; i < _labelCacheV3.length; i++) if (_labelCacheV3[i].getName() === name) return _labelCacheV3[i];
  } catch (e) { console.log('getLabelV3_("' + name + '") threw: ' + e.message); }
  return null;
}

/** Apply a label (creating if missing). Returns true only if verifiably on the thread afterward. */
function applyLabelV3_(thread, name) {
  if (!name) return false;
  let label = getLabelV3_(name);
  if (!label) {
    try { label = GmailApp.createLabel(name); _labelCacheV3 = null; console.log('Created label "' + name + '"'); }
    catch (e) { _labelCacheV3 = null; Utilities.sleep(500); label = getLabelV3_(name); }
  }
  if (!label) { console.log('⚠️ applyLabelV3_("' + name + '"): could not get or create.'); return false; }
  try {
    thread.addLabel(label);
    // Verify against the label's REAL name (Gmail label lookup is case-insensitive,
    // so the configured string may differ in casing) on a refreshed thread object.
    const realName = label.getName();
    try { thread.refresh(); } catch (e) {}
    const present = thread.getLabels().map(function (l) { return l.getName(); });
    if (present.indexOf(realName) === -1) {
      console.log('⚠️ applyLabelV3_("' + name + '" -> "' + realName + '"): not on thread after add. Present: [' + present.join(', ') + ']');
      return false;
    }
    return true;
  } catch (e) { console.log('applyLabelV3_("' + name + '") threw: ' + e.message); return false; }
}

function removeLabelV3_(thread, name) {
  if (!name) return;
  try { const l = getLabelV3_(name); if (l) thread.removeLabel(l); }
  catch (e) { console.log('removeLabelV3_("' + name + '") failed: ' + e.message); }
}

/* ═════════════════════════ TICKPICK → SUPABASE SYNC ═════════════════════════ */

function _syncTickPickToSupabaseV3() {
  const props = PropertiesService.getScriptProperties();
  const TP_TOKEN  = tickPickTokenV3_();
  const SB_URL    = (props.getProperty('SUPABASE_PROJECT_URL')    || '').trim();
  const SB_ANON   = (props.getProperty('SUPABASE_ANON_KEY')       || '').trim();
  const INGEST_SK = (props.getProperty('APPSCRIPT_INGEST_SECRET') || '').trim();
  if (!TP_TOKEN || !SB_URL || !SB_ANON || !INGEST_SK) { console.log('Supabase sync: missing properties, skipping.'); return; }

  const orders = tpFetchOrdersListV3_('unfulfilled');
  console.log('TickPick unfulfilled → ' + orders.length);
  if (!orders.length) return;
  if (TEST_MODEV3) { console.log('🧪 Would POST ' + orders.length + ' orders.'); return; }

  const CHUNK = 250, totals = { inserted: 0, updated: 0, skipped: 0, batches: 0 };
  for (let i = 0; i < orders.length; i += CHUNK) {
    const r = tpPostIngestBatchV3_(SB_URL, SB_ANON, INGEST_SK, orders.slice(i, i + CHUNK));
    totals.inserted += r.inserted; totals.updated += r.updated; totals.skipped += r.skipped; totals.batches++;
  }
  console.log('SYNC COMPLETE ' + JSON.stringify(totals));
}

/** TickPick bearer token. TickPick tokens are OAuth password-grant tokens that expire
 *  (~14 days), so a pasted TICKPICK_API_TOKEN goes 401 on its own. With
 *  TICKPICK_USERNAME + TICKPICK_PASSWORD set, a fresh token is fetched from POST /token
 *  and cached until shortly before it expires; otherwise the pasted token is used. */
function tickPickTokenV3_(forceRefresh) {
  const props = PropertiesService.getScriptProperties();
  const cache = CacheService.getScriptCache();
  const user = (props.getProperty('TICKPICK_USERNAME') || '').trim();
  const pass = (props.getProperty('TICKPICK_PASSWORD') || '').trim();
  if (!user || !pass) return (props.getProperty('TICKPICK_API_TOKEN') || '').replace('Bearer ', '').trim();

  if (!forceRefresh) {
    const cached = cache.get('v3_tp_token');
    if (cached) return cached;
    const stored = props.getProperty('v3_tp_token'), exp = Number(props.getProperty('v3_tp_token_exp') || 0);
    if (stored && exp > Date.now() + 600000) { cache.put('v3_tp_token', stored, 21600); return stored; }
  }
  const resp = UrlFetchApp.fetch(TICKPICK_API_BASEV3 + '/token', {
    method: 'post', contentType: 'application/x-www-form-urlencoded',
    payload: 'grant_type=password&username=' + encodeURIComponent(user) + '&password=' + encodeURIComponent(pass),
    muteHttpExceptions: true });
  if (resp.getResponseCode() !== 200) {
    throw new Error('TickPick /token HTTP ' + resp.getResponseCode() + ' ' + resp.getContentText().substring(0, 200));
  }
  const json = JSON.parse(resp.getContentText());
  const token = json.access_token, ttlSec = Number(json.expires_in) || 3600;
  if (!token) throw new Error('TickPick /token: no access_token in response');
  props.setProperties({ v3_tp_token: token, v3_tp_token_exp: String(Date.now() + ttlSec * 1000) });
  cache.put('v3_tp_token', token, Math.max(60, Math.min(21600, ttlSec - 600)));
  console.log('TickPick: fetched new token (expires in ' + Math.round(ttlSec / 86400) + ' days)');
  return token;
}

/** GET against the TickPick API; on 401 refreshes the token once and retries. */
function tickPickGetV3_(path) {
  const go = function (token) {
    return UrlFetchApp.fetch(TICKPICK_API_BASEV3 + path,
      { method: 'get', headers: { 'Authorization': 'Bearer ' + token, 'Accept': 'application/json' }, muteHttpExceptions: true });
  };
  let resp = go(tickPickTokenV3_());
  if (resp.getResponseCode() === 401 && PropertiesService.getScriptProperties().getProperty('TICKPICK_USERNAME')) {
    resp = go(tickPickTokenV3_(true));
  }
  return resp;
}

/** Manual check that TickPick auth works: fetches a token and one page of orders. */
function testTickPickAuthV3() {
  const resp = tickPickGetV3_('/orders?status=unfulfilled');
  console.log('TickPick /orders?status=unfulfilled -> HTTP ' + resp.getResponseCode() + ' ' + resp.getContentText().substring(0, 300));
}

function tpFetchOrdersListV3_(status) {
  const resp = tickPickGetV3_('/orders?status=' + encodeURIComponent(status));
  if (resp.getResponseCode() !== 200) throw new Error('TickPick list fetch failed: HTTP ' + resp.getResponseCode());
  const json = JSON.parse(resp.getContentText());
  if (Array.isArray(json)) return json;
  if (json && Array.isArray(json.orders)) return json.orders;
  return [];
}

function tpPostIngestBatchV3_(sbUrl, sbAnon, secret, ordersArr) {
  const resp = UrlFetchApp.fetch(sbUrl + '/rest/v1/rpc/tickpick_orders_ingest_from_apps_script', {
    method: 'post',
    headers: { 'apikey': sbAnon, 'Authorization': 'Bearer ' + sbAnon, 'Content-Type': 'application/json', 'Prefer': 'return=representation' },
    payload: JSON.stringify({ p_orders: ordersArr, p_shared_secret: secret }),
    muteHttpExceptions: true });
  if (resp.getResponseCode() !== 200) throw new Error('Supabase RPC failed: HTTP ' + resp.getResponseCode() + ' ' + resp.getContentText().substring(0, 600));
  let parsed; try { parsed = JSON.parse(resp.getContentText()); } catch (e) { parsed = []; }
  const row = (Array.isArray(parsed) && parsed.length) ? parsed[0] : {};
  return { inserted: Number(row.inserted) || 0, updated: Number(row.updated) || 0, skipped: Number(row.skipped) || 0 };
}

/* ═════════════════════════ CREDENTIALS ═════════════════════════ */

function setCredentialsV3() {
  const literals = {
    'TEVO_API_TOKEN': 'PASTE_OR_LEAVE', 'TEVO_API_SECRET': 'PASTE_OR_LEAVE',
    'VIVID_API_TOKEN': 'PASTE_OR_LEAVE', 'VIVID_AUTOMATOR_TOKEN': 'PASTE_OR_LEAVE',
    'SEATGEEK_API_TOKEN': 'PASTE_OR_LEAVE', 'TICKPICK_API_TOKEN': 'PASTE_OR_LEAVE',
    'TICKPICK_USERNAME': 'PASTE_OR_LEAVE', 'TICKPICK_PASSWORD': 'PASTE_OR_LEAVE',
    'GOTICKETS_ACCESS_ID': 'PASTE_OR_LEAVE', 'GOTICKETS_API_SECRET': 'PASTE_OR_LEAVE',
    'SUPABASE_PROJECT_URL': 'PASTE_OR_LEAVE', 'SUPABASE_ANON_KEY': 'PASTE_OR_LEAVE',
    'APPSCRIPT_INGEST_SECRET': 'PASTE_OR_LEAVE',
  };
  const toStore = {};
  Object.keys(literals).forEach(function (k) { if (!/^PASTE_/.test(literals[k])) toStore[k] = literals[k]; });
  if (!Object.keys(toStore).length) throw new Error('Nothing to store — fill in at least one value.');
  PropertiesService.getScriptProperties().setProperties(toStore, false);
  console.log('Stored: ' + Object.keys(toStore).join(', ') + '. Now blank the literals.');
}

/* ═════════════════════════ TRIGGERS ═════════════════════════ */

const MANAGED_HANDLERSV3 = ['runAllV3', 'runTriageRefreshV3', 'syncTickPickToSupabaseV3'];
// runTriageRefreshV3 kept as a manual entry point; triage now runs inside the cascade.
const LEGACY_HANDLERSV3  = ['runAllCheckers', 'runLifecycle', 'processTriageRefresh', 'syncTickPickToSupabase',
  'checkTevoOrderStatus', 'checkVividOrderStatus', 'checkSeatGeekOrderStatus', 'checkTickPickOrderStatus',
  'checkGoTicketsOrderStatus', 'checkViagogoOrderStatus', 'checkGametimeOrderStatus',
  // previous M2 build — removed so it never runs alongside V3
  'runAllM2', 'runTriageRefreshM2', 'syncTickPickToSupabaseM2'];

function installAllTriggersV3() {
  MANAGED_HANDLERSV3.concat(LEGACY_HANDLERSV3).forEach(deleteTriggersForV3_);
  ScriptApp.newTrigger('runAllV3').timeBased().everyMinutes(CHECKER_INTERVAL_MINV3).create();
  if (SYNC_TICKPICK_ENABLEDV3) {
    ScriptApp.newTrigger('syncTickPickToSupabaseV3').timeBased().everyMinutes(SYNC_INTERVAL_MINV3).create();
  }
  listTriggersV3();
}
function uninstallAllTriggersV3() { MANAGED_HANDLERSV3.concat(LEGACY_HANDLERSV3).forEach(deleteTriggersForV3_); }
function deleteTriggersForV3_(handler) {
  ScriptApp.getProjectTriggers().forEach(function (t) { if (t.getHandlerFunction() === handler) ScriptApp.deleteTrigger(t); });
}
function listTriggersV3() {
  ScriptApp.getProjectTriggers().forEach(function (t) { console.log('  ' + t.getHandlerFunction() + ' — ' + t.getEventType()); });
}

/* ═════════════════════════ DIAGNOSTICS ═════════════════════════ */

/** Every label this project references: OK / MISSING. Run before first live run. */
function checkLabelsV3() {
  const names = [LABELSV3.success, LABELSV3.poc, LABELSV3.sgbuy, LABELSV3.need2buy, LABELSV3.bought,
    LABELSV3.order, LABELSV3.issue, LABELSV3.vip, LABELSV3.filledParent, CRM_CANCEL_FALLBACKV3].concat(LABELSV3.triage);
  Object.keys(SITESV3).forEach(function (k) {
    names.push(SITESV3[k].siteLabel, SITESV3[k].filled);
    if (SITESV3[k].canceled) names.push(SITESV3[k].canceled);
  });
  names.filter(function (n, i) { return names.indexOf(n) === i; })
    .forEach(function (n) { console.log((getLabelV3_(n) ? 'OK      ' : 'MISSING ') + n); });
}

function diagnoseLabelsV3() {
  GmailApp.getUserLabels().forEach(function (l) { console.log('"' + l.getName() + '"'); });
}

function diagnoseSetupV3() {
  const props = PropertiesService.getScriptProperties().getProperties();
  ['TEVO_API_TOKEN', 'TEVO_API_SECRET', 'VIVID_API_TOKEN', 'VIVID_AUTOMATOR_TOKEN', 'SEATGEEK_API_TOKEN',
   'TICKPICK_API_TOKEN', 'TICKPICK_USERNAME', 'TICKPICK_PASSWORD',
   'GOTICKETS_ACCESS_ID', 'GOTICKETS_API_SECRET', 'SUPABASE_PROJECT_URL',
   'SUPABASE_ANON_KEY', 'APPSCRIPT_INGEST_SECRET'].forEach(function (k) {
    console.log(k + ': ' + (props[k] ? 'SET (' + props[k].length + ' chars)' : '!! MISSING'));
  });
  console.log('CRM step needs: SUPABASE_PROJECT_URL, SUPABASE_ANON_KEY, APPSCRIPT_INGEST_SECRET');
  listTriggersV3();
}
