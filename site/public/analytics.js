// Visit counting for the BetterAirdrop site, used by index.html and every guide. The pattern is
// ~/.claude/skills/ship-web-app/analytics.md (from dar-ul-adab's tv/analytics.js). PostHog loads only once the page has
// gone idle; until then track() queues (at most 200 events a page load, a guard against a runaway loop).
//
// The one number is Pro purchases: buy_click is our side of it, Polar holds the real count.
// Measured: page_view, guide_view (guide: the slug), install_copy (command: brew or curl, from the Copy button or a
// selection copied by hand), buy_click (sent by index.html's Buy button). Every event carries `path` (the page) and
// `from` (?from=hn, ?from=reddit: kept for the rest of the tab's visit, so a buy_click on the home page still says
// where the visit started). Nothing else: no autocapture, replay, heatmaps or cookies (a
// random ID in localStorage), never identify().
//
// Not counted: Do Not Track or Global Privacy Control; "Don't count me" (the footer notice); ?internal=1 (Moiz's
// devices, remembered; ?internal=0 forgets it); any host or path not in SITES (localhost, previews); automated browsers
// (posthog-js drops those itself). ?analytics=test sends anyway, every event marked test: true.
(function () {
  // The project key (PostHog org BetterAirdrop, project BetterAirdrop, ID 666721, US): public by design, it can only send.
  var KEY = 'phc_DdYDiYJj4vaaYL5SLbHUwyRY4AcZ8kP4puWU2M7F5b9D';
  var HOST = 'https://us.i.posthog.com', SCRIPT = 'https://us-assets.i.posthog.com/static/array.js', MAX_EVENTS = 200;
  // The live site: hostname -> the path it's served under. moizahmedd.github.io/betterairdrop/ now redirects here.
  var SITES = { 'betterairdrop.com': '', 'www.betterairdrop.com': '' };

  var params = new URLSearchParams(location.search);
  var flag = {
    get: function (k) { return localStorage.getItem('ba:' + k) === 'true'; },
    set: function (k, on) { on ? localStorage.setItem('ba:' + k, 'true') : localStorage.removeItem('ba:' + k); }
  };
  if (params.has('internal')) flag.set('internal', params.get('internal') !== '0');
  var tagged = ((params.get('from') || '').toLowerCase().match(/^[a-z0-9_-]{1,24}$/) || [])[0];
  if (tagged) sessionStorage.setItem('ba:from', tagged);
  var from = tagged || sessionStorage.getItem('ba:from') || 'direct';
  if (params.has('from') || params.has('internal')) {          // a copied link mustn't carry the tag on
    var u = new URL(location.href); u.searchParams.delete('from'); u.searchParams.delete('internal');
    history.replaceState(history.state, '', u);
  }
  // Attribution: the site that sent this visit (`ref`, a hostname or 'direct'), and the first-ever tag and referrer for
  // this browser (`first_from`, `first_ref`), so a buy weeks after a creator's video still credits the video. The Buy
  // button hands these to Polar as utm_* (window.baAttribution), so orders carry them too. Hostnames only, no paths.
  var ref = 'direct';
  try {
    var rh = document.referrer ? new URL(document.referrer).hostname.replace(/^www\./, '') : '';
    if (rh && !/(^|\.)betterairdrop\.com$|(^|\.)polar\.sh$/.test(rh)) ref = rh.slice(0, 64);
  } catch (e) {}
  if (!localStorage.getItem('ba:first_ref')) {
    localStorage.setItem('ba:first_ref', ref);
    localStorage.setItem('ba:first_from', from);
  }
  var firstRef = localStorage.getItem('ba:first_ref'), firstFrom = localStorage.getItem('ba:first_from') || from;
  var TEST = params.get('analytics') === 'test';
  var DNT = navigator.doNotTrack === '1' || window.doNotTrack === '1' || navigator.globalPrivacyControl === true;
  var base = Object.prototype.hasOwnProperty.call(SITES, location.hostname) ? SITES[location.hostname] : null;
  var LIVE = base !== null && (location.pathname + '/').indexOf(base + '/') === 0;
  var path = (LIVE ? location.pathname.slice(base.length) : location.pathname) || '/';
  var allowed = function () {
    return KEY.indexOf('TODO') < 0 && (TEST || !(DNT || !LIVE || flag.get('internal') || flag.get('nocount')));
  };

  // Only when this visit may be counted (no DNT/GPC, not "Don't count me", not Moiz's devices).
  if (allowed()) window.baAttribution = { from: from, ref: ref, first_ref: firstRef, first_from: firstFrom };

  var ph = null, loading = false, sent = 0, queue = [];
  function track(name, props, opts) {
    if (!allowed() || sent++ >= MAX_EVENTS) return;
    var p = Object.assign({}, props, { path: path, from: from, ref: ref, first_ref: firstRef, first_from: firstFrom }, TEST ? { test: true } : {});
    ph ? ph.capture(name, p, opts) : queue.push([name, p, opts]);
  }
  window.track = track;

  function load() {
    if (ph || loading || !allowed()) return; loading = true;
    var s = document.createElement('script'); s.src = SCRIPT; s.async = true; s.crossOrigin = 'anonymous';
    s.onload = function () {
      window.posthog && window.posthog.init(KEY, {
        api_host: HOST, persistence: 'localStorage', person_profiles: 'identified_only', respect_dnt: true,
        autocapture: false, capture_pageview: false, capture_pageleave: false, capture_dead_clicks: false,
        capture_heatmaps: false, capture_exceptions: false, capture_performance: false, disable_session_recording: true,
        disable_surveys: true, disable_web_experiments: true, advanced_disable_flags: true,
        disable_external_dependency_loading: true,
        loaded: function (p) {
          ph = p; p.register_once({ first_from: from });
          queue.splice(0).forEach(function (e) { p.capture(e[0], e[1], e[2]); });
        }
      });
    };
    s.onerror = function () { queue = []; };                   // blocked (an ad blocker): the page carries on, uncounted
    document.head.appendChild(s);
  }

  track('page_view');
  var guide = path.match(/^\/guides\/([^/]+)\//);
  if (guide) track('guide_view', { guide: guide[1] });

  // install_copy: the Copy button (always the brew line), or either command selected and copied by hand.
  var copy = document.getElementById('copy');
  if (copy) copy.addEventListener('click', function () { track('install_copy', { command: 'brew' }); });
  document.addEventListener('copy', function () {
    var text = String(window.getSelection() || '');
    var command = /brew install moizahmedd\//.test(text) ? 'brew' : /curl -fsSL/.test(text) ? 'curl' : null;
    if (command) track('install_copy', { command: command });
  });

  var idle = function () { (window.requestIdleCallback || function (f) { setTimeout(f, 1500); })(load, { timeout: 4000 }); };
  document.readyState === 'complete' ? idle() : addEventListener('load', idle, { once: true });

  // The footer's one-line notice, with its "Don't count me" switch.
  function notice() {
    var el = document.getElementById('pnote');
    if (!el) return;
    var off = flag.get('nocount') || flag.get('internal');
    el.innerHTML = DNT ? 'Your browser asks not to be tracked, so visits from it aren’t counted.'
      : off ? 'Visits from this browser aren’t counted. <button type="button">Count me again</button>'
      : 'Visits are counted anonymously, with no cookies. <button type="button">Don’t count me</button>';
    var b = el.querySelector('button');
    if (!b) return;
    b.onclick = function () {
      flag.set('nocount', !off); if (off) flag.set('internal', false);
      if (off) ph ? ph.opt_in_capturing({ captureEventName: false }) : load();
      else { queue = []; ph && ph.opt_out_capturing(); }
      notice();
    };
  }
  notice();
})();
