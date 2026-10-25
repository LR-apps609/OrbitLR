#!/bin/zsh
# ════════════════════════════════════════════════════════════════════
#  LRConverter 2.0 — converti e gestisci file dal menu del Finder
#
#  Dove sta questo file:
#    ~/Library/Application Support/LRConverter/LRConverter.zsh
#  Nell'Azione rapida di Automator ("Esegui script shell", Shell /bin/zsh,
#  Passa input: come argomenti) basta questa sola riga:
#    /bin/zsh "$HOME/Library/Application Support/LRConverter/LRConverter.zsh" "$@"
#
#  Motori (Homebrew):
#    brew install imagemagick ffmpeg ghostscript exiftool whisper-cpp
#    brew install --cask libreoffice
#    pandoc: installer ufficiale da pandoc.org
#  Facoltativo, per SVG più fedeli: brew install librsvg
#
#  PDF, OCR e finestra di avanzamento usano un piccolo programma nativo
#  (Swift) che si prepara da solo al primo utilizzo.
#
#  Controllo automatico (nel Terminale):
#    zsh ~/Library/Application\ Support/LRConverter/LRConverter.zsh --test
#  Pacchetto per installarlo su un altro Mac (finisce sulla Scrivania):
#    zsh ~/Library/Application\ Support/LRConverter/LRConverter.zsh --crea-installer
#
#  Log: ~/Library/Logs/LRConverter.log
# ════════════════════════════════════════════════════════════════════

emulate zsh
setopt NO_NOMATCH
zmodload zsh/datetime
T_START=$EPOCHREALTIME
SCRIPT_PATH=${0:A}

APP="LRConverter"
export PATH="/opt/homebrew/bin:/usr/local/bin:/Applications/LibreOffice.app/Contents/MacOS:/usr/bin:/bin:/usr/sbin:/sbin"
# 3.8 · I motori dentro l'app (ffmpeg LGPL): bastano da soli, nessuna installazione necessaria.
# Vanno in fondo: se sul Mac c'è già un ffmpeg completo (Homebrew), quello resta il primo.
# Anche quando lo script parte da fuori (Azione rapida del Finder) si trovano dentro l'app.
if [[ -z $LR_MOTORI ]]; then
  for d in /Applications/OrbitLR.app "$HOME/Applications/OrbitLR.app"; do
    [[ -x "$d/Contents/Resources/Motori/ffmpeg" ]] && { LR_MOTORI="$d/Contents/Resources/Motori"; break; }
  done
fi
[[ -n $LR_MOTORI && -x "$LR_MOTORI/ffmpeg" ]] && export PATH="$PATH:$LR_MOTORI"

# Quali codificatori ha l'ffmpeg in uso (quello incluso non ha libx264/libx265: usa il chip video del Mac)
typeset -gA ENC_CACHE
has_enc() {
  if [[ -z ${ENC_CACHE[$1]} ]]; then
    if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q " $1 "; then ENC_CACHE[$1]=1; else ENC_CACHE[$1]=0; fi
  fi
  [[ ${ENC_CACHE[$1]} == 1 ]]
}
# H.264 di ripiego: libx264 se c'è, altrimenti il chip video (anche via software, sui Mac senza chip adatto)
enc264() {  # crf (qualità), bitrate di ripiego
  if has_enc libx264; then print -r -- "-c:v libx264 -preset veryfast -crf $1"
  else print -r -- "-c:v h264_videotoolbox -allow_sw 1 -b:v ${2:-8M}"; fi
}
export LANG="en_US.UTF-8" LC_ALL="en_US.UTF-8"
ARCH=$(uname -m)
NCPU=$(sysctl -n hw.ncpu 2>/dev/null); [[ $NCPU == <-> ]] || NCPU=4

SUPPORT="$HOME/Library/Application Support/$APP"
CACHE="$HOME/Library/Caches/$APP"
LOG="$HOME/Library/Logs/$APP.log"
PREFS="$SUPPORT/prefs"
HELPER="$SUPPORT/lrhelper"
MODELS="$SUPPORT/models"
LO_PROFILE="file://$CACHE/lo-profile"   # profilo separato: funziona anche con LibreOffice aperto
LO_SLOT=""
mkdir -p "$SUPPORT" "$CACHE" "$MODELS" "${LOG:h}" || exit 1

# 3.5.2 · ImageMagick con regole di sicurezza nostre: niente formati che leggono altri file o vanno in rete
MAGICK_POLICY_DIR="$SUPPORT/magick"
if [[ ! -f "$MAGICK_POLICY_DIR/policy.xml" ]] || ! grep -q "OrbitLR-sicurezza-1" "$MAGICK_POLICY_DIR/policy.xml" 2>/dev/null; then
  mkdir -p "$MAGICK_POLICY_DIR"
  cat > "$MAGICK_POLICY_DIR/policy.xml" <<'POLICY'
<?xml version="1.0" encoding="UTF-8"?>
<!-- OrbitLR-sicurezza-1 -->
<policymap>
  <policy domain="coder" rights="none" pattern="{MVG,MSL,TEXT,URL,HTTP,HTTPS,FTP,EPHEMERAL,SHOW,WIN,PLT,MSVG,LABEL,CAPTION,PANGO,INLINE,SCREENSHOT,X}"/>
  <policy domain="path" rights="none" pattern="@*"/>
  <policy domain="delegate" rights="none" pattern="*"/>
</policymap>
POLICY
fi
export MAGICK_CONFIGURE_PATH="$MAGICK_POLICY_DIR"
WORK=$(mktemp -d "$CACHE/job.XXXXXX") || exit 1
STATUS="$WORK/status"
CANCEL="$WORK/cancel"
PROGRESS_PID=""
HELPER_STATE=0
SELFTEST=""
RUN_MODE=""      # impostato da --run: lo usa l'app LRConverter, senza finestre

progress_stop() {
  [[ -n $PROGRESS_PID ]] || return 0
  print DONE > "$STATUS"
  sleep 0.4
  kill $PROGRESS_PID 2>/dev/null
  PROGRESS_PID=""
}
cleanup() { progress_stop; lo_release; rm -rf -- "$WORK" }
trap cleanup EXIT
trap 'exit 130' INT TERM

if [[ -f $LOG ]] && (( $(wc -l < "$LOG") > 6000 )); then
  tail -n 3000 "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
fi

# ─── Preferenze ──────────────────────────────────────────────────────
#  dest: same | sub | fixed (+ destpath) · wq: small | turbo · wlang: auto | it | en | es | fr | de
#  last_<tipo>: ultima azione scelta per quel tipo di file

typeset -A PREF=(dest same wq small wlang auto)
if [[ -f $PREFS ]]; then
  while IFS= read -r line; do
    [[ $line == ?*=* ]] && PREF[${line%%=*}]=${line#*=}
  done < "$PREFS"
fi
save_prefs() {
  local k
  { for k in ${(ok)PREF}; do print -r -- "$k=${PREF[$k]}"; done } > "$PREFS.tmp" && mv -f "$PREFS.tmp" "$PREFS"
}

typeset -A WMODEL=(small ggml-small.bin turbo ggml-large-v3-turbo.bin)
typeset -A WSIZE=(small "470 MB" turbo "1,6 GB")
wq() { local q=${PREF[wq]}; [[ -n ${WMODEL[$q]} ]] || q=small; print -r -- $q }
model_path() { print -r -- "$MODELS/${WMODEL[$(wq)]}" }

# ─── Utilità ─────────────────────────────────────────────────────────

log()  { print -r -- "[$(date '+%F %T')] $*" >> "$LOG" }
have() { (( $+commands[$1] )) }
whisper_bin() { if have whisper-cli; then print whisper-cli; elif have whisper-cpp; then print whisper-cpp; else return 1; fi }

# Testi passati come argomenti, mai dentro il codice AppleScript: i nomi con simboli non rompono nulla
notify() {
  osascript - "$APP" "$1" <<'AS' >/dev/null 2>&1
on run argv
  display notification (item 2 of argv) with title (item 1 of argv)
end run
AS
}

alert() {  # titolo, messaggio
  osascript - "$1" "$2" <<'AS' >/dev/null 2>&1
on run argv
  activate
  display alert (item 1 of argv) message (item 2 of argv)
end run
AS
}

error_dialog() {  # messaggio → offre di aprire il log
  local r
  r=$(osascript - "$APP: qualcosa non è andato" "$1" <<'AS' 2>/dev/null
on run argv
  activate
  set r to display alert (item 1 of argv) message (item 2 of argv) as warning buttons {"Apri il log", "OK"} default button "OK"
  return button returned of r
end run
AS
)
  [[ $r == "Apri il log" ]] && open -e "$LOG"
}

choose_btn() {  # pulsante OK, domanda, opzioni… → stampa l'opzione scelta (vuoto se annullato)
  osascript - "$APP" "$@" <<'AS' 2>>"$LOG"
on run argv
  set t to item 1 of argv
  set b to item 2 of argv
  set p to item 3 of argv
  set opts to items 4 thru -1 of argv
  activate
  set r to choose from list opts with title t with prompt p default items {item 1 of opts} OK button name b cancel button name "Annulla"
  if r is false then return ""
  return item 1 of r
end run
AS
}
choose() { choose_btn "Continua" "$@" }

ask_text() {  # domanda, valore iniziale → stampa la risposta; esce con errore se annullato
  osascript - "$APP" "$1" "$2" <<'AS' 2>/dev/null
on run argv
  activate
  set r to display dialog (item 2 of argv) default answer (item 3 of argv) with title (item 1 of argv) buttons {"Annulla", "OK"} default button "OK" cancel button "Annulla"
  return text returned of r
end run
AS
}

ask_secret() {  # domanda → stampa la risposta senza mostrarla; esce con errore se annullato
  osascript - "$APP" "$1" <<'AS' 2>/dev/null
on run argv
  activate
  set r to display dialog (item 2 of argv) default answer "" with hidden answer with title (item 1 of argv) buttons {"Annulla", "OK"} default button "OK" cancel button "Annulla"
  return text returned of r
end run
AS
}

ask_buttons() {  # messaggio, pulsante annulla, pulsante conferma → stampa il pulsante premuto
  osascript - "$APP" "$1" "$2" "$3" <<'AS' 2>/dev/null
on run argv
  activate
  set r to display dialog (item 2 of argv) with title (item 1 of argv) buttons {item 3 of argv, item 4 of argv} default button 2 cancel button 1
  return button returned of r
end run
AS
}

choose_folder() {  # domanda → percorso della cartella scelta
  osascript - "$1" <<'AS' 2>/dev/null
on run argv
  activate
  return POSIX path of (choose folder with prompt (item 1 of argv))
end run
AS
}

kill_tree() {
  local c
  for c in $(pgrep -P $1 2>/dev/null); do kill_tree $c; done
  kill -TERM $1 2>/dev/null
}

with_timeout() {  # secondi, comando… (macOS non ha `timeout`)
  local secs=$1; shift
  "$@" & local pid=$!
  ( sleep $secs && kill -9 $pid ) >/dev/null 2>&1 &
  local w=$!
  wait $pid; local rc=$?
  pkill -P $w >/dev/null 2>&1; kill $w >/dev/null 2>&1
  return $rc
}

unique_item() {  # cartella, nome, [dir] → percorso libero: "nome.ext", "nome (1).ext"…
  local d=$1 n=$2 b e p i=1
  if [[ -n $3 || $n != *.* ]]; then b=$n; e=""; else b=${n:r}; e=".${n:e}"; fi
  p="$d/$n"
  while [[ -e $p ]]; do p="$d/$b ($i)$e"; (( i += 1 )); done
  print -r -- "$p"
}

dest_dir() {  # cartella dell'originale → cartella di destinazione
  # Cartella scelta dall'app per questo lavoro (es. cartelle automatiche): ha la precedenza sulle Opzioni
  if [[ -n $LR_DESTPATH ]]; then print -r -- "$LR_DESTPATH"; return; fi
  case ${PREF[dest]} in
    sub)   print -r -- "$1/Convertiti" ;;
    fixed) if [[ -d ${PREF[destpath]} ]]; then print -r -- "${PREF[destpath]}"; else print -r -- "$1"; fi ;;
    *)     print -r -- "$1" ;;
  esac
}

hsize() {  # byte → "2,4 MB"
  local b=$1
  if (( b >= 1073741824 )); then printf '%.1f GB' $(( b / 1073741824.0 ))
  elif (( b >= 1048576 )); then printf '%.1f MB' $(( b / 1048576.0 ))
  else printf '%d KB' $(( b / 1024 ))
  fi | tr . ,
}

parse_time() {  # "45", "1:30", "1:02:30,5" → secondi
  local s=${1// /}; s=${s//,/.}
  [[ $s =~ '^([0-9]+:){0,2}[0-9]+(\.[0-9]+)?$' ]] || return 1
  local tot=0 x
  for x in ${(s.:.)s}; do (( tot = tot * 60 + x )); done
  printf '%.3f' $tot
}

media_dur() {
  local d=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n 1)
  [[ $d =~ '^[0-9]+(\.[0-9]+)?$' ]] && print -r -- $d
}

# File di iCloud Drive non ancora scaricati sul Mac ("Ottimizza spazio"): vanno scaricati prima
is_dataless() { [[ $(stat -f %Sf "$1" 2>/dev/null) == *dataless* ]] }

ensure_local() {  # file → chiede a iCloud di scaricarlo e aspetta (max 5 minuti)
  is_dataless "$1" || return 0
  log "scarico da iCloud: $1"
  brctl download "$1" >/dev/null 2>&1
  local i=0
  while is_dataless "$1"; do
    [[ -e $CANCEL ]] && return 1
    (( i += 1 ))
    (( i == 10 )) && fileproviderctl materialize "$1" >/dev/null 2>&1   # secondo tentativo, metodo più recente
    (( i > 600 )) && return 1
    sleep 0.5
  done
  return 0
}

job_sources() {  # lavoro → tutti i file che deve leggere, uno per riga
  local j=$1
  if [[ ${J_ACT[j]} == merge ]]; then cat "$WORK/j$j/inputs"
  else print -r -- "${J_SRC[j]}"
  fi
  [[ ${J_ACT[j]} == subembed && -n ${J_PARAM[j]} ]] && print -r -- "${J_PARAM[j]}"
  return 0
}

ocr_langs() {
  case ${PREF[wlang]} in
    it) print it-IT,en-US ;; en) print en-US ;; es) print es-ES,en-US ;;
    fr) print fr-FR,en-US ;; de) print de-DE,en-US ;; *) print "" ;;
  esac
}

# ─── Finestra di avanzamento ─────────────────────────────────────────

P_DONE=0; P_TOTAL=1; P_TEXT=""; JOB_PROG=""; JOB_DUR=""; JD=""

progress_start() {
  print -r -- "-1"$'\t'"$1" > "$STATUS"
  "$HELPER" progress "$STATUS" "$CANCEL" $$ >/dev/null 2>&1 &
  PROGRESS_PID=$!
}
progress_set() {  # frazione (-1 = in corso senza percentuale), testo
  # 4.1.4 · Il testo contiene nomi di file: niente «a capo» o tabulazioni che inventino righe per l'app
  if [[ -n $RUN_MODE ]]; then local t=${2//[$'\n\r\t']/ }; print -r -- "P"$'\t'"$1"$'\t'"$t"; return 0; fi
  [[ -n $PROGRESS_PID ]] || return 0
  print -r -- "$1"$'\t'"$2" > "$STATUS.tmp" && mv -f -- "$STATUS.tmp" "$STATUS"
}
rp() {  # riga per l'app (solo in modalità --run): campi separati da tabulazioni
  [[ -n $RUN_MODE ]] || return 0
  # 3.5.2 · Un nome di file con «a capo» o tabulazioni non può inventare righe per l'app
  local -a f=(); local x
  for x in "$@"; do x=${x//$'\n'/ }; x=${x//$'\r'/ }; x=${x//$'\t'/ }; f+=("$x"); done
  print -r -- "${(pj:\t:)f}"
  return 0
}
progress_job() {  # frazione del lavoro corrente → barra complessiva
  [[ -n $PROGRESS_PID || -n $RUN_MODE ]] || return 0
  local f=$1
  (( f > 1 )) && f=1
  if (( P_TOTAL > 0 )); then progress_set "$(printf '%.3f' $(( (P_DONE + f) * 1.0 / P_TOTAL )))" "$P_TEXT"
  else progress_set "$(printf '%.3f' $f)" "$P_TEXT"
  fi
}

prog_fraction() {  # legge l'avanzamento scritto da ffmpeg, whisper, curl o dal programma nativo
  [[ -s $JOB_PROG ]] || return 0
  local last
  last=$(tail -c 3000 "$JOB_PROG" | tr '\r' '\n' | grep -aE 'out_time_us=[0-9]+|[0-9]+(\.[0-9]+)?%' | tail -n 1)
  [[ -n $last ]] || return 0
  if [[ $last == out_time_us=* ]]; then
    [[ -n $JOB_DUR ]] && (( JOB_DUR > 0 )) && printf '%.4f' $(( ${last#*=} / 1000000.0 / JOB_DUR ))
  elif [[ $last =~ '([0-9]+(\.[0-9]+)?)%' ]]; then
    printf '%.4f' $(( ${match[1]} / 100.0 ))
  fi
}

monitored() {  # comando… in sottofondo, con annullamento e barra di avanzamento
  "$@" >&2 &
  local pid=$! fr
  while kill -0 $pid 2>/dev/null; do
    if [[ -e $CANCEL ]]; then
      kill_tree $pid
      wait $pid 2>/dev/null
      return 130
    fi
    fr=$(prog_fraction)
    [[ -n $fr ]] && progress_job $fr
    sleep 0.3
  done
  wait $pid
}

# ─── Programma nativo (PDF, OCR, finestra) ───────────────────────────

write_helper_source() {
  cat <<'SWIFT'
import Foundation
import AppKit
import PDFKit
import Vision
import ImageIO

setvbuf(stdout, nil, _IONBF, 0)

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("LRERR: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

func progress(_ done: Int, _ total: Int) {
    guard total > 0 else { return }
    print("progress = \(done * 100 / total)%")
}

func openPDF(_ path: String) -> PDFDocument {
    guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
        fail("non riesco ad aprire «\((path as NSString).lastPathComponent)»: PDF danneggiato o non valido")
    }
    if doc.isLocked { fail("«\((path as NSString).lastPathComponent)» è protetto da password") }
    return doc
}

func render(_ page: PDFPage, dpi: CGFloat) -> CGImage? {
    guard let cg = page.pageRef else { return nil }
    let box = page.bounds(for: .cropBox)
    var w = box.width, h = box.height
    if abs(page.rotation) % 180 == 90 { swap(&w, &h) }
    let scale = dpi / 72.0
    let pw = Int((w * scale).rounded()), ph = Int((h * scale).rounded())
    guard pw > 0, ph > 0, pw * ph < 400_000_000,
          let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                              space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: scale, y: scale)
    let t = cg.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: w, height: h), rotate: 0, preserveAspectRatio: true)
    ctx.concatenate(t)
    ctx.drawPDFPage(cg)
    return ctx.makeImage()
}

func writeImage(_ img: CGImage, _ path: String, _ fmt: String) -> Bool {
    let type = (fmt == "jpg" ? "public.jpeg" : "public.png") as CFString
    guard let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, type, 1, nil) else { return false }
    let props: [CFString: Any] = fmt == "jpg" ? [kCGImageDestinationLossyCompressionQuality: 0.9] : [:]
    CGImageDestinationAddImage(d, img, props as CFDictionary)
    return CGImageDestinationFinalize(d)
}

func loadImage(_ path: String) -> (CGImage, CGImagePropertyOrientation)? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    var o = CGImagePropertyOrientation.up
    if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
       let raw = props[kCGImagePropertyOrientation] as? UInt32,
       let oo = CGImagePropertyOrientation(rawValue: raw) { o = oo }
    return (img, o)
}

func recognize(_ img: CGImage, _ o: CGImagePropertyOrientation, _ langs: [String]) -> String {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    if langs.isEmpty {
        if #available(macOS 13.0, *) { req.automaticallyDetectsLanguage = true }
    } else {
        req.recognitionLanguages = langs
    }
    let handler = VNImageRequestHandler(cgImage: img, orientation: o, options: [:])
    do { try handler.perform([req]) } catch { return "" }
    let obs = req.results ?? []
    return obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

func pageName(_ prefix: String, _ i: Int, _ n: Int, _ ext: String) -> String {
    let digits = max(2, String(n).count)
    return "\(prefix) - pagina \(String(format: "%0\(digits)d", i + 1)).\(ext)"
}

final class ProgressController: NSObject {
    let statusPath: String
    let cancelPath: String
    let parent: pid_t
    let panel: NSPanel
    let label = NSTextField(labelWithString: "Preparazione…")
    let bar = NSProgressIndicator()
    let button = NSButton(title: "Annulla", target: nil, action: nil)
    var last = ""

    init(status: String, cancel: String, parent: pid_t) {
        statusPath = status
        cancelPath = cancel
        self.parent = parent
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 118),
                        styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        panel.title = "LRConverter"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        if let v = panel.contentView {
            label.frame = NSRect(x: 20, y: 80, width: 420, height: 20)
            label.lineBreakMode = .byTruncatingMiddle
            bar.frame = NSRect(x: 20, y: 54, width: 420, height: 20)
            bar.style = .bar
            bar.minValue = 0
            bar.maxValue = 1
            bar.isIndeterminate = true
            bar.startAnimation(nil)
            button.frame = NSRect(x: 340, y: 12, width: 100, height: 32)
            button.bezelStyle = .rounded
            button.keyEquivalent = "\u{1b}"
            button.target = self
            button.action = #selector(cancelPressed)
            v.addSubview(label)
            v.addSubview(bar)
            v.addSubview(button)
        }
        panel.center()
        panel.orderFrontRegardless()
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }

    @objc func cancelPressed() {
        FileManager.default.createFile(atPath: cancelPath, contents: nil)
        button.isEnabled = false
        label.stringValue = "Annullamento in corso…"
    }

    func tick() {
        if parent > 0 && kill(parent, 0) != 0 { exit(0) }
        guard let s = try? String(contentsOfFile: statusPath, encoding: .utf8), s != last else { return }
        last = s
        let line = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if line == "DONE" { exit(0) }
        let parts = line.components(separatedBy: "\t")
        if let f = Double(parts[0]), f >= 0 {
            if bar.isIndeterminate { bar.isIndeterminate = false; bar.stopAnimation(nil) }
            bar.doubleValue = min(1, f)
        } else if !bar.isIndeterminate {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
        if parts.count > 1 && button.isEnabled { label.stringValue = parts[1] }
    }
}

final class MenuTarget: NSObject {
    var chosen: String?
    @objc func pick(_ sender: NSMenuItem) { chosen = sender.representedObject as? String }
}

let args = CommandLine.arguments
func arg(_ i: Int) -> String { i < args.count ? args[i] : "" }
func langList(_ s: String) -> [String] { s.split(separator: ",").map { String($0) } }
guard args.count >= 2 else { fail("comando mancante") }

switch args[1] {

case "pdf2img":   // pdf cartella formato dpi prefisso
    let doc = openPDF(arg(2))
    let outDir = arg(3), fmt = arg(4), prefix = arg(6)
    let dpi = CGFloat(Double(arg(5)) ?? 200)
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let n = doc.pageCount
    if n == 0 { fail("il PDF non ha pagine") }
    for i in 0..<n {
        autoreleasepool {
            guard let p = doc.page(at: i), let img = render(p, dpi: dpi) else { return }
            let name = n == 1 ? "\(prefix).\(fmt)" : pageName(prefix, i, n, fmt)
            _ = writeImage(img, outDir + "/" + name, fmt)
        }
        progress(i + 1, n)
    }

case "merge":     // uscita file…
    let out = PDFDocument()
    var keep: [PDFDocument] = []
    let inputs = Array(args.dropFirst(3))
    for (idx, p) in inputs.enumerated() {
        let name = (p as NSString).lastPathComponent
        if (p as NSString).pathExtension.lowercased() == "pdf" {
            let d = openPDF(p)
            keep.append(d)
            for i in 0..<d.pageCount {
                if let pg = d.page(at: i)?.copy() as? PDFPage { out.insert(pg, at: out.pageCount) }
            }
        } else {
            guard let img = NSImage(contentsOfFile: p), let pg = PDFPage(image: img) else {
                fail("non riesco a leggere l'immagine «\(name)»")
            }
            out.insert(pg, at: out.pageCount)
        }
        progress(idx + 1, inputs.count)
    }
    if out.pageCount == 0 { fail("nessuna pagina da unire") }
    if !out.write(to: URL(fileURLWithPath: arg(2))) { fail("non riesco a scrivere il PDF unito") }

case "split":     // pdf cartella prefisso
    let doc = openPDF(arg(2))
    let outDir = arg(3), prefix = arg(4)
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let n = doc.pageCount
    for i in 0..<n {
        let nd = PDFDocument()
        if let pg = doc.page(at: i)?.copy() as? PDFPage { nd.insert(pg, at: 0) }
        _ = nd.write(to: URL(fileURLWithPath: outDir + "/" + pageName(prefix, i, n, "pdf")))
        progress(i + 1, n)
    }

case "extract":   // pdf uscita "1-3,5,8-"
    let doc = openPDF(arg(2))
    let n = doc.pageCount
    var pages: [Int] = []
    for part in arg(4).replacingOccurrences(of: " ", with: "").split(separator: ",") {
        let r = part.split(separator: "-", omittingEmptySubsequences: false)
        guard let a = Int(r[0]) else { fail("intervallo non valido: \(part)") }
        let b: Int = r.count > 1 ? (r[1].isEmpty ? n : (Int(r[1]) ?? -1)) : a
        if a < 1 || b > n || a > b { fail("pagine fuori intervallo: il PDF ha \(n) pagine") }
        pages += Array(a...b)
    }
    let nd = PDFDocument()
    for p in pages {
        if let pg = doc.page(at: p - 1)?.copy() as? PDFPage { nd.insert(pg, at: nd.pageCount) }
    }
    if !nd.write(to: URL(fileURLWithPath: arg(3))) { fail("non riesco a scrivere il PDF") }

case "text":      // pdf uscita lingue — testo del PDF, con OCR per le pagine scansionate
    let doc = openPDF(arg(2))
    let langs = langList(arg(4))
    let n = doc.pageCount
    var parts: [String] = []
    var found = false
    for i in 0..<n {
        autoreleasepool {
            guard let p = doc.page(at: i) else { return }
            var s = p.string ?? ""
            if s.trimmingCharacters(in: .whitespacesAndNewlines).count < 15, let img = render(p, dpi: 300) {
                s = recognize(img, .up, langs)
            }
            if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { found = true }
            parts.append(n > 1 ? "──── Pagina \(i + 1) ────\n\(s)" : s)
        }
        progress(i + 1, n)
    }
    if !found { fail("nel PDF non ho trovato testo leggibile") }
    do { try parts.joined(separator: "\n\n").write(toFile: arg(3), atomically: true, encoding: .utf8) }
    catch { fail("non riesco a scrivere il file di testo") }

case "rotate":    // pdf uscita gradi
    let doc = openPDF(arg(2))
    let deg = Int(arg(4)) ?? 90
    for i in 0..<doc.pageCount {
        if let p = doc.page(at: i) { p.rotation = ((p.rotation + deg) % 360 + 360) % 360 }
        progress(i + 1, doc.pageCount)
    }
    if !doc.write(to: URL(fileURLWithPath: arg(3))) { fail("non riesco a scrivere il PDF") }

case "reorder":   // pdf uscita "3,1,2,7-5" oppure "reverse"; le pagine non indicate restano in fondo
    let doc = openPDF(arg(2))
    let n = doc.pageCount
    var order: [Int] = []
    if arg(4) == "reverse" {
        order = Array((1...max(n, 1)).reversed())
    } else {
        for part in arg(4).replacingOccurrences(of: " ", with: "").split(separator: ",") {
            let r = part.split(separator: "-")
            guard let a = Int(r[0]) else { fail("ordine non valido: \(part)") }
            let b = r.count > 1 ? (Int(r[1]) ?? a) : a
            if a < 1 || b < 1 || a > n || b > n { fail("pagine fuori intervallo: il PDF ha \(n) pagine") }
            order += a <= b ? Array(a...b) : Array((b...a).reversed())
        }
    }
    var seen = Set<Int>()
    order = order.filter { seen.insert($0).inserted }
    order += (1...max(n, 1)).filter { !seen.contains($0) && $0 <= n }
    let nd = PDFDocument()
    for p in order {
        if let pg = doc.page(at: p - 1)?.copy() as? PDFPage { nd.insert(pg, at: nd.pageCount) }
    }
    if !nd.write(to: URL(fileURLWithPath: arg(3))) { fail("non riesco a scrivere il PDF") }

case "protect":   // pdf uscita password («-» = la password arriva a parte, in LR_PW)
    let doc = openPDF(arg(2))
    let pw = arg(4) == "-" ? (ProcessInfo.processInfo.environment["LR_PW"] ?? "") : arg(4)
    if pw.isEmpty { fail("la password è vuota") }
    let opts: [PDFDocumentWriteOption: Any] = [.userPasswordOption: pw, .ownerPasswordOption: pw]
    if !doc.write(to: URL(fileURLWithPath: arg(3)), withOptions: opts) { fail("non riesco a scrivere il PDF protetto") }

case "unprotect": // pdf uscita password
    guard let doc = PDFDocument(url: URL(fileURLWithPath: arg(2))) else { fail("PDF danneggiato o non valido") }
    let upw = arg(4) == "-" ? (ProcessInfo.processInfo.environment["LR_PW"] ?? "") : arg(4)
    if doc.isLocked && !doc.unlock(withPassword: upw) { fail("la password non è corretta") }
    let nd = PDFDocument()
    for i in 0..<doc.pageCount {
        if let pg = doc.page(at: i)?.copy() as? PDFPage { nd.insert(pg, at: nd.pageCount) }
    }
    if !nd.write(to: URL(fileURLWithPath: arg(3))) { fail("non riesco a scrivere il PDF") }

case "ocr":       // immagine uscita lingue
    guard let li = loadImage(arg(2)) else { fail("non riesco a leggere l'immagine") }
    let text = recognize(li.0, li.1, langList(arg(4)))
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fail("nell'immagine non ho trovato testo leggibile") }
    do { try text.write(toFile: arg(3), atomically: true, encoding: .utf8) }
    catch { fail("non riesco a scrivere il file di testo") }

case "menu":      // titolo, poi voci "id<TAB>etichetta<TAB>simbolo"; "-" = separatore; "#Testo" = intestazione
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let target = MenuTarget()
    let menu = NSMenu()
    menu.autoenablesItems = false
    func header(_ t: String) {
        if #available(macOS 14.0, *) {
            menu.addItem(NSMenuItem.sectionHeader(title: t))
        } else {
            let h = NSMenuItem(title: t, action: nil, keyEquivalent: "")
            h.isEnabled = false
            menu.addItem(h)
        }
    }
    header(arg(2))
    for spec in args.dropFirst(3) {
        if spec == "-" { menu.addItem(NSMenuItem.separator()); continue }
        if spec.hasPrefix("#") { header(String(spec.dropFirst())); continue }
        let p = spec.components(separatedBy: "\t")
        guard p.count >= 2 else { continue }
        let item = NSMenuItem(title: p[1], action: #selector(MenuTarget.pick(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = p[0]
        if p.count > 2, !p[2].isEmpty, let img = NSImage(systemSymbolName: p[2], accessibilityDescription: nil) {
            item.image = img
        }
        menu.addItem(item)
    }
    DispatchQueue.main.async {
        app.activate(ignoringOtherApps: true)
        _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        if let c = target.chosen { print(c) }
        exit(0)
    }
    app.run()

case "progress":  // file-stato file-annulla pid
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let ctl = ProgressController(status: arg(2), cancel: arg(3), parent: pid_t(Int32(arg(4)) ?? 0))
    withExtendedLifetime(ctl) { app.run() }

default:
    fail("comando sconosciuto: \(args[1])")
}
SWIFT
}

helper_ready() {  # il programma nativo è già pronto e aggiornato? (non compila mai)
  (( HELPER_STATE == 1 )) && return 0
  (( HELPER_STATE == 2 )) && return 1
  [[ -x $HELPER && -f "$SUPPORT/lrhelper.swift" ]] || return 1
  write_helper_source | cmp -s - "$SUPPORT/lrhelper.swift" || return 1
  HELPER_STATE=1
  return 0
}

helper_ok() {  # prepara il programma nativo la prima volta (o dopo un aggiornamento)
  (( HELPER_STATE == 1 )) && return 0
  (( HELPER_STATE == 2 )) && return 1
  local src="$SUPPORT/lrhelper.swift" new="$WORK/lrhelper.swift" failed="$SUPPORT/lrhelper.failed.swift"
  local lock="$SUPPORT/.compile.lock" waited=0
  write_helper_source > "$new"
  if [[ -x $HELPER && -f $src ]] && cmp -s "$src" "$new"; then HELPER_STATE=1; return 0; fi
  # Già fallita con questo stesso codice: non riprovare a ogni uso (il controllo automatico riprova sempre)
  if [[ -z $SELFTEST && -f $failed ]] && cmp -s "$failed" "$new"; then HELPER_STATE=2; return 1; fi
  # Un'altra finestra di LRConverter sta già compilando: aspetta lei
  while ! mkdir "$lock" 2>/dev/null; do
    sleep 1; (( waited += 1 ))
    if (( waited > 180 )); then rmdir "$lock" 2>/dev/null; waited=0; fi
  done
  if [[ -x $HELPER && -f $src ]] && cmp -s "$src" "$new"; then rmdir "$lock"; HELPER_STATE=1; return 0; fi
  if [[ -n $RUN_MODE ]]; then progress_set -1 "Preparazione iniziale (solo la prima volta, circa un minuto)…"
  elif [[ -z $SELFTEST ]]; then notify "Preparazione iniziale: solo la prima volta, circa un minuto…"
  fi
  log "compilo il programma nativo"
  if swiftc -O -o "$HELPER.tmp" "$new" >>"$LOG" 2>&1 && mv -f -- "$HELPER.tmp" "$HELPER"; then
    cp -f -- "$new" "$src"; rm -f -- "$failed"; rmdir "$lock"
    HELPER_STATE=1; return 0
  fi
  rm -f -- "$HELPER.tmp"; cp -f -- "$new" "$failed"; rmdir "$lock"
  log "compilazione del programma nativo non riuscita"
  HELPER_STATE=2; return 1
}

# ─── Tipi di file e menu ─────────────────────────────────────────────

RAW_EXTS=(dng cr2 cr3 nef arw raf orf rw2 srw pef)
PKG_EXTS=(pages numbers key rtfd)

norm() {
  case ${(L)1} in
    jpeg|jpe)       print jpg  ;;
    tif)            print tiff ;;
    heif)           print heic ;;
    htm|xhtml)      print html ;;
    markdown|mdown) print md   ;;
    aif)            print aiff ;;
    j2k|jpf|jpx)    print jp2  ;;
    *)              print -r -- ${(L)1} ;;
  esac
}

kind_of() {
  case $1 in
    docx|doc|odt|rtf|txt|pages|wps|wpd)                        print doc   ;;
    xlsx|xls|ods|csv|numbers)                                  print sheet ;;
    pptx|ppt|odp|key)                                          print slide ;;
    md|html|epub)                                              print text  ;;
    jpg|png|heic|tiff|webp|gif|bmp|svg|ico)                    print img   ;;
    avif|psd|jxl|jp2|tga|exr)                                  print img   ;;
    dng|cr2|cr3|nef|arw|raf|orf|rw2|srw|pef)                   print img   ;;
    mp3|wav|m4a|flac|aac|ogg|opus|aiff|wma)                    print audio ;;
    caf|amr|m4b|ac3|aifc)                                      print audio ;;
    mp4|mov|mkv|avi|webm|m4v|wmv|flv|mpg|mpeg|3gp|mts|m2ts)    print video ;;
    ts|vob|mxf|ogv|dv|f4v|asf)                                 print video ;;
    pdf)                                                       print pdf   ;;
    srt)                                                       print sub   ;;
  esac
}

typeset -A OPTS=(
  doc   "pdf docx odt rtf txt html md"
  sheet "pdf xlsx ods csv html"
  slide "pdf pptx odp"
  text  "docx odt pdf html md epub"
  img   "jpg png heic webp tiff pdf ico"
  audio "mp3 m4a wav flac ogg"
  video "mp4 mov mkv webm gif mp3 m4a"
  pdf   "docx png jpg"
)
typeset -A KIND_NAME=(
  doc documenti  sheet "fogli di calcolo"  slide presentazioni  text "file di testo"
  img immagini   audio "file audio"        video video          pdf PDF
)

label() { label_r "$@"; print -r -- $REPLY }
label_r() {  # tipo, formato → REPLY = testo nel menu
  local l=${(U)2}
  case $1:$2 in
    pdf:png|pdf:jpg)     l+=" (tutte le pagine)" ;;
    pdf:docx)            l+=" (modificabile)"    ;;
    img:ico)             l+=" (icona)"           ;;
    video:gif)           l+=" (animata)"         ;;
    video:mp3|video:m4a) l+=" (solo audio)"      ;;
  esac
  REPLY=$l
}

m_drop() {  # toglie voci dal menu
  local id i
  for id in "$@"; do
    i=${M_IDS[(Ie)$id]}
    (( i )) || continue
    M_IDS[i]=(); M_LABELS[i]=()
  done
}

menu_for() {  # tipo → M_IDS e M_LABELS
  local k=$1 o i last
  M_IDS=(); M_LABELS=()
  for o in ${=OPTS[$k]}; do
    (( $#G_EXTS == 1 )) && [[ $o == ${G_EXTS[1]} ]] && continue
    label_r $k $o
    M_IDS+=("to:$o"); M_LABELS+=("→ $REPLY")
  done
  case $k in
    img)
      M_IDS+=(resize strip ocr)
      M_LABELS+=("Ridimensiona…" "Rimuovi i metadati (posizione GPS, fotocamera…)" "Estrai il testo (OCR)") ;;
    pdf)
      M_IDS+=(pdftext split extract pdfcompress rotate reorder protect unprotect)
      M_LABELS+=("Estrai il testo (anche da scansioni)" "Dividi in pagine singole" "Estrai alcune pagine…" "Comprimi…"
                 "Ruota le pagine…" "Riordina le pagine…" "Proteggi con password…" "Togli la password…") ;;
    audio)
      M_IDS+=(cut normalize voiceclean transcribe silence speed)
      M_LABELS+=("Taglia…" "Normalizza il volume" "Voce più pulita (meno rumore di fondo)" "Trascrivi (testo + sottotitoli)" "Togli i silenzi" "Cambia la velocità…") ;;
    video)
      M_IDS+=(vresize speed vcompress cut gifcut normalize voiceclean transcribe subextract subembed strip)
      M_LABELS+=("Cambia risoluzione (1080p, 720p, HEVC)…" "Cambia la velocità…" "Comprimi per WhatsApp / email…" "Taglia…" "GIF animata da un pezzo…" "Normalizza il volume"
                 "Voce più pulita (meno rumore di fondo)"
                 "Trascrivi (testo + sottotitoli)" "Estrai i sottotitoli (.srt)" "Aggiungi i sottotitoli da un file .srt"
                 "Rimuovi i metadati (posizione GPS, dispositivo…)") ;;
  esac
  if [[ $k == img ]]; then
    for o in $G_EXTS; do
      [[ $o == svg ]] && m_drop resize strip ocr
      (( ${RAW_EXTS[(Ie)$o]} )) && m_drop strip
    done
  fi
  if [[ $k == (img|pdf) ]] && (( MERGEABLE >= 2 )); then
    M_IDS+=(merge); M_LABELS+=("Unisci tutti in un unico PDF ($MERGEABLE file)")
  fi
  return 0
}

typeset -A SYM=(
  resize arrow.up.left.and.arrow.down.right  strip eye.slash  ocr text.viewfinder
  pdftext doc.text.magnifyingglass  split rectangle.split.3x1  extract doc.on.doc
  pdfcompress arrow.down.right.and.arrow.up.left  vcompress arrow.down.right.and.arrow.up.left
  cut scissors  gifcut photo.stack  normalize speaker.wave.2  voiceclean waveform.and.mic  transcribe captions.bubble
  subextract text.bubble  subembed plus.bubble  merge square.stack.3d.up  settings gearshape
  rotate rotate.right  reorder arrow.up.arrow.down  protect lock  unprotect lock.open
  vresize aspectratio  speed speedometer  silence waveform.badge.minus
)
typeset -A TSYM=(
  pdf doc.richtext  docx doc.text  odt doc.text  rtf doc.text  txt doc.plaintext  html globe  md doc.plaintext  epub book
  xlsx tablecells  ods tablecells  csv tablecells  pptx rectangle.on.rectangle  odp rectangle.on.rectangle
  jpg photo  png photo  heic photo  webp photo  tiff photo  ico app
  mp3 waveform  m4a waveform  wav waveform  flac waveform  ogg waveform
  mp4 film  mov film  mkv film  webm film  gif photo.stack
)

pick_action() {  # tipo, domanda → stampa l'id scelto (vuoto se annullato)
  local k=$1 q=$2 i li r rc sec="" sym
  li=${M_IDS[(Ie)${PREF[last_$k]}]}
  if [[ ${PREF[menu]} != classic ]] && helper_ready; then
    # Menu nativo del Mac, accanto al puntatore
    local -a spec=()
    if (( li )); then
      sym=${SYM[${M_IDS[li]}]}; [[ ${M_IDS[li]} == to:* ]] && sym=${TSYM[${M_IDS[li]#to:}]}
      spec+=("#Ultima scelta" "${M_IDS[li]}"$'\t'"${M_LABELS[li]#→ }"$'\t'"$sym" "-")
    fi
    for i in {1..$#M_IDS}; do
      if [[ ${M_IDS[i]} == to:* ]]; then
        [[ $sec == conv ]] || { spec+=("#Converti in"); sec=conv }
        sym=${TSYM[${M_IDS[i]#to:}]}
      else
        [[ $sec == tools ]] || { (( $#spec )) && spec+=("-"); spec+=("#Strumenti"); sec=tools }
        sym=${SYM[${M_IDS[i]}]}
      fi
      spec+=("${M_IDS[i]}"$'\t'"${M_LABELS[i]#→ }"$'\t'"$sym")
    done
    spec+=("-" "settings"$'\t'"Impostazioni…"$'\t'"${SYM[settings]}")
    r=$("$HELPER" menu "$q" $spec 2>>"$LOG"); rc=$?
    if (( rc == 0 )); then print -r -- $r; return 0; fi
    log "menu nativo non disponibile (codice $rc): uso quello classico"
  fi
  # Menu classico (AppleScript): l'ultima scelta in cima
  local -a ids=("${(@)M_IDS}") labels=("${(@)M_LABELS}")
  if (( li > 1 )); then
    ids=("${ids[li]}" "${(@)ids[1,li-1]}" "${(@)ids[li+1,-1]}")
    labels=("${labels[li]}" "${(@)labels[1,li-1]}" "${(@)labels[li+1,-1]}")
  fi
  ids+=(settings); labels+=("⚙️ Impostazioni…")
  r=$(choose "$q" $labels)
  [[ -n $r ]] && print -r -- ${ids[${labels[(Ie)$r]}]}
  return 0
}

ask_param() {  # azione → stampa il parametro; esce con errore se annullato
  local r s en
  case $1 in
    resize)
      r=$(choose_btn "Scegli" "Nuova dimensione:" "Metà (50%)" "Lato lungo max 3840 px (4K)" \
          "Lato lungo max 1920 px" "Lato lungo max 1280 px" "Per il web (1600 px, JPG leggero)")
      case $r in
        Metà*) print half ;; *3840*) print 3840 ;; *1920*) print 1920 ;; *1280*) print 1280 ;; Per*) print web ;; *) return 1 ;;
      esac ;;
    pdfcompress)
      r=$(choose_btn "Comprimi" "Livello di compressione:" "Media (consigliata)" "Leggera (qualità di stampa)" "Forte (file più piccolo possibile)")
      case $r in Media*) print medium ;; Leggera*) print light ;; Forte*) print strong ;; *) return 1 ;; esac ;;
    vcompress)
      r=$(choose_btn "Comprimi" "Peso massimo del video:" "25 MB (email)" "16 MB" "50 MB" "100 MB" "8 MB" "Altro…")
      case $r in
        "") return 1 ;;
        "Altro…")
          while :; do
            r=$(ask_text "Peso massimo in MB:" "25") || return 1
            r=${r// /}; r=${r%[Mm][Bb]}
            if [[ $r == <1-> ]]; then print $r; return 0; fi
            alert "$APP" "Scrivi solo un numero intero, ad esempio 25."
          done ;;
        *) print ${r%% *} ;;
      esac ;;
    cut|gifcut)
      local d2=""; [[ $1 == gifcut ]] && d2="0:05"
      while :; do
        r=$(ask_text "Da che punto iniziare? (es. 0:10 oppure 1:02:30)" "0:00") || return 1
        s=$(parse_time "$r") && break
        alert "$APP" "Formato non valido. Esempi: 45  ·  1:30  ·  1:02:30"
      done
      while :; do
        r=$(ask_text "Fino a che punto? (lascia vuoto per arrivare alla fine)" "$d2") || return 1
        if [[ -z ${r// /} ]]; then en=""; break; fi
        en=$(parse_time "$r") && (( en > s )) && break
        alert "$APP" "La fine deve essere un tempo valido e successivo all'inizio."
      done
      print -r -- "$s|$en" ;;
    vresize)
      r=$(choose_btn "Scegli" "Nuova risoluzione:" "1080p (Full HD)" "720p (HD)" "480p (leggero)" "HEVC: stessa risoluzione, file più piccolo")
      case $r in 1080p*) print 1080 ;; 720p*) print 720 ;; 480p*) print 480 ;; HEVC*) print hevc ;; *) return 1 ;; esac ;;
    speed)
      r=$(choose_btn "Scegli" "Velocità:" "0,5× (metà)" "0,75×" "1,25×" "1,5×" "2× (doppia)")
      case $r in "0,5"*) print 0.5 ;; "0,75"*) print 0.75 ;; "1,25"*) print 1.25 ;; "1,5"*) print 1.5 ;; 2*) print 2 ;; *) return 1 ;; esac ;;
    rotate)
      r=$(choose_btn "Ruota" "Ruota tutte le pagine:" "90° a destra" "180°" "90° a sinistra")
      case $r in *destra) print 90 ;; 180*) print 180 ;; *sinistra) print 270 ;; *) return 1 ;; esac ;;
    reorder)
      while :; do
        r=$(ask_text "Nuovo ordine delle pagine (es. 3,1,2 oppure 5-1). Scrivi «inverti» per rovesciarle. Le pagine non indicate restano in fondo." "inverti") || return 1
        r=${r// /}
        if [[ ${(L)r} == inverti ]]; then print reverse; return 0; fi
        if [[ $r =~ '^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$' ]]; then print -r -- $r; return 0; fi
        alert "$APP" "Formato non valido. Esempi: 3,1,2  ·  5-1  ·  inverti"
      done ;;
    protect)
      while :; do
        r=$(ask_secret "Password per aprire il PDF:") || return 1
        [[ -n $r ]] || { alert "$APP" "La password non può essere vuota."; continue }
        s=$(ask_secret "Ripeti la password:") || return 1
        [[ $r == "$s" ]] && { print -r -- "$r"; return 0 }
        alert "$APP" "Le due password non coincidono."
      done ;;
    unprotect)
      r=$(ask_secret "Password attuale del PDF:") || return 1
      print -r -- "$r" ;;
    extract)
      while :; do
        r=$(ask_text "Quali pagine vuoi estrarre? (es. 1-3, 5, 8-)" "1") || return 1
        r=${r// /}
        if [[ $r =~ '^[0-9]+(-[0-9]*)?(,[0-9]+(-[0-9]*)?)*$' ]]; then print -r -- $r; return 0; fi
        alert "$APP" "Formato non valido. Esempi: 2  ·  1-3  ·  1,4,7-9  ·  5- (dalla 5 alla fine)"
      done ;;
  esac
}

settings_menu() {
  local r d q l
  typeset -A LNAME=(auto Automatica it Italiano en Inglese es Spagnolo fr Francese de Tedesco)
  while :; do
    case ${PREF[dest]} in
      sub)   d="sottocartella «Convertiti»" ;;
      fixed) d="cartella «${PREF[destpath]:t}»" ;;
      *)     d="stessa cartella dell'originale" ;;
    esac
    if [[ $(wq) == turbo ]]; then q="precisa"; else q="veloce"; fi
    l=${LNAME[${PREF[wlang]}]:-Automatica}
    local m="nativo (veloce)"; [[ ${PREF[menu]} == classic ]] && m="classico"
    r=$(choose_btn "Modifica" "Impostazioni di $APP" "Dove salvare: $d" "Qualità della trascrizione: $q" \
        "Lingua di trascrizione e OCR: $l" "Stile del menu: $m" "Fatto")
    case $r in
      "Dove salvare"*)
        r=$(choose_btn "Scegli" "Dove salvo i file creati?" "Nella stessa cartella dell'originale" \
            "In una sottocartella «Convertiti»" "In una cartella a scelta…")
        case $r in
          Nella*)          PREF[dest]=same ;;
          "In una sotto"*) PREF[dest]=sub ;;
          *scelta*)
            d=$(choose_folder "Scegli la cartella dove salvare i file") && [[ -n $d ]] && { PREF[dest]=fixed; PREF[destpath]=${d%/} } ;;
        esac ;;
      "Qualità"*)
        r=$(choose_btn "Scegli" "Qualità della trascrizione:" "Veloce (modello da ${WSIZE[small]})" \
            "Precisa (modello da ${WSIZE[turbo]}, consigliata per l'italiano)")
        case $r in Veloce*) PREF[wq]=small ;; Precisa*) PREF[wq]=turbo ;; esac ;;
      "Stile del menu"*)
        r=$(choose_btn "Scegli" "Stile del menu:" "Nativo (si apre accanto al puntatore, più veloce)" "Classico (finestra di scelta)")
        case $r in Nativo*) PREF[menu]=native ;; Classico*) PREF[menu]=classic ;; esac ;;
      "Lingua"*)
        r=$(choose_btn "Scegli" "Lingua di trascrizione e OCR:" Automatica Italiano Inglese Spagnolo Francese Tedesco)
        case $r in
          Automatica) PREF[wlang]=auto ;; Italiano) PREF[wlang]=it ;; Inglese) PREF[wlang]=en ;;
          Spagnolo) PREF[wlang]=es ;; Francese) PREF[wlang]=fr ;; Tedesco) PREF[wlang]=de ;;
        esac ;;
      *) save_prefs; return 0 ;;
    esac
    save_prefs
  done
}

# Motore da usare per una conversione di formato
route() {  # tipo, estensione, formato
  local k=$1 e=$2 t=$3
  case $k in
    doc)
      if [[ $t == txt && $e == (doc|docx|odt|rtf) ]]; then print textutil
      elif [[ $t == md ]]; then
        if [[ $e == (docx|odt) ]]; then print pandoc; else print lo+pandoc; fi
      elif [[ $t == html && $e == (docx|odt) ]] && have pandoc; then print pandoc
      elif ! have soffice && [[ $e == (doc|docx|odt|rtf|txt) && $t == (docx|odt|rtf|html) ]]; then print textutil
      else print lo
      fi ;;
    sheet|slide) print lo ;;
    text)        if [[ $t == pdf ]]; then print pandoc+lo; else print pandoc; fi ;;
    img)         print img ;;
    audio|video) print av ;;
    pdf)         if [[ $t == docx ]]; then print lo; else print pdfimg; fi ;;
  esac
}

needs() {  # motore o azione, tipo → programmi richiesti
  case $1 in
    lo)                  print soffice ;;
    pandoc)              print pandoc ;;
    lo+pandoc|pandoc+lo) print soffice pandoc ;;
    av|cut|gifcut|vcompress|normalize|voiceclean|subextract|subembed|vresize|speed|silence) print ffmpeg ffprobe ;;
    transcribe)          print ffmpeg whisper ;;
    pdfcompress)         print gs ;;
    pdftext|ocr|split|extract|merge|rotate|reorder|protect|unprotect) print helper ;;
    strip)               [[ $2 == (audio|video) ]] && print ffmpeg ;;
  esac
  return 0
}

typeset -A INSTALL=(
  soffice "LibreOffice:  brew install --cask libreoffice"
  pandoc  "pandoc:  installer ufficiale da pandoc.org"
  ffmpeg  "ffmpeg:  brew install ffmpeg"
  ffprobe "ffmpeg:  brew install ffmpeg"
  gs      "Ghostscript:  brew install ghostscript"
  whisper "Whisper:  brew install whisper-cpp"
  magick  "ImageMagick:  brew install imagemagick"
  helper  "Strumenti per sviluppatori Apple:  xcode-select --install  (o aggiornali da Aggiornamento Software)"
)

dep_ok() {
  case $1 in
    helper)  helper_ok ;;
    whisper) whisper_bin >/dev/null ;;
    *)       have $1 ;;
  esac
}

# ─── Motori di conversione ───────────────────────────────────────────
#  Ogni lavoro scrive i risultati in "$JD/out"; i file temporanei stanno in "$JD".

lo_acquire() {  # sceglie un profilo LibreOffice libero: più conversioni insieme non si bloccano a vicenda
  [[ -n $LO_SLOT ]] && return 0
  local n d pid
  for n in 1 2 3 4 5 6; do
    d="$CACHE/lo-lock-$n"
    if mkdir "$d" 2>/dev/null; then print $$ > "$d/pid"; LO_SLOT=$n; break; fi
    pid=$(<"$d/pid") 2>/dev/null
    if [[ $pid == <-> ]] && ! kill -0 $pid 2>/dev/null; then       # occupato da una conversione ormai chiusa
      rm -rf -- "$d"
      if mkdir "$d" 2>/dev/null; then print $$ > "$d/pid"; LO_SLOT=$n; break; fi
    fi
  done
  [[ -n $LO_SLOT ]] || LO_SLOT="tmp$$"                              # tutti occupati: profilo usa e getta
  if [[ $LO_SLOT == 1 ]]; then LO_PROFILE="file://$CACHE/lo-profile"   # il primo riusa quello già pronto
  else LO_PROFILE="file://$CACHE/lo-profile-$LO_SLOT"
  fi
}

lo_release() {
  [[ -n $LO_SLOT ]] || return 0
  if [[ $LO_SLOT == <-> ]]; then rm -rf -- "$CACHE/lo-lock-$LO_SLOT"
  else rm -rf -- "$CACHE/lo-profile-$LO_SLOT"
  fi
  LO_SLOT=""
}

lo_filter() {
  case $1:$2 in
    *:txt)     print 'txt:Text (encoded):UTF8' ;;
    sheet:csv) print 'csv:Text - txt - csv (StarCalc):44,34,76' ;;   # virgola, virgolette, UTF-8
    doc:html)  print 'html:HTML (StarWriter):EmbedImages' ;;           # immagini dentro la pagina
    *)         print -r -- $2 ;;
  esac
}

# 3.5.2 · ImageMagick riconosce il formato dal NOME del file, mai dal contenuto
# (un «foto.jpg» che in realtà contiene istruzioni di disegno non può leggere altri file)
mk_src() {
  local e=$(norm "${1:e}") f=""
  case $e in
    jpg) f=JPEG ;; png) f=PNG ;; heic) f=HEIC ;; webp) f=WEBP ;; tiff) f=TIFF ;; gif) f=GIF ;; bmp) f=BMP ;;
    ico) f=ICO ;; svg) f=SVG ;; avif) f=AVIF ;; psd) f=PSD ;; tga) f=TGA ;; jxl) f=JXL ;; jp2) f=JP2 ;; exr) f=EXR ;;
  esac
  if [[ -n $f ]]; then print -r -- "$f:$1"; else print -r -- "$1"; fi
}

# 3.5.2 · LibreOffice: niente macro, niente collegamenti esterni (immagini o file presi da fuori)
lo_harden() {  # profilo (file://…)
  local dir=${1#file://}/user
  local x="$dir/registrymodifications.xcu"
  grep -q "OrbitLR-sicurezza-1" "$x" 2>/dev/null && return 0
  mkdir -p -- "$dir"
  cat > "$x" <<'XCU'
<?xml version="1.0" encoding="UTF-8"?>
<!-- OrbitLR-sicurezza-1 -->
<oor:items xmlns:oor="http://openoffice.org/2001/registry" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop></item>
<item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="DisableMacrosExecution" oor:op="fuse"><value>true</value></prop></item>
<item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="BlockUntrustedRefererLinks" oor:op="fuse"><value>true</value></prop></item>
<item oor:path="/org.openoffice.Office.Writer/Content/Update"><prop oor:name="Link" oor:op="fuse"><value>0</value></prop></item>
<item oor:path="/org.openoffice.Office.Calc/Content/Update"><prop oor:name="Link" oor:op="fuse"><value>0</value></prop></item>
</oor:items>
XCU
}

lo_run() {  # cartella di uscita, tipo, formato, file…
  local dir=$1 k=$2 t=$3; shift 3
  lo_harden "$LO_PROFILE"
  local -a args=(--headless --norestore --nolockcheck --nodefault "-env:UserInstallation=$LO_PROFILE")
  [[ $k == pdf ]] && args+=(--infilter=writer_pdf_import)
  args+=(--convert-to "$(lo_filter $k $t)" --outdir "$dir")
  with_timeout $(( 120 + 60 * $# )) soffice $args "$@" >&2
}

pandoc_filter() {  # il filtro di sicurezza per pandoc (scritto una volta)
  local f="$SUPPORT/pandoc-sicuro.lua"
  if ! grep -q "OrbitLR-sicurezza-1" "$f" 2>/dev/null; then
    cat > "$f" <<'LUA'
-- OrbitLR-sicurezza-1: niente file presi da fuori dalla cartella del documento, niente indirizzi web
local function unsafe(s)
  if not s or s == "" then return false end
  if s:match("^data:") then return false end
  if s:match("^%a[%w+.-]*:") then return true end
  local c = s:sub(1, 1)
  if c == "/" or c == "~" or c == "\\" then return true end
  if s:find("%.%.") then return true end
  return false
end
function Image(el) if unsafe(el.src) then return el.caption end end
local function risky(t) return t:lower():find("src") or t:lower():find("href") or t:lower():find("url%(") end
function RawInline(el) if el.format:match("html") and risky(el.text) then return {} end end
function RawBlock(el) if el.format:match("html") and risky(el.text) then return {} end end
LUA
  fi
  print -r -- "$f"
}

pandoc_run() {  # sorgente, formato, uscita, cartella finale (per le immagini estratte)
  local src=$1 t=$2 out=$3 dest=$4
  local -a a=(--resource-path="${src:h}")
  # 3.5.2 · Testi che possono richiamare file del Mac o indirizzi web: un filtro toglie le immagini prese da
  # fuori dalla cartella del documento (percorsi assoluti, «..», indirizzi web) e l'HTML che richiama risorse
  case $(norm "${src:e}") in
    md|markdown|html|htm|txt) a+=(--lua-filter="$(pandoc_filter)") ;;
    # Formati che possono «includere» altri file mentre si leggono: lettura chiusa, solo il file scelto
    rst|tex|org|textile) a=(--sandbox) ;;
  esac
  case $t in
    md)   a+=(-t gfm --wrap=none --extract-media="${src:t:r}_media") ;;
    html) a+=(--standalone --embed-resources -M pagetitle="${src:t:r}") ;;   # un solo file, immagini comprese
    epub) a+=(-M title="${src:t:r}") ;;
  esac
  mkdir -p -- "$dest" 2>/dev/null
  ( cd -- "$dest" && pandoc "$src" $a -o "$out" )
}

img_run() {  # sorgente, formato, uscita
  local src=$1 t=$2 out=$3 e=$(norm "${1:e}")
  if (( ${RAW_EXTS[(Ie)$e]} )); then
    # RAW: motore nativo di macOS
    case $t in
      jpg)           sips -s format jpeg -s formatOptions 92 "$src" --out "$out" >&2; return ;;
      png|tiff|heic) sips -s format $t "$src" --out "$out" >&2; return ;;
    esac
    sips -s format png "$src" --out "$JD/_src.png" >&2 || return 1
    src="$JD/_src.png"; e=png
  elif [[ $e == svg ]]; then
    if have rsvg-convert; then
      if [[ $t == pdf ]]; then rsvg-convert -f pdf -o "$out" "$src"; return; fi
      rsvg-convert -w 2048 -a -o "$JD/_src.png" "$src" || return 1
    elif have magick && { magick -density 300 -background none "$(mk_src "$src")" "$JD/_src.png" 2>/dev/null \
                          || magick -density 300 -background none "$src" "$JD/_src.png" 2>/dev/null; }; then
      :
    else
      qlmanage -t -s 2048 -o "$JD" "$src" >&2
      mv -f -- "$JD/${src:t}.png" "$JD/_src.png" 2>/dev/null || return 1
    fi
    if [[ $t == png ]]; then mv -f -- "$JD/_src.png" "$out"; return; fi
    src="$JD/_src.png"; e=png
  fi
  local in=$(mk_src "$src") raw=$src
  [[ $t == (jpg|png|heic|ico) ]] && { in="${in}[0]"; raw="${src}[0]"; }   # gif/tiff multipagina: primo fotogramma
  local -a o=(-auto-orient)
  case $t in
    jpg)       o+=(-background white -alpha remove -alpha off -quality 90) ;;
    webp|heic) o+=(-quality 85) ;;
    ico)       o=(-background none -resize 256x256 -gravity center -extent 256x256 -define icon:auto-resize=256,128,64,48,32,16) ;;
  esac
  # Se l'estensione non corrisponde al contenuto (capita con le foto scaricate), si riprova lasciando decidere a ImageMagick
  # (le regole di sicurezza bloccano comunque i formati pericolosi)
  if have magick && { magick "$in" $o "$out" 2>/dev/null || magick "$raw" $o "$out"; }; then return 0; fi
  # 3.8 · Senza ImageMagick: WebP e ICO con l'ffmpeg che viaggia dentro l'app (macOS legge già tutto il resto)
  if [[ $t == (webp|ico) ]] && have ffmpeg; then
    local png="$JD/_ff.png"
    sips -s format png "$src" --out "$png" >&2 || return 1
    if [[ $t == webp ]]; then
      ffmpeg -nostdin -hide_banner -loglevel error -y -i "$png" -c:v libwebp -quality 85 -compression_level 5 "$out" && return 0
    else
      ffmpeg -nostdin -hide_banner -loglevel error -y -i "$png" \
        -vf "scale=256:256:force_original_aspect_ratio=decrease,pad=256:256:(ow-iw)/2:(oh-ih)/2:color=0x00000000,format=rgba" "$out" && return 0
    fi
    return 1
  fi
  local f
  case $t in jpg) f=jpeg ;; png|tiff|heic|pdf) f=$t ;; *) return 1 ;; esac
  sips -s format $f "$src" --out "$out" >&2
}

resize_run() {  # sorgente, preset (half | 3840 | 1920 | 1280 | web)
  local src=$1 p=$2 e=$(norm "${1:e}") base=${1:t:r}
  local t=$e in=$src raw=0
  (( ${RAW_EXTS[(Ie)$e]} )) && raw=1
  [[ $p == web || $raw == 1 ]] && t=jpg
  [[ $t == (ico|bmp) ]] && t=png
  local suffix geo
  case $p in
    half) suffix="50%"; geo="50%" ;;
    web)  suffix="web"; geo="1600x1600>" ;;
    *)    suffix="${p}px"; geo="${p}x${p}>" ;;
  esac
  local out="$JD/out/$base ($suffix).$t"
  if (( raw )); then
    sips -s format png "$src" --out "$JD/_raw.png" >&2 || return 1
    in="$JD/_raw.png"
  fi
  if have magick; then
    local -a o=(-auto-orient -resize "$geo")
    [[ $e == gif && $t == gif ]] && o=(-coalesce -resize "$geo" -layers optimize)
    case $t in
      jpg)       o+=(-background white -alpha remove -alpha off -quality $([[ $p == web ]] && print 80 || print 88)) ;;
      webp|heic) o+=(-quality 85) ;;
    esac
    [[ $p == web ]] && o+=(-strip -interlace Plane)
    { magick "$(mk_src "$in")" $o "$out" 2>/dev/null || magick "$in" $o "$out"; } && return 0
  fi
  # Ripiego nativo (senza ImageMagick): non ingrandisce mai
  local w h f
  w=$(sips -g pixelWidth "$in" 2>/dev/null | awk '/pixelWidth/ {print $2}')
  h=$(sips -g pixelHeight "$in" 2>/dev/null | awk '/pixelHeight/ {print $2}')
  [[ $w == <-> && $h == <-> ]] || return 1
  case $t in jpg) f=jpeg ;; png|tiff|heic|gif) f=$t ;; *) f=png; out="${out:r}.png" ;; esac
  local -a z=()
  if [[ $p == half ]]; then z=(-z $(( h / 2 )) $(( w / 2 )))
  else
    local m=${p/web/1600}
    (( (w > h ? w : h) > m )) && z=(-Z $m)
  fi
  sips -s format $f $z "$in" --out "$out" >&2
}

strip_run() {  # sorgente → copia senza metadati
  local src=$1 e=$(norm "${1:e}") base=${1:t:r}
  local out="$JD/out/$base (senza metadati).${1:e}"
  case $(kind_of $e) in
    video|audio)
      local -a fs=(); [[ $e == (mp4|mov|m4v|m4a) ]] && fs=(-movflags +faststart)
      ffmpeg -nostdin -hide_banner -loglevel error -y -progress "$JOB_PROG" -nostats -i "$src" \
        -map '0:v?' -map '0:a?' -map_metadata -1 -map_chapters -1 -c copy -fflags +bitexact $fs "$out" ;;
    img)
      if have exiftool && [[ $e == (jpg|png|tiff|webp) ]]; then
        cp -- "$src" "$out" && exiftool -q -all= --icc_profile:all -tagsfromfile @ -Orientation -overwrite_original "$out" && return 0
        rm -f -- "$out"
      fi
      have magick || { print "LRERR: per questo formato serve ImageMagick" >&2; return 1 }
      local -a o=(-auto-orient -strip)
      [[ $e == jpg ]] && o+=(-quality 95)
      [[ $e == (heic|webp) ]] && o+=(-quality 90)
      magick "$(mk_src "$src")" $o "$out" 2>/dev/null || magick "$src" $o "$out" ;;
    *) return 1 ;;
  esac
}

pdfimg_run() {  # pdf, formato → un'immagine per pagina
  local src=$1 t=$2 base=${1:t:r}
  if [[ -x $HELPER ]]; then
    "$HELPER" pdf2img "$src" "$JD/pages" $t 200 "$base" > "$JOB_PROG" || return 1
    local -a pages=("$JD/pages"/*(N))
    (( $#pages )) || return 1
    if (( $#pages == 1 )); then mv -f -- "$pages[1]" "$JD/out/$base.$t"
    else mv -f -- "$JD/pages" "$JD/out/$base (pagine)"
    fi
    return 0
  fi
  # Ripiego: solo la prima pagina, con l'anteprima di macOS
  local png="$JD/${src:t}.png"
  qlmanage -t -s 2400 -o "$JD" "$src" >&2
  [[ -s $png ]] || return 1
  if [[ $t == png ]]; then mv -f -- "$png" "$JD/out/$base.png"
  else sips -s format jpeg -s formatOptions 90 "$png" --out "$JD/out/$base.jpg" >&2
  fi
}

pdfc_run() {  # pdf, livello (light | medium | strong)
  local src=$1 base=${1:t:r} set
  case $2 in light) set=/printer ;; strong) set=/screen ;; *) set=/ebook ;; esac
  local out="$JD/out/$base (compresso).pdf"
  gs -q -dNOPAUSE -dBATCH -dSAFER -sDEVICE=pdfwrite -dCompatibilityLevel=1.6 -dPDFSETTINGS=$set \
     -dDetectDuplicateImages=true -dAutoRotatePages=/None "-sOutputFile=$out" "$src" || return 1
  local a=$(stat -f %z "$src") b=$(stat -f %z "$out")
  if (( b >= a * 97 / 100 )); then
    rm -f -- "$out"
    print "LRNOTE: «${src:t}» era già compresso al massimo" >&2
    return 0
  fi
  print "LRINFO: da $(hsize $a) a $(hsize $b)" >&2
}

probe() {  # v|a, file → codec del primo flusso
  ffprobe -v error -select_streams $1:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$2" 2>/dev/null | head -n 1
}

# 4.1.5 · has_enc è definita una volta sola, in alto (con la memoria: un controllo per codificatore)

acodec_for() {  # estensione → opzioni del codec audio (con alternative se ffmpeg non ha quello preferito)
  case $1 in
    mp3)     print -- "-c:a libmp3lame -q:a 2" ;;
    wav)     print -- "-c:a pcm_s16le" ;;
    aiff)    print -- "-c:a pcm_s16be" ;;
    flac)    print -- "-c:a flac" ;;
    ogg)
      if has_enc libvorbis; then print -- "-c:a libvorbis -q:a 5"
      elif has_enc libopus; then print -- "-c:a libopus -b:a 160k"        # Opus in contenitore .ogg
      else print -- "-c:a vorbis -strict -2 -ac 2 -q:a 5"                 # codificatore interno di ffmpeg
      fi ;;
    opus)
      if has_enc libopus; then print -- "-c:a libopus -b:a 128k"
      else print -- "-c:a opus -strict -2 -ar 48000 -ac 2 -b:a 128k"
      fi ;;
    *)       print -- "-c:a aac -b:a 192k" ;;
  esac
}

av_run() {  # sorgente, formato, uscita
  local src=$1 t=$2 out=$3
  local -a ff=(ffmpeg -nostdin -hide_banner -loglevel error -y -progress "$JOB_PROG" -nostats -i "$src" -map_metadata 0)
  local -a fs=(); [[ $t == (mp4|mov|m4a) ]] && fs=(-movflags +faststart)
  local ac=$(probe a "$src") vc

  # Copertina dell'album: resta nei formati che la supportano (MP3, M4A, FLAC)
  local -a cover=()
  if [[ $(kind_of $(norm "${src:e}")) == audio && $t == (mp3|m4a|flac) && -n $(probe v "$src") ]]; then
    cover=(-map 0:a:0 -map 0:v:0 -c:v copy -disposition:v:0 attached_pic)
    [[ $t == mp3 ]] && cover+=(-id3v2_version 3)
  fi

  # Solo audio: se il codec è già quello giusto, copia senza ricodificare
  case $t:$ac in
    mp3:mp3|m4a:aac|m4a:alac|flac:flac|ogg:vorbis|ogg:opus)
      if (( $#cover )); then $ff $cover -c:a copy $fs "$out" && return 0; fi
      $ff -vn -c:a copy $fs "$out" && return 0 ;;
  esac

  case $t in
    mp3|m4a|wav|flac|ogg)
      if (( $#cover )); then $ff $cover ${=$(acodec_for $t)} $fs "$out" && return 0; fi
      $ff -vn ${=$(acodec_for $t)} $fs "$out" ;;
    gif)
      $ff -an -vf "fps=12,scale='min(720,iw)':-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" "$out" ;;
    webm)
      vc=$(probe v "$src")
      if [[ $vc == (vp8|vp9|av1) && $ac == (opus|vorbis|) ]]; then
        $ff -map 0:v:0 -map '0:a:0?' -c copy "$out" && return 0
      fi
      $ff -map 0:v:0 -map '0:a:0?' -c:v libvpx-vp9 -crf 32 -b:v 0 -row-mt 1 -deadline good -cpu-used 4 \
          -c:a libopus -b:a 128k "$out" ;;
    mp4|mov|mkv)
      vc=$(probe v "$src")
      local -a m=(-map 0:v:0 -map '0:a:0?')
      local -a tag=(); [[ $vc == hevc && $t != mkv ]] && tag=(-tag:v hvc1)
      # 1) Solo cambio di contenitore: pochi secondi anche per video lunghi
      if [[ $t == mkv || ( $vc == (h264|hevc|mpeg4) && $ac == (aac|mp3|ac3|eac3|alac|) ) ]]; then
        $ff $m -c copy $tag $fs "$out" && return 0
      fi
      local -a aud=(-c:a aac -b:a 192k); [[ $ac == aac ]] && aud=(-c:a copy)
      # 2) Codifica hardware Apple Silicon
      if [[ $ARCH == arm64 ]]; then
        $ff $m -c:v h264_videotoolbox -q:v 65 -pix_fmt yuv420p $aud $fs "$out" && return 0
      fi
      # 3) Codifica software
      $ff $m ${=$(enc264 20)} -pix_fmt yuv420p $aud $fs "$out" ;;
    *) return 1 ;;
  esac
}

vcompress_run() {  # video, MB massimi (oppure «best» = stessa qualità, meno peso)
  [[ $2 == best ]] && { vresize_run "$1" hevc; return }
  local src=$1 mb=$2 base=${1:t:r}
  local out="$JD/out/$base ($mb MB).mp4"
  local size=$(stat -f %z "$src")
  if (( size <= mb * 1048576 )); then
    print "LRNOTE: «${src:t}» pesa già meno di $mb MB" >&2
    return 0
  fi
  local dur=$(media_dur "$src")
  [[ -n $dur ]] || { print "LRERR: non riesco a leggere la durata del video" >&2; return 1 }
  integer abps=128000 vbps W limit
  (( mb <= 10 )) && abps=64000
  (( vbps = mb * 8388608 * 0.92 / dur - abps ))
  if (( vbps < 100000 )); then
    print "LRERR: il video è troppo lungo per stare in $mb MB: scegli un peso maggiore o taglialo prima" >&2
    return 1
  fi
  if (( vbps < 700000 )); then W=854; elif (( vbps < 1800000 )); then W=1280; elif (( vbps < 4500000 )); then W=1920; else W=3840; fi
  local vf="scale='if(gt(iw,ih),trunc(min($W,iw)/2)*2,-2)':'if(gt(iw,ih),-2,trunc(min($W,ih)/2)*2)'"
  local -a ff=(ffmpeg -nostdin -hide_banner -loglevel error -y -progress "$JOB_PROG" -nostats -i "$src"
               -map 0:v:0 -map '0:a:0?' -map_metadata 0 -vf "$vf" -pix_fmt yuv420p)
  local -a a=(-c:a aac -b:a $abps -movflags +faststart)
  (( limit = mb * 1048576 ))
  local first=0 got=0
  if [[ $ARCH == arm64 ]] && $ff -c:v h264_videotoolbox -b:v $vbps $a "$out"; then
    first=$(stat -f %z "$out")
    if (( first <= limit )); then
      print "LRINFO: da $(hsize $size) a $(hsize $first)" >&2
      return 0
    fi
    # 4.1.5 · Troppo grande: il secondo giro chiede meno, in proporzione a quanto ha sforato
    (( vbps = vbps * limit / first * 92 / 100 ))
  fi
  if has_enc libx264; then
    $ff -c:v libx264 -preset medium -b:v $vbps -maxrate $(( vbps * 3 / 2 )) -bufsize $(( vbps * 2 )) $a "$out" || return 1
  else
    $ff -c:v h264_videotoolbox -allow_sw 1 -b:v $vbps $a "$out" || return 1
  fi
  got=$(stat -f %z "$out")
  # 4.1.5 · Mai «riuscito» sopra il limite scelto
  if (( got > limit )); then
    rm -f -- "$out"
    print "LRERR: non riesco a farlo stare sotto $mb MB (verrebbe $(hsize $got)): scegli un peso maggiore o taglialo prima" >&2
    return 1
  fi
  print "LRINFO: da $(hsize $size) a $(hsize $got)" >&2
}

vresize_run() {  # video, preset (1080 | 720 | 480 | hevc)
  local src=$1 p=$2 base=${1:t:r} out vf
  local -a ff=(ffmpeg -nostdin -hide_banner -loglevel error -y -progress "$JOB_PROG" -nostats -i "$src"
               -map 0:v:0 -map '0:a:0?' -map_metadata 0)
  local -a a=(-c:a aac -b:a 160k -movflags +faststart)
  if [[ $p == hevc ]]; then
    out="$JD/out/$base (HEVC).mp4"
    if [[ $ARCH == arm64 ]]; then $ff -c:v hevc_videotoolbox -q:v 60 -tag:v hvc1 $a "$out" && return 0; fi
    if has_enc libx265; then $ff -c:v libx265 -preset medium -crf 26 -tag:v hvc1 -pix_fmt yuv420p $a "$out"
    else $ff -c:v hevc_videotoolbox -allow_sw 1 -b:v 6M -tag:v hvc1 $a "$out"; fi
    return
  fi
  # Il lato corto diventa 1080/720/480 (vale anche per i video verticali); mai ingrandire
  vf="scale='if(gt(iw,ih),-2,trunc(min($p,iw)/2)*2)':'if(gt(iw,ih),trunc(min($p,ih)/2)*2,-2)'"
  out="$JD/out/$base (${p}p).mp4"
  if [[ $ARCH == arm64 ]]; then
    $ff -vf "$vf" -c:v h264_videotoolbox -q:v 62 -pix_fmt yuv420p $a "$out" && return 0
  fi
  $ff -vf "$vf" ${=$(enc264 21)} -pix_fmt yuv420p $a "$out"
}

silence_run() {  # audio → senza le pause lunghe
  local src=$1 e=$(norm "${1:e}") base=${1:t:r} oe=${1:e}
  [[ $e == (wma|aac) ]] && oe=m4a
  local af="silenceremove=start_periods=1:start_duration=0.2:start_threshold=-45dB:stop_periods=-1:stop_duration=0.7:stop_threshold=-45dB"
  ffmpeg -nostdin -hide_banner -loglevel error -y -progress "$JOB_PROG" -nostats -i "$src" -map_metadata 0 \
         -map 0:a:0 -af "$af" ${=$(acodec_for $(norm $oe))} "$JD/out/$base (senza silenzi).$oe"
}

speed_run() {  # audio o video, velocità (0.5 · 0.75 · 1.25 · 1.5 · 2)
  local src=$1 sp=$2 e=$(norm "${1:e}") base=${1:t:r}
  local k=$(kind_of $e) lbl="${2/./,}x"
  local -a ff=(ffmpeg -nostdin -hide_banner -loglevel error -y -progress "$JOB_PROG" -nostats -i "$src" -map_metadata 0)
  if [[ $k == audio ]]; then
    local oe=${1:e}; [[ $e == (wma|aac) ]] && oe=m4a
    $ff -map 0:a:0 -af "atempo=$sp" ${=$(acodec_for $(norm $oe))} "$JD/out/$base (velocità $lbl).$oe"
    return
  fi
  local out="$JD/out/$base (velocità $lbl).mp4"
  local -a fc
  if [[ -n $(probe a "$src") ]]; then fc=(-filter_complex "[0:v:0]setpts=PTS/$sp[v];[0:a:0]atempo=$sp[a]" -map "[v]" -map "[a]")
  else fc=(-map 0:v:0 -vf "setpts=PTS/$sp")
  fi
  local -a a=(-c:a aac -b:a 160k -movflags +faststart)
  if [[ $ARCH == arm64 ]]; then
    $ff $fc -c:v h264_videotoolbox -q:v 62 -pix_fmt yuv420p $a "$out" && return 0
  fi
  $ff $fc ${=$(enc264 21)} -pix_fmt yuv420p $a "$out"
}

cut_run() {  # sorgente, inizio, fine ("" = fino alla fine), modo (cut | gif)
  local src=$1 s=$2 en=$3 mode=$4 e=$(norm "${1:e}") base=${1:t:r} out oe
  local k=$(kind_of $e)
  local -a tt=(); [[ -n $en ]] && tt=(-t "$(printf '%.3f' $(( en - s )))")
  local -a ff=(ffmpeg -nostdin -hide_banner -loglevel error -y -progress "$JOB_PROG" -nostats -ss $s -i "$src" $tt -map_metadata 0)
  if [[ $mode == gif ]]; then
    $ff -an -vf "fps=12,scale='min(720,iw)':-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" \
        "$JD/out/$base (pezzo).gif"
    return
  fi
  if [[ $k == audio ]]; then
    oe=${1:e}; [[ $e == wma ]] && oe=mp3
    out="$JD/out/$base (taglio).$oe"
    if [[ $e != wma ]]; then $ff -map 0:a -c copy "$out" && return 0; fi
    $ff -map 0:a ${=$(acodec_for $(norm $oe))} "$out"
    return
  fi
  oe=${1:e}; [[ $e == (mp4|mov|mkv|m4v) ]] || oe=mp4
  out="$JD/out/$base (taglio).$oe"
  local -a m=(-map 0:v:0 -map '0:a:0?') fs=()
  [[ $oe == (mp4|mov|m4v) ]] && fs=(-movflags +faststart)
  # 3.6 · Prima il taglio istantaneo senza ricodifica (secondi anche su un film); se non riesce, si ricodifica
  if [[ $oe == ${1:e} ]] && $ff $m -c copy $fs "$out" && [[ -s $out ]]; then return 0; fi
  if [[ $ARCH == arm64 ]]; then
    $ff $m -c:v h264_videotoolbox -q:v 65 -pix_fmt yuv420p -c:a aac -b:a 192k $fs "$out" && return 0
  fi
  $ff $m ${=$(enc264 20)} -pix_fmt yuv420p -c:a aac -b:a 192k $fs "$out"
}

norm_run() {  # sorgente [clean] → volume uniforme; con «clean» anche la voce ripulita (4.0)
  local src=$1 e=$(norm "${1:e}") base=${1:t:r} mode=${2:-}
  local k=$(kind_of $e) oe=${1:e} out
  # Voce più pulita: via il rombo sotto gli 80 Hz, il fruscio costante attenuato con delicatezza
  # (12 dB: di più la voce diventa metallica), poi il volume uniforme. Il video non si tocca.
  local chain="loudnorm=I=-16:TP=-1.5:LRA=11" tag="normalizzato"
  [[ $mode == clean ]] && { chain="highpass=f=80,afftdn=nr=12:nf=-35:tn=1,$chain"; tag="voce pulita" }
  local sr=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of default=nw=1:nk=1 "$src" 2>/dev/null | head -n 1)
  [[ -n $sr ]] || { print "LRERR: il file non contiene audio" >&2; return 1 }
  [[ $sr == <-> ]] || sr=48000
  (( sr > 48000 )) && sr=48000
  local -a ff=(ffmpeg -nostdin -hide_banner -loglevel error -y -progress "$JOB_PROG" -nostats -i "$src" -map_metadata 0)
  local -a af=(-af "$chain" -ar $sr)
  if [[ $k == audio ]]; then
    [[ $e == (wma|aac) ]] && oe=m4a
    [[ $e == (ogg|opus) ]] && af=(-af "$chain" -ar 48000)
    $ff -map 0:a:0 $af ${=$(acodec_for $(norm $oe))} "$JD/out/$base ($tag).$oe"
    return
  fi
  [[ $e == (mp4|mov|mkv|m4v) ]] || oe=mp4
  local -a fs=(); [[ $oe == (mp4|mov|m4v) ]] && fs=(-movflags +faststart)
  out="$JD/out/$base ($tag).$oe"
  $ff -map 0:v:0 -map 0:a:0 -c:v copy $af -c:a aac -b:a 192k $fs "$out" && return 0
  $ff -map 0:v:0 -map 0:a:0 ${=$(enc264 20)} -pix_fmt yuv420p $af -c:a aac -b:a 192k $fs "$out"
}

transcribe_run() {  # audio o video → testo + sottotitoli
  local src=$1 base=${1:t:r} wb model=$(model_path)
  wb=$(whisper_bin) || { print "LRERR: Whisper non è installato" >&2; return 1 }
  [[ -s $model ]] || { print "LRERR: manca il modello di trascrizione" >&2; return 1 }
  ffmpeg -nostdin -hide_banner -loglevel error -y -progress "$JOB_PROG" -nostats -i "$src" \
         -vn -ac 1 -ar 16000 -c:a pcm_s16le "$JD/audio.wav" || return 1
  local th=$NCPU; (( th > 8 )) && th=8
  $wb -m "$model" -f "$JD/audio.wav" -l ${PREF[wlang]:-auto} -t $th -pp -otxt -osrt \
      -of "$JD/out/$base (trascrizione)" 2>"$JOB_PROG" >/dev/null
  local rc=$?
  cat "$JOB_PROG" >&2
  return $rc
}

subx_run() {  # video → un .srt per ogni traccia di sottotitoli testuale
  local src=$1 base=${1:t:r}
  local lines=$(ffprobe -v error -select_streams s -show_entries stream=codec_name:stream_tags=language -of csv=p=0 "$src" 2>/dev/null)
  [[ -n $lines ]] || { print "LRERR: il video non contiene sottotitoli" >&2; return 1 }
  local -a L=("${(@f)lines}")
  local i=0 n=0 line c l name
  for line in $L; do
    c=${line%%,*}; l=${line#*,}; [[ $l == $line ]] && l=""
    if [[ $c == (subrip|srt|ass|ssa|mov_text|webvtt|text) ]]; then
      if (( $#L == 1 )); then name=$base; else name="$base.$(( i + 1 ))${l:+.$l}"; fi
      ffmpeg -nostdin -hide_banner -loglevel error -y -i "$src" -map 0:s:$i -c:s srt "$JD/out/$name.srt" && (( n += 1 ))
    fi
    (( i += 1 ))
  done
  (( n > 0 )) || { print "LRERR: i sottotitoli di questo video sono immagini (es. Blu-ray), non convertibili in testo" >&2; return 1 }
  return 0
}

sube_run() {  # video, srt → video con sottotitoli selezionabili
  local src=$1 srt=$2 e=$(norm "${1:e}") base=${1:t:r}
  local oe=${1:e} sc=mov_text
  if [[ $e == mkv ]]; then sc=srt
  elif [[ $e != (mp4|mov|m4v) ]]; then oe=mkv; sc=srt
  fi
  local -a fs=(); [[ $oe == (mp4|mov|m4v) ]] && fs=(-movflags +faststart)
  local out="$JD/out/$base (con sottotitoli).$oe"
  local enc
  for enc in UTF-8 CP1252; do   # molti .srt italiani non sono in UTF-8
    ffmpeg -nostdin -hide_banner -loglevel error -y -progress "$JOB_PROG" -nostats -i "$src" -sub_charenc $enc -i "$srt" \
      -map 0:v -map '0:a?' -map 1:0 -c:v copy -c:a copy -c:s $sc -disposition:s:0 default $fs "$out" && return 0
  done
  return 1
}

conv_job() {  # conversione di formato
  local j=$1
  local src=${J_SRC[j]} t=${J_ACT[j]#to:} k=${J_KIND[j]} base=${J_SRC[j]:t:r}
  local out="$JD/out/$base.$t" dest=${J_DEST[j]}
  case ${J_ROUTE[j]} in
    textutil)
      local -a enc=(); [[ $t == (txt|html) ]] && enc=(-encoding UTF-8)
      textutil -convert $t $enc -output "$out" "$src" >&2 ;;
    pandoc)    pandoc_run "$src" $t "$out" "$dest" ;;
    lo+pandoc) lo_run "$JD" $k docx "$src" && pandoc_run "$JD/$base.docx" md "$out" "$dest" ;;
    pandoc+lo) pandoc_run "$src" docx "$JD/_tmp.docx" "$dest" && lo_run "$JD" doc pdf "$JD/_tmp.docx" \
                 && mv -f -- "$JD/_tmp.pdf" "$out" ;;
    lo)        lo_run "$JD" $k $t "$src" && mv -f -- "$JD/$base.$t" "$out" ;;
    img)       img_run "$src" $t "$out" ;;
    pdfimg)    pdfimg_run "$src" $t ;;
    av)        av_run "$src" $t "$out" ;;
    *)         return 1 ;;
  esac
}

run_job() {
  local j=$1
  local src=${J_SRC[j]} p=${J_PARAM[j]} base=${J_SRC[j]:t:r}
  case ${J_ACT[j]} in
    to:*)        conv_job $j ;;
    resize)      resize_run "$src" "$p" ;;
    strip)       strip_run "$src" ;;
    ocr)         "$HELPER" ocr "$src" "$JD/out/$base (testo).txt" "$(ocr_langs)" > "$JOB_PROG" ;;
    pdftext)     "$HELPER" text "$src" "$JD/out/$base.txt" "$(ocr_langs)" > "$JOB_PROG" ;;
    merge)       "$HELPER" merge "$JD/out/PDF unito.pdf" "${(@f)$(<"$JD/inputs")}" > "$JOB_PROG" ;;
    split)       "$HELPER" split "$src" "$JD/out/$base (pagine)" "$base" > "$JOB_PROG" ;;
    extract)     "$HELPER" extract "$src" "$JD/out/$base (pagine $p).pdf" "$p" > "$JOB_PROG" ;;
    pdfcompress) pdfc_run "$src" "$p" ;;
    vcompress)   vcompress_run "$src" "$p" ;;
    cut)         cut_run "$src" "${p%%|*}" "${p#*|}" cut ;;
    gifcut)      cut_run "$src" "${p%%|*}" "${p#*|}" gif ;;
    normalize)   norm_run "$src" ;;
    voiceclean)  norm_run "$src" clean ;;
    transcribe)  transcribe_run "$src" ;;
    subextract)  subx_run "$src" ;;
    subembed)
      [[ -n $p ]] || { print "LRERR: non ho trovato un file .srt con lo stesso nome del video (selezionali insieme)" >&2; return 1 }
      sube_run "$src" "$p" ;;
    vresize)     vresize_run "$src" "$p" ;;
    silence)     silence_run "$src" ;;
    speed)       speed_run "$src" "$p" ;;
    rotate)      "$HELPER" rotate "$src" "$JD/out/$base (ruotato).pdf" "$p" > "$JOB_PROG" ;;
    reorder)     "$HELPER" reorder "$src" "$JD/out/$base (riordinato).pdf" "$p" > "$JOB_PROG" ;;
    protect)     LR_PW="$p" "$HELPER" protect "$src" "$JD/out/$base (protetto).pdf" - > "$JOB_PROG" ;;
    unprotect)   LR_PW="$p" "$HELPER" unprotect "$src" "$JD/out/$base (sbloccato).pdf" - > "$JOB_PROG" ;;
    *) return 1 ;;
  esac
}

explain() {  # file degli errori, codice → motivo comprensibile
  local f=$1 rc=$2 l txt
  l=$(grep -a '^LRERR: ' "$f" 2>/dev/null | tail -n 1)
  if [[ -n $l ]]; then print -r -- "${l#LRERR: }"; return; fi
  if (( rc == 137 )); then print "ci ha messo troppo ed è stato interrotto"; return; fi
  if (( rc == 127 )); then print "manca un programma necessario (vedi il log)"; return; fi
  txt=$(tail -n 40 "$f" 2>/dev/null)
  case $txt in
    *"No space left"*)                                   print "spazio su disco esaurito" ;;
    *"Operation not permitted"*|*"Permission denied"*)   print "macOS non ha dato il permesso di leggere o scrivere in quella cartella" ;;
    *"Resource deadlock"*|*dataless*)                    print "il file è su iCloud ma non è scaricato sul Mac: aprilo una volta e riprova" ;;
    *[Pp]assword*|*[Ee]ncrypted*)                        print "il file è protetto da password" ;;
    *"Invalid data found"*|*"moov atom not found"*|*"could not find codec"*|*"no decode delegate"*|*"improper image header"*|*corrupt*)
                                                         print "il file sembra danneggiato o in un formato non riconosciuto" ;;
    *"matches no streams"*|*"does not contain any stream"*) print "nel file manca la traccia audio o video necessaria" ;;
    *"Unknown encoder"*|*"Encoder not found"*)           print "la versione installata di ffmpeg non supporta questo formato" ;;
    *)
      l=$(print -r -- "$txt" | grep -av '^[[:space:]]*$' | tail -n 1)
      if [[ -n $l ]]; then print -r -- "${l[1,160]}"; else print "errore sconosciuto (dettagli nel log)"; fi ;;
  esac
}

# ─── Lavori ──────────────────────────────────────────────────────────

typeset -a J_ACT J_SRC J_KIND J_EXT J_PARAM J_DEST J_ROUTE J_RC
typeset -a F_SRC F_KIND F_EXT ORDER SRTS

add_job() {  # azione, sorgente, tipo, estensione, parametro, motore
  J_ACT+=("$1"); J_SRC+=("$2"); J_KIND+=("$3"); J_EXT+=("$4"); J_PARAM+=("$5"); J_ROUTE+=("$6")
  J_DEST+=("$(dest_dir "${2:h}")")
  mkdir -p "$WORK/j$#J_ACT/out"
}

find_srt() {  # video → percorso del .srt da usare
  local v=$1 b=${(L)1:t:r} s
  for s in $SRTS; do
    [[ ${(L)s:t:r} == "$b" || ${(L)s:t:r} == "$b".* ]] && { print -r -- $s; return 0 }
  done
  if (( $#SRTS == 1 && VIDEOS == 1 )); then print -r -- $SRTS[1]; return 0; fi
  for s in "${v:r}".srt(N) "${v:r}".*.srt(N); do print -r -- $s; return 0; done
  return 1
}

# ─── Controllo automatico: zsh LRConverter.zsh --test ────────────────
#  Crea file di prova e prova davvero ogni operazione, con gli stessi motori dell'uso normale.

st() {  # tipo, etichetta, azione, file, [parametro]
  local k=$1 lbl=$2 act=$3 f=$4 p=$5 r d rc secs t0 note e
  local -a miss=()
  if [[ ! -e $f ]]; then print -r -- "  ⏭️  $lbl — file di prova non disponibile"; (( T_SKIP += 1 )); return 0; fi
  e=$(norm "${f:e}")
  if [[ $act == to:* ]]; then r=$(route $k $e ${act#to:}); else r=$act; fi
  for d in ${=$(needs $r $k)}; do dep_ok $d || miss+=("${INSTALL[$d]%%:*}"); done
  if [[ $act == strip && $k == img ]] && ! have magick && ! have exiftool; then miss+=(ImageMagick); fi
  if (( $#miss )); then print -r -- "  ⏭️  $lbl — manca ${(j:, :)${(u)miss}}"; (( T_SKIP += 1 )); return 0; fi
  add_job "$act" "$f" $k $e "$p" "$r"
  local jj=$#J_ACT
  JD="$WORK/j$jj"; JOB_PROG="$JD/prog"; JOB_DUR=""; : > "$JOB_PROG"
  [[ $act == merge ]] && print -rl -- "$T_DIR/prova.pdf" "$T_DIR/prova.png" > "$JD/inputs"
  t0=$SECONDS
  monitored run_job $jj 2>>"$JD/err"
  rc=$?
  secs=$(( SECONDS - t0 ))
  local -a items=("$JD/out"/*(N))
  { print -r -- "[$(date '+%F %T')] [test] $lbl → codice $rc"; cat "$JD/err" } >> "$LOG"
  note=$(grep -a '^LRNOTE: ' "$JD/err" 2>/dev/null | tail -n 1)
  if (( rc == 0 && $#items )); then
    print -r -- "  ✅ $lbl  (${secs} s)"; (( T_PASS += 1 ))
  elif (( rc == 0 )) && [[ -n $note ]]; then
    print -r -- "  ✅ $lbl — ${note#LRNOTE: }"; (( T_PASS += 1 ))
  else
    print -r -- "  ❌ $lbl — $(explain "$JD/err" $rc)"; (( T_FAIL += 1 ))
  fi
  return 0
}

selftest() {
  SELFTEST=1
  T_PASS=0; T_FAIL=0; T_SKIP=0
  T_DIR="$WORK/prova"; mkdir -p "$T_DIR"
  lo_acquire
  PREF[dest]=same                     # solo per il test, non viene salvato
  local x T=$T_DIR t0=$SECONDS ocr_ok=0
  print -r -- ""
  print -r -- "LRConverter — controllo automatico"
  print -r -- "══════════════════════════════════"
  print -r -- ""
  print -r -- "Programmi:"
  for x in ffmpeg ffprobe magick soffice pandoc gs exiftool whisper-cli rsvg-convert swiftc; do
    if have $x; then print -r -- "  ✅ $x"; else print -r -- "  ⬜ $x non trovato"; fi
  done
  print -r -- ""
  print -r -- "Programma nativo (la prima volta ci vuole circa un minuto)…"
  if helper_ok; then print -r -- "  ✅ pronto"
  else
    print -r -- "  ❌ non sono riuscito a prepararlo. Ultime righe del log:"
    tail -n 12 "$LOG" | sed 's/^/     /'
  fi
  print -r -- ""
  print -r -- "Creo i file di prova…"
  {
    print -r -- '<html><head><meta charset="utf-8"></head><body><h1>Prova LRConverter</h1><p>Documento di prova con lettere accentate: àèéìòù.</p><p>Numero di controllo 12345.</p></body></html>' > "$T/prova.html"
    textutil -convert docx "$T/prova.html" -output "$T/prova.docx"
    textutil -convert txt "$T/prova.html" -output "$T/prova.txt"
    print -r -- $'# Titolo di prova\n\nTesto in **grassetto** e una lista:\n\n- uno\n- due' > "$T/prova.md"
    print -r -- $'nome,città,numero\nAnna,Roma,1\nLuca,Milano,2' > "$T/prova.csv"
    print -r -- $'1\n00:00:00,500 --> 00:00:02,500\nCiao, questa è una prova.\n\n2\n00:00:03,000 --> 00:00:05,000\nSecondo sottotitolo.\n' > "$T/prova.srt"
    cupsfilter "$T/prova.txt" > "$T/prova.pdf"
    if [[ ! -s $T/prova.pdf ]]; then
      rm -f -- "$T/prova.pdf"
      have soffice && soffice --headless "-env:UserInstallation=$LO_PROFILE" --convert-to pdf --outdir "$T" "$T/prova.docx"
    fi
    if [[ -x $HELPER && -s $T/prova.pdf ]]; then
      "$HELPER" pdf2img "$T/prova.pdf" "$T/pag" png 150 prova && mv -f -- "$T/pag/prova.png" "$T/prova.png" && ocr_ok=1
    fi
    if have ffmpeg; then
      ffmpeg -nostdin -loglevel error -y -f lavfi -i "sine=frequency=440:duration=6" -c:a libmp3lame -q:a 4 "$T/prova.mp3"
      ffmpeg -nostdin -loglevel error -y -f lavfi -i "testsrc2=size=640x360:rate=25:duration=6" \
             -f lavfi -i "sine=frequency=660:duration=6" ${=$(enc264 23 2M)} -pix_fmt yuv420p -c:a aac -shortest "$T/prova.mp4"
      ffmpeg -nostdin -loglevel error -y -i "$T/prova.mp4" -i "$T/prova.srt" -map 0 -map 1 -c copy -c:s srt "$T/prova-sottotitoli.mkv"
      [[ -s $T/prova.png ]] || ffmpeg -nostdin -loglevel error -y -f lavfi -i "testsrc2=size=800x600" -frames:v 1 "$T/prova.png"
    fi
    [[ -s $T/prova.png ]] && sips -s format jpeg "$T/prova.png" --out "$T/prova.jpg"
  } >>"$LOG" 2>&1

  print -r -- ""; print -r -- "Audio:"
  st audio "MP3 → WAV"                 to:wav      "$T/prova.mp3"
  st audio "MP3 → M4A"                 to:m4a      "$T/prova.mp3"
  st audio "MP3 → FLAC"                to:flac     "$T/prova.mp3"
  st audio "MP3 → OGG"                 to:ogg      "$T/prova.mp3"
  st audio "Taglia"                    cut         "$T/prova.mp3" "1.000|3.000"
  st audio "Normalizza il volume"      normalize   "$T/prova.mp3"
  st audio "Voce più pulita"           voiceclean  "$T/prova.mp3"
  st audio "Togli i silenzi"           silence     "$T/prova.mp3"
  st audio "Velocità 1,5×"             speed       "$T/prova.mp3" 1.5
  if [[ -s $(model_path) ]]; then st audio "Trascrivi" transcribe "$T/prova.mp3"
  else print -r -- "  ⏭️  Trascrivi — il modello si scarica al primo utilizzo dal menu"; (( T_SKIP += 1 ))
  fi

  print -r -- ""; print -r -- "Video:"
  st video "MP4 → MOV"                 to:mov      "$T/prova.mp4"
  st video "MP4 → MKV"                 to:mkv      "$T/prova.mp4"
  st video "MP4 → WEBM"                to:webm     "$T/prova.mp4"
  st video "MP4 → GIF"                 to:gif      "$T/prova.mp4"
  st video "MP4 → MP3 (solo audio)"    to:mp3      "$T/prova.mp4"
  st video "Comprimi (1 MB)"           vcompress   "$T/prova.mp4" 1
  st video "Taglia"                    cut         "$T/prova.mp4" "1.000|4.000"
  st video "GIF da un pezzo"           gifcut      "$T/prova.mp4" "0.000|2.000"
  st video "Normalizza il volume"      normalize   "$T/prova.mp4"
  st video "Voce più pulita"           voiceclean  "$T/prova.mp4"
  st video "Rimuovi i metadati"        strip       "$T/prova.mp4"
  st video "Aggiungi sottotitoli"      subembed    "$T/prova.mp4" "$T/prova.srt"
  st video "Estrai sottotitoli"        subextract  "$T/prova-sottotitoli.mkv"
  st video "Risoluzione 480p"          vresize     "$T/prova.mp4" 480
  st video "HEVC"                      vresize     "$T/prova.mp4" hevc
  st video "Velocità 2×"               speed       "$T/prova.mp4" 2

  print -r -- ""; print -r -- "Immagini:"
  st img "PNG → JPG"                   to:jpg      "$T/prova.png"
  st img "PNG → WEBP"                  to:webp     "$T/prova.png"
  st img "PNG → HEIC"                  to:heic     "$T/prova.png"
  st img "PNG → TIFF"                  to:tiff     "$T/prova.png"
  st img "PNG → PDF"                   to:pdf      "$T/prova.png"
  st img "PNG → ICO"                   to:ico      "$T/prova.png"
  st img "JPG → PNG"                   to:png      "$T/prova.jpg"
  st img "Ridimensiona (1280 px)"      resize      "$T/prova.png" 1280
  st img "Ridimensiona (metà)"         resize      "$T/prova.png" half
  st img "Ridimensiona (web)"          resize      "$T/prova.png" web
  st img "Rimuovi i metadati"          strip       "$T/prova.jpg"
  if (( ocr_ok )); then st img "Estrai il testo (OCR)" ocr "$T/prova.png"
  else print -r -- "  ⏭️  Estrai il testo (OCR) — serve il programma nativo"; (( T_SKIP += 1 ))
  fi

  print -r -- ""; print -r -- "PDF:"
  st pdf "PDF → PNG"                   to:png      "$T/prova.pdf"
  st pdf "PDF → JPG"                   to:jpg      "$T/prova.pdf"
  st pdf "PDF → DOCX"                  to:docx     "$T/prova.pdf"
  st pdf "Estrai il testo"             pdftext     "$T/prova.pdf"
  st pdf "Dividi in pagine"            split       "$T/prova.pdf"
  st pdf "Estrai pagine"               extract     "$T/prova.pdf" 1
  st pdf "Comprimi"                    pdfcompress "$T/prova.pdf" medium
  st pdf "Unisci PDF + immagine"       merge       "$T/prova.pdf"
  st pdf "Ruota le pagine"             rotate      "$T/prova.pdf" 90
  st pdf "Riordina le pagine"          reorder     "$T/prova.pdf" reverse
  st pdf "Proteggi con password"       protect     "$T/prova.pdf" prova123
  if [[ -x $HELPER && -s $T/prova.pdf ]]; then "$HELPER" protect "$T/prova.pdf" "$T/protetto.pdf" prova123 >/dev/null 2>&1; fi
  st pdf "Togli la password"           unprotect   "$T/protetto.pdf" prova123

  print -r -- ""; print -r -- "Documenti:"
  st doc   "DOCX → PDF"                to:pdf      "$T/prova.docx"
  st doc   "DOCX → ODT"                to:odt      "$T/prova.docx"
  st doc   "DOCX → TXT"                to:txt      "$T/prova.docx"
  st doc   "DOCX → HTML"               to:html     "$T/prova.docx"
  st doc   "DOCX → Markdown"           to:md       "$T/prova.docx"
  st text  "Markdown → DOCX"           to:docx     "$T/prova.md"
  st text  "Markdown → HTML"           to:html     "$T/prova.md"
  st text  "Markdown → PDF"            to:pdf      "$T/prova.md"
  st sheet "CSV → XLSX"                to:xlsx     "$T/prova.csv"
  st sheet "CSV → PDF"                 to:pdf      "$T/prova.csv"

  print -r -- ""
  print -r -- "Totale: $T_PASS riuscite · $T_FAIL non riuscite · $T_SKIP saltate   ($(( SECONDS - t0 )) s)"
  (( T_FAIL )) && print -r -- "Dettagli degli errori nel log: $LOG"
  print -r -- ""
}

# ─── Pacchetto per un altro Mac: zsh LRConverter.zsh --crea-installer ─

write_installer() {
  cat <<'INSTALL'
#!/bin/zsh
# ════════════════════════════════════════════════════════════════════
#  Installa LRConverter su questo Mac — fai doppio clic su questo file
# ════════════════════════════════════════════════════════════════════
cd "${0:A:h}" || exit 1
SUP="$HOME/Library/Application Support/LRConverter"
clear
print ""
print "  LRConverter — installazione"
print "  ═══════════════════════════"
print ""
print "  Ci vorranno alcuni minuti, quasi tutti di download."
print "  Quando ti viene chiesta la password del Mac, scrivila (non vedrai i caratteri) e premi Invio."
print ""

xattr -dr com.apple.quarantine . 2>/dev/null

# 1. Homebrew
brew_path() { [[ -x /opt/homebrew/bin/brew ]] && print /opt/homebrew/bin/brew || { [[ -x /usr/local/bin/brew ]] && print /usr/local/bin/brew } }
BREW=$(brew_path)
if [[ -z $BREW ]]; then
  print "  1/5  Installo Homebrew…"
  sudo -v || { print "  Password non accettata: riprova."; exit 1 }
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  BREW=$(brew_path)
  [[ -n $BREW ]] || { print "  ❌ Installazione di Homebrew non riuscita. Controlla la connessione e riprova."; exit 1 }
else
  print "  1/5  Homebrew è già installato ✅"
fi
eval "$($BREW shellenv)"
grep -q 'brew shellenv' ~/.zprofile 2>/dev/null || print "eval \"\$($BREW shellenv)\"" >> ~/.zprofile

# 2. Motori di conversione
print ""
print "  2/5  Installo i motori di conversione…"
for pkg in ffmpeg imagemagick ghostscript exiftool pandoc whisper-cpp; do
  if $BREW list --formula $pkg >/dev/null 2>&1; then print "       $pkg ✅ (già presente)"
  else print "       $pkg…"; $BREW install --quiet $pkg >/dev/null 2>&1 && print "       $pkg ✅" || print "       $pkg ⚠️  non installato (le funzioni che lo usano verranno saltate)"
  fi
done
if [[ -d /Applications/LibreOffice.app ]]; then print "       LibreOffice ✅ (già presente)"
else print "       LibreOffice…"; $BREW install --cask --quiet libreoffice >/dev/null 2>&1 && print "       LibreOffice ✅" || print "       LibreOffice ⚠️  non installato"
fi
xattr -dr com.apple.quarantine /Applications/LibreOffice.app 2>/dev/null

# 3. File di LRConverter
print ""
print "  3/5  Copio LRConverter…"
mkdir -p "$SUP" "$HOME/Library/Services"
cp -f LRConverter.zsh "$SUP/" || { print "  ❌ Non riesco a copiare lo script."; exit 1 }
rm -rf "$HOME/Library/Services/LRConverter.workflow"
cp -R LRConverter.workflow "$HOME/Library/Services/" || { print "  ❌ Non riesco a copiare l'Azione rapida."; exit 1 }
xattr -dr com.apple.quarantine "$SUP" "$HOME/Library/Services/LRConverter.workflow" 2>/dev/null
/System/Library/CoreServices/pbs -update 2>/dev/null

# 4-5. Programma nativo e controllo automatico
print ""
print "  4/5  Preparo il programma nativo e provo tutte le funzioni…"
zsh "$SUP/LRConverter.zsh" --test

print "  5/5  Fatto! 🎉"
print ""
print "  Nel Finder: tasto destro su un file → Azioni rapide → LRConverter."
print "  Se non lo vedi subito, scegli «Personalizza…» in quel menu e attivalo."
print ""
INSTALL
}

make_installer() {
  local wf="$HOME/Library/Services/LRConverter.workflow"
  local dir="$HOME/Desktop/LRConverter Installer" zip="$HOME/Desktop/LRConverter Installer.zip"
  print ""
  if [[ ! -d $wf ]]; then print "❌ Non trovo l'Azione rapida in $wf"; return 1; fi
  rm -rf -- "$dir" "$zip"
  mkdir -p "$dir" || return 1
  cp -R "$wf" "$dir/" && cp -f "$SCRIPT_PATH" "$dir/LRConverter.zsh" || { print "❌ Copia non riuscita"; return 1 }
  write_installer > "$dir/Installa.command"
  chmod +x "$dir/Installa.command" "$dir/LRConverter.zsh"
  ditto -c -k --keepParent "$dir" "$zip" || { print "❌ Non riesco a creare lo zip"; return 1 }
  rm -rf -- "$dir"
  print "✅ Creato sulla Scrivania: «LRConverter Installer.zip»"
  print ""
  print "Sull'altro Mac: apri lo zip, poi fai doppio clic su «Installa.command»."
  print ""
}

if [[ $1 == --test ]]; then selftest; exit 0; fi
if [[ $1 == --crea-installer ]]; then make_installer; exit $?; fi

# Da qui in poi ogni errore imprevisto finisce nel log, così si può capire cosa è successo
if [[ $1 == --run ]]; then   # usato dall'app: --run AZIONE PARAMETRO file…
  RUN_MODE=1; RUN_ACT=$2; RUN_PARAM=$3; shift 3
  # 3.5.2 · Le password non passano tra gli argomenti (visibili ad altri programmi): arrivano a parte
  if [[ $RUN_ACT == (protect|unprotect) ]]; then
    RUN_PARAM=$LR_SECRET
    if [[ -z $RUN_PARAM ]]; then print -r -- "FAIL"$'\t'"-"$'\t'"serve una password: scrivila quando OrbitLR te la chiede"; exit 1; fi
  fi
  unset LR_SECRET
  trap 'touch "$CANCEL"' TERM   # l'app chiede di annullare: si ferma in modo pulito
fi
exec 2>>"$LOG"
log "avvio con $# elementi"

# ─── 1. Raccolta dei file (anche da cartelle) ────────────────────────

unsupported=0; ignored=0; nfolders=0

add_file() {  # percorso, [quiet]
  local f=$1 e k
  e=$(norm "${f:e}")
  k=$(kind_of "$e")
  if [[ -z $k ]]; then
    if [[ -n $2 ]]; then (( ignored += 1 )); else (( unsupported += 1 )); log "non supportato: $f"; fi
    return 0
  fi
  if [[ $k == sub ]]; then SRTS+=("$f"); return 0; fi
  (( ${F_SRC[(Ie)$f]} )) && return 0
  F_SRC+=("$f"); F_KIND+=("$k"); F_EXT+=("$e")
  (( ${ORDER[(Ie)$k]} )) || ORDER+=("$k")
  return 0
}

for f in "$@"; do
  f=${f%/}
  if [[ -d $f ]]; then
    if (( ${PKG_EXTS[(Ie)$(norm "${f:e}")]} )); then add_file "$f"; continue; fi   # Pages, Numbers, Keynote
    (( nfolders += 1 ))
    for g in "$f"/**/*(.N) "$f"/**/*.(pages|numbers|key|rtfd)(/N); do
      [[ $g == */Convertiti/* ]] && continue
      [[ $g == *.(pages|numbers|key|rtfd)/* ]] && continue
      add_file "$g" quiet
    done
  elif [[ -f $f ]]; then
    add_file "$f"
  fi
done

if (( $#F_SRC == 0 )); then
  if [[ -n $RUN_MODE ]]; then rp FAIL - "Nessun file supportato"; rp END 0 1; exit 0; fi
  if (( $#SRTS )); then notify "Seleziona il video insieme al file .srt"
  else notify "Nessun file supportato selezionato"
  fi
  exit 0
fi

if [[ -z $RUN_MODE ]] && (( nfolders && $#F_SRC > 30 )); then
  [[ $(ask_buttons "Ho trovato $#F_SRC file da elaborare nelle cartelle selezionate. Procedo?" "Annulla" "Procedi") == Procedi ]] || exit 0
fi

MERGEABLE=0; VIDEOS=0
for k in $F_KIND; do
  [[ $k == (pdf|img) ]] && (( MERGEABLE += 1 ))
  [[ $k == video ]] && (( VIDEOS += 1 ))
done

# ─── 2. Una domanda per tipo di file ─────────────────────────────────

typeset -A CHOICE PARAM
merge_chosen=0; menu_logged=0
if [[ -n $RUN_MODE ]]; then
  # L'azione arriva già scelta dall'app: la applico a ogni tipo di file per cui ha senso
  for k in $ORDER; do
    G_EXTS=()
    for i in {1..$#F_SRC}; do [[ ${F_KIND[i]} == $k ]] && G_EXTS+=(${F_EXT[i]}); done
    G_EXTS=(${(u)G_EXTS})
    menu_for $k
    if (( ${M_IDS[(Ie)$RUN_ACT]} )) || [[ $RUN_ACT == to:* && " ${OPTS[$k]} " == *" ${RUN_ACT#to:} "* ]] \
       || [[ $RUN_ACT == merge && $k == (img|pdf) ]]; then
      CHOICE[$k]=$RUN_ACT; PARAM[$k]=$RUN_PARAM
    else
      for i in {1..$#F_SRC}; do
        [[ ${F_KIND[i]} == $k ]] && rp FAIL "${F_SRC[i]}" "azione non disponibile per questo tipo di file"
      done
    fi
  done
else
for k in $ORDER; do
  [[ $k == (img|pdf) ]] && (( merge_chosen )) && continue
  G_IDX=(); G_EXTS=()
  for i in {1..$#F_SRC}; do
    [[ ${F_KIND[i]} == $k ]] && { G_IDX+=($i); G_EXTS+=(${F_EXT[i]}) }
  done
  G_EXTS=(${(u)G_EXTS})
  if (( $#G_IDX == 1 )); then question="«${F_SRC[G_IDX[1]]:t}»: cosa vuoi fare?"
  else question="$#G_IDX ${KIND_NAME[$k]}: cosa vuoi fare?"
  fi
  while :; do
    menu_for $k
    if (( ! menu_logged )); then
      menu_logged=1
      log "menu pronto in $(printf '%.0f' $(( (EPOCHREALTIME - T_START) * 1000 ))) ms dall'avvio dello script"
    fi
    id=$(pick_action $k "$question")
    [[ -z $id ]] && break
    if [[ $id == settings ]]; then settings_menu; continue; fi
    p=""
    if [[ $id == (resize|pdfcompress|vcompress|cut|gifcut|extract|vresize|speed|rotate|reorder|protect|unprotect) ]]; then
      p=$(ask_param $id) || continue
      [[ -n $p ]] || continue
    fi
    CHOICE[$k]=$id; PARAM[$k]=$p
    PREF[last_$k]=$id; save_prefs
    [[ $id == merge ]] && merge_chosen=1
    break
  done
done
fi

if (( $#CHOICE == 0 )); then rp END 0 0; exit 0; fi

# ─── 3. Pianificazione ───────────────────────────────────────────────

typeset -A MISSING
skipped=0; NEED_MODEL=0; model_asked=0; skip_transcribe=0; merge_planned=0

for k in $ORDER; do
  id=${CHOICE[$k]}
  [[ -z $id ]] && continue

  if [[ $id == merge ]]; then
    (( merge_planned )) && continue
    merge_planned=1
    dep_ok helper || { MISSING[helper]=1; continue }
    tmp=()
    for i in {1..$#F_SRC}; do
      [[ ${F_KIND[i]} == (pdf|img) ]] && tmp+=("${(L)F_SRC[i]:t}"$'\x1f'"${F_SRC[i]}")
    done
    tmp=("${(@on)tmp}")                    # ordine dei nomi, con i numeri in ordine naturale
    sorted=("${(@)tmp#*$'\x1f'}")
    add_job merge "${sorted[1]}" pdf pdf "" merge
    print -rl -- $sorted > "$WORK/j$#J_ACT/inputs"
    continue
  fi

  for i in {1..$#F_SRC}; do
    [[ ${F_KIND[i]} == $k ]] || continue
    src=${F_SRC[i]}; e=${F_EXT[i]}; p=${PARAM[$k]}
    if [[ $id == to:* ]]; then
      t=${id#to:}
      if [[ $e == $t ]]; then (( skipped += 1 )); continue; fi
      r=$(route $k $e $t)
      [[ $r == pdfimg ]] && helper_ok
    else
      r=$id
    fi
    if [[ $id == transcribe ]] && (( ! model_asked )); then
      model_asked=1
      if [[ ! -s $(model_path) && -n $RUN_MODE ]]; then
        NEED_MODEL=1                                  # l'app ha già chiesto il consenso
      elif [[ ! -s $(model_path) ]]; then
        b=$(ask_buttons "Per trascrivere serve scaricare il modello Whisper (${WSIZE[$(wq)]}). Si fa una volta sola, poi la trascrizione funziona anche senza internet e nulla viene inviato online." "Annulla" "Scarica")
        if [[ $b == Scarica ]]; then NEED_MODEL=1; else skip_transcribe=1; fi
      fi
    fi
    [[ $id == transcribe ]] && (( skip_transcribe )) && continue
    [[ $id == subembed ]] && p=$(find_srt "$src")
    ok_deps=1
    for d in ${=$(needs $r $k)}; do
      dep_ok $d || { MISSING[$d]=1; ok_deps=0 }
    done
    if [[ $id == strip && $k == img ]] && ! have magick && ! have exiftool; then MISSING[magick]=1; ok_deps=0; fi
    (( ok_deps )) || continue
    add_job "$id" "$src" $k $e "$p" "$r"
  done
done

if (( $#MISSING )) && [[ -n $RUN_MODE ]]; then
  for d in ${(k)MISSING}; do rp MISSING $d "${INSTALL[$d]}"; done
elif (( $#MISSING )); then
  cmds=(); for d in ${(k)MISSING}; do cmds+=("${INSTALL[$d]}"); done
  alert "$APP: manca qualche programma" "Per alcune operazioni serve installare (nel Terminale):"$'\n\n'"${(pj:\n:)${(u)cmds}}"
fi

if (( $#J_ACT == 0 )); then rp END 0 $#MISSING; exit 0; fi

# ─── 4. Esecuzione ───────────────────────────────────────────────────

any_cloud=0
for j in {1..$#J_ACT}; do
  for f in "${(@f)$(job_sources $j)}"; do is_dataless "$f" && any_cloud=1; done
done

show_win=0
(( $#J_ACT > 1 || NEED_MODEL || any_cloud )) && show_win=1
[[ ${J_ACT[1]} == to:* && ${J_ROUTE[1]} == (img|textutil) ]] || show_win=1
(( show_win )) && [[ -z $RUN_MODE ]] && helper_ok && progress_start "Preparazione…"

P_TOTAL=$#J_ACT; P_DONE=0

# 4a. Modello di trascrizione (solo la prima volta)
if (( NEED_MODEL )); then
  mp=$(model_path)
  P_TEXT="Scarico il modello di trascrizione (solo la prima volta)…"
  JOB_PROG="$WORK/model.prog"; JOB_DUR=""; : > "$JOB_PROG"
  P_TOTAL=0; progress_set -1 "$P_TEXT"
  monitored curl -L --fail --progress-bar -o "$mp.part" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${WMODEL[$(wq)]}" 2>"$JOB_PROG"
  rc=$?
  P_TOTAL=$#J_ACT
  if (( rc == 0 )) && [[ -s "$mp.part" ]]; then
    mv -f -- "$mp.part" "$mp"
  else
    rm -f -- "$mp.part"
    for j in {1..$#J_ACT}; do
      if [[ ${J_ACT[j]} == transcribe ]]; then
        print "LRERR: download del modello non riuscito (controlla la connessione)" > "$WORK/j$j/err"
        J_RC[j]=1
      fi
    done
  fi
fi

# 4a-bis. File su iCloud non ancora scaricati sul Mac
if (( any_cloud )); then
  for j in {1..$#J_ACT}; do
    [[ -n ${J_RC[j]} ]] && continue
    [[ -e $CANCEL ]] && break
    for f in "${(@f)$(job_sources $j)}"; do
      is_dataless "$f" || continue
      P_TEXT="Scarico da iCloud «${f:t}»…"
      progress_set -1 "$P_TEXT"
      if ! ensure_local "$f"; then
        print -r -- "LRERR: «${f:t}» è su iCloud e non sono riuscito a scaricarlo sul Mac: aprilo una volta dal Finder e riprova" >> "$WORK/j$j/err"
        J_RC[j]=1
        break
      fi
    done
  done
fi

for r in $J_ROUTE; do
  [[ $r == (lo|lo+pandoc|pandoc+lo) ]] && { lo_acquire; break }
done

# 4b. LibreOffice: un solo avvio per tutti i documenti con lo stesso formato di arrivo
typeset -A LO_GROUP LO_SEEN
for j in {1..$#J_ACT}; do
  [[ ${J_ROUTE[j]} == lo && -z ${J_RC[j]} ]] || continue
  b=${(L)J_SRC[j]:t:r}; n=0
  while :; do
    key="${J_KIND[j]}|${J_ACT[j]#to:}|$n"; sk="$key/$b"
    (( ${+LO_SEEN[$sk]} )) || break
    (( n += 1 ))
  done
  LO_SEEN[$sk]=1
  LO_GROUP[$key]+=" $j"
done

g=0
for key in ${(k)LO_GROUP}; do
  [[ -e $CANCEL ]] && break
  idx=(${=LO_GROUP[$key]})
  k=${key%%|*}; rest=${key#*|}; t=${rest%%|*}
  (( g += 1 )); gdir="$WORK/lo$g"; mkdir -p "$gdir"
  srcs=(); for j in $idx; do srcs+=("${J_SRC[j]}"); done
  if (( $#idx == 1 )); then P_TEXT="$(( P_DONE + 1 ))/$P_TOTAL · ${J_SRC[idx[1]]:t}"
  else P_TEXT="Converto $#idx documenti con LibreOffice…"
  fi
  JOB_PROG="$gdir/prog"; JOB_DUR=""; : > "$JOB_PROG"
  progress_job 0
  monitored lo_run "$gdir" $k $t $srcs 2>>"$gdir/err"
  produced=0
  for j in $idx; do [[ -s "$gdir/${J_SRC[j]:t:r}.$t" ]] && (( produced += 1 )); done
  if (( produced == 0 )) && [[ ! -e $CANCEL ]]; then   # il primissimo avvio a volte non converte
    monitored lo_run "$gdir" $k $t $srcs 2>>"$gdir/err"
  fi
  [[ -e $CANCEL ]] && break
  for j in $idx; do
    pf="$gdir/${J_SRC[j]:t:r}.$t"
    if [[ -s $pf ]] && mv -f -- "$pf" "$WORK/j$j/out/${J_SRC[j]:t:r}.$t"; then J_RC[j]=0
    else J_RC[j]=1; cat "$gdir/err" >> "$WORK/j$j/err" 2>/dev/null
    fi
    (( P_DONE += 1 ))
  done
done

# 4c. Tutto il resto, un lavoro alla volta
for j in {1..$#J_ACT}; do
  [[ -n ${J_RC[j]} ]] && continue
  [[ -e $CANCEL ]] && break
  JD="$WORK/j$j"; JOB_PROG="$JD/prog"; JOB_DUR=""; : > "$JOB_PROG"
  case ${J_ACT[j]} in
    to:*) [[ ${J_ROUTE[j]} == av ]] && JOB_DUR=$(media_dur "${J_SRC[j]}") ;;
    vcompress|normalize|voiceclean|transcribe|subembed|vresize|silence) JOB_DUR=$(media_dur "${J_SRC[j]}") ;;
    speed) d=$(media_dur "${J_SRC[j]}"); [[ -n $d ]] && JOB_DUR=$(( d / ${J_PARAM[j]:-1} )) ;;
    strip) [[ ${J_KIND[j]} == (audio|video) ]] && JOB_DUR=$(media_dur "${J_SRC[j]}") ;;
    cut|gifcut)
      p=${J_PARAM[j]}; s=${p%%|*}; en=${p#*|}
      if [[ -n $en ]]; then JOB_DUR=$(( en - s ))
      else d=$(media_dur "${J_SRC[j]}"); [[ -n $d ]] && JOB_DUR=$(( d - s ))
      fi ;;
  esac
  if [[ ${J_ACT[j]} == merge ]]; then P_TEXT="$(( P_DONE + 1 ))/$P_TOTAL · Unisco $MERGEABLE file in un PDF"
  else P_TEXT="$(( P_DONE + 1 ))/$P_TOTAL · ${J_SRC[j]:t}"
  fi
  progress_job 0
  monitored run_job $j 2>>"$JD/err"
  rc=$?
  if (( rc == 130 )) && [[ -e $CANCEL ]]; then break; fi
  J_RC[j]=$rc
  (( P_DONE += 1 ))
done

progress_stop

# ─── 5. Risultati ────────────────────────────────────────────────────

ok=0; cancelled=0; last_out=""; last_info=""
typeset -a FAILS NOTES
for j in {1..$#J_ACT}; do
  JD="$WORK/j$j"
  if [[ -s "$JD/err" ]]; then
    { print -r -- "[$(date '+%F %T')] ── ${J_SRC[j]} (${J_ACT[j]})"; cat "$JD/err" } >> "$LOG"
  fi
  if [[ -z ${J_RC[j]} ]]; then (( cancelled += 1 )); rp CANCEL "${J_SRC[j]}"; continue; fi
  items=("$JD/out"/*(N))
  if (( J_RC[j] == 0 && $#items )); then
    dest=${J_DEST[j]}
    mkdir -p -- "$dest" 2>/dev/null
    moved=0
    for it in $items; do
      if [[ -d $it ]]; then tgt=$(unique_item "$dest" "${it:t}" dir); else tgt=$(unique_item "$dest" "${it:t}"); fi
      if mv -f -- "$it" "$tgt"; then (( moved += 1 )); last_out=$tgt; rp OUT "$tgt"; fi
    done
    if (( moved )); then
      (( ok += 1 ))
      log "ok: ${J_SRC[j]:t} (${J_ACT[j]}) → ${last_out:t}"
      info=$(grep -a '^LRINFO: ' "$JD/err" 2>/dev/null | tail -n 1)
      [[ -n $info ]] && last_info=${info#LRINFO: }
      rp OK "${J_SRC[j]}" "${info#LRINFO: }"
      continue
    fi
  fi
  note=$(grep -a '^LRNOTE: ' "$JD/err" 2>/dev/null | tail -n 1)
  if (( J_RC[j] == 0 )) && [[ -n $note ]]; then NOTES+=("${note#LRNOTE: }"); rp NOTE "${J_SRC[j]}" "${note#LRNOTE: }"; continue; fi
  FAILS+=("${J_SRC[j]:t}: $(explain "$JD/err" ${J_RC[j]})")
  rp FAIL "${J_SRC[j]}" "$(explain "$JD/err" ${J_RC[j]})"
  log "non riuscito: ${J_SRC[j]} (${J_ACT[j]}, codice ${J_RC[j]})"
done

if [[ -n $RUN_MODE ]]; then
  rp END $ok $#FAILS
  helper_ready || helper_ok >/dev/null
  exit 0
fi

extra=""
(( $#NOTES ))   && extra+=" · ${(j: · :)NOTES[1,2]}"
(( skipped ))   && extra+=" · $skipped già nel formato scelto"
(( unsupported )) && extra+=" · $unsupported non supportati"
(( cancelled )) && extra+=" · $cancelled annullati"

if (( $#FAILS )); then
  msg="Riusciti: $ok   ·   Non riusciti: $#FAILS"$'\n\n'"${(pj:\n\n:)FAILS[1,6]}"
  (( $#FAILS > 6 )) && msg+=$'\n\n'"…e altri $(( $#FAILS - 6 ))."
  [[ -n $extra ]] && msg+=$'\n\n'"${extra# · }"
  error_dialog "$msg"
else
  if (( ok == 1 )); then
    msg="Creato «${last_out:t}»"
    [[ -n $last_info ]] && msg+=" ($last_info)"
  elif (( ok > 1 )); then msg="$ok file pronti"
  elif (( cancelled )); then msg="Operazione annullata"
  else msg="Nessun file creato"
  fi
  notify "$msg$extra"
fi
helper_ready || helper_ok
exit 0
