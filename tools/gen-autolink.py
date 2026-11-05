#!/usr/bin/env python3
"""Generate Sources/Kit/AutolinkWebURL.swift from androidx's PatternsCompat.java.

The Android app detects links with
`androidx.core.text.util.PatternsCompat.AUTOLINK_WEB_URL.matcher(text)`. That
pattern is a huge generated alternation (RFC 3987 grammar + the IANA TLD list),
so the iOS port generates it from the actual Java source instead of transcribing
it by hand.

ICU (which backs NSRegularExpression) does not support Java's character-class
intersection syntax, so `UCS_CHAR` is pre-computed into explicit ranges, and the
astral-plane ranges are offered as an optional variant because some regex engines
reject \\x{...} inside a character class.

Usage:
    python3 tools/gen-autolink.py <PatternsCompat.java> <AutolinkWebURL.swift>
"""

import pathlib
import re
import sys


def extract_iana(source: str) -> str:
    match = re.search(r"IANA_TOP_LEVEL_DOMAINS\s*=\s*(.*?);", source, re.S)
    if not match:
        raise SystemExit("IANA_TOP_LEVEL_DOMAINS not found in source")
    # The constant is a Java string concatenation: join all literals in order.
    literals = re.findall(r'"((?:[^"\\]|\\.)*)"', match.group(1))
    iana = "".join(literals)
    if len(iana) < 1000 or "aaa" not in iana:
        raise SystemExit("IANA TLD list looks wrong (%d chars)" % len(iana))
    return iana


def build_pattern(iana: str, ucs: str) -> str:
    # RFC 3987 character classes (UCS_CHAR pre-computed, see module docstring).
    label_char = "a-zA-Z0-9" + ucs
    tld_char = "a-zA-Z" + ucs

    iri_label = "[" + label_char + "](?:[" + label_char + r"_\-]{0,61}[" + label_char + "]){0,1}"
    punycode_tld = r"xn\-\-[\w\-]{0,58}\w"
    tld = "(" + punycode_tld + "|[" + tld_char + "]{2,63})"
    host_name = "(" + iri_label + r"\.)+" + tld
    ip_address = (
        r"((25[0-5]|2[0-4][0-9]|[0-1][0-9]{2}|[1-9][0-9]|[1-9])\.(25[0-5]|2[0-4][0-9]"
        r"|[0-1][0-9]{2}|[1-9][0-9]|[1-9]|0)\.(25[0-5]|2[0-4][0-9]|[0-1][0-9]{2}"
        r"|[1-9][0-9]|[1-9]|0)\.(25[0-5]|2[0-4][0-9]|[0-1][0-9]{2}|[1-9][0-9]|[0-9]))"
    )
    domain_name = "(" + host_name + "|" + ip_address + ")"

    protocol = r"(?i:http|https|rtsp)://"
    word_boundary = r"(?:\b|$|^)"
    user_info = (
        r"(?:[a-zA-Z0-9\$\-\_\.\+\!\*\'\(\)\,\;\?\&\=]|(?:\%[a-fA-F0-9]{2})){1,64}"
        r"(?:\:(?:[a-zA-Z0-9\$\-\_\.\+\!\*\'\(\)\,\;\?\&\=]|(?:\%[a-fA-F0-9]{2})){1,25})?\@"
    )
    port_number = r"\:\d{1,5}"
    path_and_query = (
        r"[/\?](?:(?:["
        + label_char
        + r";\/\?:@&=#~\-\.\+!\*'\(\),_\$])|(?:%[a-fA-F0-9]{2}))*"
    )

    strict_tld = "(?:" + iana + "|" + punycode_tld + ")"
    strict_host_name = "(?:(?:" + iri_label + r"\.)+" + strict_tld + ")"
    strict_domain_name = "(?:" + strict_host_name + "|" + ip_address + ")"
    relaxed_domain_name = r"(?:(?:" + iri_label + r"(?:\.(?=\S))?)+|" + ip_address + ")"

    without_protocol = (
        "("
        + word_boundary
        + r"(?<!:\/\/)"
        + "("
        + "(?:" + strict_domain_name + ")"
        + "(?:" + port_number + ")?"
        + ")"
        + "(?:" + path_and_query + ")?"
        + word_boundary
        + ")"
    )
    with_protocol = (
        "("
        + word_boundary
        + "(?:"
        + "(?:" + protocol + "(?:" + user_info + ")?" + ")"
        + "(?:" + relaxed_domain_name + ")?"
        + "(?:" + port_number + ")?"
        + ")"
        + "(?:" + path_and_query + ")?"
        + word_boundary
        + ")"
    )
    return "(" + with_protocol + "|" + without_protocol + ")"


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    java_path = pathlib.Path(sys.argv[1])
    swift_path = pathlib.Path(sys.argv[2])

    source = java_path.read_text(encoding="utf-8")
    iana = extract_iana(source)

    # UCS_CHAR = [\u00A0-\uD7FF \uF900-\uFDCF \uFDF0-\uFFEF <astral>] minus
    # { U+00A0, U+2000-U+200A, U+2028, U+2029, U+202F, U+3000 }.
    bmp = r"[\u00A1-\u1FFF\u200B-\u2027\u202A-\u202E\u2030-\u2FFF\u3001-\uD7FF\uF900-\uFDCF\uFDF0-\uFFEF]"
    astral = r"[\u00A1-\u1FFF\u200B-\u2027\u202A-\u202E\u2030-\u2FFF\u3001-\uD7FF\uF900-\uFDCF\uFDF0-\uFFEF\x{10000}-\x{3FFFD}]"

    with_astral = build_pattern(iana, astral)
    without_astral = build_pattern(iana, bmp)

    # NOTE: each pattern must be a SINGLE-LINE raw string (`#"..."#`); a multi-line
    # `#"""..."""#` would embed the newlines into the regex.
    header = '''//
//  AutolinkWebURL.swift
//  Untracker for iOS
//
//  GENERATED FILE — produced by tools/gen-autolink.py, do not edit by hand.
//  Source: androidx.core:core `PatternsCompat.AUTOLINK_WEB_URL`
//  (Apache License 2.0, Copyright The Android Open Source Project).
//
//  This is the exact pattern the upstream Android app uses to find links in
//  shared text, re-expressed for ICU/NSRegularExpression.
//

import Foundation

enum AutolinkWebURL {
    /// AUTOLINK_WEB_URL, with astral-plane code points allowed in labels.
    static let pattern = #"'''

    middle = '''"#

    /// Same pattern with BMP-only character classes (fallback for regex engines
    /// that reject \\x{...} inside a character class).
    static let patternWithoutAstral = #"'''

    footer = '''"#

    static let regex: NSRegularExpression? = {
        if let regex = try? NSRegularExpression(pattern: pattern) {
            return regex
        }
        NSLog("[Untracker] AUTOLINK_WEB_URL: astral variant failed, using BMP-only pattern")
        return try? NSRegularExpression(pattern: patternWithoutAstral)
    }()
}
'''

    swift = header + with_astral + middle + without_astral + footer
    swift_path.write_text(swift, encoding="utf-8")

    print("IANA TLD list: %d chars" % len(iana))
    print("with astral ranges   : %d chars" % len(with_astral))
    print("without astral ranges: %d chars" % len(without_astral))
    print("wrote %s (%d bytes)" % (swift_path, len(swift)))


if __name__ == "__main__":
    main()
