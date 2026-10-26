#!/usr/bin/env python3
"""Raccoglie i messaggi d'errore del motore Windows (Rust) da tradurre: EngineError::new("…") / format!("…")
e gli Err("…") dei comandi. Stampa un JSON {modello italiano con {0}, {1}…: [file]}."""
import json, re, sys, pathlib

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "Windows")
files = list((root / "engine" / "src").glob("*.rs")) + [root / "src-tauri" / "src" / "main.rs"]
pat = re.compile(r'(?:EngineError::new\(\s*(?:format!\(\s*)?|Err\(\s*(?:format!\(\s*)?|\.ok_or\(\s*|\.into\(\)\s*;\s*//)"((?:[^"\\]|\\.)*)"')
out = {}
for f in files:
    s = f.read_text(encoding="utf-8")
    for m in pat.finditer(s):
        raw = m.group(1)
        if not re.search(r"[a-zà-ù]{3}", raw):
            continue
        text = bytes(raw, "utf-8").decode("unicode_escape").encode("latin-1").decode("utf-8") if "\\" in raw else raw
        n = [0]
        def rep(mm):
            if mm.group(0) in ("{{", "}}"):
                return mm.group(0)[0]
            k = n[0]; n[0] += 1
            return "{%d}" % k
        tmpl = re.sub(r"\{\{|\}\}|\{[^{}]*\}", rep, text)
        out.setdefault(tmpl, [])
        if f.name not in out[tmpl]:
            out[tmpl].append(f.name)
print(json.dumps(out, ensure_ascii=False, indent=1))
