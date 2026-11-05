# tools/rules — Untracker rule data + test oracles

Everything here is derived from the upstream Android app (`zhanghai/Untracker`, master).

## Deliverables (consumed by the iOS app / tests)

| file | what it is |
|---|---|
| `builtin-rules.json` | The 27 built-in rules, upstream order: `{id, name, description, script, enabled}`. `script` is exactly the text upstream interpolates as `(function(url) { <script> })(url)` — i.e. the Kotlin `"""` raw string after `String.trimIndent()`. 25 enabled; **Bilibili BV** and **Old Reddit** are `enabled: false`. |
| `test-cases.json` | 78 oracle cases `{name, input, expected, ruleIds?, note}`: the exact text `untrack(input)` must return. `ruleIds` (optional) = run only those rules, in upstream order, **enabling them even if `enabled: false`** (that is how the two disabled rules are covered). Without `ruleIds`, run all enabled rules. No case uses `fetch()` (network). |
| `findurls-cases.json` | 60 golden link-detection cases `{input, spans: [{location, length, hasScheme, url, match}], skipped?, note}` — the spans `findUrls()` must produce for each `input`, so the iOS `findURLs` can be diffed directly (text in, spans out) without running the rules. |
| `SEMANTICS.md` | Precise spec of `$` (`matches`, getters/setters, `remove`/`retainQueryParameters`, `fetch`), of `findUrls()`, and of the span oracle. Read this before implementing. |
| `verify-findurls.mjs` | Diffs an iOS-produced span file against `findurls-cases.json`. |

`Resources/BuiltinRules.json` in the app bundle is a copy of `builtin-rules.json`.

### Span index unit (important)

`findurls-cases.json` offsets are **UTF-16 code units**: `location`/`length` are Java String /
`Matcher.start()/end()` offsets, which are exactly `NSString`/`NSRange` offsets, so they compare 1:1
with an iOS implementation. They are **not** Unicode scalar, `Character`/grapheme or UTF-8 byte
offsets. A character outside the BMP (an emoji, U+1F600) counts as **2**; see the
`emoji-index-check` case (`location: 3` after `"😀 "` = 2 + 1 units).

The iOS side should emit, for each case it runs:

```json
{"input": "…", "spans": [{"location": 6, "length": 36, "hasScheme": true, "url": "https://…"}]}
```

(an array of those, `{"cases": [...]}`, or a single object are all accepted).

## Diffing the iOS implementation

```sh
node verify-findurls.mjs --actual ios-spans.json          # per-case diffs, exit 1 on mismatch
node verify-findurls.mjs --actual ios-spans.json --verbose
node verify-findurls.mjs --actual ios-spans.json --json   # machine-readable summary for CI
node verify-findurls.mjs --self-check                     # validate the golden file itself
```

Cases are matched by `name` when present, else by exact `input`. Only `location`, `length`,
`hasScheme` and `url` are compared (`match` is a human-readable extra); `hasScheme` may be omitted
in the actual file. Extra cases reported by the actual file are warned about and fail the run.

## Provenance / how the data was produced

* `extract-rules.mjs` — parses `_ref/BuiltinRuleList.kt` and writes `builtin-rules.json`
  (re-implements Kotlin `trimIndent()`; the raw strings are literal).
* `verify-rules.mjs` — re-extracts the raw strings independently and asserts, for every rule:
  byte-exact script, verbatim occurrence in the `.kt` with block indentation restored, unique
  UUID, field shape, and rule count == number of `Rule(` tokens.
* `make-findurls.mjs` + `_ref/FindUrlsDump.java` — generate `findurls-cases.json` from the **real**
  `androidx.core.util.PatternsCompat.AUTOLINK_WEB_URL` regex object (sliced verbatim out of
  `_ref/PatternsCompat.java`), a transcription of `Untracker.findUrls()` and the real
  `java.net.URI.normalize()`, all executed on a JVM. Not a JS/TS reimplementation of the regex.
* `_ref/` — copies of the upstream Kotlin sources, the AOSP `android.net.Uri`/`UriCodec`,
  `androidx.core.util.PatternsCompat`, the case source `findurls-cases.src.json`, and the Java
  probes. Development reference only.

## Regenerating / re-verifying everything

```sh
# rules + rule-behaviour oracle
node extract-rules.mjs && node verify-rules.mjs
node validate-testcases.mjs
node make-spans.mjs
java -cp _ref Probe _ref/case-inputs.txt _ref/case-spans.txt   # needs a JDK
node run-node.js            # prints 78/78 agree

# golden link-detection spans
node make-findurls.mjs --gen
javac -encoding UTF-8 -d _ref _ref/FindUrlsDump.java
java -cp _ref FindUrlsDump _ref/findurls-inputs.tsv _ref/findurls-spans.tsv
node make-findurls.mjs --assemble
node verify-findurls.mjs --self-check
```

`expected` values in `test-cases.json` were derived **by hand** from the rule scripts and the
`Uri`/`$` semantics, not produced by `run-node.js`; the harness is only a consistency check
(and shares no code with the app). `findurls-cases.json` is generated, not hand-written — it *is*
the Android behaviour.

## Validating the JSON

```sh
python3 -m json.tool builtin-rules.json > /dev/null
python3 -m json.tool test-cases.json > /dev/null
python3 -m json.tool findurls-cases.json > /dev/null
```
