#!/usr/bin/env python3
"""M08 - controllo dei blocchi di OrbitLR.
Uso: probe.py <scenario> <secondi> <cartella_uscita>
Ogni ~1.5 s: (1) un Apple Event con 3 s di tempo massimo (risposta veloce = la finestra risponde,
anche se e' un errore -1708), (2) `sample` del processo per 1 s e quota del thread principale
ferma in mach_msg (= a riposo). Scrive una riga JSON per controllo in <out>/probe.jsonl.
Se il thread principale e' occupato salva il campionamento intero; al primo blocco lungo fa spindump.
"""
import json, os, re, subprocess, sys, time

scen, dur, out = sys.argv[1], float(sys.argv[2]), sys.argv[3]
os.makedirs(out, exist_ok=True)
log = open(os.path.join(out, "probe.jsonl"), "a")
BID = "it.ledion.OrbitLR"

def pid():
    r = subprocess.run(["pgrep", "-o", "-x", "OrbitLR"], capture_output=True, text=True)
    return r.stdout.strip().split("\n")[0] if r.stdout.strip() else ""

def count():
    r = subprocess.run(["pgrep", "-x", "OrbitLR"], capture_output=True, text=True)
    return len([x for x in r.stdout.split() if x])

def ae():
    t = time.time()
    try:
        r = subprocess.run(["osascript", "-e", "with timeout of 3 seconds",
                            "-e", 'tell application id "%s" to count windows' % BID, "-e", "end timeout"],
                           capture_output=True, text=True, timeout=8)
        msg = (r.stdout + r.stderr).strip().replace("\n", " ")[:160]
        rc = r.returncode
    except subprocess.TimeoutExpired:
        msg, rc = "osascript killed after 8 s", 999
    return int((time.time() - t) * 1000), rc, msg

LINE = re.compile(r"^[\s+!:|]*?(\d+)\s+(\S.*)$")

def parse(text):
    lines = text.split("\n")
    total, sec = 0, []
    for i, l in enumerate(lines):
        if "com.apple.main-thread" in l and "Thread_" in l:
            m = re.match(r"^\s*(\d+)\s+Thread_", l)
            total = int(m.group(1)) if m else 0
            for l2 in lines[i + 1:]:
                if not l2.strip() or re.match(r"^\s*\d+\s+Thread_", l2):
                    break
                sec.append(l2)
            break
    if not total:
        return None, [], []
    idle, heavy, leaves = 0, [], {}
    for l in sec:
        m = LINE.match(l)
        if not m:
            continue
        n, frame = int(m.group(1)), m.group(2)
        f = re.sub(r"\s+\[0x[0-9a-f,]+\].*$", "", frame)
        f = re.sub(r"\s+\+\s+\d+$", "", f)
        if frame.startswith("mach_msg2_trap") or frame.startswith("mach_msg_trap"):
            idle += n
        if n >= 0.5 * total:
            heavy.append("%d %s" % (n, f[:150]))
    return idle / total, heavy, total

t_end = time.time() + dur
bad_run, spun, i = 0, False, 0
worst = 0.0
bad_since = None
while time.time() < t_end:
    i += 1
    p = pid()
    rec = {"scen": scen, "t": round(time.time(), 1), "n_proc": count()}
    if not p:
        rec["state"] = "non in esecuzione"
        log.write(json.dumps(rec) + "\n"); log.flush()
        time.sleep(1.5)
        continue
    ms, rc, msg = ae()
    rec.update({"pid": p, "ae_ms": ms, "ae_rc": rc, "ae": msg})
    sf = os.path.join(out, "sample-%s-%03d.txt" % (scen, i))
    sr = subprocess.run(["sample", p, "1", "2", "-mayDie", "-file", sf], capture_output=True, text=True, timeout=30)
    try:
        txt = open(sf, errors="replace").read()
    except OSError:
        txt = ""
    idle, heavy, total = parse(txt)
    rec["idle"] = None if idle is None else round(idle, 2)
    rec["samples"] = total
    # l'Apple Event qui puo' restare senza risposta per i permessi di Automazione: conta solo il campionamento
    busy = (idle is not None and idle < 0.25) or rc == 999
    if idle is None:
        rec["sample_err"] = (sr.stdout + sr.stderr)[-200:].replace("\n", " ")
    rec["busy"] = busy
    if busy:
        rec["heavy"] = heavy[-30:]
        bad_run += 1
        bad_since = bad_since or rec["t"]
        worst = max(worst, rec["t"] - bad_since + 1.0)
    else:
        bad_run, bad_since = 0, None
        try:
            os.remove(sf)
        except OSError:
            pass
    rec["busy_for_s"] = 0 if bad_since is None else round(rec["t"] - bad_since + 1.0, 1)
    log.write(json.dumps(rec) + "\n"); log.flush()
    print("[%s] n=%s ae=%dms rc=%s [%s] idle=%s busy=%s %s %s" % (scen, rec["n_proc"], ms, rc, msg[:70], rec["idle"], busy,
          (" <- ".join(reversed(heavy[-8:])) if busy and heavy else ""), rec.get("sample_err", "")[:120]), flush=True)
    if bad_run >= 2 and not spun:
        spun = True
        sp = os.path.join(out, "spindump-%s.txt" % scen)
        subprocess.run(["sudo", "-n", "spindump", p, "5", "10", "-file", sp], capture_output=True, timeout=120)
    time.sleep(0.3)

summ = open(os.path.join(out, "riassunto.tsv"), "a")
summ.write("%s\tpeggior_blocco_s=%.1f\n" % (scen, worst))
print("[%s] FINE peggior blocco continuo: %.1f s" % (scen, worst))
