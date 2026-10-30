# OrbitLR · Regole di disegno (5.2 «Sistema»)

Queste regole valgono per Mac e Windows. Ogni schermata nuova le segue; se una regola non basta, si cambia qui prima che nel codice.

## Parole (vocabolario della 3.0)

| Parola | Significa | Esempi |
| --- | --- | --- |
| **Togli** | Esce dal progetto o dall’elenco; il file resta dov’è | Togli la clip, Togli la musica, Togli il testo, Togli dal Cassetto |
| **Elimina** | Va nel Cestino (si recupera da lì) | Elimina il risultato, Elimina i file creati… |
| **Rimuovi** | Toglie una parte del contenuto | Rimuovi i silenzi, Rimuovi la password…, Rimuovi lo sfondo |
| **Muta / Riattiva l’audio** | Audio di una clip | Muta la clip, Muta da qui, Muta tutti i video |
| **Inizia qui / Finisci qui** | Punto dell’indicatore | In clip, testi, musica, Audio e Taglia |
| **Ripristina** | Torna com’era (clip intera, progetto all’apertura) | |
| **Interrompi** | Ferma un lavoro in corso; sempre con il testo | |
| **Annulla** | Chiude senza fare niente (mai «disfa») | |
| **Mostra nel Finder** | Sempre questa, mai «nella cartella» | |

Nomi delle sezioni: **Converti**, **PDF e documenti**, **Immagini**, **Video**, **Audio**, **Attività**, **Cartelle automatiche**, **Le mie azioni**. In codice si mostra sempre `SidebarItem.title`, mai `rawValue`.

Un comando con «…» apre una domanda o un pannello prima di agire.

## Un posto per comando

| Comando | Posto unico |
| --- | --- |
| Velocità della clip | Montaggio → Clip |
| Muto, volume, Muta da qui, Stacca l’audio | Montaggio → Audio, sezione «Audio di questa clip» |
| Transizione | Pallino tra due clip nella sequenza |
| Salvare il progetto | Automatico (⌘S c’è ma non serve) |
| Chiudere progetto o file | ✕ in alto a destra |
| Azione finale di un editor | In alto a destra (Esporta, Salva una copia) |
| Azione di un pannello | In basso a destra, ↩; Annulla alla sua sinistra |

Il clic destro ripete i comandi della cosa cliccata, non ne aggiunge.

## Pulsanti (un ruolo, un aspetto)

| Ruolo | In codice | Regola |
| --- | --- | --- |
| Principale | `.primaryButton()` (o `.mainButton(colore)`) | Uno per schermata; colore della sezione o `Theme.accent` |
| Risolve un errore | `.fixButton()` | Ottone; accanto all’errore |
| Secondario | stile di sistema | Testo chiaro, mai solo icona se c’è spazio |
| Distruttivo | `role: .destructive` | Mai predefinito; negli avvisi «Annulla» è predefinito (`Sheet.confirmDestructive`) |
| Solo icona | `.buttonStyle(.plain)` + `.hitArea()` | Sempre `.help(…)` e `.accessibilityLabel(…)` |

Un pulsante spento dice perché nel suggerimento.

## Misure

- Area di clic: almeno 24 × 24 pt (`.hitArea()`), anche se il disegno è più piccolo.
- Arrotondamenti: `Radius.xs` 5 · `Radius.s` 7 · `Radius.m` 9 · `Radius.l` 12 · `Radius.xl` 14.
- Colori: solo da `Theme` (mai esadecimali nelle viste). Ogni tipo di file ha il suo colore (`Theme.color(kind)`).
- Testi: minimo 11 pt; le etichette della sequenza 10,5 pt.

## Avvisi

- Un’azione che non si può fare non fa un «bip» muto: una riga dice cosa manca.
- Prima di buttare lavoro si chiede («Buttare …?» Butta · Continua, Continua predefinito); un’eliminazione si annulla con la riga «Annulla» e ⌘Z.
- Ogni testo è in italiano e inglese.
