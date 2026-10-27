/**
 * ============================================================================
 * S4K GMAIL RELAY  v1.0.0  (2026-10-27)
 * Bump RELAY_VERSION + the CHANGELOG below on every change.
 * ============================================================================
 *
 * The script only RELAYS; Supabase DECIDES (gmail_relay_sync, Terminal-2 mig
 * 20261027160000). Every minute relaySync():
 *   1. lists, by id only, the Need2Buy book (threads with a need2Buy label),
 *      the cancelled ones in it, and recent sale / cancel emails,
 *   2. posts them to Supabase, which answers with what it has not seen yet,
 *      Gmail searches to run (Step 2+ SUCCESS emails of open sales), and label
 *      changes to make,
 *   3. fetches only those emails, runs those searches, applies those label
 *      changes, and posts again until nothing is wanted.
 * Each email is read once, ever. Supabase stores it, keeps the N2B (PED) rows
 * current, and decides:
 *   - bought: a need2Buy sale with a "[SUCCESS] [Step 2-8/x]" email for the same
 *     Order # + Site Order # -> add bought, drop need2Buy + triage, mark read.
 *   - event passed (24h+): drop need2Buy + triage.
 *
 * Uses the Gmail API ADVANCED SERVICE (Services -> Gmail API), not GmailApp, so
 * it does not count against GmailApp's daily "premium gmail" quota.
 *
 * Script properties (same as n2b_sync.gs / the lifecycle script):
 *   SUPABASE_PROJECT_URL, SUPABASE_ANON_KEY, APPSCRIPT_INGEST_SECRET
 *
 * Setup: enable the Gmail API advanced service, run relaySync() once by hand
 * (authorise), then installRelayTrigger(). That also removes the old
 * syncN2bToSupabase trigger, which this replaces.
 *
 * CHANGELOG
 *   1.0.0  2026-10-27  First version: N2B book + bought / event-passed decisions in Supabase.
 * ============================================================================
 */

const RELAY_VERSION = '1.0.0';

const RELAY = {
  // the Need2Buy book: any need2Buy label, on a sale thread
  BOOK_Q: '(label:need2buy-waittobuy OR label:need2buy) subject:"PEDDLING SALE RECEIVED"',
  CANCEL_Q: '(label:need2buy-cancelled OR label:issue-cancelled)',
  // new sale / cancel emails to offer Supabase (it asks for the ones it lacks)
  RECENT_Q: 'from:orders@s4kent.com newer_than:1d (subject:"PEDDLING SALE RECEIVED" OR subject:cancel)',
  BOOK_MAX: 2000,
  MAX_ROUNDS: 5,
  TIME_BUDGET_MS: 240000,
  BODY_MAX: 20000,
};

/* ─────────────────────────────── RUN ─────────────────────────────── */

function relaySync() {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(1000)) { console.log('relay: previous run still going, skipping'); return; }
  const t0 = Date.now();
  try {
    console.log('S4K Gmail Relay v' + RELAY_VERSION);
    let complete = true;
    let book;
    try {
      book = relayList_('threads', RELAY.BOOK_Q, RELAY.BOOK_MAX);
      if (book.length >= RELAY.BOOK_MAX) complete = false;
    } catch (e) {
      // never send an empty "complete" book: it would close every open sale
      console.error('relay: book list failed, sending no book: ' + e);
      book = null;
    }
    const cancelled = book ? relayList_('threads', RELAY.BOOK_Q + ' ' + RELAY.CANCEL_Q, 500) : [];
    const base = { book: book, book_complete: !!book && complete, cancelled: cancelled };

    let r = relayPost_(Object.assign({}, base, {
      candidates: relayList_('messages', RELAY.RECENT_Q, 500), messages: [], acks: [] }));
    const stats = { fetched: 0, searched: 0, applied: 0, failed: 0 };

    for (let round = 0; round < RELAY.MAX_ROUNDS && r; round++) {
      if (Date.now() - t0 > RELAY.TIME_BUDGET_MS) { console.log('relay: time budget used, continuing next run'); break; }
      const messages = [], seen = {};
      const keep = function (m) { if (m && !seen[m.id]) { seen[m.id] = true; messages.push(m); } };
      (r.want_threads || []).forEach(function (tid) { relayGetThread_(tid).forEach(keep); });
      (r.want_msgs || []).forEach(function (id) { if (!seen[id]) keep(relayGetMessage_(id)); });
      let extra = [];
      (r.searches || []).forEach(function (q) {
        extra = extra.concat(relayList_('messages', q, 100)); stats.searched++;
      });
      const acks = (r.actions || []).map(relayApply_);
      acks.forEach(function (a) { a.ok ? stats.applied++ : stats.failed++; });
      stats.fetched += messages.length;
      if (!messages.length && !extra.length && !acks.length) break;
      r = relayPost_(Object.assign({}, base, { candidates: extra, messages: messages, acks: acks }));
    }
    console.log('relay: book ' + (book ? book.length : 'n/a') + ', ' + JSON.stringify(stats) +
                (r && r.n2b ? ', n2b ' + JSON.stringify(r.n2b) : '') +
                ' (' + Math.round((Date.now() - t0) / 1000) + 's)');
  } finally {
    lock.releaseLock();
  }
}

/* ─────────────────────────────── GMAIL (advanced service) ─────────────────────────────── */

/** Ids only, all pages, up to max. kind: 'threads' | 'messages'. */
function relayList_(kind, q, max) {
  const out = [];
  let pageToken;
  do {
    const opts = { q: q, maxResults: Math.min(500, max - out.length) };
    if (pageToken) opts.pageToken = pageToken;
    const res = kind === 'threads' ? Gmail.Users.Threads.list('me', opts)
                                   : Gmail.Users.Messages.list('me', opts);
    (res[kind] || []).forEach(function (x) { out.push(x.id); });
    pageToken = res.nextPageToken;
  } while (pageToken && out.length < max);
  return out;
}

function relayGetMessage_(id) {
  try { return relayShape_(Gmail.Users.Messages.get('me', id, { format: 'full' })); }
  catch (e) { console.error('relay: get message ' + id + ' failed: ' + e); return null; }
}

function relayGetThread_(tid) {
  try {
    const t = Gmail.Users.Threads.get('me', tid, { format: 'full' });
    return (t.messages || []).map(relayShape_);
  } catch (e) { console.error('relay: get thread ' + tid + ' failed: ' + e); return []; }
}

function relayShape_(m) {
  const headers = (m.payload && m.payload.headers) || [];
  const subj = (headers.filter(function (h) { return /^subject$/i.test(h.name); })[0] || {}).value || '';
  const names = relayLabels_().byId;
  return {
    id: m.id,
    thread_id: m.threadId,
    internal_ms: m.internalDate,
    subject: subj,
    body: relayBody_(m.payload).slice(0, RELAY.BODY_MAX),
    labels: (m.labelIds || []).map(function (id) { return names[id] || id; }),
  };
}

/** text/plain if present, else text/html with tags stripped. */
function relayBody_(payload) {
  let plain = '', html = '';
  (function walk(p) {
    if (!p) return;
    if (p.body && p.body.data) {
      const txt = Utilities.newBlob(Utilities.base64DecodeWebSafe(p.body.data)).getDataAsString();
      if (p.mimeType === 'text/plain' && !plain) plain = txt;
      else if (p.mimeType === 'text/html' && !html) html = txt;
    }
    (p.parts || []).forEach(walk);
  })(payload);
  if (plain) return plain;
  return html.replace(/<(br|\/p|\/tr|\/div)[^>]*>/gi, '\n').replace(/<\/t[dh]>/gi, '\t')
             .replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&')
             .replace(/&#36;|&dollar;/g, '$');
}

/** { byId: id -> name, byName: lowercase name -> id }, cached 6 h. */
function relayLabels_() {
  if (relayLabels_.memo) return relayLabels_.memo;
  const cache = CacheService.getScriptCache();
  const hit = cache.get('relay_labels_v1');
  if (hit) { relayLabels_.memo = JSON.parse(hit); return relayLabels_.memo; }
  const byId = {}, byName = {};
  (Gmail.Users.Labels.list('me').labels || []).forEach(function (l) {
    byId[l.id] = l.name; byName[l.name.toLowerCase()] = l.id;
  });
  relayLabels_.memo = { byId: byId, byName: byName };
  cache.put('relay_labels_v1', JSON.stringify(relayLabels_.memo), 21600);
  return relayLabels_.memo;
}

/** Apply one Supabase action; returns its ack. A label to remove that does not
 *  exist is skipped; a label to add that does not exist is an error. */
function relayApply_(a) {
  try {
    const byName = relayLabels_().byName;
    const add = (a.add || []).map(function (n) {
      const id = byName[String(n).toLowerCase()];
      if (!id) throw new Error('label not found: ' + n);
      return id;
    });
    const rm = (a.remove || []).map(function (n) { return byName[String(n).toLowerCase()]; })
                               .filter(function (id) { return !!id; });
    if (a.read) rm.push('UNREAD');
    if (add.length || rm.length) {
      Gmail.Users.Threads.modify({ addLabelIds: add, removeLabelIds: rm }, 'me', a.thread_id);
    }
    console.log('✅ relay ' + a.reason + ' ' + (a.order_no || '') + ' on ' + a.thread_id);
    return { id: a.id, ok: true };
  } catch (e) {
    console.error('relay ' + a.reason + ' ' + (a.order_no || '') + ' failed: ' + e);
    return { id: a.id, ok: false, error: String(e).slice(0, 500) };
  }
}

/* ─────────────────────────────── SUPABASE ─────────────────────────────── */

function relayPost_(payload) {
  const props = PropertiesService.getScriptProperties();
  const url = props.getProperty('SUPABASE_PROJECT_URL');
  const anon = props.getProperty('SUPABASE_ANON_KEY');
  const secret = props.getProperty('APPSCRIPT_INGEST_SECRET');
  if (!url || !anon || !secret) throw new Error('Missing SUPABASE_PROJECT_URL / SUPABASE_ANON_KEY / APPSCRIPT_INGEST_SECRET');
  const res = UrlFetchApp.fetch(url.replace(/\/+$/, '') + '/rest/v1/rpc/gmail_relay_sync', {
    method: 'post',
    contentType: 'application/json',
    headers: { apikey: anon.trim(), Authorization: 'Bearer ' + anon.trim() },
    payload: JSON.stringify({ p_secret: secret.trim(), p_payload: payload }),
    muteHttpExceptions: true,
  });
  const code = res.getResponseCode();
  if (code < 200 || code >= 300) {
    console.error('relay: Supabase HTTP ' + code + ' ' + res.getContentText().slice(0, 500));
    return null;
  }
  return JSON.parse(res.getContentText());
}

/* ─────────────────────────────── ONE-OFFS ─────────────────────────────── */

/** Every minute. Also removes the old n2b_sync trigger this replaces. */
function installRelayTrigger() {
  ScriptApp.getProjectTriggers().forEach(function (t) {
    const f = t.getHandlerFunction();
    if (f === 'relaySync' || f === 'syncN2bToSupabase') ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger('relaySync').timeBased().everyMinutes(1).create();
  console.log('Installed: relaySync every minute (syncN2bToSupabase trigger removed).');
}

function uninstallRelayTrigger() {
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (t.getHandlerFunction() === 'relaySync') ScriptApp.deleteTrigger(t);
  });
}

/** Counts only; posts nothing. */
function relayPreview() {
  const book = relayList_('threads', RELAY.BOOK_Q, RELAY.BOOK_MAX);
  const cancelled = relayList_('threads', RELAY.BOOK_Q + ' ' + RELAY.CANCEL_Q, 500);
  const recent = relayList_('messages', RELAY.RECENT_Q, 500);
  console.log('book ' + book.length + ', cancelled ' + cancelled.length + ', recent sale/cancel emails ' + recent.length);
}
