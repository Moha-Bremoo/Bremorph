#!/usr/bin/env python3
"""Collects every translatable string from Sources/ and checks each language file covers it.

    python3 l10n/extract.py            # list keys missing from l10n/ar.json
    python3 l10n/extract.py --build    # write Resources/<lang>.lproj files from l10n/*.json

Keys are the English text exactly as written in the Swift literal (escapes included).
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Sources")
LIT = r'"((?:[^"\\\n]|\\.)*)"'

PATTERNS = [
    r'\bLF?\(' + LIT,                                   # L("…"), LF("…", …)
    r'\b(?:Text|Button|Toggle|Label|Section|Picker|TextField|Stepper|Menu|ColorPicker|LabeledContent)\(' + LIT,
    r'\.help\(' + LIT + r'\)',
    r'\bprompt: Text\(' + LIT,
    r'\bBremorphError\(' + LIT + r'\)',
    r'\bActionInfo\(title: ' + LIT,
    r'\bNumberField\(label: ' + LIT,
]
RAW_ENUMS = ["EditorTool", "AspectChoice", "RedactStyle", "ActionGroup"]   # enums shown via L(rawValue)
NOT_TEXT = {"", "Bremorph", "ffmpeg", "LibreOffice", "Pages", "Keynote", "Numbers"}


def keys():
    found = {}
    for name in sorted(os.listdir(SRC)):
        if not name.endswith(".swift") or name == "CLI.swift":
            continue
        text = open(os.path.join(SRC, name), encoding="utf-8").read()
        for pat in PATTERNS:
            for m in re.finditer(pat, text):
                k = m.group(1)
                if "\\(" in k:
                    print(f"warning: interpolated literal in {name}: {k}", file=sys.stderr)
                    continue
                found.setdefault(k, name)
        # enums whose raw values are shown to people
        for enum in RAW_ENUMS:
            m = re.search(r'enum ' + enum + r'\b[^{]*\{(.*?)\n\}', text, re.S)
            if m:
                for k in re.findall(r'= ' + LIT, m.group(1)):
                    found.setdefault(k, name)
        # `var englishTitle: String { switch … return "…" }`
        for m in re.finditer(r'var englishTitle: String \{(.*?)\n    \}', text, re.S):
            for k in re.findall(r'return ' + LIT, m.group(1)):
                found.setdefault(k, name)
    return {k: v for k, v in found.items() if k not in NOT_TEXT and re.search(r'[A-Za-z]', k)}


def esc(s):
    return s  # keys/values are already in Swift/strings escape form


def build():
    ks = keys()
    for lang_file in sorted(os.listdir(os.path.join(ROOT, "l10n"))):
        if not lang_file.endswith(".json"):
            continue
        lang = lang_file[:-5]
        data = json.load(open(os.path.join(ROOT, "l10n", lang_file), encoding="utf-8"))
        strings = data.get("strings", {})
        out_dir = os.path.join(ROOT, "Resources", f"{lang}.lproj")
        os.makedirs(out_dir, exist_ok=True)
        with open(os.path.join(out_dir, "Localizable.strings"), "w", encoding="utf-8") as f:
            f.write(f"/* Bremorph — {lang}. Generated from l10n/{lang_file} by l10n/extract.py; edit the JSON, not this file. */\n\n")
            for k in sorted(strings):
                f.write(f'"{esc(k)}" = "{esc(strings[k])}";\n')
        for extra in ("InfoPlist", "ServicesMenu"):
            if extra in data:
                with open(os.path.join(out_dir, f"{extra}.strings"), "w", encoding="utf-8") as f:
                    for k, v in data[extra].items():
                        f.write(f'"{k}" = "{v}";\n')
        plurals = data.get("plurals", {})
        with open(os.path.join(out_dir, "Localizable.stringsdict"), "w", encoding="utf-8") as f:
            f.write('<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
                    '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n')
            for key, forms in plurals.items():
                f.write(f"\t<key>{xml(key)}</key>\n\t<dict>\n\t\t<key>NSStringLocalizedFormatKey</key>\n")
                f.write(f"\t\t<string>{xml(forms['format'])}</string>\n\t\t<key>n</key>\n\t\t<dict>\n")
                f.write("\t\t\t<key>NSStringFormatSpecTypeKey</key>\n\t\t\t<string>NSStringPluralRuleType</string>\n")
                f.write("\t\t\t<key>NSStringFormatValueTypeKey</key>\n\t\t\t<string>d</string>\n")
                for rule in ("zero", "one", "two", "few", "many", "other"):
                    if rule in forms:
                        f.write(f"\t\t\t<key>{rule}</key>\n\t\t\t<string>{xml(forms[rule])}</string>\n")
                f.write("\t\t</dict>\n\t</dict>\n")
            f.write("</dict>\n</plist>\n")
        missing = [k for k in ks if k not in strings and k not in plurals and k not in data.get("same", []) and lang != "en"]
        print(f"{lang}: {len(strings)} strings, {len(plurals)} plurals, {len(missing)} missing")
        for k in missing:
            print("   missing:", k)


def xml(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


if __name__ == "__main__":
    if "--build" in sys.argv:
        build()
    else:
        ks = keys()
        have = {}
        p = os.path.join(ROOT, "l10n", "ar.json")
        if os.path.exists(p):
            d = json.load(open(p, encoding="utf-8"))
            have = {**d.get("strings", {}), **d.get("plurals", {}), **{k: k for k in d.get("same", [])}}
        for k, src in sorted(ks.items(), key=lambda kv: (kv[1], kv[0])):
            if k not in have:
                print(f"{src}\t{k}")
        print(f"{len(ks)} keys, {sum(1 for k in ks if k not in have)} without Arabic", file=sys.stderr)
