#!/usr/bin/env python3
"""Checks a translation against the texts the Swift sources use.

    scripts/check-strings.py                                  # checks Resources/es.lproj
    scripts/check-strings.py Resources/fr.lproj/Localizable.strings

Keys are the English texts in the code. Interpolations become format specifiers
(%@ for text, %lld for whole numbers); this check treats every specifier alike,
so mind the kind when you write a translation. A literal % is written %%.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CALL = re.compile(r'(?:String\(localized:|Text\(|Toggle\(|Button\(|Section\(|Label\(|LabeledContent\(|Picker\(|\.help\(|\.value\()\s*"')


def literal_at(source, start):
    """The Swift string literal starting after its opening quote, with interpolations as %#."""
    out, i = [], start
    while i < len(source):
        c = source[i]
        if c == '"':
            return "".join(out)
        if c == "\\" and source[i + 1] == "(":
            depth, i = 1, i + 2
            while depth:
                depth += {"(": 1, ")": -1}.get(source[i], 0)
                i += 1
            out.append("%#")
            continue
        if c == "\\":
            out.append(source[i + 1])
            i += 2
            continue
        out.append(c)
        i += 1
    raise ValueError("unterminated literal")


def used_keys():
    keys = {}
    for path in sorted((ROOT / "Sources").rglob("*.swift")):
        source = path.read_text()
        for match in CALL.finditer(source):
            keys.setdefault(literal_at(source, match.end()), path.name)
    return keys


def defined_keys(path):
    text = pathlib.Path(path).read_text()
    pairs = re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', text, re.M)
    keys = {}
    for key, value in pairs:
        key = key.replace('\\"', '"').replace("%%", "\0")
        key = re.sub(r"%(?:\d+\$)?(?:lld|ld|d|@|lf|f)", "%#", key).replace("\0", "%")
        keys[key] = value
    return keys


def main():
    strings = sys.argv[1] if len(sys.argv) > 1 else ROOT / "Resources/es.lproj/Localizable.strings"
    used, defined = used_keys(), defined_keys(strings)
    missing = sorted(set(used) - set(defined))
    unused = sorted(set(defined) - set(used))
    for key in missing:
        print(f"missing: {key!r} ({used[key]})")
    for key in unused:
        print(f"unused:  {key!r}")
    print(f"{len(used)} texts in the code, {len(defined)} translated, {len(missing)} missing")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
