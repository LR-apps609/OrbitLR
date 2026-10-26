#!/usr/bin/env python3
"""Manifesto firmato degli aggiornamenti di OrbitLR per Windows.

uso: manifesto-windows.py <installatore.exe> <versione> <build> <novità.txt> <manifest.json> <manifest.sig>
La chiave privata (Ed25519, 32 byte in base64, la stessa del Mac) arriva da ORBITLR_SIGNING_KEY e non si stampa mai.
"""
import base64, hashlib, json, os, sys

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

TRUSTED = {"xOzQ8TT6IqdlLtj8FQnyLAelvSBtXehmmkPAArIsVis=", "Nr/1zqg8DjVw1zAVnbZbHPHNya+soZ83wNB9zLhCung="}


def die(msg):
    print("::error::" + msg)
    sys.exit(1)


def main():
    if len(sys.argv) != 7:
        die(__doc__.strip().splitlines()[2])
    exe, version, build, news, out_json, out_sig = sys.argv[1:]
    raw = os.environ.get("ORBITLR_SIGNING_KEY", "").strip()
    if not raw:
        die("manca il segreto ORBITLR_SIGNING_KEY su GitHub")
    try:
        key = Ed25519PrivateKey.from_private_bytes(base64.b64decode(raw))
    except Exception:
        die("ORBITLR_SIGNING_KEY non è una chiave valida")
    pub = base64.b64encode(key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()
    if pub not in TRUSTED:
        die("la chiave non corrisponde a quelle di cui l'app si fida")
    data = open(exe, "rb").read()
    notes = notes_en = ""
    if os.path.exists(news):
        blocks = [b.strip() for b in open(news, encoding="utf-8").read().strip().split("\n\n")]
        notes = blocks[0][:1500]
        # Il primo paragrafo in inglese («What’s new…»), se c'è subito dopo
        if len(blocks) > 1 and blocks[1].startswith("What"):
            notes_en = blocks[1][:1500]
    manifest = {
        "version": version,
        "build": int(build),
        "file": os.path.basename(exe),
        "sha256": hashlib.sha256(data).hexdigest(),
        "size": len(data),
        "notes": notes,
        "notes_en": notes_en,
    }
    body = json.dumps(manifest, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    open(out_json, "wb").write(body)
    open(out_sig, "wb").write(key.sign(body))
    print(f"Manifesto firmato: {manifest['file']} {version} (build {build}), {len(data)} byte, chiave {pub[:8]}…")


main()
