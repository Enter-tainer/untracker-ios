# Rule data, semantics and oracles

Everything in this directory is **data and verification tooling** for the rule
engine — no third-party source code is vendored in this repository.

| File | What it is |
| --- | --- |
| `builtin-rules.json` | The 27 upstream rules (`id`, `name`, `description`, `script`, `enabled`), scripts byte-identical to `BuiltinRuleList.kt` |
| `test-cases.json` | 78 end-to-end cases (`input` → `expected`), expectations derived by hand and cross-checked against the real rule scripts |
| `findurls-cases.json` | 60 golden link-detection cases (52 spans), produced by running the **real** `androidx` matcher + `java.net.URI.normalize()` |
| `SEMANTICS.md` | Exact semantics of the JS `$` API and of `findUrls()`, including the upstream quirks this port must reproduce |
| `verify-rules.mjs` | Byte-compares the scripts in `builtin-rules.json` with upstream `BuiltinRuleList.kt` |
| `verify-findurls.mjs` | Diffs an iOS span export against `findurls-cases.json` |
| `validate-testcases.mjs` | Schema check for `test-cases.json` |
| `extract-rules.mjs` | Extracts `BuiltinRuleList.kt` → `builtin-rules.json` |

The app bundles copies of `builtin-rules.json`, `test-cases.json` and
`findurls-cases.json` (as `Resources/*.json`) for the on-device self test.

## Verifying

```bash
# 1. rules are byte-identical to upstream
node tools/rules/verify-rules.mjs <path-to>/BuiltinRuleList.kt tools/rules/builtin-rules.json

# 2. link detection matches the Android matcher
#    (export the spans from the app: launch with --run-selftest, then pull Documents/findurls-actual.json)
node tools/rules/verify-findurls.mjs --actual findurls-actual.json

# 3. case file is well formed
node tools/rules/validate-testcases.mjs
```

`verify-findurls.mjs` matches cases by `name`, then by exact `input`, and compares
`location` / `length` / `hasScheme` / `url`. Offsets are **UTF-16 code units**
(Java `Matcher.start/end` == `NSString`/`NSRange`), so a Python or Swift
`Character`-based validator will mis-count the two emoji cases.

## Regenerating (needs the upstream projects)

These files were generated from external sources that are deliberately **not**
committed here:

- `builtin-rules.json` ← `BuiltinRuleList.kt` from
  [zhanghai/Untracker](https://github.com/zhanghai/Untracker) (Apache-2.0)
- `findurls-cases.json` ← the `AUTOLINK_WEB_URL` pattern and `findUrls()` logic
  from that same project, plus `PatternsCompat` from androidx.core and a JDK
- `test-cases.json` ← hand-derived, then cross-checked by executing the real rule
  scripts in Node over spans produced by the real matcher

To regenerate, clone those repositories next to a scratch directory, then:

```bash
git clone --depth 1 https://github.com/zhanghai/Untracker /tmp/untracker
node tools/rules/extract-rules.mjs /tmp/untracker/app/src/main/java/me/zhanghai/android/untracker/BuiltinRuleList.kt \
     tools/rules/builtin-rules.json
node tools/rules/verify-rules.mjs /tmp/untracker/app/src/main/java/me/zhanghai/android/untracker/BuiltinRuleList.kt \
     tools/rules/builtin-rules.json
```

For the span oracle you additionally need `androidx.core`'s `PatternsCompat.java`
(or the AOSP `Uri`/`UriCodec` for the guard-rail checks) and a JDK; see
`SEMANTICS.md` for the exact behaviour that must be reproduced.

`tools/gen-autolink.py` regenerates `Sources/Kit/AutolinkWebURL.swift` from a local
copy of `PatternsCompat.java`:

```bash
python3 tools/gen-autolink.py /tmp/androidx/PatternsCompat.java Sources/Kit/AutolinkWebURL.swift
```
