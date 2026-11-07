# M01 · Controlla i risultati di prova.zsh: misure, orientamento, trasparenza, GPS, originali intatti,
# niente file in posti inattesi. Scrive RADICE/_log/<FASE>-esito.json e stampa un riassunto.
# Uso: python controlla.py ISPEZIONA RADICE FASE [FASE…]
import json, os, subprocess, sys, collections

ISP, ROOT = sys.argv[1], sys.argv[2]
FASI = sys.argv[3:]
BROKEN = {"rotta.jpg", "vuota.png"}
TYPE = {"jpg": "public.jpeg", "png": "public.png", "heic": "public.heic", "webp": "org.webmproject.webp",
        "tiff": "public.tiff", "pdf": "com.adobe.pdf", "ico": "com.microsoft.ico"}
ALPHA_OK = {"png", "webp", "tiff", "heic", "ico"}


def inspect(paths):
    out = {}
    paths = list(paths)
    for i in range(0, len(paths), 150):
        r = subprocess.run([ISP] + paths[i:i + 150], capture_output=True, text=True)
        for line in r.stdout.splitlines():
            try:
                d = json.loads(line); out[d["path"]] = d
            except Exception:
                pass
    return out


def norm(e):
    e = e.lower()
    return {"jpeg": "jpg", "jpe": "jpg", "tif": "tiff", "heif": "heic"}.get(e, e)


def close(a, b, tol=60):
    return all(abs(x - y) <= tol for x, y in zip(a[:3], b[:3]))


def corners_check(src, out, oext, problems):
    sc, oc = src.get("corners") or [], out.get("corners") or []
    if len(sc) != 4 or len(oc) != 4:
        return
    names = ["alto-sx", "alto-dx", "basso-sx", "basso-dx"]
    for n, s, o in zip(names, sc, oc):
        if s[3] < 30:                                  # trasparente nell'originale
            if oext == "jpg" or oext == "pdf":
                if min(o[:3]) < 200 and o[3] > 200:
                    problems.append(f"angolo {n}: trasparente nell'originale, nero/scuro nel JPG {o}")
            elif oext in ALPHA_OK and o[3] > 200:
                problems.append(f"angolo {n}: la trasparenza si è persa (alfa {o[3]}, colore {o[:3]})")
            continue
        if o[3] < 30:
            problems.append(f"angolo {n}: diventato trasparente {o}")
        elif not close(s, o):
            problems.append(f"angolo {n}: colore {o[:3]} invece di {s[:3]} (orientamento o colori sbagliati)")


def parse_out(path):
    res = collections.defaultdict(list)
    try:
        for line in open(path, encoding="utf-8", errors="replace"):
            p = line.rstrip("\n").split("\t")
            if p and p[0] in ("OUT", "OK", "FAIL", "NOTE", "MISSING", "END", "SKIP", "CANCEL"):
                res[p[0]].append(p[1:])
    except FileNotFoundError:
        pass
    return res


def expected_long(param, long_):
    if param == "half":
        return max(1, long_ // 2), 1
    if param == "web":
        return min(1600, long_), 1
    return min(int(param), long_), 1


summary = {}
for fase in FASI:
    idx = os.path.join(ROOT, "_log", fase + ".tsv")
    if not os.path.exists(idx):
        continue
    rows = [l.rstrip("\n").split("\t") for l in open(idx, encoding="utf-8")][1:]
    runs = []
    paths = set()
    for r in rows:
        fase_, act, par, f, rc, secs, lg, d = r
        o = parse_out(os.path.join(ROOT, lg))
        outs = [x[0] for x in o.get("OUT", [])]
        runs.append(dict(azione=act, param=par, file=f, rc=int(rc), secondi=float(secs), log=lg, dir=d, res=o, outs=outs))
        if f not in ("*",) and not f.endswith(" file"):
            paths.add(os.path.join(ROOT, d, f))
        paths.update(outs)
    info = inspect(paths)
    results = []
    gps_table = collections.Counter()
    for run in runs:
        act, par, f = run["azione"], run["param"], run["file"]
        pr = []
        base = os.path.basename(f)
        srcp = os.path.join(ROOT, run["dir"], f)
        src = info.get(srcp, {})
        fails = run["res"].get("FAIL", []) + run["res"].get("SKIP", [])
        if run["rc"] == 142:
            pr.append(f"BLOCCATO: interrotto dopo {run['secondi']:.0f} s")
        elif run["rc"] != 0 and not fails:
            pr.append(f"codice di uscita {run['rc']} senza riga FAIL")
        if act == "merge":
            if run["outs"] or os.path.exists(os.path.join(ROOT, run["log"].replace(".out", ".pdf"))):
                pdf = os.path.join(ROOT, run["log"].replace(".out", ".pdf"))
                pi = inspect([pdf]).get(pdf, {})
                n = int(f.split()[0])
                if pi.get("pages") != n and par == "buone":
                    pr.append(f"PDF unito con {pi.get('pages')} pagine invece di {n}")
                run["pdf_pagine"] = pi.get("pages")
            elif par == "buone":
                pr.append("nessun PDF unito: " + "; ".join(" ".join(x) for x in fails))
            results.append(dict(run, problemi=pr)); continue
        if par == "tutti":
            results.append(dict(run, problemi=pr, n_out=len(run["outs"]), n_fail=len(fails))); continue
        broken = base in BROKEN
        locked = f.startswith("bloccata/")
        if run["res"].get("SKIP"):
            results.append(dict(run, problemi=pr, saltato=True)); continue
        if broken or locked:
            if run["outs"]:
                pr.append(f"ha creato un file da un originale {'rotto' if broken else 'in cartella senza permesso di scrittura'}: {run['outs']}")
            if not fails and run["rc"] != 142:
                pr.append("nessun messaggio di errore per l'utente")
            results.append(dict(run, problemi=pr)); continue
        if not run["outs"]:
            if not fails:
                pr.append("nessun file creato e nessun errore")
            else:
                pr.append("NON RIUSCITO: " + "; ".join(" ".join(x) for x in fails))
            results.append(dict(run, problemi=pr)); continue
        if len(run["outs"]) > 1:
            pr.append(f"{len(run['outs'])} file creati invece di 1")
        for op in run["outs"]:
            out = info.get(op, {})
            oext = norm(os.path.splitext(op)[1][1:])
            if not out.get("exists"):
                pr.append(f"il file annunciato non esiste: {op}"); continue
            if os.path.dirname(op) != os.path.dirname(srcp):
                pr.append(f"creato in un'altra cartella: {op}")
            if out.get("error"):
                pr.append(f"uscita non leggibile ({oext})"); continue
            want = None
            if act.startswith("to:"):
                want = act[3:]
            if want and oext != want:
                pr.append(f"estensione .{oext} invece di .{want}")
            if want and out.get("type") != TYPE.get(want):
                pr.append(f"contenuto {out.get('type')} invece di {TYPE.get(want)}")
            if oext == "pdf":
                if src.get("dw") and out.get("page_w"):
                    sp = src["dw"] >= src["dh"]; op_ = out["page_w"] >= out["page_h"]
                    if out.get("page_rot") in (90, 270): op_ = not op_
                    if sp != op_ and src["dw"] != src["dh"]:
                        pr.append(f"PDF girato: pagina {out['page_w']}×{out['page_h']}, foto {src['dw']}×{src['dh']}")
                continue
            sl, ol = max(src.get("dw", 0), src.get("dh", 0)), max(out.get("dw", 0), out.get("dh", 0))
            if act.startswith("to:") and want != "ico":
                if (out.get("dw"), out.get("dh")) != (src.get("dw"), src.get("dh")):
                    pr.append(f"misure {out.get('dw')}×{out.get('dh')} invece di {src.get('dw')}×{src.get('dh')}")
            if want == "ico" and ol > 256:
                pr.append(f"icona di {ol} px (massimo 256)")
            if act == "resize":
                exp, tol = expected_long(par, sl)
                if abs(ol - exp) > tol:
                    pr.append(f"lato lungo {ol} px invece di {exp} (originale {sl})")
                if src.get("dw") and out.get("dw") and src["dw"] != src["dh"]:
                    if (src["dw"] > src["dh"]) != (out["dw"] > out["dh"]):
                        pr.append(f"orientamento cambiato: {out['dw']}×{out['dh']} da {src['dw']}×{src['dh']}")
                if par == "web" and (out.get("gps") or out.get("camera")):
                    pr.append("«Per il web» doveva togliere i dati personali: GPS/fotocamera ancora presenti")
            if act == "strip":
                left = [k for k in ("gps", "make", "camera", "date", "artist") if out.get(k)]
                if left:
                    pr.append("metadati ancora presenti dopo «Rimuovi i metadati»: " + ", ".join(f"{k}={out.get(k)}" for k in left))
                if (out.get("dw"), out.get("dh")) != (src.get("dw"), src.get("dh")):
                    pr.append(f"misure {out.get('dw')}×{out.get('dh')} invece di {src.get('dw')}×{src.get('dh')}")
            if act == "icompress":
                if par != "best":
                    if out.get("size", 0) > int(par) * 1000:
                        pr.append(f"pesa {out['size']} byte, più di {par} KB")
                    if out.get("gps") or out.get("camera"):
                        pr.append("peso fisso: dovevano sparire i dati personali, GPS/fotocamera ancora presenti")
                elif src.get("size") and out.get("size", 0) >= src["size"]:
                    pr.append(f"«più leggera» ma pesa {out['size']} ≥ {src['size']}")
                if (out.get("dw"), out.get("dh")) != (src.get("dw"), src.get("dh")) and par == "best":
                    pr.append(f"misure {out.get('dw')}×{out.get('dh')} invece di {src.get('dw')}×{src.get('dh')}")
            if want != "ico":
                corners_check(src, out, oext, pr)
            if src.get("gps") and act.startswith("to:"):
                gps_table[(act, "tenuto" if out.get("gps") else "perso")] += 1
                if not out.get("gps") and want in ("jpg", "heic", "tiff"):
                    pr.append("GPS perso nella conversione (i dati della foto dovevano restare)")
            if out.get("perm") and out["perm"] in ("444", "400"):
                pr.append(f"il file creato è in sola lettura (permessi {out['perm']})")
        results.append(dict(run, problemi=pr))
    # originali intatti, file inattesi
    extra = []
    for d in sorted({r["dir"] for r in runs}):
        L = os.path.join(ROOT, "_log", fase, os.path.basename(d))
        pre = os.path.join(L, "prima.sha")
        if os.path.basename(d) == "tutti-insieme-png":
            L = os.path.join(ROOT, "_log", fase, "to-png"); pre = os.path.join(L, "tutti-prima.sha")
        if not os.path.exists(pre):
            continue
        before = dict(reversed(l.rstrip("\n").split("  ", 1)) for l in open(pre, encoding="utf-8"))
        announced = {os.path.relpath(o, os.path.join(ROOT, d)) for r in runs if r["dir"] == d for o in r["outs"]}
        now = {}
        for dp, dn, fn in os.walk(os.path.join(ROOT, d)):
            for x in fn:
                p = os.path.join(dp, x); rel = "./" + os.path.relpath(p, os.path.join(ROOT, d))
                now[rel] = p
        for rel, h in before.items():
            p = os.path.join(ROOT, d, rel)
            if not os.path.exists(p):
                extra.append(dict(dir=d, file=rel, problema="originale sparito"))
            else:
                import hashlib
                hh = hashlib.sha256(open(p, "rb").read()).hexdigest()
                if hh != h:
                    extra.append(dict(dir=d, file=rel, problema="originale modificato"))
        for rel in now:
            if rel not in before and rel[2:] not in announced:
                extra.append(dict(dir=d, file=rel, problema="file inatteso (non annunciato)"))
    bad = [r for r in results if r["problemi"]]
    for r in results:
        r.pop("res", None)
    summary[fase] = dict(prove=len(results), con_problemi=len(bad), file_inattesi=extra,
                         gps={f"{a} {s}": n for (a, s), n in gps_table.items()})
    json.dump(dict(fase=fase, risultati=results, file_inattesi=extra, gps=summary[fase]["gps"]),
              open(os.path.join(ROOT, "_log", fase + "-esito.json"), "w"), ensure_ascii=False, indent=1)
    print(f"\n===== {fase}: {len(results)} prove, {len(bad)} con problemi, {len(extra)} file inattesi/originali toccati")
    by = collections.defaultdict(list)
    for r in bad:
        for p in r["problemi"]:
            by[(r["azione"] + " " + r["param"]).strip()].append(f"{r['file'][:60]}: {p}")
    for k in sorted(by):
        print(f"--- {k}")
        for x in by[k]:
            print("   ", x)
    for e in extra:
        print("  !!", e)
    print("  GPS:", summary[fase]["gps"])
    slow = sorted(results, key=lambda r: -r["secondi"])[:5]
    print("  più lenti:", [(r["azione"], r["param"], r["file"][:30], r["secondi"]) for r in slow])
json.dump(summary, open(os.path.join(ROOT, "_log", "riassunto.json"), "w"), ensure_ascii=False, indent=1)
