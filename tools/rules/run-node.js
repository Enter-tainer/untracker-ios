#!/usr/bin/env node
// run-node.js — CROSS-CHECK HARNESS, NOT GROUND TRUTH.
//
// This is a *self-implementation* of the Android `Uri` subset that Untracker.kt's `$` API
// exposes, plus a driver that runs the real rule scripts (builtin-rules.json) over the URL
// spans found by the REAL androidx AUTOLINK_WEB_URL regex (extracted with a Java probe, see
// make-probe.mjs / _ref/Probe.java). It is used only to sanity-check the hand-derived
// expected values in test-cases.json; when this harness and the expected value disagree, the
// expected value is re-derived by hand from the Kotlin/Uri sources and the harness is fixed.
//
// usage:
//   node make-spans.mjs && java -cp _ref Probe _ref/case-inputs.txt _ref/case-spans.txt
//   node run-node.js [--verbose]
//
// Everything `fetch`-related throws: no test case exercises the network.
'use strict';
const fs = require('fs');
const path = require('path');

const HERE = __dirname;
const rules = JSON.parse(fs.readFileSync(path.join(HERE, 'builtin-rules.json'), 'utf8'));
const cases = JSON.parse(fs.readFileSync(path.join(HERE, 'test-cases.json'), 'utf8'));
const spansText = fs.readFileSync(path.join(HERE, '_ref', 'case-spans.txt'), 'utf8');

// ---------------------------------------------------------------- Android Uri
const HEX = '0123456789ABCDEF';

function pctEncode(bytes) {
  let out = '';
  for (const b of bytes) out += '%' + HEX[(b >> 4) & 0xf] + HEX[b & 0xf];
  return out;
}

// android.net.Uri.encode(s, allow=null): alnum + "-_!.~'()*" copied, everything else UTF-8 %XX
function encode(s) {
  if (s === null || s === undefined) return null;
  const allow = /[A-Za-z0-9\-_.!~*'()]/;
  let out = '';
  for (const ch of s) {
    if (allow.test(ch)) out += ch;
    else out += pctEncode(Buffer.from(ch, 'utf8'));
  }
  return out;
}

const HEXVAL = (c) => {
  if (c >= '0' && c <= '9') return c.charCodeAt(0) - 48;
  if (c >= 'a' && c <= 'f') return c.charCodeAt(0) - 87;
  if (c >= 'A' && c <= 'F') return c.charCodeAt(0) - 55;
  return -1;
};

// android.net.Uri.decode(s) / UriCodec.decode(s, convertPlus, UTF_8, throwOnFailure=false)
function decode(s, convertPlus) {
  if (s === null) return null;
  let out = '';
  const bytes = [];
  const flush = () => {
    if (bytes.length) {
      out += Buffer.from(bytes).toString('utf8');
      bytes.length = 0;
    }
  };
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (ch === '+') {
      flush();
      out += convertPlus ? ' ' : '+';
    } else if (ch === '%') {
      const h1 = i + 1 < s.length ? HEXVAL(s[i + 1]) : -1;
      const h2 = i + 2 < s.length ? HEXVAL(s[i + 2]) : -1;
      if (h1 < 0 || h2 < 0) {
        // AOSP: emits U+FFFD and stops decoding (throwOnFailure == false)
        flush();
        out += '\ufffd';
        return out + s.slice(i + 1);
      }
      bytes.push((h1 << 4) | h2);
      i += 2;
    } else {
      flush();
      out += ch;
    }
  }
  flush();
  return out;
}

function findSchemeSeparator(s) {
  return s.indexOf(':');
}

function isHierarchical(s) {
  const ssi = findSchemeSeparator(s);
  if (ssi === -1) return true;
  if (s.length === ssi + 1) return false;
  return s[ssi + 1] === '/';
}

// Android Uri.parse() -> component bag (StringUri semantics). Enough for the built-in rules.
function parseUri(s) {
  const ssi = findSchemeSeparator(s);
  const scheme = ssi === -1 ? null : s.slice(0, ssi);
  const fsi = s.indexOf('#', ssi === -1 ? 0 : ssi);
  const u = {
    scheme,
    authority: null,
    path: '',
    query: null,
    fragment: fsi === -1 ? null : s.slice(fsi + 1),
    opaque: !isHierarchical(s),
  };
  if (u.opaque) {
    // not produced by any rule in the built-in list; keep it simple
    return u;
  }
  // query
  const qsi = s.indexOf('?', ssi === -1 ? 0 : ssi);
  if (qsi !== -1 && (fsi === -1 || qsi < fsi)) {
    u.query = s.slice(qsi + 1, fsi === -1 ? s.length : fsi);
  }
  // authority + path
  const hasAuthority = ssi !== -1 && s.length > ssi + 2 && s[ssi + 1] === '/' && s[ssi + 2] === '/';
  if (hasAuthority) {
    let end = ssi + 3;
    while (end < s.length && s[end] !== '/' && s[end] !== '?' && s[end] !== '#') end++;
    u.authority = s.slice(ssi + 3, end);
    if (end < s.length && s[end] === '/') {
      let pe = end;
      while (pe < s.length && s[pe] !== '?' && s[pe] !== '#') pe++;
      u.path = s.slice(end, pe);
    } else {
      u.path = '';
    }
  } else if (ssi !== -1) {
    // e.g. "https:/x" - not used by the built-in rules
    let pe = ssi + 1;
    while (pe < s.length && s[pe] !== '?' && s[pe] !== '#') pe++;
    u.path = s.slice(ssi + 1, pe);
  } else {
    let pe = 0;
    while (pe < s.length && s[pe] !== '?' && s[pe] !== '#') pe++;
    u.path = s.slice(0, pe);
  }
  return u;
}

// android.net.Uri#getHost(): userinfo and port stripped, percent-decoded
function hostOf(u) {
  if (u.authority === null) return null;
  const at = u.authority.lastIndexOf('@');
  const colon = u.authority.indexOf(':', at + 1);
  const end = colon === -1 ? u.authority.length : colon;
  return decode(u.authority.slice(at + 1, end), false);
}

function portOf(u) {
  if (u.authority === null) return -1;
  const at = u.authority.lastIndexOf('@');
  const colon = u.authority.indexOf(':', at + 1);
  if (colon === -1) return -1;
  const p = Number(u.authority.slice(colon + 1));
  return Number.isInteger(p) && p >= 0 && p <= 65535 ? p : -1;
}

function userInfoOf(u) {
  if (u.authority === null) return null;
  const at = u.authority.lastIndexOf('@');
  return at === -1 ? null : u.authority.slice(0, at);
}

// Uri.Builder / HierarchicalUri string assembly. An empty (or null) part is omitted entirely;
// a non-empty path without a leading '/' is made absolute when a scheme/authority is present.
function buildUri(u) {
  let out = '';
  if (u.scheme !== null) out += u.scheme + ':';
  if (u.authority !== null) out += '//' + u.authority;
  let p = u.path === null ? '' : u.path;
  const hasSchemeOrAuthority = u.authority !== null || (u.scheme !== null && u.scheme.length > 0);
  if (p.length > 0) {
    if (hasSchemeOrAuthority && p[0] !== '/') p = '/' + p;
    out += p;
  }
  if (u.query !== null && u.query !== '') out += '?' + u.query;
  if (u.fragment !== null && u.fragment !== '') out += '#' + u.fragment;
  return out;
}

// The `Uri.queryParameters` extension in Untracker.kt (copied from the old getQueryParameters).
function queryParameters(u) {
  if (u.opaque) return [];
  const query = u.query;
  if (query === null) return [];
  const params = [];
  let start = 0;
  for (;;) {
    const nextAmp = query.indexOf('&', start);
    const end = nextAmp !== -1 ? nextAmp : query.length;
    let sep = query.indexOf('=', start);
    if (sep === -1 || sep >= end) sep = end;
    const key = decode(query.slice(start, sep), false);
    const value = sep < end ? decode(query.slice(sep + 1, end), false) : '';
    params.push([key, value]);
    if (nextAmp === -1) break;
    start = nextAmp + 1;
  }
  return params;
}

// ---------------------------------------------------------------- $ API
function matches(url, hostPattern, pathPattern, queryPattern, fragmentPattern) {
  const u = parseUri(String(url));
  const host = hostOf(u);
  if (hostPattern !== null && hostPattern !== undefined) {
    if (host === null) throw new Error('NullPointerException: uri.host');
    if (!fullMatch(hostPattern, host)) return false;
  }
  if (pathPattern !== null && pathPattern !== undefined) {
    if (!fullMatch(pathPattern, u.path === null ? '' : u.path)) return false;
  }
  if (queryPattern !== null && queryPattern !== undefined) {
    if (u.query !== null && !fullMatch(queryPattern, u.query)) return false;
  }
  if (fragmentPattern !== null && fragmentPattern !== undefined) {
    if (u.fragment !== null && !fullMatch(fragmentPattern, u.fragment)) return false;
  }
  return true;
}

// Kotlin Regex(pattern, IGNORE_CASE).matches(s) == full-string match, case-insensitive.
const reCache = new Map();
function fullMatch(pattern, s) {
  let re = reCache.get(pattern);
  if (!re) {
    re = new RegExp('^(?:' + pattern + ')$', 'i');
    reCache.set(pattern, re);
  }
  return re.test(s);
}

function getQueryParameter(url, key) {
  const u = parseUri(String(url));
  const query = u.query;
  if (query === null) return null;
  const encodedKey = encode(key);
  let start = 0;
  for (;;) {
    const nextAmp = query.indexOf('&', start);
    const end = nextAmp !== -1 ? nextAmp : query.length;
    let sep = query.indexOf('=', start);
    if (sep === -1 || sep > end) sep = end;
    if (sep - start === encodedKey.length && query.slice(start, start + encodedKey.length) === encodedKey) {
      if (sep === end) return '';
      return decode(query.slice(sep + 1, end), true); // convertPlus = true
    }
    if (nextAmp === -1) break;
    start = nextAmp + 1;
  }
  return null;
}

function removeQueryParameters(url, keyPattern, valuePattern, invertMatch) {
  const u = parseUri(String(url));
  const keyRe = keyPattern === null || keyPattern === undefined ? null : new RegExp('^(?:' + keyPattern + ')$', 'i');
  const valueRe = valuePattern === null || valuePattern === undefined ? null : new RegExp('^(?:' + valuePattern + ')$', 'i');
  const kept = [];
  for (const [key, value] of queryParameters(u)) {
    const m = (keyRe === null || keyRe.test(key)) && (valueRe === null || valueRe.test(value));
    const keep = invertMatch ? m : !m;
    if (keep) kept.push([key, value]);
  }
  u.query = kept.length === 0 ? null : kept.map(([k, v]) => encode(k) + '=' + encode(v)).join('&');
  return buildUri(u);
}

function setHost(url, host) {
  const u = parseUri(String(url));
  const ui = userInfoOf(u);
  const port = portOf(u);
  let auth = '';
  if (ui !== null) auth += ui + '@';
  auth += encode(host);
  if (port !== -1) auth += ':' + port;
  u.authority = auth;
  return buildUri(u);
}

function setEncodedPath(url, p) {
  const u = parseUri(String(url));
  u.path = p;
  return buildUri(u);
}

function setEncodedQuery(url, q) {
  const u = parseUri(String(url));
  u.query = q === null || q === undefined ? null : q;
  return buildUri(u);
}

function setEncodedFragment(url, f) {
  const u = parseUri(String(url));
  u.fragment = f === null || f === undefined ? null : f;
  return buildUri(u);
}

const $ = {
  matches,
  getHost: (url) => {
    const h = hostOf(parseUri(String(url)));
    if (h === null) throw new Error('NullPointerException: uri.host');
    return h;
  },
  getEncodedPath: (url) => {
    const p = parseUri(String(url)).path;
    if (p === null) throw new Error('NullPointerException: uri.encodedPath');
    return p;
  },
  getEncodedQuery: (url) => parseUri(String(url)).query,
  getQueryParameter,
  getEncodedFragment: (url) => parseUri(String(url)).fragment,
  setHost,
  setEncodedPath,
  setEncodedQuery,
  setEncodedFragment,
  removeQueryParameters: (url, k, v) => removeQueryParameters(url, k, v, false),
  retainQueryParameters: (url, k, v) => removeQueryParameters(url, k, v, true),
  fetch: () => {
    throw new Error('fetch() is not implemented in this cross-check harness (no network in tests)');
  },
};

// ---------------------------------------------------------------- findUrls spans
// Parsed from the Java probe output (real androidx regex + java.net.URI.normalize()).
function parseSpans(text) {
  const byIndex = [];
  let cur = null;
  for (const line of text.split('\n')) {
    let m = /^### (\d+)\s*$/.exec(line);
    if (m) {
      cur = { n: Number(m[1]), urls: [] };
      byIndex[cur.n] = cur;
      continue;
    }
    m = /^\s+span \[(\d+),(\d+)\) hasScheme=(true|false) len=\d+\s*$/.exec(line);
    if (m && cur) {
      cur.pending = { start: Number(m[1]), end: Number(m[2]), hasScheme: m[3] === 'true' };
      continue;
    }
    m = /^\s+url\s+<(.*)>\s*$/.exec(line);
    if (m && cur && cur.pending) {
      cur.urls.push({ ...cur.pending, url: m[1] });
      cur.pending = null;
    }
  }
  return byIndex;
}

// ---------------------------------------------------------------- pipeline
// The rule scripts are evaluated as function bodies that reference a global `$`
// (QuickJS gets it via quickJs.set("$", ...)), so expose ours globally.
globalThis.$ = $;

const compiled = new Map();
function ruleFn(rule) {
  let f = compiled.get(rule.id);
  if (!f) {
    // Rules are function bodies: (function(url) { <script> })(url)
    f = new Function('url', rule.script);
    compiled.set(rule.id, f);
  }
  return f;
}

function untrackText(text, spans) {
  if (!spans.byIndex || spans.byIndex.length === 0) return text;
  let out = text;
  // iterate from the last URL to the first so offsets stay valid
  for (let i = spans.byIndex.length - 1; i >= 0; i--) {
    const info = spans.byIndex[i];
    let url = info.url;
    for (const rule of spans.rules) {
      let r;
      try {
        r = ruleFn(rule)(url);
      } catch (e) {
        r = undefined;
        spans.errors.push(`${rule.name}: ${e.message}`);
      }
      url = typeof r === 'string' ? r : url;
    }
    if (!info.hasScheme) url = url.replace(/^http:\/\//, '');
    out = out.slice(0, info.start) + url + out.slice(info.end);
  }
  return out;
}

function main() {
  const verbose = process.argv.includes('--verbose');
  const all = parseSpans(spansText);
  const ruleIndex = new Map(rules.map((r) => [r.id, r]));

  let pass = 0;
  const failures = [];

  cases.forEach((c, i) => {
    const spanRecord = all[i + 1] || { urls: [] };
    const active = c.ruleIds
      ? c.ruleIds.map((id) => {
          const r = ruleIndex.get(id);
          if (!r) throw new Error(`unknown rule id ${id}`);
          return r; // ruleIds enables the rule even if enabled === false
        })
      : rules.filter((r) => r.enabled);
    // preserve upstream order in both cases
    const ordered = rules.filter((r) => active.includes(r));
    const ctx = { byIndex: spanRecord.urls, rules: ordered, errors: [] };
    let got;
    try {
      got = untrackText(c.input, ctx);
    } catch (e) {
      got = `THREW: ${e.message}`;
    }
    const ok = got === c.expected && ctx.errors.length === 0;
    if (ok) pass++;
    else failures.push({ case: c, got, errors: ctx.errors, spans: spanRecord.urls });
    if (verbose) console.log(`${ok ? 'ok  ' : 'DIFF'} ${c.name}${ok ? '' : `\n  in  <${c.input}>\n  exp <${c.expected}>\n  got <${got}>`}`);
  });

  console.log(`\nrun-node.js cross-check: ${pass}/${cases.length} agree with the hand-derived expectations`);
  if (failures.length) {
    console.log(`\n${failures.length} disagreement(s):`);
    for (const f of failures) {
      console.log(`\n- ${f.case.name}`);
      console.log(`   input    <${f.case.input}>`);
      console.log(`   expected <${f.case.expected}>`);
      console.log(`   harness  <${f.got}>`);
      if (f.errors.length) console.log(`   rule errors: ${f.errors.join('; ')}`);
      console.log(`   spans: ${JSON.stringify(f.spans)}`);
    }
    process.exitCode = 2;
  }
}

main();
