# Untracker `$` API semantics (authoritative spec for the iOS port)

Everything below is derived from the upstream Android sources, not from a reimplementation:

* `app/src/main/java/me/zhanghai/android/untracker/Untracker.kt` (pipeline, `Builtins`, `findUrls`)
* `android.net.Uri` / `android.net.UriCodec` (AOSP master, see `_ref/Uri.java`, `_ref/UriCodec.java`)
* `androidx.core.util.PatternsCompat` (see `_ref/PatternsCompat.java`) and `android.text.util.Linkify.sUrlMatchFilter`
* `java.net.URI` (JDK `normalize()`)

The regex/URI facts were additionally checked against the *real* `PatternsCompat.AUTOLINK_WEB_URL`
and the real JDK `java.net.URI.normalize()` with a throw-away Java probe (`make-probe.mjs` →
`_ref/Probe.java`), so `findUrls()` match extents in the test cases are not guesswork.
`tools/rules/_ref/` is development reference material; the app only needs
`builtin-rules.json`, `test-cases.json` and this document.

---

## 0. Pipeline: `untrack(text)`

1. `findUrls(text)` → `List<UrlInfo(start, end, hasScheme, url)>` (see §8). If empty, return `text` unchanged.
2. Keep only rules with `enabled == true` (upstream ships 27 rules, 25 enabled: **Bilibili BV** and
   **Old Reddit** are `enabled = false`). If none are enabled, return `text` unchanged.
3. For every URL **from the last to the first** (so earlier offsets stay valid):
   1. `url = urlInfo.url`
   2. for each enabled rule **in list order**:
      `result = eval("(function(url) { <rule.script> })(url)")`
      if `result` is a string → `url = result`; otherwise (undefined, null, number, …) → `url` unchanged.
      Rules never short-circuit: every enabled rule runs on the current value.
   3. if `urlInfo.hasScheme == false` → `url = url.removePrefix("http://")` (case-sensitive, literal prefix)
   4. replace `text[start, end)` with `url`
4. Return the resulting text.

Consequences the iOS port must reproduce:

* A rule sees **only the URL string**, never the surrounding text, and it sees the *current* value
  (already modified by previous rules).
* Rule scripts are function **bodies**: `return X;` replaces the URL with `X`; falling off the end
  (or `return;`) means "no change".
* Non-string return values are ignored.
* A rule that returns a differently-shaped URL changes what later rules see (the redirect rule
  returns a whole new URL string; later rules then operate on that text).

---

## 1. `matches(url, hostPattern?, encodedPathPattern?, encodedQueryPattern?, encodedFragmentPattern?)`

Implemented as:

```kotlin
val uri = url.toUri()
if (hostPattern != null && !Regex(hostPattern, IGNORE_CASE).matches(uri.host!!)) return false
if (pathPattern != null && !Regex(pathPattern, IGNORE_CASE).matches(uri.encodedPath!!)) return false
if (queryPattern != null) {
    val q = uri.encodedQuery
    if (q != null && !Regex(queryPattern, IGNORE_CASE).matches(q)) return false
}
if (fragmentPattern != null) {
    val f = uri.encodedFragment
    if (f != null && !Regex(fragmentPattern, IGNORE_CASE).matches(f)) return false
}
return true
```

* **Full-string matching.** Kotlin `Regex.matches()` = the *whole* component must match, i.e. the
  pattern is implicitly `^(?:pattern)$`. `host === 'x\.com'` does **not** match `www.x.com`, and
  `/search` does **not** match `/search/`. Use `find`-like semantics only where a rule writes `.*`
  itself (e.g. `'.*\burl=.+'`).
* **Case-insensitive** (`RegexOption.IGNORE_CASE`) for *all* four components.
* **Missing-pattern argument** (JS `undefined`) behaves as `null` → that component is not checked.
  The `INIT_SCRIPT` wrapper explicitly forwards 5 arguments so short calls like
  `$.matches(url, 'search.app', '/')` become `(…, path, undefined, undefined)` → nulls.
* **Absent query ⇒ the query check is SKIPPED, `matches()` returns `true`** (as long as host/path
  match). A query pattern does *not* require that a query exists. Same for the fragment.
  This is the single most surprising semantic: `matches(url, 'search\.app', '/', '.*\blink=.+')`
  is `true` for `https://search.app/` with no query at all.
* But a **present-but-empty** query (`…?`) gives `encodedQuery == ""`, which *is* checked against the
  pattern (so a query pattern typically fails on it).
* `uri.host!!` / `uri.encodedPath!!`: a URL without a host (e.g. `http:///x`, `mailto:…`,
  or `""`) **throws NPE** here. See §9.

Component values as Android `Uri` defines them:

| component | absent | present-but-empty |
|---|---|---|
| `host` | `null` (URLs used by the rules always have one) | – |
| `encodedPath` | `""` (e.g. `https://example.com`), never `null` for hierarchical URLs | `""` |
| `encodedQuery` | `null` when there is no `?` | `""` for `…?` |
| `encodedFragment` | `null` when there is no `#` | `""` for `…#` |

`host` is **percent-decoded** and excludes userinfo and port (`https://u@www.reddit.com:8080/x` →
host `www.reddit.com`). `encodedPath/Query/Fragment` are the **raw encoded** components.

---

## 2. Percent-encoding / decoding

Two different decoders are used, and the difference is observable:

| API | plus handling | used by |
|---|---|---|
| `Uri.decode(s)` → `UriCodec.decode(s, convertPlus=false, UTF_8, throwOnFailure=false)` | literal `+` **stays `+`** | `removeQueryParameters` / `retainQueryParameters` (via the `queryParameters` walker) |
| `getQueryParameter(key)` → `UriCodec.decode(value, convertPlus=true, …)` | literal `+` → **space** | `$.getQueryParameter` |

Both decode `%XX` sequences as UTF-8; malformed input yields U+FFFD (never throws).
`%2B` is an escape and always decodes to `+` (it is *not* affected by `convertPlus`).

`Uri.encode(s)` (= `Uri.encode(s, null)`): letters, digits and the unreserved set
**`_ - ! . ~ ' ( ) *`** are copied; **everything else** is written as UTF-8 `%XX` with
**uppercase** hex digits. In particular: space → `%20` (never `+`), `+` → `%2B`,
`:` → `%3A`, `/` → `%2F`, `,` → `%2C`, `;` → `%3B`, `=` → `%3D`, `&` → `%26`, `$` → `%24`,
`@` → `%40`, `?` → `%3F`, `#` → `%23`, `[`/`]` → `%5B`/`%5D`.

Therefore `encode(decode(s)) == s` **only for canonical encodings**. Rebuilding a query can change
the URI even when nothing is removed:

* `q=a+b` → `q=a%2Bb` (literal `+` is not a space for `Uri.decode`)
* `q=%e4%b8%ad` → `q=%E4%B8%AD` (uppercase hex)
* `q=%41` → `q=A` (unreserved characters are written literally)
* `q=%28a%29` → `q=(a)` (parentheses are unreserved)
* `q=%20` → `q=%20`, `q=%2B` → `q=%2B` (already canonical)

`getQueryParameter(key)` details:

* Key comparison is **case-sensitive** and done on the *encoded* key
  (`query.regionMatches(start, encode(key), …)`, the 4-arg overload → case-sensitive).
  So `?URL=…` does **not** yield a value for key `url`; `?%75rl=…` does not either.
* Returns `null` if the key is absent; returns `""` if the key is present without `=`
  (e.g. `?url` or `?url=&…`).
* Splits on `&`, then splits each segment at the **first** `=`; the value is everything after it
  (which may itself contain `=`).
* Only the first matching parameter is returned.

---

## 3. `removeQueryParameters(url, keyPattern?, valuePattern?)` and `retainQueryParameters(...)`

Same implementation with `invertMatch = false` (remove) / `true` (retain).

**Parameter walker** (`Uri.queryParameters` in `Untracker.kt`, copied from the old
`Uri.getQueryParameters` behaviour):

* if `encodedQuery == null` → **no parameters** (loop does not run), *not* one empty parameter.
* otherwise split the raw encoded query on `&` only (`;` is *not* a separator).
* each segment: key = `Uri.decode(segment up to first '=')`; value = `Uri.decode(rest)`; if the
  segment has no `=` the value is `""`.
* **A trailing `&`, or an empty query string, produces one extra `("", "")` pair.**
  (`?` → one pair `("","")`; `?a=1&` → `("a","1")`, `("","")`)

**Match rule** (both patterns are `Regex(pattern, IGNORE_CASE)` matched **fully**; a `null` pattern
means "match anything"):

```
matches = (keyPattern == null || keyRegex.matches(decodedKey))
       && (valuePattern == null || valueRegex.matches(decodedValue))
keep = remove ? !matches : matches
```

Note both sides are **decoded** before matching, so e.g. `p`/`1` are compared post-decoding and a
value `%31` matches pattern `1`.

**Rebuild**: `uri.buildUpon().clearQuery()` then `appendQueryParameter(key, value)` for each kept
pair, in original order. `appendQueryParameter` writes `Uri.encode(key) + "=" + Uri.encode(value)`
and joins with `&`; the first kept pair supplies no leading `&`. The query is *always* rebuilt, so:

| encoded query | parameter walker | rebuilt (`retain*`/`remove*` keeps everything) |
|---|---|---|
| (absent) | no pairs | no `?` (unchanged) |
| `""` (`…?`) | `("","")` | `?=` |
| `a` | `("a","")` | `a=` |
| `a=` | `("a","")` | `a=` |
| `a=1&a=2` | `("a","1")`, `("a","2")` | `a=1&a=2` (order kept, duplicates kept) |
| `a=1&` | `("a","1")`, `("","")` | `a=1&=` |
| `=x` | `("","x")` | `=x` |

* If **nothing** is kept, `clearQuery()` leaves `query == null`, so the `?` disappears entirely.
  Same effect as `setEncodedQuery(url, null)`.
* Fragment, path, authority and scheme are byte-preserved by the rebuild (only the query is
  re-encoded). An empty-path apex URL stays `https://example.com` (no slash is added).
* Because the rebuild always happens, calling any of these two functions on a URL with a
  non-canonical query re-canonicalises it (§2). The two generic rules
  (`Common analytics`, `Common ads`) therefore touch the query of **every** URL, even URLs belonging
  to no site rule.

---

## 4. `setHost(url, host)`

```kotlin
val encodedAuthority = buildString {
    uri.encodedUserInfo?.let { append(it); append('@') }
    append(Uri.encode(host))
    uri.port.let { if (it != -1) { append(':'); append(it) } }
}
uri.buildUpon().encodedAuthority(encodedAuthority).toString()
```

* `encodedUserInfo` (raw encoded userinfo) is preserved **verbatim** and re-attached with `@`.
* The new host is passed through `Uri.encode` (so a plain DNS name such as `old.reddit.com` is
  unchanged; anything not in the unreserved set would be escaped).
* An **explicit** port is preserved as-is (`https://www.reddit.com:8080/x` →
  `https://old.reddit.com:8080/x`). There is no default-port inference: a URL without a port gains
  none, and a URL with `:443` keeps `:443`.
* Path, query and fragment are preserved (the query is **not** rebuilt/re-encoded here, because
  `encodedAuthority()` only replaces the authority part).

---

## 5. `setEncodedPath` / `setEncodedQuery` / `setEncodedFragment`

These set the component as an **already-encoded** string — no re-encoding, no validation.

* `setEncodedQuery(url, null)` → removes the query component and the `?`.
* `setEncodedQuery(url, "")` → also produces **no** `?` (an empty part is omitted on output), i.e.
  the same as `null`. A rule wanting a literal `?` cannot express it.
* `setEncodedPath(url, path)`: `Uri.Builder` makes the path absolute when a scheme/authority is
  present, so a path not starting with `/` gets a `/` prepended. `""` yields "no path"
  (an apex URL is unaffected).
* None of these re-encode the rest of the URI: the scheme, authority, the other components and the
  original escape sequences of untouched components are byte-preserved.
* `encodedQuery`/`encodedFragment` setters do **not** clear each other; setting the query leaves the
  fragment alone and vice versa.

---

## 6. Getters

* `getHost(url)` → `uri.host!!` — percent-decoded, no userinfo, no port. NPE if absent.
* `getEncodedPath(url)` → raw path; **`""`** for an apex URL (`https://example.com`), `"/"` for
  `https://example.com/`. Never `null` for these URLs (`!!` in Kotlin).
* `getEncodedQuery(url)` → `null` when there is no `?`, `""` for a bare `?`.
* `getEncodedFragment(url)` → `null` when there is no `#`, `""` for a bare `#`.
* `getQueryParameter(url, key)` → see §2.

---

## 7. `fetch(argumentsJson)` — network API used by the short-link rule

`$.fetch` is wrapped in `INIT_SCRIPT`:

```js
const fetch = $.fetch.bind($);
$.fetch = function () { return JSON.parse(fetch(JSON.stringify(Array.from(arguments)))); };
```

so any JS call shape is serialised as a JSON **array** and parsed by Kotlin:

* `$.fetch(url)` → `arguments = [url]`.
* `$.fetch(url, options)` → `arguments = [url, options]`.
* `$.fetch({url, ...})` → `resource` is an object → `url = resource.url`, `options = resource`.

Options object (all optional, shapes matter — this is a hand-rolled parser, not real `fetch`):

| key | accepted shape | default |
|---|---|---|
| `method` | string, uppercased (`get` → `GET`); body is attached as request body | `"GET"` |
| `headers` | **array of `[name, value]` pairs** (`[["a","b"],["c","d"]]`) — *not* an object map. A `Content-Type` header is special-cased into the media type and must not be duplicated | none |
| `body` | string → request body | none |
| `redirect` | one of `"follow"`, `"error"`, `"manual"`; anything else throws | `"follow"` (`"manual"` → `followRedirects(false)`) |

Response JSON returned to JS (keys in this order, all present):

```json
{ "body": "<response body as string>",
  "headers": [["Name","Value"], ...],           // array of pairs, wire order, duplicates kept
  "ok": true,                                    // HTTP status in 200..299
  "redirected": false,                           // OkHttp priorResponse != null
  "status": 200,
  "statusText": "OK",                            // HTTP reason phrase (may be "")
  "url": "https://final/url/after/redirects" }
```

Notes:

* `headers` is a **list of `[name, value]` arrays**, so the rule does
  `response.headers.find(it => it[0].toLowerCase() === 'location')?.[1]`.
* `body` is read once, eagerly, and is always a string (no binary support).
* Network failure throws `IOException` out of the Kotlin bridge (no `catch` anywhere in the rule
  language path); with `redirect: 'error'` a 3xx also throws. There is no timeout, UA, cookie jar,
  cache or redirect-limit configuration beyond OkHttp defaults.
* Rules call `fetch` in `while (true)` loops with no iteration cap; a redirect loop would hang.
* `Common short links` is the only built-in rule that fetches. **No test case in
  `test-cases.json` exercises `fetch`** (it needs network); that code path is specified only from
  the source above.

---

## 8. `findUrls(text)` — which substrings count as URLs

Uses `androidx.core.util.PatternsCompat.AUTOLINK_WEB_URL` (copied from AOSP `Patterns.WEB_URL`),
`Linkify.sUrlMatchFilter`, and `java.net.URI`:

```kotlin
matcher = PatternsCompat.AUTOLINK_WEB_URL.matcher(text)
for each match [start,end):
    if (!Linkify.sUrlMatchFilter.acceptMatch(text, start, end)) continue   // reject if text[start-1] == '@'
    if (urlWithIgnoredSchemeRegex.matches(match)) continue                  // (rtsp|ftp)://.* (ignore case)
    hasScheme = urlWithSchemeRegex.matches(match)                           // https?://.* (ignore case)
    url = if (hasScheme) match else "http://$match"
    if (!(uri.isHierarchical && uri.isAbsolute)) continue
    url = URI(url).normalize().toString()
    add UrlInfo(start, end, hasScheme, url)
```

The regex, exactly (from `_ref/PatternsCompat.java`):

```
PROTOCOL       = (?i:http|https|rtsp)://
WORD_BOUNDARY  = (?:\b|$|^)
USER_INFO      = (?:[a-zA-Z0-9$\-_.+!*'(),;?&=]|(?:%[a-fA-F0-9]{2})){1,64}(?::(?:…){1,25})?@
PORT_NUMBER    = :\d{1,5}
LABEL_CHAR     = a-zA-Z0-9 + UCS_CHAR        // UCS_CHAR ≈ U+00A0-U+D7FF, U+F900-U+FDCF, U+FDF0-U+FFEF
PATH_AND_QUERY = [/ ?](?:(?:[LABEL_CHAR ;/?:@&=#~-.+!*'(),_$])|(?:%[a-fA-F0-9]{2}))*
```

`AUTOLINK_WEB_URL = "(" + WEB_URL_WITH_PROTOCOL + "|" + WEB_URL_WITHOUT_PROTOCOL + ")"`, where

* **with protocol**: `PROTOCOL (USER_INFO)? (RELAXED_DOMAIN)? (PORT)? (PATH_AND_QUERY)?  WORD_BOUNDARY`
  — the domain is relaxed (TLD not required) and *optional*, any host case is fine.
* **without protocol**: `WORD_BOUNDARY (?<!://) (STRICT_DOMAIN) (PORT)? (PATH_AND_QUERY)? WORD_BOUNDARY`
  — the TLD must be in the (auto-generated) IANA list, matched case-**sensitively** because the list
  is lowercase and only `PROTOCOL` is wrapped in `(?i:…)`. So a scheme-less `WWW.Douban.COM/x`
  is *not* detected, while `https://WWW.Douban.COM/x` is.

Observable consequences (all verified with the real regex):

* The match generally spans the whole URL including `?query#fragment`, because `/ ? # & = + %` are
  all in the char class. A trailing `?` or `&` at the end of the matched text is included.
* **Trailing punctuation**: `WORD_BOUNDARY` at the end means a final `,`/`.`/`)`/`/` is dropped when
  the next character is whitespace, but **kept when the URL ends the string** (`$`). E.g.
  `https://example.com/a?utm_source=x, then` → match stops before `,`; but
  `https://example.com/a?utm_source=x.` at end-of-input → the `.` is part of the URL.
* Leading `(`/`<`/`"`/space are not in the char class, so they are not included; a match directly
  preceded by `@` is rejected (emails are skipped).
* **Start boundary is `Character.isLetterOrDigit`-based (NOT ASCII `\w`).** Java's `\b` uses
  `Character.isLetterOrDigit`, so any *letter or digit* immediately before the scheme kills the
  match — `ahttps://example.com/x`, `1https://example.com/x` and `看https://example.com/x` all
  produce **zero** spans, while `😀https://example.com/x` does match (an emoji is not a letter).
  A port that implements the boundary as ASCII `[A-Za-z0-9_]` or as "any alphanumeric including
  CJK but not emoji" must be checked against `findurls-cases.json`; this is the single easiest
  place to diverge. NB: `\w` in the char classes is ASCII-only, so `\b` and `\w` disagree on CJK —
  which is exactly why CJK is both *allowed inside* a URL and *blocks* a match when glued before it.
* **Trailing CJK letters are absorbed** (unlike ASCII punctuation): `https://example.com/x谢谢` and
  `https://example.com/x谢谢 后面` both match `…x谢谢` (letter→space is a boundary), whereas
  `https://example.com/x。 后面` and `https://example.com/x， 后面` stop at `x` (punctuation→space is
  not), and `。`/`，`/`；` + CJK at end-of-input are absorbed again because `$` terminates the match.
* `ftp://…` is never matched at all; `rtsp://…` matches but is then skipped explicitly.
* A match that is only a bare scheme (`https://`, no authority) is matched by the regex but dropped
  by the `uri.isHierarchical && uri.isAbsolute` check.
* A scheme-less URL gets `http://` prepended for processing, and the result has that literal prefix
  stripped again *only if it is still there* (§0.3) — so if a rule returns an `https://…` URL for a
  scheme-less input, the output text gains a scheme.
* Non-ASCII (CJK etc.) is matched in path, query **and host labels** because of `UCS_CHAR`:
  `https://例え.jp/パス` matches, and a scheme-less `分享链接example.com/x` is parsed as host
  `分享链接example.com` (one span for the whole text, no scheme).
* `java.net.URI(url).normalize()` only removes `.`/`..` path segments
  (`/a/./b/../c` → `/a/c`); it does not lowercase, decode or re-encode anything.
* The golden span oracle for all of the above is `findurls-cases.json` (§13).
* `uri.isHierarchical && uri.isAbsolute` requires an absolute hierarchical URI (scheme + `//`).

---

## 9. Crashes / undefined behaviour in upstream (iOS must choose deliberately)

These are real holes in `Untracker.kt`; they are **not** covered by test cases.

1. A rule can return a string that is not an absolute URL — e.g. `Common redirections` returns
   `getQueryParameter('url')`, and `?url=` (key without value) returns `""`, or a target written
   as `example.com/x`. The next enabled rule calls `matches()`, which does `uri.host!!` on that
   string and throws `NullPointerException` → the QuickJS evaluation fails and `untrack()` throws
   (the UI catches/reports it as a failure). Same for any other rule-produced garbage.
2. A URL that reaches the rules without a host/path would NPE the same way.
3. `fetch` failures throw `IOException` out of the bridge; rules have no try/catch, so the whole
   untrack fails.
4. `Common short links` loops `while (true)` with no cap; a redirect cycle hangs/never terminates.
5. `url` is interpolated into a JS source string with `"(...)(\"$untrackedUrl\")"` — a URL containing
   `"` or `\` would break the snippet. The detected URL charset excludes `"`, but a rule could return
   a string containing quotes (e.g. a redirect target), which would then be interpolated in the
   *next* rule call and produce a JS syntax error. Worth guarding in a reimplementation.

Recommendation for iOS: keep the observable behaviour of §1–§8 identical for all well-formed
inputs, and add the guards upstream lacks (host nil → no match; non-string/empty result → keep the
previous URL) behind a documented behavioural note rather than crashing.

---

## 10. `builtin-rules.json`

Array, upstream order, one object per Kotlin `Rule`:
`{"id", "name", "description", "script", "enabled"}`.

* `script` is the exact text that is interpolated as the body of `(function(url) { … })(url)`:
  the content of the Kotlin `"""` raw string after `String.trimIndent()` (two rules are single-line
  literals with no `trimIndent()`: *Common analytics* and *Common ads*).
* Kotlin raw strings are literal, so every `\\` in the source stays **two** backslashes in the
  script text — which is what JS needs to write a literal `.` in a RegExp from a string
  (`'www\\.douban\\.com'` is the JS source for the string `www\.douban\.com`).
* `enabled` is `false` only for **Bilibili BV** (`db094a08-e3c4-4bd9-aa98-16df86237f6d`) and
  **Old Reddit** (`55662cf5-b43e-491a-b72b-adc1111b8583`); all other rules default to `true`.
* Verified programmatically (`verify-rules.mjs`): 27 rules, ids unique, scripts byte-identical to
  the (`trimIndent`-ed) raw strings, and each script occurs verbatim in `BuiltinRuleList.kt` once its
  original block indentation is restored.

The app bundle copy is `Resources/BuiltinRules.json` (same content).

---

## 11. `test-cases.json` conventions

`[{"name", "input", "expected", "ruleIds"?, "note"}]`

* `input` is the *text* handed to `untrack(text)` — usually one URL, sometimes with prose around it.
* `expected` is the exact final text.
* **If `ruleIds` is present**: run **only** the listed rules, in upstream order, **enabling them even
  if `enabled == false`**. This is how the two disabled rules (BV→av, Old Reddit) stay covered.
  `ruleIds` lists the rules that matter; rules not listed are not run and their absent effects are
  part of `expected` (see e.g. `bilibili-bv-rule-disabled-by-default` vs `bilibili-bv-to-av-170001`).
* **If `ruleIds` is absent**: run all `enabled` rules, in upstream order (the default app behaviour).
* All `expected` values are hand-derived from the rule scripts + the semantics above; they were not
  produced by running a JS implementation of the engine.
* No case triggers `fetch()` (network); short-link hosts (`t.cn`, `b23.tv`, `u.jd.com`, `amzn.*`,
  `pin.it`, `search.app` with a non-`link=` query, …) are deliberately avoided except where the
  redirect rule resolves them before the short-link rule can fetch (`redirect-search-app`).

---

## 12. Notes for the JavaScriptCore port

1. Regex flavour: the rules use JS regex syntax evaluated by QuickJS. JSC is also ECMAScript, so the
   scripts should run unchanged — **except** for host/`fetch` bindings, which must be provided.
   Things to check: `BigInt` literals (`23442827791579n`, used by BV→av), lookbehind
   `(?<=\/)` (used by Amazon and Pinterest only), optional chaining `?.` (short-link rule) and
   short-link rule), named-less groups, `/i` flags. All supported by modern JSC (iOS 14+), but the
   lookbehind and BigInt availability should be checked against the deployment target.
2. `$` must be a global object whose methods mirror the Kotlin signatures above; the
   `INIT_SCRIPT` wrapper is needed only because QuickJS needed explicit binding and arity padding
   for `matches` (5 args). With JSC you can either run the same `INIT_SCRIPT` or define the methods
   with default/optional parameter handling — but keep the "missing ⇒ null" behaviour.
3. `matches` must implement **full-match, case-insensitive** matching on *components*, with the
   absent-query ⇒ true rule. Do not use `NSRegularExpression` `firstMatch` semantics directly.
4. `findUrls` should be a port of the exact regex above, **not** `NSDataDetector`: the spans (and
   therefore which characters are replaced) differ, and the oracle test cases encode the Android
   spans (trailing `.` at end-of-input, bare `?`/`&`, CJK in path/query, scheme-less handling).
5. Query rebuild must apply `encode(decode(x))` with the exact allowed set (§2), otherwise
   `a+b → a%2Bb`, `%41 → A`, `%28 → (` cases will fail.
6. `Uri`'s "empty part is omitted" rule: setting an empty query removes the `?`; a URL ending in `?`
   that goes through any query-rebuilding rule ends up as `…?=` (see case `empty-query-becomes-equals`).
7. `setHost` must preserve userinfo and explicit port, and must not re-encode the rest of the URI.
8. Rules run against the *whole* rule list for *every* URL, cumulatively, in order; `undefined`
   return = no change. Don't stop at the first matching rule.

### Genuinely ambiguous / version-dependent points

* **`Uri.decode` plus handling**: pre-Jelly-Bean Android decoded `+` as `+` too, but
  `getQueryParameter`'s `convertPlus=true` is the documented behaviour and is what this spec and the
  oracle use. Keep `+` literal in the generic walker and `+`→space only in `getQueryParameter`.
* **`PatternsCompat.AUTOLINK_WEB_URL`'s IANA TLD list** changes with androidx versions; the list
  shipped in the extracted `_ref/PatternsCompat.java` is the 2023-09 snapshot (androidx-main).
  A scheme-less host whose TLD is newer than that snapshot may not be detected by the Android app.
* **`Uri` internals** (`parseHost`, `getPort`, `encodedUserInfo`, "empty part" printing) were read
  from AOSP master; older/newer platform versions could differ in exotic cases. The behaviour
  asserted here matches long-standing Android behaviour.
* The oracle does not pin down what happens when a rule returns a non-absolute URL (§9) or when
  `fetch` fails — both crash/fail upstream; treat as out of scope.

---

## 13. `findurls-cases.json` — golden link-detection spans (for diffing `findURLs`)

Separate from `test-cases.json` (which pins the *text* result of `untrack`), this file pins the
**detected link spans** themselves, so the iOS `findURLs` can be diffed directly.

```jsonc
{
  "indexUnit": "UTF-16 code units",
  "cases": [
    { "name": "two-links-in-one-string",
      "input": "first https://a.example.com/x?utm_source=1 and second https://b.example.com/y?utm_source=2 end",
      "spans": [
        { "location": 6,  "length": 36, "hasScheme": true,  "url": "https://a.example.com/x?utm_source=1", "match": "https://a.example.com/x?utm_source=1" },
        { "location": 54, "length": 36, "hasScheme": true,  "url": "https://b.example.com/y?utm_source=2", "match": "https://b.example.com/y?utm_source=2" }
      ],
      "note": "..." }
  ]
}
```

* `location`/`length` are **UTF-16 code-unit** offsets into `input`. That is exactly what Java
  String/`Matcher.start()`/`end()` return and exactly what `NSString`/`NSRange` use, so they compare
  1:1 with an iOS implementation. They are **not** Unicode-scalar, `Character`, grapheme or UTF-8
  byte offsets — see case `emoji-index-check` (`location: 3` after `"😀 "`, which is 2+1 units).
* `spans` are ascending and non-overlapping, one per link, in the order `untrack` would replace them
  (it iterates them in reverse, but the list itself is ascending).
* `hasScheme` = the matched **text** had an explicit `https?://`.
* `url` = the string handed to the rules: the matched text, with `http://` prepended when
  `hasScheme == false`, after `java.net.URI(url).normalize()`. `match` is the raw slice (for humans;
  the diff runner only compares `location`, `length`, `hasScheme`, `url`).
* `skipped` (only on some cases) lists candidate matches that `findUrls()` discarded, with the reason
  — `email-filter`, `ignored-scheme`, `not-hierarchical-absolute`, `uri-parse-error`. Upstream just
  drops them; they are here to explain a zero-span result.
* Generated by `make-findurls.mjs` from `_ref/findurls-cases.src.json`, executing the **real**
  `PatternsCompat.AUTOLINK_WEB_URL` + a transcription of `findUrls()` + the real
  `java.net.URI.normalize()` on the JVM (`_ref/FindUrlsDump.java`).
* Diff it with: `node verify-findurls.mjs --actual ios-spans.json` (see README). `--self-check`
  validates the golden file's invariants. The iOS side emits
  `{input, spans: [{location, length, hasScheme, url}]}` (array or `{cases: […]}`).
