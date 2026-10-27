/* OrbitLR · il sito. Tutto avviene nel browser: niente viene caricato.
   Le animazioni toccano solo transform e opacity, da un solo ciclo requestAnimationFrame. */
(() => {
'use strict';
const $ = s => document.querySelector(s), $$ = s => [...document.querySelectorAll(s)];
const NS = 'http://www.w3.org/2000/svg';
const MAC_URL = 'https://github.com/LR-apps609/OrbitLR/releases';
const WIN_URL = 'https://github.com/LR-apps609/OrbitLR/releases/tag/windows-anteprima';
const PDFJS_URL = 'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/4.4.168/pdf.min.mjs';
const PDFJS_WORKER = 'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/4.4.168/pdf.worker.min.mjs';
const REDUCED = matchMedia('(prefers-reduced-motion: reduce)').matches;
const SMALL = innerWidth < 600;
const clamp = (x, a, b) => Math.max(a, Math.min(b, x));

/* ---------- Un solo ciclo di animazione ---------- */
const loops = new Set(); let rafId = 0;
function tick(t){ for (const f of loops) if (!f(t)) loops.delete(f); rafId = loops.size ? requestAnimationFrame(tick) : 0; }
function addLoop(f){ loops.add(f); if (!rafId) rafId = requestAnimationFrame(tick); }

/* ---------- Lingua ---------- */
let LANG = 'it';
try { const v = localStorage.getItem('orbitlr-lang'); if (v === 'en' || v === 'it') LANG = v; } catch (e) {}
const T = (it, en) => LANG === 'en' ? (en ?? it) : it;
const L = o => o ? (LANG === 'en' ? (o.en ?? o.it) : o.it) : '';
function applyLang(){
  document.documentElement.lang = LANG;
  $$('[data-en]').forEach(el => {
    if (el.dataset.it === undefined) el.dataset.it = el.innerHTML;
    el.innerHTML = LANG === 'en' ? el.dataset.en : el.dataset.it;
  });
  $('#lang-it').setAttribute('aria-pressed', LANG === 'it');
  $('#lang-en').setAttribute('aria-pressed', LANG === 'en');
  $('#dial').setAttribute('data-drop', LANG === 'en' ? $('#dial').dataset.dropEn : 'Lascia andare');
  $('#pie').setAttribute('aria-label', T('Menu a torta: scegli cosa fare del file', 'Pie menu: choose what to do with the file'));
  $('#barX').setAttribute('aria-label', T('Chiudi', 'Close'));
  $('#pasteKey').textContent = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent) ? '⌘V' : 'Ctrl+V';
  renderStores(); draw(false); caption(); rerenderOut(); renderQuiz(); manifestoCenter(true); renderCats(false);
}
function setLang(l){
  LANG = l; try { localStorage.setItem('orbitlr-lang', l); } catch (e) {}
  applyLang();
  if (S.sample) sample(S.sampleKind);
}

/* ---------- Numeri ---------- */
const num = (x, d) => { const s = x.toFixed(d); return LANG === 'it' ? s.replace('.', ',') : s; };
const fmt = b => b < 1024 ? b + ' B' : b < 1048576 ? Math.round(b / 1024) + ' KB' : num(b / 1048576, 1) + ' MB';
const dur = s => { s = Math.round(s || 0); return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0'); };
const base = n => n.replace(/\.[^.]+$/, '');
const extOf = n => (n.split('.').pop() || '').toLowerCase();
const esc = s => String(s).replace(/[&<>"]/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[ch]);
const wait = (p, ms) => Promise.race([p, new Promise((_, r) => setTimeout(() => r(new Error('timeout')), ms))]);

/* ---------- Schede: Converter e Applicazione ---------- */
const VIEWS = { converter: $('#view-converter'), app: $('#view-app') };
let TAB = null;
const tabFromHash = () => ['applicazione', 'app', 'scarica', 'torta', 'cosa'].includes(location.hash.slice(1)) ? 'app' : 'converter';
function showTab(name, { to = null, push = true } = {}){
  name = name === 'app' ? 'app' : 'converter';
  if (TAB !== name) {
    const first = TAB === null;
    VIEWS.converter.hidden = name !== 'converter'; VIEWS.app.hidden = name !== 'app';
    const v = VIEWS[name]; v.classList.remove('enter');
    if (!first && !REDUCED) { void v.offsetWidth; v.classList.add('enter'); }
    $('#tab-converter').setAttribute('aria-selected', name === 'converter');
    $('#tab-app').setAttribute('aria-selected', name === 'app');
    $('.tabs').classList.toggle('app', name === 'app');
    TAB = name;
    if (push) history.pushState({ tab: name }, '', name === 'app' ? '#applicazione' : '#converter');
    if (!to && !first) scrollTo(0, 0);
    // solo gli sfondi della scheda mostrata: i primi due subito, gli altri nelle pause del browser
    requestAnimationFrame(() => {
      FX.filter(f => VIEWS[name].contains(f.layer)).forEach((f, i) => i < 2 ? layoutFx(f) : idle().then(() => layoutFx(f)));
      M.p = -1; manifestoUpdate(); heroDefaults(); kickFx(); idle().then(cloudSize);
    });
  }
  if (to) requestAnimationFrame(() => requestAnimationFrame(() => document.getElementById(to)?.scrollIntoView({ behavior: REDUCED ? 'auto' : 'smooth' })));
}
$('#tab-converter').addEventListener('click', () => showTab('converter'));
$('#tab-app').addEventListener('click', () => showTab('app'));
$('.tabs').addEventListener('keydown', ev => { if (ev.key === 'ArrowRight' || ev.key === 'ArrowLeft') { const n = TAB === 'app' ? 'converter' : 'app'; showTab(n); $('#tab-' + n).focus(); } });
$('#logoLink').addEventListener('click', ev => { ev.preventDefault(); showTab('converter'); });
document.addEventListener('click', ev => {
  const dl = ev.target.closest('[data-goto-dl], #getApp'); if (dl) { ev.preventDefault(); showTab('app', { to: 'scarica' }); return; }
  const ap = ev.target.closest('[data-goto="app"]'); if (ap) { ev.preventDefault(); showTab('app'); }
});
addEventListener('popstate', () => showTab(tabFromHash(), { push: false }));

/* ---------- Pulsanti per scaricare (icone generiche nostre; nessun negozio di terzi disponibile oggi) ---------- */
const ICON = {
  laptop: '<svg width="30" height="30" viewBox="0 0 48 48" aria-hidden="true"><rect x="9" y="10" width="30" height="20" rx="2.5" fill="none" stroke="currentColor" stroke-width="3"/><path d="M4 35h40l-3 4H7z" fill="currentColor"/></svg>',
  desktop: '<svg width="30" height="30" viewBox="0 0 48 48" aria-hidden="true"><rect x="5" y="7" width="38" height="25" rx="2.5" fill="none" stroke="currentColor" stroke-width="3"/><path d="M19 32l-2 7h14l-2-7M13 41h22" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  tablet: '<svg width="30" height="30" viewBox="0 0 48 48" aria-hidden="true"><rect x="6" y="6" width="26" height="36" rx="4" fill="none" stroke="currentColor" stroke-width="2.8"/><rect x="26" y="18" width="16" height="26" rx="3.5" fill="var(--forest-2)" stroke="currentColor" stroke-width="2.8"/><circle cx="34" cy="39" r="1.6" fill="currentColor"/></svg>',
  phone: '<svg width="30" height="30" viewBox="0 0 48 48" aria-hidden="true"><rect x="12" y="4" width="22" height="40" rx="4.5" fill="none" stroke="currentColor" stroke-width="2.8"/><path d="M23 14v14m0 0l-5-5m5 5l5-5" fill="none" stroke="currentColor" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"/><path d="M19 37h8" stroke="currentColor" stroke-width="2.8" stroke-linecap="round"/></svg>',
};
function renderStores(){
  $$('[data-stores]').forEach(box => {
    const soonOnly = box.dataset.stores === 'soon';
    const real = soonOnly ? '' :
      `<a class="store" href="${MAC_URL}" target="_blank" rel="noopener">${ICON.laptop}<span><small>${T('Scarica per', 'Download for')}</small><b>Mac</b></span></a>` +
      `<a class="store" href="${WIN_URL}" target="_blank" rel="noopener">${ICON.desktop}<span><small>${T('Scarica per', 'Download for')}</small><b>Windows</b></span></a>`;
    const soon = [['App Store', ICON.tablet], ['Google Play', ICON.phone]].map(([n, ic]) =>
      `<button type="button" class="store soon" data-soon="${n}">${ic}<span><i>${T('In arrivo su', 'Coming to')}</i><b>${n}</b></span></button>`).join('');
    box.innerHTML = (real ? `<div class="st-row">${real}</div>` : '') + `<div class="st-row">${soon}</div>`;
  });
}
document.addEventListener('click', ev => {
  const b = ev.target.closest('.store.soon'); if (!b) return;
  const i = b.querySelector('i'); i.textContent = T('Arriverà presto', 'Coming soon'); b.classList.add('said');
  clearTimeout(b._t); b._t = setTimeout(() => { i.textContent = T('In arrivo su', 'Coming to'); b.classList.remove('said'); }, 2200);
});

/* ---------- Stato ---------- */
let S = { files: [], kind: null, est: {}, level: 'root' };
let OUT = null, loadToken = 0;
const IMAGE = ['jpg','jpeg','png','webp','avif','gif','bmp','jfif','ico','tif','tiff'];
const HEIC = ['heic','heif'];
const VIDEO = ['mp4','mov','m4v','mkv','webm','avi','wmv','flv','mpg','mpeg','ts','mts','m2ts','3gp','ogv','vob','mxf','asf','f4v'];
const AUDIO = ['mp3','m4a','wav','flac','ogg','opus','aac','wma','aiff','aif','aifc','caf','m4b','m4r','amr','ac3','oga','mka'];
const TEXT = ['txt','md','markdown','csv','htm','html'];
const DOCS = ['docx','doc','odt','rtf','xlsx','xls','ods','pptx','ppt','odp','epub','pages','numbers','key'];
function kindOf(f){
  const e = extOf(f.name);
  if (HEIC.includes(e) || /hei[cf]/.test(f.type)) return 'heic';
  if (IMAGE.includes(e) || f.type.startsWith('image/')) return 'img';
  if (VIDEO.includes(e) || f.type.startsWith('video/')) return 'video';
  if (AUDIO.includes(e) || f.type.startsWith('audio/')) return 'audio';
  if (e === 'pdf' || f.type === 'application/pdf') return 'pdf';
  if (TEXT.includes(e) || f.type.startsWith('text/')) return 'text';
  if (DOCS.includes(e)) return 'doc';
  return 'other';
}

/* ---------- Gli spicchi ---------- */
const C = ['var(--s4)','var(--s2)','var(--s3)','var(--s1)','var(--s6)','var(--s7)','var(--s5)'];
const app = (id, it, en, hit, hen) => ({ id: 'app:' + id, it, en, app: true, hit, hen });
const back = () => ({ id: 'back', it: '‹ Indietro', en: '‹ Back', back: true });
function slicesFor(){
  const k = S.kind, lv = S.level;
  if (k === 'img') {
    if (lv === 'cmp') return [
      { id: 'cmp:best', it: 'Più\nleggera', en: 'Lighter', real: true },
      { id: 'cmp:1000', it: '1 MB', en: '1 MB', real: true }, { id: 'cmp:500', it: '500 KB', en: '500 KB', real: true },
      { id: 'cmp:200', it: '200 KB', en: '200 KB', real: true }, { id: 'cmp:100', it: '100 KB', en: '100 KB', real: true },
      { id: 'cmp:50', it: '50 KB', en: '50 KB', real: true }, back() ];
    if (lv === 'soc') return [
      { id: 'soc:1x1', it: '1:1', en: '1:1', sub2: { it: 'post', en: 'post' }, real: true },
      { id: 'soc:4x5', it: '4:5', en: '4:5', sub2: { it: 'feed', en: 'feed' }, real: true },
      { id: 'soc:9x16', it: '9:16', en: '9:16', sub2: { it: 'storie', en: 'stories' }, real: true },
      { id: 'soc:16x9', it: '16:9', en: '16:9', sub2: { it: 'YouTube', en: 'YouTube' }, real: true }, back() ];
    if (lv === 'mod') return [
      { id: 'mod:rot', it: 'Ruota ↻', en: 'Rotate ↻', real: true }, { id: 'mod:75', it: '75%', en: '75%', real: true },
      { id: 'mod:50', it: '50%', en: '50%', real: true }, { id: 'mod:25', it: '25%', en: '25%', real: true },
      { id: 'mod:strip', it: 'Senza\nmetadati', en: 'No\nmetadata', real: true },
      { id: 'mod:reset', it: 'Com’era', en: 'Original', real: true }, back() ];
    if (lv === 'more') return [
      app('removebg', 'Rimuovi\nlo sfondo', 'Remove\nBackground', 'Resta solo il soggetto, su sfondo trasparente. Tutto sul computer.', 'Only the subject stays, on a transparent background. All on your computer.'),
      app('aienhance', 'Migliora\ncon l’IA', 'Enhance\nwith AI', 'Più nitida e pulita, senza inventare dettagli.', 'Sharper and cleaner, without inventing details.'),
      app('upscale', 'Ingrandisci', 'Upscale', 'Due o quattro volte più grande, con i contorni nitidi.', 'Two or four times bigger, with crisp edges.'),
      app('straighten', 'Raddrizza\nun foglio', 'Straighten\na sheet', '«Raddrizza un documento»: la foto storta di un foglio diventa una pagina dritta, come uno scanner.', '“Straighten a Document”: a crooked photo of a sheet becomes a straight page, like a scanner.'),
      app('ocr', 'Estrai\nil testo', 'Extract\ntext', 'Dalle foto e dagli screenshot, in un file di testo.', 'From photos and screenshots, into a text file.'),
      app('vector', 'Vettoriale\nSVG', 'Vector\nSVG', 'Loghi, disegni e firme diventano SVG, nitidi a qualunque misura.', 'Logos, drawings and signatures become SVG, sharp at any size.'),
      back() ];
    return [
      { id: 'to:jpg', it: 'JPG', en: 'JPG', real: true }, { id: 'to:png', it: 'PNG', en: 'PNG', real: true },
      { id: 'to:webp', it: 'WEBP', en: 'WEBP', real: true }, { id: 'to:pdf', it: 'PDF', en: 'PDF', real: true },
      { id: 'sub:cmp', it: 'Comprimi', en: 'Compress', real: true, sub: true },
      { id: 'sub:soc', it: 'Social', en: 'Social', real: true, sub: true },
      { id: 'sub:mod', it: 'Modifica', en: 'Edit', real: true, sub: true },
      { id: 'sub:more', it: 'Altro\nnell’app', en: 'More in\nthe app', app: true, sub: true } ];
  }
  if (k === 'imgs') return [
    { id: 'multi:pdf', it: 'Unisci\nin un PDF', en: 'Merge\ninto PDF', real: true },
    { id: 'multi:first', it: 'Solo la\nprima', en: 'Just the\nfirst', real: true },
    app('convertall', 'Converti\ntutte', 'Convert\nall', 'Cento foto insieme nella stessa torta, ognuna con il suo nome.', 'A hundred photos at once in the same pie, each with its own name.'),
    app('rename', 'Rinomina\ntutti', 'Rename\nall', 'Per esempio Vacanze 001, Vacanze 002…', 'For example Holiday 001, Holiday 002…'),
    app('stack', 'Unisci più\nscatti', 'Merge\nshots', 'Più foto della stessa scena, allineate e fuse: meno rumore al buio.', 'Several shots of the same scene, aligned and merged: less noise in the dark.') ];
  if (k === 'audio') return [
    { id: 'au:wav', it: 'WAV', en: 'WAV', real: true },
    { id: 'au:ring', it: 'Suoneria\n30 s', en: 'Ringtone\n30 s', real: true },
    app('mp3', 'MP3', 'MP3', 'Anche M4A, FLAC, OGG e OPUS, con la qualità che scegli.', 'Also M4A, FLAC, OGG and OPUS, at the quality you choose.'),
    app('cut', 'Taglia', 'Trim', 'Sulla forma d’onda, con lo zoom fino al millesimo di secondo.', 'On the waveform, zooming down to the millisecond.'),
    app('voiceclean', 'Voce più\npulita', 'Cleaner\nvoice', 'Meno ronzio e fruscio di fondo, volume uniforme.', 'Less background hum and hiss, even volume.'),
    app('transcribe', 'Trascrivi', 'Transcribe', 'Le parole diventano testo e sottotitoli, sul computer.', 'Speech becomes text and subtitles, on the computer.'),
    app('whatsapp', 'WhatsApp', 'WhatsApp', 'Un vocale leggero, per i messaggi.', 'A light voice note, for messages.') ];
  if (k === 'text') return [
    { id: 'tx:html', it: 'Pagina\nweb', en: 'Web\npage', real: true },
    { id: 'tx:txt', it: 'Solo\ntesto', en: 'Plain\ntext', real: true },
    app('pdf', 'PDF', 'PDF', 'Testi e documenti in PDF, DOCX, ODT e altri.', 'Texts and documents to PDF, DOCX, ODT and more.'),
    app('tts', 'Testo\nin voce', 'Text to\nspeech', 'Il testo letto ad alta voce, in un file audio.', 'The text read aloud, into an audio file.') ];
  if (k === 'video') return [
    app('vcompress', 'Comprimi', 'Compress', 'Stessa qualità, meno peso (di solito la metà), o per Discord 9 MB, WhatsApp 15 MB, email 18 MB.', 'Same quality, smaller (usually half), or for Discord 9 MB, WhatsApp 15 MB, email 18 MB.'),
    app('cut', 'Taglia', 'Trim', 'Tieni solo un pezzo: istantaneo e senza perdita.', 'Keep just a piece: instant and lossless.'),
    app('social', 'Social\n9:16', 'Social\n9:16', 'Verticale, quadrato o 4:5 per Reels, TikTok e post.', 'Vertical, square or 4:5 for Reels, TikTok and posts.'),
    app('gif', 'GIF', 'GIF', 'Un’animazione da un tratto del video.', 'An animation from a stretch of the video.'),
    app('mp3', 'Solo\naudio', 'Audio\nonly', 'L’audio in MP3, M4A o WAV.', 'The audio as MP3, M4A or WAV.'),
    app('transcribe', 'Sottotitoli', 'Subtitles', 'Le parole diventano sottotitoli .srt, sul computer.', 'Speech becomes .srt subtitles, on the computer.'),
    app('mute', 'Togli\nl’audio', 'Mute', 'Istantaneo: il video non si tocca.', 'Instant: the video is untouched.'),
    app('speed', 'Velocità', 'Speed', 'Da un quarto a quattro volte; la voce mantiene il tono.', 'From ¼× to 4×; the voice keeps its pitch.') ];
  if (k === 'pdf') return [
    app('pdfcompress', 'Comprimi', 'Compress', 'Per l’email: testo, link e moduli restano come sono.', 'For email: text, links and forms stay as they are.'),
    app('pdfedit', 'Firma', 'Sign', 'Compila i moduli, metti la firma, scrivi sul PDF.', 'Fill forms, sign, write on the PDF.'),
    app('pdfmerge', 'Unisci', 'Merge', 'Più PDF in uno, nell’ordine dell’elenco.', 'Several PDFs into one, in list order.'),
    app('split', 'Dividi', 'Split', 'Un PDF per ogni pagina, o solo alcune pagine.', 'One PDF per page, or only some pages.'),
    app('protect', 'Password', 'Password', 'Serve la password per aprirlo (AES-256).', 'A password is needed to open it (AES-256).'),
    app('pdftext', 'Estrai\nil testo', 'Extract\ntext', 'In un file di testo; dai PDF scansionati lo legge dalle pagine.', 'Into a text file; from scanned PDFs it reads the pages.'),
    app('pdfimg', 'In JPG\no PNG', 'To JPG\nor PNG', 'Ogni pagina diventa un’immagine.', 'Each page becomes an image.') ];
  if (k === 'heic') return [
    app('heicjpg', 'JPG', 'JPG', 'Le foto HEIC dell’iPhone diventano JPG, con data e posizione GPS.', 'iPhone HEIC photos become JPG, keeping date and GPS location.'),
    app('heicpng', 'PNG', 'PNG', 'Le foto HEIC dell’iPhone diventano PNG.', 'iPhone HEIC photos become PNG.'),
    app('heicpdf', 'PDF', 'PDF', 'Una foto per pagina.', 'One photo per page.'),
    app('heicauto', 'Da sole', 'Auto', 'Cartelle automatiche: le HEIC scaricate diventano JPG da sole.', 'Automatic folders: downloaded HEIC photos become JPG by themselves.'),
    app('icompress', 'Comprimi', 'Compress', 'Stessa qualità con meno peso, o sotto un peso preciso.', 'Same quality, smaller, or under an exact size.') ];
  if (k === 'doc') return [
    app('docpdf', 'PDF', 'PDF', 'Word, Excel e PowerPoint in PDF (con LibreOffice, facoltativo).', 'Word, Excel and PowerPoint to PDF (with optional LibreOffice).'),
    app('docx', 'DOCX\nXLSX', 'DOCX\nXLSX', 'E ODT, ODS, ODP, RTF, CSV, TXT.', 'And ODT, ODS, ODP, RTF, CSV, TXT.'),
    app('docodt', 'ODT', 'ODT', 'Il formato aperto di LibreOffice.', 'LibreOffice’s open format.') ];
  return [app('open', 'Apri\nnell’app', 'Open in\nthe app', 'L’app riconosce molti più formati: video, documenti, PDF e altro.', 'The app opens many more formats: video, documents, PDF and more.')];
}
const LEVEL_NAME = { cmp: { it: 'Comprimi', en: 'Compress' }, soc: { it: 'Social', en: 'Social' }, mod: { it: 'Modifica', en: 'Edit' }, more: { it: 'Nell’app', en: 'In the app' } };
const estIds = () => slicesFor().filter(s => s.real && !s.sub && !s.id.startsWith('mod:') && s.id !== 'multi:first').map(s => s.id);

/* ---------- Disegno della torta ---------- */
const R0 = 98, R1 = 236;
const el = (t, a = {}) => { const n = document.createElementNS(NS, t); for (const k in a) n.setAttribute(k, a[k]); return n; };
const P = (r, a) => [Math.cos(a) * r, Math.sin(a) * r];
function sector(r0, r1, a0, a1){
  const [x0, y0] = P(r1, a0), [x1, y1] = P(r1, a1), [x2, y2] = P(r0, a1), [x3, y3] = P(r0, a0), big = a1 - a0 > Math.PI ? 1 : 0;
  return `M${x0.toFixed(2)} ${y0.toFixed(2)}A${r1} ${r1} 0 ${big} 1 ${x1.toFixed(2)} ${y1.toFixed(2)}L${x2.toFixed(2)} ${y2.toFixed(2)}A${r0} ${r0} 0 ${big} 0 ${x3.toFixed(2)} ${y3.toFixed(2)}Z`;
}
function drawGhost(){
  const pie = $('#pie'); pie.innerHTML = '';
  pie.append(el('circle', { class: 'ring', r: 246 }));
  const g = el('g', { class: 'ghost' }), n = 8, step = Math.PI * 2 / n;
  for (let i = 0; i < n; i++) { const a0 = -Math.PI / 2 + i * step; g.append(el('path', { d: sector(R0, R1, a0, a0 + step), fill: C[i % C.length], 'fill-opacity': .34 })); }
  pie.append(g);
}
function draw(animate = true, holeMode = ''){
  if (!S.files.length) { drawGhost(); return; }
  if (S.docking) return;
  const pie = $('#pie'); pie.innerHTML = '';
  const defs = el('defs'); const cp = el('clipPath', { id: 'holeclip' }); cp.append(el('circle', { r: R0 - 14 })); defs.append(cp); pie.append(defs);
  pie.append(el('circle', { class: 'ring', r: 246 }));
  const list = slicesFor(), n = list.length, step = Math.PI * 2 / n, start = -Math.PI / 2 - step / 2, ests = estIds();
  let ci = 0;
  list.forEach((sl, i) => {
    const a0 = start + i * step, a1 = a0 + step, mid = (a0 + a1) / 2;
    const g = el('g', { class: 'slice' + (sl.app ? ' app' : '') + (sl.back ? ' back' : '') + (animate && !REDUCED ? ' bloom' : ''), tabindex: 0, role: 'button', 'data-id': sl.id });
    g.style.setProperty('--dx', (Math.cos(mid) * 9).toFixed(1) + 'px');
    g.style.setProperty('--dy', (Math.sin(mid) * 9).toFixed(1) + 'px');
    if (animate) g.style.animationDelay = (i * 34) + 'ms';
    // l'area da toccare resta ferma; si sposta solo la parte visibile (niente sfarfallio al bordo)
    g.append(el('path', { class: 'hit', d: sector(R0, R1, a0, a1), fill: 'transparent' }));
    const vis = el('g', { class: 'vis' }); g.append(vis);
    const fill = el('path', { class: 'fill', d: sector(R0, R1, a0, a1) });
    if (!sl.app && !sl.back) fill.setAttribute('fill', C[ci++ % C.length]);
    vis.append(fill);
    if (sl.app) vis.append(el('path', { class: 'edge', d: sector(R0 + 7, R1 - 7, a0 + 0.035, a1 - 0.035) }));
    const [cx, cy] = P((R0 + R1) / 2 + 4, mid);
    const lines = L(sl).split('\n'), hasEst = ests.includes(sl.id), sub2 = sl.sub2 ? L(sl.sub2) : null;
    const tag = sl.app && !sl.sub, extra = (tag ? 1 : 0) + (hasEst || sub2 ? 1 : 0);
    let y = cy - (lines.length * 21 + extra * 17) / 2 + 15;
    if (tag) { const tg = el('text', { class: 'tag', x: cx, y: y - 4 }); tg.textContent = T('NELL’APP', 'IN APP'); vis.append(tg); y += 15; }
    lines.forEach((t, k) => { const tx = el('text', { x: cx, y }); tx.textContent = t + (sl.sub && k === lines.length - 1 ? ' ›' : ''); vis.append(tx); y += 21; });
    if (hasEst || sub2) { const e = el('text', { class: 'est', x: cx, y: y - 3 }); e.textContent = hasEst ? estText(sl.id) : sub2; vis.append(e); }
    g.setAttribute('aria-label', lines.join(' ') + (tag ? ', ' + T('nell’app', 'in the app') : ''));
    wireSlice(g, sl);
    pie.append(g);
  });
  const hole = el('g', { class: 'hole' + (!REDUCED && holeMode ? ' ' + holeMode : ''), tabindex: 0, role: 'button' });
  hole.append(el('circle', { class: 'rim', r: R0 - 8 }));
  if (S.thumb) {
    const img = el('image', { href: S.thumb, x: -(R0 - 14), y: -(R0 - 14), width: (R0 - 14) * 2, height: (R0 - 14) * 2, 'clip-path': 'url(#holeclip)', preserveAspectRatio: 'xMidYMid slice' });
    if (S.kind === 'img' && S.rot) img.setAttribute('transform', `rotate(${S.rot})`);
    hole.append(img);
  } else {
    const e = el('text', { class: 'ext', y: 14 }); e.textContent = S.kind === 'imgs' ? S.files.length + '×' : (extOf(S.files[0].name) || '?').toUpperCase().slice(0, 4); hole.append(e);
  }
  if (S.level !== 'root') {
    hole.append(el('circle', { class: 'shade', r: R0 - 14 }));
    const t = el('text', { class: 'cap', y: 7 }); t.textContent = L(LEVEL_NAME[S.level]); hole.append(t);
    hole.setAttribute('aria-label', T('Torna alla torta', 'Back to the pie'));
    hole.addEventListener('click', () => goLevel('root'));
  } else if (S.preview) {
    hole.setAttribute('aria-label', T('Mostra l’anteprima in grande', 'Show the preview large'));
    hole.addEventListener('click', () => openPreview());
  } else {
    hole.setAttribute('aria-label', T('Scegli un altro file', 'Choose another file'));
    hole.addEventListener('click', () => $('#file').click());
  }
  hole.addEventListener('keydown', ev => { if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); hole.dispatchEvent(new MouseEvent('click')); } });
  pie.append(hole);
}
const estText = id => { const e = S.est[id]; return e && !e.pending ? '≈ ' + fmt(e.size) : '…'; };

/* Spicchi: tocca, oppure trascina fuori dalla torta per lanciarlo */
let sliceDrag = null;
function wireSlice(g, sl){
  g.addEventListener('click', ev => { ev.preventDefault(); if (g._suppress) { g._suppress = false; return; } pick(sl); });
  g.addEventListener('keydown', ev => { if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); pick(sl); } });
  g.addEventListener('pointerdown', ev => { if (ev.button !== 0) return; sliceDrag = { g, sl, x: ev.clientX, y: ev.clientY, moved: false, id: ev.pointerId, scale: $('#pie').getBoundingClientRect().width / 500 }; });
  g.addEventListener('pointermove', ev => {
    const d = sliceDrag; if (!d || d.g !== g || d.id !== ev.pointerId) return;
    const dx = ev.clientX - d.x, dy = ev.clientY - d.y;
    if (!d.moved && Math.hypot(dx, dy) > 8) { d.moved = true; g.classList.add('dragging'); try { g.setPointerCapture(ev.pointerId); } catch (e) {} }
    if (d.moved) { d.dx = dx / d.scale; d.dy = dy / d.scale; g.style.transform = `translate(${d.dx.toFixed(1)}px,${d.dy.toFixed(1)}px)`; }
  });
  const end = ev => {
    const d = sliceDrag; if (!d || d.g !== g) return; sliceDrag = null;
    if (!d.moved) return;
    g._suppress = true; setTimeout(() => { g._suppress = false; }, 50);
    g.classList.remove('dragging');
    const dist = Math.hypot(d.dx || 0, d.dy || 0);
    if (ev.type === 'pointerup' && dist > 70) {
      const k = 300 / dist; g.classList.add('fling');
      g.style.transform = `translate(${(d.dx * k).toFixed(1)}px,${(d.dy * k).toFixed(1)}px) scale(.7)`;
      pick(d.sl);
      setTimeout(() => { if (g.isConnected) { g.classList.remove('fling'); g.style.transform = ''; } }, 420);
    } else g.style.transform = '';
  };
  g.addEventListener('pointerup', end); g.addEventListener('pointercancel', end);
}
function goLevel(lv){
  if (REDUCED) { S.level = lv; draw(false); estimate(); return; }
  $$('#pie .slice').forEach(g => g.classList.add('leaving'));
  setTimeout(() => { S.level = lv; draw(true, 'swap'); estimate(); }, 150);
}

function caption(){
  const c = $('#caption');
  if (!S.files.length) { c.textContent = ''; return; }
  const f = S.files[0], parts = [];
  if (S.kind === 'imgs') parts.push(`<b>${S.files.length} ${T('foto', 'photos')}</b>`, fmt(S.files.reduce((a, x) => a + x.size, 0)));
  else parts.push(`<b>${esc(f.name)}</b>`, S.demo ? T('file d’esempio', 'sample file') : fmt(f.size));
  if (S.kind === 'img' && S.img) {
    const w = Math.round(S.img.width * S.scale), h = Math.round(S.img.height * S.scale), r = S.rot % 180;
    parts.push(`${r ? h : w}×${r ? w : h}`);
    if (S.scale !== 1) parts.push(Math.round(S.scale * 100) + '%');
    if (S.rot) parts.push('↻ ' + S.rot + '°');
    if (S.exif && S.exif.gps) parts.push(`<span class="gps">${T('ha la posizione GPS', 'has GPS location')}</span>`);
    else if (S.exif && S.exif.exif) parts.push(`<span class="gps">${T('ha i metadati EXIF', 'has EXIF metadata')}</span>`);
  }
  if (S.kind === 'pdf' && S.pages) parts.push(S.pages + ' ' + (S.pages === 1 ? T('pagina', 'page') : T('pagine', 'pages')));
  if ((S.kind === 'audio' || S.kind === 'video') && S.duration) parts.push(dur(S.duration));
  if (S.sample) parts.push(T('esempio', 'sample'));
  c.innerHTML = parts.join(' · ');
}

/* ---------- Anteprima: il file compare subito in grande, poi si posa al centro della torta ---------- */
const pv = $('#preview'), pvImg = $('#pvImg');
function showPreview(p, token){
  return new Promise(res => {
    pvImg.onload = pvImg.onerror = null;
    pv.classList.toggle('page', !!p.page);
    $('#pvBadge').textContent = p.badge || '';
    const go = () => {
      if (token !== loadToken) return res(false);
      pv.classList.remove('dock'); void pv.offsetWidth; pv.classList.add('show'); pv.setAttribute('aria-hidden', 'false');
      setTimeout(() => res(true), 950);
    };
    pvImg.onload = go; pvImg.onerror = () => res(false);
    pvImg.src = p.url;
    if (pvImg.complete && pvImg.naturalWidth) { pvImg.onload = null; go(); }
  });
}
function dockPreview(){ if (!pv.classList.contains('show')) return; pv.classList.remove('show'); pv.classList.add('dock'); pv.setAttribute('aria-hidden', 'true'); }
function openPreview(){ if (!S.preview) return; pv.classList.remove('dock'); void pv.offsetWidth; pv.classList.add('show'); pv.setAttribute('aria-hidden', 'false'); }
pv.addEventListener('click', dockPreview);
addEventListener('keydown', ev => { if (ev.key === 'Escape') dockPreview(); });

/* pdf.js da cdnjs, caricato solo quando serve; se non arriva, un'icona curata */
let pdfjsP = null;
const loadPdfjs = () => pdfjsP ??= import(PDFJS_URL).then(lib => { lib.GlobalWorkerOptions.workerSrc = PDFJS_WORKER; return lib; }).catch(e => { pdfjsP = null; throw e; });
async function renderPdf(file){
  const lib = await wait(loadPdfjs(), 9000);
  const task = lib.getDocument({ data: new Uint8Array(await file.arrayBuffer()), isEvalSupported: false });
  const doc = await wait(task.promise, 9000);
  const page = await doc.getPage(1), v1 = page.getViewport({ scale: 1 }), sc = Math.min(2.5, 900 / Math.max(v1.width, v1.height)), vp = page.getViewport({ scale: sc });
  const c = document.createElement('canvas'); c.width = Math.round(vp.width); c.height = Math.round(vp.height);
  const g = c.getContext('2d'); g.fillStyle = '#fff'; g.fillRect(0, 0, c.width, c.height);
  await wait(page.render({ canvasContext: g, viewport: vp }).promise, 9000);
  const pages = doc.numPages; doc.destroy(); return { canvas: c, pages };
}
function countPdfPages(u8){ const s = new TextDecoder('latin1').decode(u8); return (s.match(/\/Type\s*\/Page(?![s\w])/g) || []).length; }
function pdfIcon(name){
  const c = document.createElement('canvas'); c.width = 600; c.height = 780; const g = c.getContext('2d');
  g.fillStyle = '#FAF8EF'; g.beginPath(); g.moveTo(40, 30); g.lineTo(440, 30); g.lineTo(560, 150); g.lineTo(560, 750); g.lineTo(40, 750); g.closePath(); g.fill();
  g.fillStyle = '#E4DFCB'; g.beginPath(); g.moveTo(440, 30); g.lineTo(440, 150); g.lineTo(560, 150); g.closePath(); g.fill();
  g.fillStyle = '#D9D4C0'; for (let i = 0; i < 9; i++) g.fillRect(90, 250 + i * 46, i % 3 === 2 ? 260 : 420, 14);
  g.fillStyle = '#C76B4F'; g.fillRect(40, 600, 520, 110);
  g.fillStyle = '#FAF8EF'; g.font = '900 70px Nunito, system-ui, sans-serif'; g.textAlign = 'center'; g.fillText('PDF', 300, 680);
  g.fillStyle = '#2F3328'; g.font = '700 30px system-ui, sans-serif'; g.fillText(name.length > 26 ? name.slice(0, 24) + '…' : name, 300, 200);
  return c;
}
function videoFrame(file){
  return new Promise(res => {
    const v = document.createElement('video'), u = URL.createObjectURL(file); let done = false;
    const fin = r => { if (done) return; done = true; v.removeAttribute('src'); v.load(); URL.revokeObjectURL(u); res(r); };
    v.muted = true; v.playsInline = true; v.preload = 'auto';
    v.onloadedmetadata = () => { try { v.currentTime = Math.min(1, (v.duration || 2) / 3); } catch (e) { fin(null); } };
    v.onseeked = () => { try { const c = document.createElement('canvas'); c.width = v.videoWidth; c.height = v.videoHeight; if (!c.width) return fin(null); c.getContext('2d').drawImage(v, 0, 0); fin({ canvas: c, duration: v.duration }); } catch (e) { fin(null); } };
    v.onerror = () => fin(null); setTimeout(() => fin(null), 5000);
    v.src = u;
  });
}
function fanImage(imgs){
  const c = document.createElement('canvas'); c.width = 900; c.height = 700; const g = c.getContext('2d');
  const list = imgs.slice(0, 4), n = list.length;
  list.forEach((im, i) => {
    const t = n === 1 ? 0 : i / (n - 1) - .5, w = 460, h = w * im.height / im.width;
    g.save(); g.translate(450 + t * 300, 380 + Math.abs(t) * 60); g.rotate(t * .5);
    g.shadowColor = 'rgba(0,0,0,.45)'; g.shadowBlur = 40; g.shadowOffsetY = 18;
    g.fillStyle = '#F7F5EC'; g.fillRect(-w / 2 - 12, -h / 2 - 12, w + 24, h + 24); g.shadowColor = 'transparent';
    g.drawImage(im, -w / 2, -h / 2, w, h); g.restore();
  });
  return c;
}
function waveBig(buf){
  const c = document.createElement('canvas'); c.width = 900; c.height = 520; const g = c.getContext('2d');
  const grd = g.createLinearGradient(0, 0, 0, 520); grd.addColorStop(0, '#1F3E35'); grd.addColorStop(1, '#0D201A');
  g.fillStyle = grd; g.beginPath(); g.roundRect ? g.roundRect(0, 0, 900, 520, 36) : g.rect(0, 0, 900, 520); g.fill();
  const d = buf.getChannelData(0), bars = 120, per = Math.floor(d.length / bars);
  for (let i = 0; i < bars; i++) {
    let m = 0, sum = 0, cnt = 0;
    for (let k = 0; k < per; k += 32) { const v = Math.abs(d[i * per + k] || 0); m = Math.max(m, v); sum += v * v; cnt++; }
    const rms = Math.sqrt(sum / Math.max(1, cnt)), x = 40 + i * 6.85, hp = Math.max(4, m * 360), hr = Math.max(3, rms * 420);
    g.fillStyle = 'rgba(226,181,98,.35)'; g.fillRect(x, 260 - hp / 2, 4, hp);
    g.fillStyle = i < bars * (30 / Math.max(30, buf.duration)) ? '#E2B562' : '#C76B4F'; g.fillRect(x, 260 - hr / 2, 4, hr);
  }
  return c;
}
function textPaper(text, name){
  const c = document.createElement('canvas'); c.width = 620; c.height = 800; const g = c.getContext('2d');
  g.fillStyle = '#FAF8EF'; g.fillRect(0, 0, 620, 800);
  g.fillStyle = '#2F3328'; g.font = '800 34px Nunito, system-ui, sans-serif'; g.fillText(name.length > 24 ? name.slice(0, 22) + '…' : name, 50, 80);
  g.font = '22px system-ui, sans-serif'; g.fillStyle = '#4E584B';
  let y = 140;
  for (const para of text.split('\n')) {
    let line = '';
    for (const w of para.split(' ')) { const t = line ? line + ' ' + w : w; if (g.measureText(t).width > 520) { g.fillText(line, 50, y); y += 34; line = w; } else line = t; if (y > 760) break; }
    if (y > 760) break; g.fillText(line, 50, y); y += 46;
  }
  return c;
}

/* ---------- Caricamento ---------- */
const dropzone = $('#dropzone');
async function load(files, opts = {}){
  files = [...files]; if (!files.length) return;
  const token = ++loadToken; estToken++;
  const imgs = files.filter(f => kindOf(f) === 'img');
  S = { files, kind: null, img: null, imgs: [], rot: 0, scale: 1, text: null, audio: opts.audio || null, est: {}, level: 'root', exif: null,
    demo: !!opts.demo, sample: !!opts.sample, sampleKind: opts.sampleKind, thumb: null, preview: null, pages: 0, duration: 0, docking: false };
  OUT = null;
  if (files.length > 1 && imgs.length >= 2) { S.kind = 'imgs'; S.files = imgs; }
  else { S.files = [files[0]]; S.kind = kindOf(files[0]); }
  dropzone.hidden = true; $('#fileActions').hidden = false;
  $$('.fcard[data-sample]').forEach(b => b.classList.toggle('active', !!opts.sampleKind && b.dataset.sample === opts.sampleKind));
  pv.classList.remove('show', 'dock'); $('#pie').innerHTML = ''; caption(); rerenderOut(true);
  const f0 = S.files[0];
  try {
    if (S.kind === 'img') {
      S.img = await createImageBitmap(f0);
      S.thumb = thumbOf(S.img);
      S.preview = { url: URL.createObjectURL(f0), badge: `${S.img.width}×${S.img.height}` };
      if (/jpe?g$/.test(extOf(f0.name)) || f0.type === 'image/jpeg') S.exif = exifInfo(new Uint8Array(await f0.slice(0, 262144).arrayBuffer()));
    } else if (S.kind === 'imgs') {
      for (const f of S.files) S.imgs.push(await createImageBitmap(f));
      S.thumb = thumbStack(S.imgs);
      S.preview = { url: fanImage(S.imgs).toDataURL('image/png'), badge: `${S.imgs.length} ${T('foto', 'photos')}` };
    } else if (S.kind === 'heic') {
      try { S.img = await createImageBitmap(f0); S.kind = 'img'; S.thumb = thumbOf(S.img); S.preview = { url: URL.createObjectURL(f0) }; } catch (e) { /* il browser non legge le HEIC */ }
    } else if (S.kind === 'pdf' && !S.demo) {
      let page = null;
      try { page = await renderPdf(f0); } catch (e) { page = null; }
      if (token !== loadToken) return;
      if (page) { S.pages = page.pages; S.thumb = thumbOf(page.canvas, true); S.preview = { url: page.canvas.toDataURL('image/jpeg', .9), page: true, badge: `${page.pages} ${page.pages === 1 ? T('pagina', 'page') : T('pagine', 'pages')}` }; }
      else { const ic = pdfIcon(f0.name); S.pages = countPdfPages(new Uint8Array(await f0.arrayBuffer())); S.thumb = thumbOf(ic, true); S.preview = { url: ic.toDataURL('image/png'), page: true, badge: S.pages ? `${S.pages} ${S.pages === 1 ? T('pagina', 'page') : T('pagine', 'pages')}` : '' }; }
    } else if (S.kind === 'video' && !S.demo) {
      const fr = await videoFrame(f0);
      if (fr) { S.duration = fr.duration; S.thumb = thumbOf(fr.canvas); S.preview = { url: fr.canvas.toDataURL('image/jpeg', .88), badge: `${fr.canvas.width}×${fr.canvas.height} · ${dur(fr.duration)}` }; }
    } else if (S.kind === 'text') {
      S.text = await f0.text(); const pc = textPaper(S.text, f0.name);
      S.thumb = thumbOf(pc, true); S.preview = { url: pc.toDataURL('image/png'), page: true };
    } else if (S.kind === 'audio') {
      if (!S.audio) { const ctx = new OfflineAudioContext(2, 44100, 44100); S.audio = await ctx.decodeAudioData(await f0.arrayBuffer()); }
      S.duration = S.audio.duration; S.thumb = waveThumb(S.audio);
      S.preview = { url: waveBig(S.audio).toDataURL('image/png'), badge: dur(S.audio.duration) };
    }
  } catch (e) { if (['img', 'imgs', 'audio'].includes(S.kind)) S.kind = 'bad'; }
  if (token !== loadToken) return;
  caption();
  if (S.kind === 'img' && !opts.keepQuiz) setQuizSource(S.img, f0);
  estimate();
  if (S.preview && !REDUCED) {
    S.docking = true;
    const shown = await showPreview(S.preview, token);
    if (token !== loadToken) return;
    S.docking = false; if (shown) dockPreview();
  }
  draw(true, 'gulp');
  if (S.kind === 'heic') showInvite({ it: 'Le foto HEIC dell’iPhone', en: 'iPhone HEIC photos' },
    { it: 'Questo browser non sa aprire le HEIC. OrbitLR sì: le converte in JPG tenendo data e posizione GPS, anche cento alla volta.', en: 'This browser can’t open HEIC files. OrbitLR can: it converts them to JPG keeping date and GPS location, even a hundred at a time.' });
  else if (S.kind === 'bad') showInvite({ it: 'Questo file il browser non lo apre', en: 'The browser can’t open this file' }, { it: 'L’app lo apre con il suo motore, sul tuo computer.', en: 'The app opens it with its own engine, on your computer.' });
  else rerenderOut();
}
function resetToDrop(){
  loadToken++; estToken++;
  S = { files: [], kind: null, est: {}, level: 'root' }; OUT = null;
  pv.classList.remove('show', 'dock'); dropzone.hidden = false; $('#fileActions').hidden = true;
  $$('.fcard').forEach(b => b.classList.remove('active'));
  drawGhost(); caption(); rerenderOut(true);
}

function thumbOf(img, top){
  const c = document.createElement('canvas'); c.width = c.height = 220; const g = c.getContext('2d');
  const s = Math.max(220 / img.width, 220 / img.height), w = img.width * s, h = img.height * s;
  g.drawImage(img, (220 - w) / 2, top ? 0 : (220 - h) / 2, w, h); return c.toDataURL('image/jpeg', .85);
}
function thumbStack(imgs){
  const c = document.createElement('canvas'); c.width = c.height = 220; const g = c.getContext('2d');
  g.fillStyle = '#0F231D'; g.fillRect(0, 0, 220, 220);
  imgs.slice(0, 3).forEach((im, i) => {
    g.save(); g.translate(110 + (i - 1) * 26, 116 - (i - 1) * 8); g.rotate((i - 1) * .2);
    const w = 110, h = w * im.height / im.width; g.fillStyle = '#F1F2E8'; g.fillRect(-w / 2 - 4, -h / 2 - 4, w + 8, h + 8); g.drawImage(im, -w / 2, -h / 2, w, h); g.restore();
  });
  return c.toDataURL('image/jpeg', .85);
}
function waveThumb(buf){
  const c = document.createElement('canvas'); c.width = c.height = 220; const g = c.getContext('2d');
  g.fillStyle = '#0F231D'; g.fillRect(0, 0, 220, 220);
  const d = buf.getChannelData(0), bars = 34, per = Math.floor(d.length / bars);
  for (let i = 0; i < bars; i++) {
    let m = 0; for (let k = 0; k < per; k += 64) m = Math.max(m, Math.abs(d[i * per + k] || 0));
    const h = Math.max(4, m * 120); g.fillStyle = i % 2 ? '#C76B4F' : '#E2B562'; g.fillRect(20 + i * 5.3, 110 - h / 2, 3.4, h);
  }
  return c.toDataURL('image/png');
}
/* EXIF: c'è il blocco Exif? c'è la posizione GPS (tag 0x8825)? */
function exifInfo(u){
  if (u[0] !== 0xFF || u[1] !== 0xD8) return null;
  let p = 2;
  while (p + 4 < u.length) {
    if (u[p] !== 0xFF) break;
    const m = u[p + 1], len = (u[p + 2] << 8) | u[p + 3];
    if (m === 0xE1 && u[p + 4] === 0x45 && u[p + 5] === 0x78 && u[p + 6] === 0x69 && u[p + 7] === 0x66) {
      const t = p + 10, le = u[t] === 0x49;
      const r16 = o => le ? u[t + o] | (u[t + o + 1] << 8) : (u[t + o] << 8) | u[t + o + 1];
      const r32 = o => le ? (u[t + o] | (u[t + o + 1] << 8) | (u[t + o + 2] << 16)) + u[t + o + 3] * 16777216 : u[t + o] * 16777216 + ((u[t + o + 1] << 16) | (u[t + o + 2] << 8) | u[t + o + 3]);
      const ifd = r32(4), n = r16(ifd); let gps = false;
      for (let i = 0; i < n; i++) if (r16(ifd + 2 + i * 12) === 0x8825) gps = true;
      return { exif: true, gps };
    }
    if (m === 0xDA) break;
    p += 2 + len;
  }
  return { exif: false, gps: false };
}

/* ---------- Le conversioni vere ---------- */
const toBlob = (c, type, q) => new Promise((res, rej) => c.toBlob(b => b ? res(b) : rej(new Error('encode')), type, q));
function workCanvas(scale = S.scale, im = S.img, rot = S.rot){
  const w = Math.max(1, Math.round(im.width * scale)), h = Math.max(1, Math.round(im.height * scale)), r = rot % 180 !== 0;
  const c = document.createElement('canvas'); c.width = r ? h : w; c.height = r ? w : h;
  const g = c.getContext('2d'); g.imageSmoothingQuality = 'high';
  g.translate(c.width / 2, c.height / 2); g.rotate(rot * Math.PI / 180); g.drawImage(im, -w / 2, -h / 2, w, h);
  return c;
}
function flatten(c){ const d = document.createElement('canvas'); d.width = c.width; d.height = c.height; const g = d.getContext('2d'); g.fillStyle = '#fff'; g.fillRect(0, 0, d.width, d.height); g.drawImage(c, 0, 0); return d; }
async function underBytes(target){
  let scale = S.scale, best = null;
  for (let round = 0; round < 7; round++) {
    const c = flatten(workCanvas(scale));
    let lo = .3, hi = .95, okBlob = null;
    const top = await toBlob(c, 'image/jpeg', hi);
    if (top.size <= target) return top;
    for (let i = 0; i < 7; i++) { const q = (lo + hi) / 2, b = await toBlob(c, 'image/jpeg', q); if (b.size <= target) { okBlob = b; lo = q; } else hi = q; }
    if (okBlob) return okBlob;
    const b = await toBlob(c, 'image/jpeg', .3); best = b;
    scale *= Math.max(.3, Math.sqrt(target / b.size) * .92);
  }
  return best;
}
function cropTo(rw, rh){
  const src = workCanvas(), r = rw / rh;
  let sw = src.width, sh = src.height;
  if (sw / sh > r) sw = Math.round(sh * r); else sh = Math.round(sw / r);
  const maxW = rw >= rh ? 1920 : 1080, k = Math.min(1, maxW / sw);
  const c = document.createElement('canvas'); c.width = Math.round(sw * k); c.height = Math.round(sh * k);
  const g = c.getContext('2d'); g.fillStyle = '#fff'; g.fillRect(0, 0, c.width, c.height); g.imageSmoothingQuality = 'high';
  g.drawImage(src, (src.width - sw) / 2, (src.height - sh) / 2, sw, sh, 0, 0, c.width, c.height);
  return c;
}
// PDF scritto a mano: una pagina per immagine, larga 595 punti (A4)
async function pdfFrom(canvases, q = .88){
  const enc = new TextEncoder(), parts = [], offs = []; let len = 0;
  const add = x => { const b = typeof x === 'string' ? enc.encode(x) : x; parts.push(b); len += b.length; };
  const obj = (n, body, stream) => { offs[n] = len; add(`${n} 0 obj\n${body}\n`); if (stream) { add('stream\n'); add(stream); add('\nendstream\n'); } add('endobj\n'); };
  add('%PDF-1.4\n');
  const N = canvases.length, kids = [];
  for (let i = 0; i < N; i++) kids.push(`${3 + i * 3} 0 R`);
  obj(1, '<< /Type /Catalog /Pages 2 0 R >>');
  obj(2, `<< /Type /Pages /Kids [${kids.join(' ')}] /Count ${N} >>`);
  for (let i = 0; i < N; i++) {
    const c = flatten(canvases[i]), jpg = new Uint8Array(await (await toBlob(c, 'image/jpeg', q)).arrayBuffer());
    const W = 595, H = Math.round(595 * c.height / c.width), pn = 3 + i * 3, content = enc.encode(`q ${W} 0 0 ${H} 0 0 cm /Im0 Do Q`);
    obj(pn, `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${W} ${H}] /Resources << /XObject << /Im0 ${pn + 1} 0 R >> >> /Contents ${pn + 2} 0 R >>`);
    obj(pn + 1, `<< /Type /XObject /Subtype /Image /Width ${c.width} /Height ${c.height} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${jpg.length} >>`, jpg);
    obj(pn + 2, `<< /Length ${content.length} >>`, content);
  }
  const total = 3 + N * 3, xref = len;
  let x = `xref\n0 ${total}\n0000000000 65535 f \n`;
  for (let n = 1; n < total; n++) x += String(offs[n]).padStart(10, '0') + ' 00000 n \n';
  add(x + `trailer\n<< /Size ${total} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`);
  return new Blob(parts, { type: 'application/pdf' });
}
function wavFrom(buf, maxSec){
  const ch = Math.min(2, buf.numberOfChannels), sr = buf.sampleRate, n = Math.min(buf.length, isFinite(maxSec) ? Math.round(maxSec * sr) : buf.length);
  const out = new DataView(new ArrayBuffer(44 + n * ch * 2)), s = (o, t) => [...t].forEach((x, i) => out.setUint8(o + i, x.charCodeAt(0)));
  s(0, 'RIFF'); out.setUint32(4, 36 + n * ch * 2, true); s(8, 'WAVEfmt '); out.setUint32(16, 16, true); out.setUint16(20, 1, true); out.setUint16(22, ch, true);
  out.setUint32(24, sr, true); out.setUint32(28, sr * ch * 2, true); out.setUint16(32, ch * 2, true); out.setUint16(34, 16, true); s(36, 'data'); out.setUint32(40, n * ch * 2, true);
  const data = [...Array(ch)].map((_, i) => buf.getChannelData(i)), fade = isFinite(maxSec) && n < buf.length ? Math.round(sr * 1.5) : 0;
  for (let i = 0, o = 44; i < n; i++) for (let k = 0; k < ch; k++, o += 2) {
    let v = data[k][i]; if (fade && i > n - fade) v *= (n - i) / fade;
    out.setInt16(o, Math.max(-1, Math.min(1, v)) * 32767, true);
  }
  return new Blob([out], { type: 'audio/wav' });
}
const SUFFIX = { smaller: { it: ' (più leggera)', en: ' (smaller)' }, nometa: { it: ' (senza metadati)', en: ' (no metadata)' }, ring: { it: ' (suoneria)', en: ' (ringtone)' }, merged: { it: 'Foto unite', en: 'Merged photos' } };
const typeExt = t => t === 'image/png' ? 'png' : t === 'image/webp' ? 'webp' : 'jpg';

/** Esegue uno spicchio vero: restituisce { blob, name } */
async function run(id){
  const f = S.files[0], b0 = base(f.name);
  const [grp, arg] = id.split(':');
  if (S.kind === 'img') {
    if (grp === 'to') {
      const c = workCanvas();
      if (arg === 'jpg') return { blob: await toBlob(flatten(c), 'image/jpeg', .9), name: b0 + '.jpg' };
      if (arg === 'png') return { blob: await toBlob(c, 'image/png'), name: b0 + '.png' };
      if (arg === 'webp') return { blob: await toBlob(c, 'image/webp', .88), name: b0 + '.webp' };
      if (arg === 'pdf') return { blob: await pdfFrom([c]), name: b0 + '.pdf' };
    }
    if (grp === 'cmp') {
      if (arg === 'best') return { blob: await toBlob(flatten(workCanvas()), 'image/jpeg', .78), name: b0 + L(SUFFIX.smaller) + '.jpg' };
      const kb = +arg; return { blob: await underBytes(kb * 1000), name: `${b0} (${kb >= 1000 ? kb / 1000 + ' MB' : kb + ' KB'}).jpg` };
    }
    if (grp === 'soc') { const [w, h] = arg.split('x').map(Number); return { blob: await toBlob(cropTo(w, h), 'image/jpeg', .9), name: `${b0} (${w}-${h}).jpg` }; }
    if (id === 'mod:strip') {
      const t = ['image/jpeg', 'image/png', 'image/webp'].includes(f.type) ? f.type : 'image/jpeg', c = workCanvas(1, S.img, 0);
      return { blob: await toBlob(t === 'image/jpeg' ? flatten(c) : c, t, .92), name: b0 + L(SUFFIX.nometa) + '.' + typeExt(t) };
    }
  }
  if (S.kind === 'imgs' && id === 'multi:pdf') {
    const cs = S.imgs.map(im => workCanvas(Math.min(1, 2000 / Math.max(im.width, im.height)), im, 0));
    return { blob: await pdfFrom(cs, .85), name: L(SUFFIX.merged) + '.pdf' };
  }
  if (S.kind === 'audio') {
    if (id === 'au:wav') return { blob: wavFrom(S.audio, Infinity), name: b0 + '.wav' };
    if (id === 'au:ring') return { blob: wavFrom(S.audio, 30), name: b0 + L(SUFFIX.ring) + '.wav' };
  }
  if (S.kind === 'text') {
    if (id === 'tx:txt') return { blob: new Blob([S.text.replace(/^#+\s*/gm, '').replace(/[*_`>]/g, '')], { type: 'text/plain' }), name: b0 + '.txt' };
    const e = S.text.replace(/&/g, '&amp;').replace(/</g, '&lt;');
    const html = e.split(/\n{2,}/).map(p => { const h = p.match(/^(#{1,3}) /); return h ? `<h${h[1].length}>${p.slice(h[0].length)}</h${h[1].length}>` : `<p>${p.replace(/\n/g, '<br>')}</p>`; }).join('\n');
    return { blob: new Blob([`<!doctype html><meta charset="utf-8"><title>${esc(b0)}</title><body style="font-family:system-ui;max-width:42rem;margin:2rem auto;line-height:1.6;padding:0 1rem">${html}</body>`], { type: 'text/html' }), name: b0 + '.html' };
  }
  return null;
}

/* Pesi previsti sugli spicchi, uno alla volta, nelle pause del browser */
let estToken = 0;
const estCache = new Map();
const sig = () => [S.files.map(f => f.name + f.size).join('|'), S.rot, S.scale].join('#');
const idle = () => new Promise(r => (window.requestIdleCallback ? requestIdleCallback(() => r(), { timeout: 200 }) : setTimeout(r, 16)));
async function estimate(){
  if (!S.files.length) return;
  const t = ++estToken, ids = estIds();
  for (const id of ids) { const v = estCache.get(sig() + id); S.est[id] = v != null ? { size: v } : { pending: true }; }
  updateEst();
  for (const id of ids) {
    const key = sig() + id; if (estCache.has(key)) continue;
    await idle(); if (t !== estToken) return;
    try { const r = await run(id); if (t !== estToken) return; if (r) { estCache.set(key, r.blob.size); S.est[id] = { size: r.blob.size }; updateEst(); } }
    catch (e) { delete S.est[id]; }
  }
}
function updateEst(){ $$('#pie .slice').forEach(g => { const t = g.querySelector('text.est'); if (t && S.est[g.dataset.id]) t.textContent = estText(g.dataset.id); }); }

/* ---------- Scelta di uno spicchio ---------- */
async function pick(sl){
  if (!sl) return;
  const id = sl.id;
  if (sl.back) { goLevel('root'); return; }
  if (id.startsWith('sub:')) {
    goLevel(id.slice(4));
    if (id === 'sub:more') showInvite({ it: 'Questi spicchi sono nell’app', en: 'These slices are in the app' }, { it: 'Scegline uno per vedere cosa fa. Nell’app li trovi nella scheda Immagini, su una foto o su cento.', en: 'Pick one to see what it does. In the app they are in the Images tab, on one photo or a hundred.' });
    return;
  }
  if (sl.app) { showInvite({ it: sl.it.replace(/\n/g, ' '), en: sl.en.replace(/\n/g, ' ') }, { it: sl.hit, en: sl.hen }, true); return; }
  if (id === 'mod:rot') { S.rot = (S.rot + 90) % 360; afterEdit(); return; }
  if (/^mod:\d+$/.test(id)) { S.scale = +id.slice(4) / 100; afterEdit(); return; }
  if (id === 'mod:reset') { S.rot = 0; S.scale = 1; afterEdit(); return; }
  if (id === 'multi:first') { load([S.files[0]]); return; }
  const g = $(`#pie .slice[data-id="${CSS.escape(id)}"]`); g && g.classList.add('busy');
  try {
    const r = await run(id);
    if (r) {
      const before = S.kind === 'imgs' ? S.files.reduce((a, x) => a + x.size, 0) : S.files[0].size;
      if (OUT && OUT.url) URL.revokeObjectURL(OUT.url);
      OUT = { type: 'result', blob: r.blob, name: r.name, before, id, url: URL.createObjectURL(r.blob) };
      window.__orbitLast = OUT; rerenderOut();
      const hole = $('#pie .hole'); if (hole && !REDUCED) { hole.classList.remove('gulp'); void hole.getBBox(); hole.classList.add('gulp'); }
    }
  } catch (e) { OUT = { type: 'error' }; rerenderOut(); }
  finally { g && g.classList.remove('busy'); }
}
function afterEdit(){ goLevel('root'); caption(); }

/* ---------- Risultato e inviti (stessa zona, altezza riservata) ---------- */
const MORE_AFTER = {
  to: { it: 'Nell’app: anche AVIF, ICO, TIFF e le HEIC dell’iPhone, su cento foto insieme.', en: 'In the app: also AVIF, ICO, TIFF and iPhone HEIC, on a hundred photos at once.' },
  cmp: { it: 'Nell’app lo stesso spicchio comprime anche video e PDF.', en: 'In the app the same slice also compresses videos and PDFs.' },
  soc: { it: 'Nell’app il formato social funziona anche sui video.', en: 'In the app the social format works on videos too.' },
  mod: { it: 'Qui la foto è stata ricodificata. L’app toglie i metadati senza perdere qualità.', en: 'Here the photo was re-encoded. The app removes metadata without losing quality.' },
  multi: { it: 'Nell’app scegli l’ordine, e unisci anche PDF e video.', en: 'In the app you choose the order, and merge PDFs and videos too.' },
  au: { it: 'Nell’app: MP3, «Vai al ritornello», taglio sulla forma d’onda.', en: 'In the app: MP3, “Go to Chorus”, trimming on the waveform.' },
  tx: { it: 'Nell’app: Word, Excel, PowerPoint e PDF.', en: 'In the app: Word, Excel, PowerPoint and PDF.' },
};
const HINTS = {
  img: { it: 'Tocca uno spicchio, o trascinalo fuori dalla torta. Tocca il centro per rivedere la foto.', en: 'Tap a slice, or drag it out of the pie. Tap the centre to see the photo again.' },
  imgs: { it: 'Più foto, un PDF: tocca «Unisci in un PDF».', en: 'Several photos, one PDF: tap “Merge into PDF”.' },
  audio: { it: 'Tocca «Suoneria»: i primi 30 secondi, con la sfumatura alla fine.', en: 'Tap “Ringtone”: the first 30 seconds, fading out at the end.' },
  text: { it: 'Tocca uno spicchio per convertire il testo.', en: 'Tap a slice to convert the text.' },
  video: { it: 'I video si lavorano nell’app, con il chip video del computer. Tocca uno spicchio.', en: 'Videos are handled in the app, with your computer’s video chip. Tap a slice.' },
  pdf: { it: 'I PDF si lavorano nell’app. Tocca il centro per rivedere la pagina, o uno spicchio.', en: 'PDFs are handled in the app. Tap the centre to see the page again, or a slice.' },
  doc: { it: 'Word, Excel e PowerPoint si convertono nell’app.', en: 'Word, Excel and PowerPoint are converted in the app.' },
};
function showInvite(title, hint, fromSlice){ OUT = { type: 'invite', title, hint, fromSlice }; rerenderOut(); }
function rerenderOut(blank){
  const o = $('#out'); o.innerHTML = '';
  const d = document.createElement('div');
  if (blank) return;
  if (!OUT) { d.className = 'hint'; d.textContent = L(HINTS[S.kind]) || ''; if (d.textContent) o.append(d); return; }
  if (OUT.type === 'result') {
    const pct = Math.round((OUT.before - OUT.blob.size) / OUT.before * 100);
    const gain = T('Fatto', 'Done') + ' · ' + T('da ', 'from ') + fmt(OUT.before) + T(' a ', ' to ') + fmt(OUT.blob.size) + (pct >= 3 ? ' · −' + pct + '%' : pct <= -3 ? ' · +' + (-pct) + '%' : '');
    const isImg = OUT.blob.type.startsWith('image/');
    d.className = 'ticket';
    d.innerHTML = `${isImg ? `<img class="thumb" alt="" src="${OUT.url}">` : `<div class="thumb" style="display:grid;place-items:center;font-family:var(--display);font-weight:900;color:#2F7A4C">${extOf(OUT.name).toUpperCase()}</div>`}
      <div class="tt"><b>${esc(OUT.name)}</b><span class="gain">${gain}</span><div class="more">${L(MORE_AFTER[OUT.id.split(':')[0]])}</div></div>
      <button class="dl" type="button" id="dlBtn">${OUT.saved ? T('Scaricato ✓', 'Saved ✓') : T('Scarica', 'Download')}</button>`;
    o.append(d); $('#dlBtn').addEventListener('click', save); return;
  }
  if (OUT.type === 'error') { d.className = 'hint'; d.textContent = T('Questa conversione non è riuscita nel browser. Nell’app passa dal suo motore.', 'This conversion failed in the browser. The app uses its own engine.'); o.append(d); return; }
  d.className = 'ticket invite';
  d.innerHTML = `<div class="tt"><span class="apptag">${OUT.fromSlice ? T('LO FA L’APP', 'THE APP DOES IT') : T('NELL’APP', 'IN THE APP')}</span><b>${esc(L(OUT.title))}</b><div class="more">${esc(L(OUT.hint))}</div></div>
    <div class="two"><a href="${MAC_URL}" target="_blank" rel="noopener">${T('Scarica per Mac', 'Get it for Mac')}</a><a class="alt" href="${WIN_URL}" target="_blank" rel="noopener">Windows</a></div>`;
  o.append(d);
}
/* Scarica: dentro claude.ai passa dalla conferma del visualizzatore; fuori (GitHub Pages) è un normale download */
let saver = null;
try { (window.claude && window.claude.use ? window.claude.use('downloads') : Promise.resolve(null)).then(d => { saver = d; }, () => { saver = null; }); } catch (e) {}
async function save(){
  if (!OUT || OUT.type !== 'result') return;
  if (saver) { try { await saver.save({ filename: OUT.name, data: OUT.blob }); OUT.saved = true; rerenderOut(); } catch (e) { /* annullato */ } return; }
  const a = document.createElement('a'); a.href = OUT.url; a.download = OUT.name; document.body.append(a); a.click(); a.remove();
  OUT.saved = true; rerenderOut();
}

/* ---------- Esempi ---------- */
function drawScene(w, h, v){
  const c = document.createElement('canvas'); c.width = w; c.height = h; const g = c.getContext('2d');
  const P3 = [['#8EC0EA', '#F6D9A8', '#3F7FA6', '#5E8F78', '#FFE39A'], ['#2B3F6B', '#E98C5F', '#24324F', '#1C2A3B', '#FFD27A'], ['#BFD8C6', '#F4EFD8', '#6E9C83', '#3E6150', '#FFFFFF']][v % 3];
  const sky = g.createLinearGradient(0, 0, 0, h); sky.addColorStop(0, P3[0]); sky.addColorStop(.62, P3[1]); g.fillStyle = sky; g.fillRect(0, 0, w, h);
  g.fillStyle = P3[4]; g.beginPath(); g.arc(w * .72, h * .43, h * .09, 0, 7); g.fill();
  if (v % 3 === 2) { g.fillStyle = P3[2]; for (let i = 0; i < 4; i++) { g.beginPath(); g.moveTo(w * (i * .3 - .1), h * .75); g.lineTo(w * (i * .3 + .12), h * (.32 + (i % 2) * .08)); g.lineTo(w * (i * .3 + .34), h * .75); g.fill(); } }
  g.fillStyle = P3[2]; g.fillRect(0, h * .63, w, h * .37);
  let seed = 7 + v; const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
  for (let i = 0; i < 4200; i++) { g.fillStyle = `rgba(255,255,255,${rnd() * .22})`; g.fillRect(rnd() * w, h * .63 + rnd() * h * .37, 2 + rnd() * 14, 2); }
  g.fillStyle = P3[3]; g.beginPath(); g.moveTo(0, h * .68); g.bezierCurveTo(w * .25, h * .53, w * .44, h * .63, w * .62, h * .67); g.lineTo(w * .62, h); g.lineTo(0, h); g.fill();
  if (v % 3 === 1) { g.fillStyle = '#121A26'; for (let i = 0; i < 14; i++) { const bw = w * .045, bh = h * (.12 + rnd() * .2); g.fillRect(w * .5 + i * bw * 1.05, h * .63 - bh, bw, bh); } }
  if (v % 3 === 0) {
    g.fillStyle = '#F7F3E6'; g.beginPath(); g.moveTo(w * .80, h * .70); g.lineTo(w * .88, h * .70); g.lineTo(w * .86, h * .73); g.lineTo(w * .82, h * .73); g.fill();
    g.fillStyle = '#C76B4F'; g.beginPath(); g.moveTo(w * .84, h * .70); g.lineTo(w * .84, h * .58); g.lineTo(w * .875, h * .69); g.fill();
    g.strokeStyle = '#2F3328'; g.lineWidth = 3; for (let i = 0; i < 5; i++) { const x = w * (.2 + i * .09), y = h * (.18 + (i % 2) * .06); g.beginPath(); g.moveTo(x - 14, y); g.quadraticCurveTo(x - 7, y - 8, x, y); g.quadraticCurveTo(x + 7, y - 8, x + 14, y); g.stroke(); }
  }
  return c;
}
const toFile = async (c, name, type = 'image/jpeg', q = .9) => new File([await toBlob(c, type, q)], name, { type });
function synthMelody(){
  const sr = 22050, n = sr * 42, buf = new AudioBuffer({ length: n, numberOfChannels: 1, sampleRate: sr }), d = buf.getChannelData(0);
  const notes = [0, 4, 7, 12, 7, 4, 2, 5, 9, 14, 9, 5, -3, 0, 4, 9, 4, 0, -5, -1, 2, 7, 2, -1];
  for (let i = 0; i < n; i++) {
    const t = i / sr, k = Math.floor(t / .25), tn = t - k * .25, f = 261.63 * Math.pow(2, notes[k % notes.length] / 12);
    const env = Math.exp(-tn * 6) * (k % 4 === 0 ? 1 : .7) * (.55 + .45 * Math.sin(t / 42 * Math.PI)), bass = Math.sin(2 * Math.PI * 65.4 * Math.pow(2, notes[(k >> 2 << 2) % notes.length] / 12) * t) * .12;
    d[i] = (Math.sin(2 * Math.PI * f * t) * .5 + Math.sin(4 * Math.PI * f * t) * .12) * env * .6 + bass;
  }
  return buf;
}
const sampleCache = {};
async function sample(kind){
  const k = LANG + kind;
  if (kind === 'photo') { sampleCache[k] ??= await toFile(drawScene(1600, 1200, 0), T('Vacanze al mare.png', 'Seaside holiday.png'), 'image/png'); return load([sampleCache[k]], { sample: true, sampleKind: kind }); }
  if (kind === 'photos') { sampleCache[k] ??= await Promise.all([0, 1, 2].map(v => toFile(drawScene(1200, 900, v), [T('Mare', 'Sea'), T('Città', 'City'), T('Montagna', 'Mountain')][v] + '.jpg'))); return load(sampleCache[k], { sample: true, sampleKind: kind }); }
  if (kind === 'pdf') { sampleCache[k] ??= new File([await pdfFrom([drawScene(1200, 1600, 0), drawScene(1200, 1600, 2)], .85)], T('Opuscolo.pdf', 'Brochure.pdf'), { type: 'application/pdf' }); return load([sampleCache[k]], { sample: true, sampleKind: kind }); }
  if (kind === 'audio') { sampleCache.audio ??= synthMelody(); const f = new File([wavFrom(sampleCache.audio, Infinity)], T('Melodia d’esempio.wav', 'Sample tune.wav'), { type: 'audio/wav' }); return load([f], { sample: true, audio: sampleCache.audio, sampleKind: kind }); }
  if (kind === 'video') return load([new File([new Uint8Array(16)], T('Gita in montagna.mp4', 'Mountain trip.mp4'), { type: 'video/mp4' })], { demo: true, sample: true, sampleKind: kind });
}

/* ---------- File d'esempio da lanciare nella torta ---------- */
const dial = $('#dial');
function pieCircle(){ const r = dial.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2, r: r.width * .47 }; }
function throwInto(card){
  const kind = card.dataset.sample;
  if (REDUCED) { sample(kind); return; }
  const c = pieCircle(), r = card.getBoundingClientRect(), cs = getComputedStyle(card).transform, cur = new DOMMatrix(cs === 'none' ? undefined : cs);
  const hx = r.left + r.width / 2 - cur.m41, hy = r.top + r.height / 2 - cur.m42;
  card.classList.remove('drag'); card.classList.add('gone');
  card.style.transform = `translate(${(c.x - hx).toFixed(0)}px,${(c.y - hy).toFixed(0)}px) scale(.25) rotate(${(c.x > hx ? 24 : -24)}deg)`;
  setTimeout(() => {
    sample(kind);
    card.classList.remove('gone'); card.style.transition = 'none'; card.style.transform = 'scale(.5)'; card.style.opacity = '0';
    requestAnimationFrame(() => requestAnimationFrame(() => { card.style.transition = ''; card.style.transform = ''; card.style.opacity = ''; }));
  }, 400);
}
$$('.fcard[data-sample]').forEach(card => {
  let d = null;
  card.addEventListener('click', () => { if (card._suppress) { card._suppress = false; return; } throwInto(card); });
  card.addEventListener('pointerdown', ev => { if (ev.button !== 0) return; d = { x: ev.clientX, y: ev.clientY, moved: false, hist: [[ev.clientX, ev.clientY, ev.timeStamp]] }; try { card.setPointerCapture(ev.pointerId); } catch (e) {} });
  card.addEventListener('pointermove', ev => {
    if (!d) return;
    const dx = ev.clientX - d.x, dy = ev.clientY - d.y;
    if (!d.moved && Math.hypot(dx, dy) > 6) { d.moved = true; card.classList.add('drag'); try { card.setPointerCapture(ev.pointerId); } catch (e) {} }
    if (!d.moved) return;
    d.hist.push([ev.clientX, ev.clientY, ev.timeStamp]); if (d.hist.length > 6) d.hist.shift();
    card.style.transform = `translate(${dx}px,${dy}px) rotate(${clamp(dx * .05, -14, 14)}deg) scale(1.06)`;
    const c = pieCircle(); dial.classList.toggle('hot', Math.hypot(ev.clientX - c.x, ev.clientY - c.y) < c.r);
  });
  const end = ev => {
    if (!d) return; const dd = d; d = null; dial.classList.remove('hot');
    if (!dd.moved) return;
    card._suppress = true; setTimeout(() => { card._suppress = false; }, 60);
    const a = dd.hist[0], b = dd.hist[dd.hist.length - 1], dt = Math.max(16, b[2] - a[2]);
    const vx = (b[0] - a[0]) / dt, vy = (b[1] - a[1]) / dt, c = pieCircle(), sp = Math.hypot(vx, vy) || 1;
    const inside = Math.hypot(ev.clientX - c.x, ev.clientY - c.y) < c.r;
    const px = ev.clientX + vx * 220, py = ev.clientY + vy * 220;
    const tx = c.x - ev.clientX, ty = c.y - ev.clientY, toward = (tx * vx + ty * vy) > 0 && sp > .35;
    const miss = toward ? Math.abs(tx * vy - ty * vx) / sp : Infinity;
    if (ev.type === 'pointerup' && (inside || Math.hypot(px - c.x, py - c.y) < c.r || miss < c.r)) throwInto(card);
    else { card.classList.remove('drag'); card.style.transform = ''; }
  };
  card.addEventListener('pointerup', end); card.addEventListener('pointercancel', end);
});

/* ---------- La torta segue il cursore; una luce calda la accompagna ---------- */
const hero = $('#prova'), tilt = $('#tilt'), glow = $('#glow');
const TL = { tx: 0, ty: 0, x: 0, y: 0, gx: 0, gy: 0, gtx: 0, gty: 0, running: false };
function heroDefaults(){ const r = hero.getBoundingClientRect(), d = dial.getBoundingClientRect(); TL.gtx = d.left - r.left + d.width / 2; TL.gty = d.top - r.top + d.height / 2; }
function tiltLoop(){
  TL.x += (TL.tx - TL.x) * .12; TL.y += (TL.ty - TL.y) * .12; TL.gx += (TL.gtx - TL.gx) * .1; TL.gy += (TL.gty - TL.gy) * .1;
  tilt.style.transform = `perspective(1100px) rotateX(${(-TL.y * 7).toFixed(2)}deg) rotateY(${(TL.x * 9).toFixed(2)}deg)`;
  glow.style.transform = `translate3d(${TL.gx.toFixed(1)}px,${TL.gy.toFixed(1)}px,0)`;
  const busy = Math.abs(TL.tx - TL.x) + Math.abs(TL.ty - TL.y) > .002 || Math.abs(TL.gtx - TL.gx) + Math.abs(TL.gty - TL.gy) > .5;
  if (!busy) TL.running = false; return busy;
}
const kickTilt = () => { if (!TL.running) { TL.running = true; addLoop(tiltLoop); } };
if (!REDUCED) {
  heroDefaults(); TL.gx = TL.gtx; TL.gy = TL.gty; glow.style.transform = `translate3d(${TL.gx}px,${TL.gy}px,0)`;
  hero.addEventListener('pointermove', ev => {
    if (ev.pointerType !== 'mouse' || sliceDrag) return;
    const d = dial.getBoundingClientRect(), r = hero.getBoundingClientRect();
    TL.tx = clamp((ev.clientX - (d.left + d.width / 2)) / (d.width * .9), -1, 1); TL.ty = clamp((ev.clientY - (d.top + d.height / 2)) / (d.height * .9), -1, 1);
    TL.gtx = ev.clientX - r.left; TL.gty = ev.clientY - r.top; kickTilt();
  });
  hero.addEventListener('pointerleave', () => { TL.tx = TL.ty = 0; heroDefaults(); kickTilt(); });
  addEventListener('resize', () => { heroDefaults(); kickTilt(); });
} else glow.hidden = true;

/* ---------- La sfida: quanto pesa dopo? (sulla tua foto, o su quella d'esempio) ---------- */
const QS = { src: null, size: 0, type: '', thumb: '' };
function setQuizSource(img, file){
  const k = Math.min(1, 1400 / Math.max(img.width, img.height));
  const c = document.createElement('canvas'); c.width = Math.round(img.width * k); c.height = Math.round(img.height * k);
  const g = c.getContext('2d'); g.imageSmoothingQuality = 'high'; g.drawImage(img, 0, 0, c.width, c.height);
  QS.src = flatten(c); QS.size = file.size; QS.type = extOf(file.name).toUpperCase(); QS.thumb = thumbOf(QS.src);
  resetQuiz();
}
const ROUNDS = [
  { type: 'image/jpeg', q: .3, it: 'in JPG a qualità 30', en: 'as JPG at quality 30', f: [.32, 2.6], why: { it: 'Il JPG butta i dettagli che l’occhio nota meno.', en: 'JPG drops the details the eye notices least.' } },
  { type: 'image/webp', q: .6, it: 'in WEBP a qualità 60', en: 'as WEBP at quality 60', f: [3.1, .4], why: { it: 'Il WEBP pesa meno del JPG a parità di qualità.', en: 'WEBP weighs less than JPG at the same quality.' } },
  { type: 'image/png', it: 'in PNG, senza perdita', en: 'as PNG, lossless', f: [.18, .45], why: { it: 'Il PNG non perde niente, e si vede sul peso.', en: 'PNG loses nothing, and it shows in the size.' } },
];
const ORDER = [[1, 0, 2], [0, 2, 1], [2, 1, 0]];
const QZ = { round: 0, score: 0, answered: null, sizes: null, token: 0 };
async function resetQuiz(){
  QZ.round = 0; QZ.score = 0; QZ.answered = null; QZ.sizes = null; const t = ++QZ.token; renderQuiz();
  const sizes = [];
  for (const r of ROUNDS) { await idle(); if (t !== QZ.token) return; sizes.push((await toBlob(QS.src, r.type, r.q)).size); }
  QZ.sizes = sizes; renderQuiz();
}
function renderQuiz(){
  const box = $('#quiz'); if (!box) return;
  if (!QS.src) { box.innerHTML = `<div class="qk"><span>${T('Sfida', 'Challenge')}</span></div><h3>${T('Quanto pesa una foto dopo?', 'How much does a photo weigh after?')}</h3>`; return; }
  const dots = ROUNDS.map((_, i) => `<i class="${i < QZ.round || (i === QZ.round && QZ.answered != null) ? 'on' : ''}"></i>`).join('');
  if (QZ.round >= ROUNDS.length) {
    box.innerHTML = `<div class="qk"><span>${T('Sfida finita', 'Challenge over')}</span><span class="dots">${dots}</span></div>
      <p class="score">${QZ.score} ${T('su', 'of')} ${ROUNDS.length}</p>
      <h3>${T('L’app non ti fa indovinare.', 'The app doesn’t make you guess.')}</h3>
      <p class="why">${T('Scegli il peso che ti serve (per un modulo, un visto, un’email) e OrbitLR trova da sola la qualità più alta che ci sta dentro. Anche su video e PDF.', 'Choose the size you need (for a form, a visa, an email) and OrbitLR finds the highest quality that fits. On videos and PDFs too.')}</p>
      <div style="display:flex;gap:10px;flex-wrap:wrap"><a class="btn gold" href="#scarica" data-goto-dl>${T('Ottieni l’app', 'Get the app')}</a><button class="next" type="button" id="qAgain">${T('Rigioca', 'Play again')}</button></div>`;
    $('#qAgain').addEventListener('click', resetQuiz); return;
  }
  const r = ROUNDS[QZ.round];
  const head = `<div class="qk"><span>${T('Sfida', 'Challenge')} · ${QZ.round + 1}/${ROUNDS.length}</span><span class="dots">${dots}</span></div>
    <img class="qthumb" src="${QS.thumb}" alt="">
    <h3>${T('Questa foto pesa', 'This photo weighs')} ${fmt(QS.size)}. ${T('Quanto pesa', 'How much does it weigh')} ${L(r)}?</h3>`;
  if (!QZ.sizes) { box.innerHTML = head + `<p class="why">${T('Sto pesando la foto…', 'Weighing the photo…')}</p>`; return; }
  const real = QZ.sizes[QZ.round], vals = [real, real * r.f[0], real * r.f[1]], ord = ORDER[QZ.round];
  box.innerHTML = head + `<div class="opts">${ord.map(i => {
      const cls = QZ.answered == null ? '' : i === 0 ? 'right' : i === QZ.answered ? 'wrong' : '';
      const mark = QZ.answered == null ? '' : i === 0 ? `<i>${T('vero', 'real')}</i>` : i === QZ.answered ? `<i>${T('no', 'no')}</i>` : '';
      return `<button class="opt ${cls}" type="button" data-i="${i}" ${QZ.answered != null ? 'disabled' : ''}><span>≈ ${fmt(Math.round(vals[i]))}</span>${mark}</button>`; }).join('')}</div>` +
    (QZ.answered != null ? `<p class="why"><b>${QZ.answered === 0 ? T('Esatto.', 'Right.') : T('Quasi.', 'Close.')}</b> ${L(r.why)}</p><button class="next" type="button" id="qNext">${QZ.round < ROUNDS.length - 1 ? T('Avanti', 'Next') : T('Risultato', 'Result')} →</button>` : '');
  $$('#quiz .opt').forEach(b => b.addEventListener('click', () => { QZ.answered = +b.dataset.i; if (QZ.answered === 0) QZ.score++; renderQuiz(); $('#qNext')?.focus({ preventScroll: true }); }));
  $('#qNext')?.addEventListener('click', () => { QZ.round++; QZ.answered = null; renderQuiz(); });
}

/* ---------- Il manifesto: scorrendo, la torta si riempie di quello che fa l'app ---------- */
const MG = [
  { it: 'Foto', en: 'Photos', c: 'var(--s4)', t: [['Comprimi sotto un peso', 'Compress under a size'], ['Rimuovi lo sfondo', 'Remove Background'], ['Migliora con l’IA', 'Enhance with AI'], ['Da logo a SVG', 'Logo to SVG']] },
  { it: 'Video', en: 'Video', c: 'var(--s3)', t: [['Taglia senza perdita', 'Lossless Trim'], ['Formato social', 'Social Format'], ['Sottotitoli', 'Subtitles'], ['Montaggio', 'Editor']] },
  { it: 'Audio', en: 'Audio', c: 'var(--s2)', t: [['Suoneria', 'Ringtone'], ['Voce più pulita', 'Cleaner Voice'], ['Trascrivi', 'Transcribe'], ['Da un link', 'From a Link']] },
  { it: 'PDF', en: 'PDF', c: 'var(--s1)', t: [['Compila e firma', 'Fill and Sign'], ['Unisci e dividi', 'Merge and Split'], ['Proteggi con password', 'Protect with Password'], ['Comprimi il PDF', 'Compress PDF']] },
  { it: 'Comodità', en: 'Convenience', c: 'var(--s6)', t: [['Ricette', 'Recipes'], ['Cartelle automatiche', 'Automatic Folders'], ['Al telefono', 'To Phone'], ['⌥⌘C · Ctrl+Alt+C', '⌥⌘C · Ctrl+Alt+C']] },
  { it: 'Privacy', en: 'Privacy', c: 'var(--s5)', t: [['Senza metadati', 'No Metadata'], ['Niente caricato', 'Nothing Uploaded'], ['Nessun account', 'No Account'], ['Aggiornamenti firmati', 'Signed Updates']] },
];
const MT = MG.flatMap((g, gi) => g.t.map(t => ({ g: gi, it: t[0], en: t[1] })));
const M = { p: -1, count: -1, cur: -1, manual: -1, rot: 0, rotT: 0, lines: $$('#mLines .m-line'), slices: [] };
(function buildBigPie(){
  const svg = $('#bigpie'), n = MT.length, step = Math.PI * 2 / n;
  MT.forEach((t, i) => {
    const a0 = -Math.PI / 2 + i * step, a1 = a0 + step;
    const g = el('g', { class: 'bp' }); g.append(el('path', { d: sector(96, 240, a0, a1), fill: MG[t.g].c }));
    g.addEventListener('pointerenter', () => { if (M.slices[i].classList.contains('on')) { M.manual = i; manifestoCenter(); } });
    g.addEventListener('click', () => { M.manual = i; g.classList.add('on'); manifestoCenter(); });
    svg.append(g); M.slices.push(g);
  });
})();
function manifestoCenter(force){
  const i = M.manual >= 0 ? M.manual : M.cur;
  const key = i + LANG; if (!force && key === M.lastKey) return; M.lastKey = key;
  M.slices.forEach((g, k) => g.classList.toggle('cur', k === i));
  if (i < 0) { $('#mGroup').textContent = 'OrbitLR'; $('#mTool').textContent = T('Scorri ↓', 'Scroll ↓'); return; }
  $('#mGroup').textContent = L(MG[MT[i].g]); $('#mTool').textContent = L(MT[i]);
}
const manifesto = $('#torta');
function manifestoUpdate(){
  if (TAB !== 'app') return;
  const r = manifesto.getBoundingClientRect(), total = r.height - innerHeight;
  const p = REDUCED ? 1 : clamp(-r.top / Math.max(1, total), 0, 1);
  if (Math.abs(p - M.p) < .0005) return;
  M.p = p;
  const count = REDUCED ? MT.length : clamp(Math.ceil(p * 1.2 * MT.length), 0, MT.length);
  if (count !== M.count) { M.slices.forEach((g, i) => g.classList.toggle('on', i < count)); M.count = count; M.cur = count - 1; M.manual = -1; manifestoCenter(); }
  const lineOn = REDUCED ? 4 : [0, .18, .42, .62].filter(x => p >= x).length;
  M.lines.forEach((l, i) => l.classList.toggle('on', i < Math.max(1, lineOn)));
  M.rotT = REDUCED ? 0 : -p * 150;
  addLoop(rotLoop);
}
function rotLoop(){ M.rot += (M.rotT - M.rot) * .14; if (Math.abs(M.rotT - M.rot) < .02) M.rot = M.rotT; $('#mRot').style.transform = `rotate(${M.rot.toFixed(2)}deg)`; return M.rot !== M.rotT; }

/* ---------- Cosa fa: una torta per Foto, Video, Audio, PDF ---------- */
const CATS = [
  { it: 'Foto', en: 'Photos', c: 'var(--s4)', t: [
    ['Converti', 'Convert', 'Converti in ogni formato', 'Convert to any format', 'JPG, PNG, WEBP, AVIF, ICO, TIFF, GIF e PDF. Anche le HEIC dell’iPhone, con data e posizione.', 'JPG, PNG, WEBP, AVIF, ICO, TIFF, GIF and PDF. iPhone HEIC too, keeping date and location.'],
    ['Comprimi', 'Compress', 'Comprimi sotto un peso', 'Compress under a size', 'Stessa qualità con meno peso, o sotto il peso che chiede un modulo: 500 KB, 200 KB, 50 KB.', 'Same quality, smaller file, or under the size a form asks for: 500 KB, 200 KB, 50 KB.'],
    ['Sfondo', 'Background', 'Rimuovi lo sfondo', 'Remove Background', 'Resta solo il soggetto: trasparente, su bianco o ritagliato.', 'Only the subject stays: transparent, on white or cropped.'],
    ['IA', 'AI', 'Migliora con l’IA e ingrandisci', 'Enhance with AI and upscale', 'Più nitida senza inventare dettagli; due o quattro volte più grande.', 'Sharper without inventing details; two or four times bigger.'],
    ['Scanner', 'Scanner', 'Raddrizza un documento', 'Straighten a Document', 'La foto storta di un foglio diventa una pagina dritta, JPG o PDF.', 'A crooked photo of a sheet becomes a straight page, JPG or PDF.'],
    ['SVG', 'SVG', 'Vettoriale (SVG)', 'Vector (SVG)', 'Loghi, disegni e firme diventano SVG: colori puliti, angoli netti, nitidi a qualunque misura. Con «Precisione massima» ricalca ogni curva.', 'Logos, drawings and signatures become SVG: clean colors, crisp corners, sharp at any size. “Maximum precision” traces every curve.'] ] },
  { it: 'Video', en: 'Video', c: 'var(--s3)', t: [
    ['Comprimi', 'Compress', 'Comprimi', 'Compress', 'Di solito la metà del peso, o per Discord 9 MB, WhatsApp 15 MB, email 18 MB.', 'Usually half the size, or for Discord 9 MB, WhatsApp 15 MB, email 18 MB.'],
    ['Taglia', 'Trim', 'Taglia senza perdita', 'Lossless Trim', 'Tieni solo un pezzo, in pochi secondi anche su un film di due ore.', 'Keep just a piece, in seconds even on a two-hour film.'],
    ['Social', 'Social', 'Formato social', 'Social Format', '9:16, 1:1, 4:5 o 16:9 per Reels, TikTok, Shorts e YouTube.', '9:16, 1:1, 4:5 or 16:9 for Reels, TikTok, Shorts and YouTube.'],
    ['Sottotitoli', 'Subtitles', 'Trascrivi e sottotitoli', 'Transcribe and Subtitles', 'Le parole diventano testo e sottotitoli .srt, sul computer.', 'Speech becomes text and .srt subtitles, on the computer.'],
    ['Montaggio', 'Editor', 'Montaggio', 'Editor', 'Clip, testi, musica e «Togli i silenzi»: restano i pezzi in cui si parla.', 'Clips, text, music and “Remove Silences”: only the parts where you speak stay.'],
    ['GIF', 'GIF', 'GIF e velocità', 'GIF and Speed', 'Un’animazione da un tratto; da un quarto a quattro volte, la voce tiene il tono.', 'An animation from a stretch; from ¼× to 4×, the voice keeps its pitch.'] ] },
  { it: 'Audio', en: 'Audio', c: 'var(--s2)', t: [
    ['Converti', 'Convert', 'Converti', 'Convert', 'MP3, M4A, WAV, FLAC, OGG, OPUS.', 'MP3, M4A, WAV, FLAC, OGG, OPUS.'],
    ['Suoneria', 'Ringtone', 'Suoneria', 'Ringtone', '«Vai al ritornello» trova il pezzo più pieno della canzone.', '“Go to Chorus” finds the fullest part of the song.'],
    ['Voce', 'Voice', 'Voce più pulita', 'Cleaner Voice', 'Meno ronzio e fruscio, volume uniforme.', 'Less hum and hiss, even volume.'],
    ['Trascrivi', 'Transcribe', 'Trascrivi e testo in voce', 'Transcribe, Text to Speech', 'Dalla voce al testo e dal testo alla voce, sul computer.', 'From voice to text and back, on the computer.'],
    ['WhatsApp', 'WhatsApp', 'Vocale per WhatsApp', 'WhatsApp Voice Note', 'Leggero, per i messaggi.', 'Light, for messages.'],
    ['Link', 'Link', 'Da un link', 'From a Link', 'Incolli il link e l’audio arriva in Download. Solo ciò che hai il diritto di scaricare.', 'Paste a link and the audio lands in Downloads. Only what you have the right to download.'] ] },
  { it: 'PDF', en: 'PDF', c: 'var(--s1)', t: [
    ['Comprimi', 'Compress', 'Comprimi il PDF', 'Compress PDF', 'Per l’email: testo, link e moduli restano come sono.', 'For email: text, links and forms stay as they are.'],
    ['Firma', 'Sign', 'Compila e firma', 'Fill and Sign', 'Moduli, firma, data e testo. Su Windows anche l’oscuramento vero dei dati.', 'Forms, signature, date and text. On Windows also true redaction.'],
    ['Unisci', 'Merge', 'Unisci, dividi, riordina', 'Merge, Split, Reorder', 'Più PDF in uno, un PDF per pagina, alcune pagine, un nuovo ordine.', 'Several PDFs into one, one per page, some pages, a new order.'],
    ['Password', 'Password', 'Proteggi con password', 'Protect with Password', 'AES-256. E se la conosci, la togli.', 'AES-256. And if you know it, remove it.'],
    ['Testo', 'Text', 'Estrai il testo', 'Extract Text', 'Anche dai PDF scansionati.', 'Even from scanned PDFs.'],
    ['Office', 'Office', 'Word, Excel, PowerPoint', 'Word, Excel, PowerPoint', 'In PDF, DOCX, ODT, XLSX, CSV, PPTX (con LibreOffice, facoltativo).', 'To PDF, DOCX, ODT, XLSX, CSV, PPTX (with optional LibreOffice).'] ] },
];
const CAT = { i: 0, j: 0, touched: false, timer: 0, visible: false };
function renderCats(animate = true){
  const tabs = $('#catTabs');
  tabs.innerHTML = CATS.map((c, i) => `<button type="button" role="tab" class="cat-tab" style="--c:${c.c}" aria-selected="${i === CAT.i}" data-i="${i}"><i></i>${L(c)}<small>${c.t.length}</small></button>`).join('');
  tabs.querySelectorAll('.cat-tab').forEach(b => b.addEventListener('click', () => { CAT.touched = true; CAT.i = +b.dataset.i; CAT.j = 0; renderCats(); }));
  const cat = CATS[CAT.i], svg = $('#catpie'); svg.innerHTML = '';
  const n = cat.t.length, step = Math.PI * 2 / n, start = -Math.PI / 2 - step / 2;
  cat.t.forEach((t, j) => {
    const a0 = start + j * step, a1 = a0 + step, mid = (a0 + a1) / 2, [cx, cy] = P(172, mid);
    const g = el('g', { class: 'cs' + (animate && !REDUCED ? ' bloom' : '') + (j === CAT.j ? ' cur' : ''), tabindex: 0, role: 'button', 'aria-label': L({ it: t[2], en: t[3] }) });
    g.style.setProperty('--dx', (Math.cos(mid) * 12).toFixed(1) + 'px'); g.style.setProperty('--dy', (Math.sin(mid) * 12).toFixed(1) + 'px');
    if (animate) g.style.animationDelay = j * 45 + 'ms';
    g.append(el('path', { class: 'hit', d: sector(110, 240, a0, a1), fill: 'transparent' }));
    const vis = el('g', { class: 'vis' }); g.append(vis);
    vis.append(el('path', { d: sector(110, 240, a0, a1), fill: cat.c, 'fill-opacity': j % 2 ? .78 : 1 }));
    const tx = el('text', { x: cx, y: cy + 5 }); tx.textContent = LANG === 'en' ? t[1] : t[0]; vis.append(tx);
    const sel = () => { CAT.j = j; catInfo(); $$('#catpie .cs').forEach((x, k) => x.classList.toggle('cur', k === j)); };
    g.addEventListener('pointerenter', sel); g.addEventListener('focus', sel);
    g.addEventListener('click', () => { CAT.touched = true; sel(); });
    svg.append(g);
  });
  $('#catCenter').textContent = L(cat);
  catInfo();
}
function catInfo(){
  const cat = CATS[CAT.i], t = cat.t[CAT.j];
  $('#catInfo').innerHTML = `<span class="ci-k">${L(cat)} · ${CAT.j + 1}/${cat.t.length}</span><h3>${LANG === 'en' ? t[3] : t[2]}</h3><p>${LANG === 'en' ? t[5] : t[4]}</p>
    <div class="ci-dots" style="--c:${cat.c}">${cat.t.map((_, k) => `<button type="button" aria-label="${k + 1}" aria-current="${k === CAT.j}" data-k="${k}"></button>`).join('')}</div>`;
  $$('#catInfo .ci-dots button').forEach(b => b.addEventListener('click', () => { CAT.touched = true; CAT.j = +b.dataset.k; catInfo(); $$('#catpie .cs').forEach((x, k) => x.classList.toggle('cur', k === CAT.j)); }));
}
// gira da sola finché nessuno la tocca, solo quando si vede
function catAuto(){
  clearInterval(CAT.timer);
  if (REDUCED || !CAT.visible || CAT.touched) return;
  CAT.timer = setInterval(() => {
    if (CAT.touched || !CAT.visible || document.hidden) return;
    CAT.j++; if (CAT.j >= CATS[CAT.i].t.length) { CAT.j = 0; CAT.i = (CAT.i + 1) % CATS.length; renderCats(); } else { catInfo(); $$('#catpie .cs').forEach((x, k) => x.classList.toggle('cur', k === CAT.j)); }
  }, 2600);
}
new IntersectionObserver(es => { CAT.visible = es[0].isIntersecting; catAuto(); }, { threshold: .3 }).observe($('.cat-grid'));
$('.cat-grid').addEventListener('pointerdown', () => { CAT.touched = true; clearInterval(CAT.timer); });

/* ---------- Nuvola di formati: si avvicina al cursore, scappa al tocco ---------- */
const FORMATS = [['JPG', 4], ['PNG', 4], ['HEIC', 4], ['WEBP', 4], ['AVIF', 4], ['TIFF', 4], ['GIF', 4], ['ICO', 4], ['MP4', 3], ['MOV', 3], ['MKV', 3], ['WEBM', 3], ['AVI', 3], ['MP3', 2], ['M4A', 2], ['WAV', 2],
  ['FLAC', 2], ['OGG', 2], ['OPUS', 2], ['M4R', 2], ['PDF', 1], ['DOCX', 1], ['XLSX', 1], ['PPTX', 1], ['ODT', 1], ['CSV', 1], ['RTF', 1], ['SRT', 6], ['TXT', 6], ['3GP', 3], ['AAC', 2], ['BMP', 4]];
const CL = { items: [], px: -9999, py: -9999, active: false, visible: false, burst: null, w: 0, h: 0 };
(function buildCloud(){
  const box = $('#cloud'); let seed = 11; const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
  FORMATS.slice(0, SMALL ? 18 : 99).forEach(([f, s]) => {
    const sp = document.createElement('span'); sp.textContent = f; sp.style.color = `var(--s${s})`; sp.style.fontSize = (18 + rnd() * 46).toFixed(0) + 'px';
    box.append(sp); CL.items.push({ el: sp, hx: rnd(), hy: rnd(), ph: rnd() * 6.28, sp: .4 + rnd() * .6, ox: 0, oy: 0, op: .1 });
  });
})();
function cloudSize(){ const r = $('#scarica').getBoundingClientRect(); CL.w = r.width; CL.h = r.height; }
function cloudLoop(t){
  if (!CL.visible || document.hidden) return false;
  const s = t / 1000, R = 280;
  for (const it of CL.items) {
    const hx = it.hx * (CL.w - 60), hy = it.hy * (CL.h - 40), bx = hx + Math.sin(s * it.sp + it.ph) * 14, by = hy + Math.cos(s * it.sp * .8 + it.ph) * 10;
    let tx = 0, ty = 0, top = .1;
    const dx = CL.px - bx, dy = CL.py - by, dist = Math.hypot(dx, dy);
    if (CL.active && dist < R) { const k = 1 - dist / R; tx = dx * k * .5; ty = dy * k * .5; top = .1 + k * .6; }
    if (CL.burst) { const age = s - CL.burst.t; if (age < .9) { const bx2 = bx - CL.burst.x, by2 = by - CL.burst.y, bd = Math.hypot(bx2, by2) || 1, f = Math.max(0, 1 - bd / 420) * (1 - age / .9) * 120; tx += bx2 / bd * f; ty += by2 / bd * f; top = Math.max(top, .5 * (1 - age / .9)); } }
    it.ox += (tx - it.ox) * .1; it.oy += (ty - it.oy) * .1; it.op += (top - it.op) * .1;
    it.el.style.transform = `translate3d(${(bx + it.ox).toFixed(1)}px,${(by + it.oy).toFixed(1)}px,0)`; it.el.style.opacity = it.op.toFixed(3);
  }
  return true;
}
{
  const dlSec = $('#scarica');
  if (!REDUCED) {
    new IntersectionObserver(es => { CL.visible = es[0].isIntersecting; if (CL.visible) { cloudSize(); addLoop(cloudLoop); } }).observe(dlSec);
    dlSec.addEventListener('pointermove', ev => { const r = dlSec.getBoundingClientRect(); CL.px = ev.clientX - r.left; CL.py = ev.clientY - r.top; CL.active = true; });
    dlSec.addEventListener('pointerleave', () => { CL.active = false; });
    dlSec.addEventListener('pointerdown', ev => { const r = dlSec.getBoundingClientRect(); CL.burst = { x: ev.clientX - r.left, y: ev.clientY - r.top, t: performance.now() / 1000 }; });
    addEventListener('resize', cloudSize);
  } else new IntersectionObserver(es => { if (!es[0].isIntersecting) return; cloudSize(); CL.items.forEach(it => { it.el.style.transform = `translate3d(${(it.hx * (CL.w - 60)).toFixed(0)}px,${(it.hy * (CL.h - 40)).toFixed(0)}px,0)`; }); }).observe(dlSec);
}

/* ---------- Le carte di download si inclinano verso il cursore ---------- */
$$('.dlc').forEach(card => {
  const shine = card.querySelector('.shine');
  card.addEventListener('pointermove', ev => {
    if (ev.pointerType !== 'mouse' || REDUCED) return;
    const r = card.getBoundingClientRect(), x = (ev.clientX - r.left) / r.width - .5, y = (ev.clientY - r.top) / r.height - .5;
    card.style.transform = `perspective(900px) rotateX(${(-y * 6).toFixed(2)}deg) rotateY(${(x * 8).toFixed(2)}deg)`;
    shine.style.transform = `translate3d(${(ev.clientX - r.left).toFixed(0)}px,${(ev.clientY - r.top).toFixed(0)}px,0)`;
  });
  card.addEventListener('pointerleave', () => { card.style.transform = ''; });
});

/* ---------- Sfondi vivi: orbite con satelliti, luci che respirano, grana, vignettatura ----------
   Luci e vignettatura in un canvas piccolo per sezione (opaco, 1/8, 20 volte al secondo, in pausa mentre si scorre);
   anelli e grana in un livello fermo; si muovono solo i satelliti. Pausa quando la sezione non si vede. */
const COL = { sage: '94,143,120', brass: '193,145,62', gold: '226,181,98', blue: '124,154,200', purple: '154,127,192', terra: '199,107,79', teal: '106,175,168', cream: '241,236,214' };
const SATC = ['#7C9AC8', '#C76B4F', '#9A7FC0', '#D9A441', '#5E8F78', '#6AAFA8'];
const relCenter = (hostSel, targetSel, ref) => { const r = $(hostSel).getBoundingClientRect(), d = $(targetSel).getBoundingClientRect(); return [d.left - r.left + d.width / 2, d.top - r.top + d.height / 2, Math.max(.45, d.width / ref)]; };
const FXCFG = {
  hero: { dark: true, center: () => relCenter('#prova', '#dial', 540), rings: [300, 372, 455, 560, 690, 840], dash: [415, 620],
    sats: [[0, 0, .11, 0], [1, 3, -.08, 2], [2, 1, .06, 4], [3, 5, -.05, 1], [4, 2, .04, 3.5], [5, 4, -.03, 5.2], [2, 3, .06, 1.2, 1], [4, 0, .04, .4, 1]],
    blobs: [{ c: 'sage', a: .45, s: .8, x: .76, y: .42, ax: 70, ay: 40, sp: .07, d: 28 }, { c: 'gold', a: .2, s: .6, x: .12, y: .1, ax: 90, ay: 50, sp: .05, d: 60 },
      { c: 'blue', a: .17, s: .55, x: .55, y: 1, ax: 80, ay: 40, sp: .06, d: 18, m: 0 }, { c: 'purple', a: .15, s: .5, x: 0, y: .85, ax: 60, ay: 70, sp: .045, d: 44, m: 0 }] },
  band: { dark: false, center: (w, h) => [w * .82, h * .5, Math.min(1, w / 1280)], rings: [230, 330, 470, 640], dash: [400],
    sats: [[1, 3, .07, 0], [2, 0, -.05, 2], [3, 1, .04, 4, 1]],
    blobs: [{ c: 'brass', a: .22, s: .7, x: .9, y: .2, ax: 70, ay: 50, sp: .05, d: 40 }, { c: 'sage', a: .2, s: .65, x: .05, y: .75, ax: 60, ay: 60, sp: .06, d: 25 },
      { c: 'cream', a: .9, s: .5, x: .45, y: .05, ax: 90, ay: 30, sp: .04, d: 55, m: 0 }, { c: 'blue', a: .1, s: .5, x: .6, y: 1, ax: 60, ay: 40, sp: .055, d: 15, m: 0 }] },
  apphero: { dark: true, center: () => relCenter('#apphero', '#ahLogo', 320), rings: [200, 270, 350, 450, 570, 720], dash: [310, 510],
    sats: [[0, 3, .12, 0], [1, 0, -.09, 1.5], [2, 2, .07, 3], [3, 1, -.05, 4.5], [4, 5, .04, 2.2], [5, 4, -.03, .8], [1, 5, .09, 4, 1]],
    blobs: [{ c: 'gold', a: .3, s: .6, x: .75, y: .45, ax: 60, ay: 40, sp: .06, d: 30 }, { c: 'sage', a: .4, s: .8, x: .2, y: .2, ax: 80, ay: 50, sp: .05, d: 55 },
      { c: 'purple', a: .16, s: .5, x: .5, y: 1, ax: 70, ay: 40, sp: .05, d: 20, m: 0 }] },
  man: { dark: true, sticky: true, center: () => relCenter('#torta .sticky', '.m-pie', 560), rings: [330, 410, 500, 610, 740], dash: [370, 560],
    sats: [[0, 0, .09, 0], [1, 1, -.07, 1], [2, 2, .05, 2], [3, 3, -.04, 3], [4, 4, .03, 4], [2, 5, .05, 5, 1]],
    blobs: [{ c: 'sage', a: .38, s: .75, x: .7, y: .5, ax: 60, ay: 40, sp: .06, d: 30, tone: 0 }, { c: 'gold', a: .2, s: .55, x: .1, y: .2, ax: 70, ay: 50, sp: .05, d: 50, tone: 0, m: 0 },
      { c: 'blue', a: .3, s: .75, x: .75, y: .4, ax: 60, ay: 40, sp: .06, d: 30, tone: 1 }, { c: 'purple', a: .24, s: .6, x: .15, y: .8, ax: 70, ay: 50, sp: .05, d: 50, tone: 1, m: 0 },
      { c: 'terra', a: .26, s: .7, x: .72, y: .6, ax: 60, ay: 40, sp: .06, d: 30, tone: 2 }, { c: 'gold', a: .28, s: .6, x: .2, y: .3, ax: 70, ay: 50, sp: .05, d: 50, tone: 2, m: 0 }] },
  dl: { dark: true, center: (w, h) => [w * .88, h * .18, Math.min(1, w / 1280)], rings: [240, 380, 560, 780], dash: [470],
    sats: [[1, 3, .07, 1], [2, 0, -.05, 3], [3, 5, .035, 5, 1]],
    blobs: [{ c: 'gold', a: .2, s: .65, x: .85, y: .1, ax: 70, ay: 40, sp: .05, d: 40 }, { c: 'teal', a: .2, s: .7, x: .1, y: .9, ax: 80, ay: 50, sp: .06, d: 25 },
      { c: 'purple', a: .14, s: .5, x: .45, y: .55, ax: 60, ay: 60, sp: .045, d: 55, m: 0 }] },
  foot: { dark: true, center: (w, h) => [w * .5, h * 3.2, 1], rings: [], ringsF: [3, 3.35, 3.75], dash: [],
    sats: [[1, 3, .025, 1.6], [2, 5, -.018, 1.3, 1]],
    blobs: [{ c: 'sage', a: .3, s: .6, x: .2, y: 1, ax: 80, ay: 20, sp: .05, d: 30 }, { c: 'gold', a: .14, s: .45, x: .85, y: .2, ax: 60, ay: 20, sp: .04, d: 40, m: 0 }] },
};
const FX = [];
function cssVar(n){ return getComputedStyle(document.documentElement).getPropertyValue(n).trim(); }
function mixHex(a, b, t){ const p = h => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16)); const A = p(a), B = p(b); return `rgb(${A.map((x, i) => Math.round(x + (B[i] - x) * t)).join(',')})`; }
function fxBase(f, h){
  const key = f.layer.dataset.fx;
  if (key === 'hero' || key === 'apphero') return cssVar('--forest');
  if (key !== 'band') return cssVar('--forest-2');
  const bg = cssVar('--bg'), paper = cssVar('--paper'), forest = cssVar('--forest');
  const gr = f.ctx.createLinearGradient(0, 0, 0, Math.ceil(h / 8));
  gr.addColorStop(0, bg); gr.addColorStop(.4, paper); gr.addColorStop(1, /^#/.test(paper) && /^#/.test(forest) ? mixHex(paper, forest, .12) : paper);
  return gr;
}
function buildFx(layer){
  const cfg = FXCFG[layer.dataset.fx]; if (!cfg) return;
  layer.classList.toggle('light', !cfg.dark);
  const host = layer.closest('section, footer');
  const f = { cfg, layer, host, visible: false, blobs: [], cars: [], w: 0, h: 0 };
  layer.innerHTML = '';
  f.cv = document.createElement('canvas'); f.cv.className = 'lights'; layer.append(f.cv); f.ctx = f.cv.getContext('2d', { alpha: false });
  for (const b of cfg.blobs) { if (SMALL && b.m === 0) continue; f.blobs.push({ ...b, ph: Math.random() * 6.28 }); }
  f.rings = document.createElementNS(NS, 'svg'); f.rings.setAttribute('class', 'rings'); layer.append(f.rings);
  for (const s of cfg.sats) {
    if (SMALL && s[4]) continue;
    const car = document.createElement('div'); car.className = 'car';
    const dot = document.createElement('i'); dot.className = 'sat' + (s[4] ? ' s' : ''); dot.style.color = SATC[s[1]];
    car.append(dot); layer.append(car); f.cars.push({ ring: s[0], sp: s[2], ph: s[3], e: car, dot });
  }
  FX.push(f); layoutFx(f);
}
function layoutFx(f){
  const w = f.layer.clientWidth, h = f.layer.clientHeight; f.w = w; f.h = h;
  if (!w || !h) return;
  const [cx, cy, k0] = f.cfg.center(w, h), k = Math.max(.45, k0);
  f.cx = cx; f.cy = cy;
  const radii = f.cfg.ringsF ? f.cfg.ringsF.map(x => x * h) : f.cfg.rings.map(r => r * k);
  const stroke = f.cfg.dark ? 'var(--ring-dark)' : 'var(--ring-light)';
  f.rings.setAttribute('width', w + 32); f.rings.setAttribute('height', h + 32); f.rings.setAttribute('viewBox', `-16 -16 ${w + 32} ${h + 32}`);
  f.rings.innerHTML = radii.slice(0, SMALL ? 4 : 99).map((r, i) => `<circle cx="${cx.toFixed(1)}" cy="${cy.toFixed(1)}" r="${r.toFixed(1)}" fill="none" stroke="${stroke}" stroke-width="${i % 2 ? 1 : 1.4}"/>`).join('') +
    f.cfg.dash.slice(0, SMALL ? 1 : 9).map(r => `<circle cx="${cx.toFixed(1)}" cy="${cy.toFixed(1)}" r="${(r * k).toFixed(1)}" fill="none" stroke="${stroke}" stroke-width="1.8" stroke-dasharray="2 14" stroke-linecap="round"/>`).join('');
  f.cars.forEach(c => { c.dot.style.left = (radii[c.ring] || 0).toFixed(1) + 'px'; c.dot.style.marginLeft = c.dot.classList.contains('s') ? '-2.5px' : '-4px'; });
  f.blobs.forEach(b => { b.size = Math.max(320, Math.min(w, 1400) * b.s); });
  f.cv.width = Math.max(8, Math.ceil(w / 8)); f.cv.height = Math.max(8, Math.ceil(h / 8)); f.vig = null;
  f.base = fxBase(f, h);
  { const p = cssVar('--paper'); f.darkPaper = /^#/.test(p) && parseInt(p.slice(1, 3), 16) < 90; }
  paintFx(f, REDUCED ? 0 : performance.now() / 1000, 0, true);
}
const PT = { x: 0, y: 0, tx: 0, ty: 0 };
function smooth(a, b, x){ const t = clamp((x - a) / (b - a), 0, 1); return t * t * (3 - 2 * t); }
function paintFx(f, s, top, lights = true){
  if (!f.w) return;
  const pmx = PT.x, pmy = PT.y, man = f.cfg.sticky;
  if (lights) {
    const tones = man ? (() => { const p = Math.max(0, M.p); return [1 - smooth(.25, .5, p), smooth(.25, .5, p) * (1 - smooth(.6, .85, p)), smooth(.6, .85, p)]; })() : null;
    const g = f.ctx, cw = f.cv.width, ch = f.cv.height, k = cw / f.w;
    g.fillStyle = f.base; g.fillRect(0, 0, cw, ch);
    for (const b of f.blobs) {
      const br = Math.sin(s * b.sp * 9 + b.ph * 2), op = (0.82 + br * .18) * (tones ? tones[b.tone] : 1) * (b.c === 'cream' && f.darkPaper ? .08 : 1);
      if (op < .01) continue;
      const x = (b.x * f.w + Math.sin(s * b.sp * 6.28 + b.ph) * b.ax + pmx * b.d) * k;
      const y = (b.y * f.h + Math.cos(s * b.sp * 5.1 + b.ph) * b.ay + pmy * b.d * .7 + (man ? 0 : top * b.d * -.004)) * k;
      const r = b.size / 2 * (1 + br * .07) * k * 1.36, c = COL[b.c];
      const gr = g.createRadialGradient(x, y, 0, x, y, r);
      gr.addColorStop(0, `rgba(${c},${b.a})`); gr.addColorStop(.47, `rgba(${c},${b.a * .45})`); gr.addColorStop(1, `rgba(${c},0)`);
      g.globalAlpha = op; g.fillStyle = gr; g.fillRect(x - r, y - r, r * 2, r * 2);
    }
    g.globalAlpha = 1;
    if (!f.vig) { const v = g.createRadialGradient(cw / 2, ch * .45, Math.min(cw, ch) * .35, cw / 2, ch * .45, Math.hypot(cw, ch) * .62);
      v.addColorStop(0, 'rgba(0,0,0,0)'); v.addColorStop(1, f.cfg.dark ? 'rgba(3,12,9,.45)' : 'rgba(110,90,40,.12)'); f.vig = v; }
    g.fillStyle = f.vig; g.fillRect(0, 0, cw, ch);
  }
  // i satelliti sulle orbite esterne si spostano di più col cursore: parallasse a più livelli
  const ox = pmx * 10, oy = pmy * 8;
  for (const c of f.cars) { const depth = 1 + c.ring * .5; c.e.style.transform = `translate3d(${(f.cx + ox * depth).toFixed(1)}px,${(f.cy + oy * depth).toFixed(1)}px,0) rotate(${((s * c.sp + c.ph) * 57.3).toFixed(2)}deg)`; }
}
let fxOn = false, fxFrame = 0, lastScrollT = -1e9;
addEventListener('scroll', () => { lastScrollT = performance.now(); }, { passive: true });
function fxLoop(t){
  if (document.hidden) { fxOn = false; return false; }
  const vis = FX.filter(f => f.visible); if (!vis.length) { fxOn = false; return false; }
  PT.x += (PT.tx - PT.x) * .05; PT.y += (PT.ty - PT.y) * .05;
  const s = t / 1000, tops = vis.map(f => f.host.getBoundingClientRect().top);
  const lights = (++fxFrame % 3) === 0 && t - lastScrollT > 140;
  vis.forEach((f, i) => paintFx(f, s, tops[i], lights));
  return true;
}
const kickFx = () => { if (REDUCED || fxOn) return; fxOn = true; addLoop(fxLoop); };
$$('.bgfx').forEach(buildFx);
if (!REDUCED) {
  const io = new IntersectionObserver(es => { for (const e of es) { const f = FX.find(x => x.host === e.target); if (f) { f.visible = e.isIntersecting; if (f.visible && !f.w) layoutFx(f); } } kickFx(); }, { rootMargin: '80px' });
  FX.forEach(f => io.observe(f.host));
  addEventListener('pointermove', ev => { if (ev.pointerType !== 'mouse') return; PT.tx = ev.clientX / innerWidth * 2 - 1; PT.ty = ev.clientY / innerHeight * 2 - 1; kickFx(); }, { passive: true });
  document.addEventListener('visibilitychange', () => { if (!document.hidden) { kickFx(); if (CL.visible) addLoop(cloudLoop); } });
}
let fxResize = 0;
addEventListener('resize', () => { clearTimeout(fxResize); fxResize = setTimeout(() => FX.forEach(layoutFx), 150); });
document.fonts && document.fonts.ready.then(() => FX.forEach(layoutFx));
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => FX.forEach(layoutFx));
new MutationObserver(() => FX.forEach(layoutFx)).observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });

/* ---------- Scroll: un solo aggiornamento per frame ---------- */
let scrollQueued = false;
addEventListener('scroll', () => { if (scrollQueued) return; scrollQueued = true; requestAnimationFrame(() => { scrollQueued = false; manifestoUpdate(); }); }, { passive: true });
addEventListener('resize', () => { M.p = -1; manifestoUpdate(); });

/* ---------- Caricare: pulsante, zona, trascinamento su tutta la finestra, incolla ---------- */
$('#file').addEventListener('change', e => { if (e.target.files.length) load(e.target.files); e.target.value = ''; });
$('#pickBtn').addEventListener('click', () => $('#file').click());
dropzone.addEventListener('click', () => $('#file').click());
$('#changeBtn').addEventListener('click', () => $('#file').click());
$('#resetBtn').addEventListener('click', resetToDrop);
let dragDepth = 0;
addEventListener('dragenter', e => {
  if (![...(e.dataTransfer?.types || [])].includes('Files')) return;
  e.preventDefault(); dragDepth++;
  if (TAB !== 'converter') showTab('converter');
  dial.classList.add('over');
});
addEventListener('dragleave', () => { if (--dragDepth <= 0) { dragDepth = 0; dial.classList.remove('over'); } });
addEventListener('dragover', e => e.preventDefault());
addEventListener('drop', e => {
  e.preventDefault(); dragDepth = 0; dial.classList.remove('over');
  const fs = e.dataTransfer?.files; if (fs && fs.length) { if (TAB !== 'converter') showTab('converter'); load(fs); if (hero.getBoundingClientRect().bottom < 0) hero.scrollIntoView({ behavior: REDUCED ? 'auto' : 'smooth' }); }
});
document.addEventListener('paste', e => {
  const fs = [...(e.clipboardData?.files || [])]; if (!fs.length) return;
  e.preventDefault(); if (TAB !== 'converter') showTab('converter'); load(fs);
});
$('#lang-it').addEventListener('click', () => setLang('it'));
$('#lang-en').addEventListener('click', () => setLang('en'));

/* Barra in basso: compare quando non si vede né l'apertura né un invito a scaricare */
const bar = $('#bar'); let barClosed = false; const barSeen = new Set();
const syncBar = () => { const on = !barClosed && barSeen.size === 0; bar.classList.toggle('on', on); bar.setAttribute('aria-hidden', !on); bar.inert = !on; };
const barIO = new IntersectionObserver(es => { for (const e of es) e.isIntersecting ? barSeen.add(e.target) : barSeen.delete(e.target); syncBar(); }, { threshold: .05 });
['#prova', '#apphero', '#scarica', '#inviteCard'].forEach(s => barIO.observe($(s)));
$('#barX').addEventListener('click', () => { barClosed = true; syncBar(); });
barSeen.add(hero); syncBar();

/* Per le prove automatiche */
window.__orbit = { run, load, sample, resetToDrop, showTab, get tab(){ return TAB; }, get state(){ return S; }, get quiz(){ return QZ; }, get man(){ return M; }, get cat(){ return CAT; },
  pick: id => pick(slicesFor().find(s => s.id === id)) };

/* Avvio */
showTab(tabFromHash(), { push: false, to: ['scarica', 'torta', 'cosa'].includes(location.hash.slice(1)) ? location.hash.slice(1) : null });
history.replaceState({ tab: TAB }, '', TAB === 'app' ? (location.hash && location.hash !== '#app' ? location.hash : '#applicazione') : '#converter');
applyLang();
drawGhost();
// la sfida parte con la foto d'esempio, finché non ne carichi una tua
idle().then(async () => { const f = await toFile(drawScene(1600, 1200, 0), 'sample.png', 'image/png'); if (!QS.src) setQuizSource(await createImageBitmap(f), f); });
})();
