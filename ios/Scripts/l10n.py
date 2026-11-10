#!/usr/bin/env python3
"""Keeps the string catalogs in step with the `L("…")` calls in the Swift sources: one catalog per kit (each target
ships its own, `Bundle.module`) and the App's.

    core       YoyoKit/Sources/YoyoCore/Resources/Localizable.xcstrings       ← YoyoKit/Sources/YoyoCore/**
    clipboard  YoyoKit/Sources/YoyoClipboard/Resources/Localizable.xcstrings  ← YoyoKit/Sources/YoyoClipboard/**
    screen     YoyoKit/Sources/YoyoScreen/Resources/Localizable.xcstrings     ← YoyoKit/Sources/YoyoScreen/**
    direct     YoyoKit/Sources/YoyoDirect/Resources/Localizable.xcstrings     ← YoyoKit/Sources/YoyoDirect/**
    pro        YoyoKit/Sources/YoyoPro/Resources/Localizable.xcstrings        ← YoyoKit/Sources/YoyoPro/**

The App's own catalogs (App/YoyoControl/*.xcstrings) are SwiftUI's (`Text("…")`), kept by Xcode.

    python3 ios/Scripts/l10n.py check                      # every catalog: each L("…") has a key with a zh-Hans translation
    python3 ios/Scripts/l10n.py merge --screen a.json …    # add / update keys of a catalog from fragments
    python3 ios/Scripts/l10n.py prune --screen             # drop keys no L("…") uses any more

Keys are the English source text as `String.LocalizationValue` spells it: `\\(aString)` → `%@`, `\\(anInt)` → `%lld`,
a literal `%` → `%%`. A fragment maps key → translations; a language left out means "same as the key" (English):

    {"Clipboard": {"zh-Hans": "剪贴板"},
     "%lld files": {"en": {"one": "%lld file", "other": "%lld files"}, "zh-Hans": "%lld 个文件"}}

A dict value is a plural variation (CLDR categories: one / other / …) on the key's first number.
"""
import glob, json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KITS = ["core", "clipboard", "screen", "direct", "pro"]
CATALOGS = {
    **{k: (f"YoyoKit/Sources/Yoyo{k.capitalize()}/Resources/Localizable.xcstrings", [f"YoyoKit/Sources/Yoyo{k.capitalize()}"])
       for k in KITS},
}
CATALOG, ROOTS, EXCLUDES = None, None, []


def use(name):
    global CATALOG, ROOTS, EXCLUDES
    path, roots, *excludes = CATALOGS[name]
    CATALOG, ROOTS = os.path.join(ROOT, path), roots
    EXCLUDES = [os.path.join(ROOT, e) + "/" for e in (excludes[0] if excludes else [])]
LANGS = ["en", "zh-Hans"]
SPEC = r"%(?:\d+\$)?(?:lld|llu|ld|lu|lf|d|u|f|@)"


def load():
    if os.path.exists(CATALOG):
        with open(CATALOG, encoding="utf-8") as f:
            return json.load(f)
    return {"sourceLanguage": "en", "strings": {}, "version": "1.0"}


def save(cat):
    cat["strings"] = dict(sorted(cat["strings"].items(), key=lambda kv: kv[0].lower()))
    with open(CATALOG, "w", encoding="utf-8") as f:
        json.dump(cat, f, ensure_ascii=False, indent=2, separators=(",", " : "))
        f.write("\n")


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def localization(value):
    if isinstance(value, dict):
        return {"variations": {"plural": {k: unit(v) for k, v in value.items()}}}
    return unit(value)


def merge(paths):
    cat = load()
    n = 0
    for p in paths:
        with open(p, encoding="utf-8") as f:
            frag = json.load(f)
        for key, tr in frag.items():
            entry = {}
            if tr.get("comment"):
                entry["comment"] = tr["comment"]
            locs = {}
            # English is spelled out too (not left to the key) so the build always emits en.lproj: `L10n` loads
            # that bundle explicitly, and Bundle.main would otherwise follow the device's language.
            locs["en"] = localization(tr.get("en", key))
            zh = tr.get("zh-Hans")
            if zh is None:
                print(f"warning: {p}: no zh-Hans for {key!r}", file=sys.stderr)
            else:
                locs["zh-Hans"] = localization(zh)
            if locs:
                entry["localizations"] = locs
            cat["strings"][key] = entry
            n += 1
    save(cat)
    print(f"merged {n} keys → {len(cat['strings'])} in catalog")


def swift_calls():
    """Yields (file, line, [static parts], literal) for every L("…") with a plain string literal."""
    files = [f for root in ROOTS for f in glob.glob(os.path.join(ROOT, root, "**/*.swift"), recursive=True)
             if "/Debug/" not in f and not any(f.startswith(e) for e in EXCLUDES)]
    for path in sorted(files):
        src = open(path, encoding="utf-8").read()
        for m in re.finditer(r'(?<![\w.])L\(\s*"', src):
            if "//" in src[src.rfind("\n", 0, m.start()) + 1:m.start()]:
                continue
            i = m.end()
            parts, cur, depth = [], "", 0
            ok = True
            while i < len(src):
                c = src[i]
                if c == "\\":
                    nxt = src[i + 1]
                    if nxt == "(":
                        parts.append(cur); cur = ""
                        # skip the interpolated expression (balanced parens, nested strings)
                        i += 2; depth = 1
                        while depth and i < len(src):
                            ch = src[i]
                            if ch == '"':
                                i += 1
                                while src[i] != '"':
                                    i += 2 if src[i] == "\\" else 1
                            elif ch == "(":
                                depth += 1
                            elif ch == ")":
                                depth -= 1
                            i += 1
                        continue
                    cur += {"n": "\n", "t": "\t", '"': '"', "\\": "\\", "'": "'", "0": "\0"}.get(nxt, "\\" + nxt)
                    if nxt == "u":
                        j = src.index("}", i)
                        cur = cur[:-2] + chr(int(src[i + 3:j], 16)); i = j + 1; continue
                    i += 2; continue
                if c == '"':
                    break
                if c == "\n":
                    ok = False; break
                cur += c; i += 1
            if not ok:
                continue
            parts.append(cur)
            line = src.count("\n", 0, m.start()) + 1
            yield os.path.relpath(path, ROOT), line, parts


def specifiers(s):
    """Argument types in order of position: "%2$@ … %1$lld" → ["lld", "@"]."""
    found = []
    for n, m in enumerate(re.finditer(r"%(?:(\d+)\$)?(lld|llu|ld|lu|lf|d|u|f|@)", s.replace("%%", ""))):
        found.append((int(m.group(1)) if m.group(1) else n + 1, m.group(2)))
    return [t for _, t in sorted(found)]


def check():
    cat = load()
    keys = cat["strings"]
    used, missing, untranslated = set(), [], []
    for path, line, parts in swift_calls():
        pattern = "^" + SPEC.join(re.escape(p.replace("%", "%%")) for p in parts) + "$"
        hits = [k for k in keys if re.match(pattern, k, re.S)]
        literal = "…".join(parts)
        if not hits:
            missing.append(f"{path}:{line}: {literal!r}")
            continue
        used.update(hits)
        for k in hits:
            if "zh-Hans" not in keys[k].get("localizations", {}):
                untranslated.append(f"{path}:{line}: {k!r}")
    unused = sorted(set(keys) - used)
    # A translation must take the same arguments as its key, or String(format:) reads garbage / crashes.
    mismatched = []
    for k, entry in keys.items():
        want = specifiers(k)
        for lang, loc in entry.get("localizations", {}).items():
            values = [loc["stringUnit"]["value"]] if "stringUnit" in loc else \
                [v["stringUnit"]["value"] for v in loc.get("variations", {}).get("plural", {}).values()]
            for v in values:
                if specifiers(v) != want:
                    mismatched.append(f"{lang}: {k!r} → {v!r}")
    for title, items in (("missing from catalog", missing), ("no zh-Hans", untranslated),
                         ("placeholders differ from the key", mismatched), ("unused keys", unused)):
        if items:
            print(f"{title} ({len(items)}):")
            for it in items:
                print("  " + it)
    print(f"{len(used)} keys used, {len(keys)} in catalog")
    return 1 if missing or untranslated or mismatched else 0


def prune():
    cat = load()
    used = set()
    for _, _, parts in swift_calls():
        pattern = "^" + SPEC.join(re.escape(p.replace("%", "%%")) for p in parts) + "$"
        used.update(k for k in cat["strings"] if re.match(pattern, k, re.S))
    gone = [k for k in cat["strings"] if k not in used]
    for k in gone:
        del cat["strings"][k]
    save(cat)
    print(f"pruned {len(gone)} keys")


if __name__ == "__main__":
    args = sys.argv[1:]
    cmd = args.pop(0) if args else "check"
    flags = [a[2:] for a in args if a.startswith("--") and a[2:] in CATALOGS]
    target = flags[0] if flags else "screen"
    args = [a for a in args if not (a.startswith("--") and a[2:] in CATALOGS)]
    if cmd == "merge":
        use(target)
        merge(args)
    elif cmd == "prune":
        use(target)
        prune()
    else:
        status = 0
        for name in CATALOGS:
            use(name)
            print(f"== {name}: {os.path.relpath(CATALOG, ROOT)}")
            status |= check()
        sys.exit(status)
