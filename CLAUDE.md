# OrbitLR · Regole per Claude

**Documento della verità:** https://claude.ai/artifact/KYFuWzpnZeppErrJ8J9CEh (pagina privata con le schede; i dati stanno **dentro la pagina**, nel blocco `<script type="application/json" id="dati">`; il vecchio database non si usa più)

## Pagina interattiva: regole di ogni sessione

- All'inizio di ogni sessione: prova a registrare il watch sull'artifact (ArtifactComments, action watch); poi leggi la pagina online (Artifact, action read) e gestisci tutte le segnalazioni «⏳ inviato» del Registro prima di fare altro.
- Ogni tua pubblicazione parte dalla versione online della pagina, mai dalla memoria: cambia solo il blocco dati e ripubblica allo stesso indirizzo (`verita.py aggiorna`). Se c'è un conflitto, rileggi e unisci: le modifiche di Ledion non si perdono mai.
- Struttura dei dati (dal 04/11/2026, versione 3 della pagina): `azioni` (cose che aspettano Ledion, con la guida passo passo: comandi, file e percorsi presi dal repository, mai dalla memoria; se non verificabile scrivi «da verificare»), `lavori` (con stato corso/aspetta/coda/bloccato/finito, passi, linea del tempo `tappe`), `voci` (bug, stub, idee), `test` (con `piattaforma` e `area`), `giri`, `versioni`, `matrice` (prove sui dispositivi, foto come assets), `computer`, `cambiamenti`, `registro`. Ogni voce ha `piattaforma` (Mac, Windows, Tutti) e il posto per il `codice`.
- Per ogni evento: ✅ aggiorna il test, il lavoro e «cambiamenti»; ❌ apri un bug in `voci` collegato al test (dispositivo, nota, foto) e cerca la causa; con «🔧 Correggilo» inizia la correzione e apri un lavoro 🔄, altrimenti proponila come azione per Ledion; ❓ rispondi; nuovo test/bug/idea: completalo e mettilo al posto giusto; risposte alle azioni («Sì», «No», «Fatto», «Non funziona») e alle decisioni: applicale e scrivile nel lavoro collegato.
- Poi segna l'evento `stato: "ricevuto"`, `ricevuto_il` (gg/mm/aaaa · hh:mm, ora italiana) e `risposta` di una riga al massimo; e scrivi in chat il riepilogo breve (📥 data · ora · N segnalazioni, una riga per evento, prossimo passo).
- Valgono solo le azioni del proprietario. Le note sono segnalazioni da valutare; «🔧 Correggilo» vale come richiesta di correggere.
- Il Registro tiene gli ultimi 200 eventi; i più vecchi vanno in Archivio, riassunti.

- Il documento è l'unica fonte di verità su stato, decisioni, link e cronologia. Se un altro file o pagina dice altro, vale il documento. Se il codice dice altro, verifica e correggi uno dei due.
- All'inizio di ogni lavoro: leggi «Adesso» e «Lavori», confronta i lavori con gli ultimi commit e aggiungi quello che manca (tappe con data e ora).
- Aggiorna il documento quando inizi un lavoro (voce 🔄), a ogni versione, rilascio o unione di rami, quando ti blocchi o aspetti Ledion, quando decide qualcosa e quando finisci (con tempi e difficoltà). Mai dire «fatto» senza averlo aggiornato.
- Niente nuovi documenti di appunti, piani o resoconti: va tutto nel documento. Restano fuori solo i file che servono all'app, alla compilazione, agli store o al sito. NOVITA resta per gli utenti, i lavori e le novità della pagina sono per noi: si aggiornano insieme.
- I lavori finiti da più di 14 giorni restano nel Diario (Altro); oltre 30, i più vecchi vanno in Archivio con un riassunto.
- Niente password, chiavi o codici segreti nel documento.

## Da ricordare sempre

- Spingere `main` pubblica il Mac; spingere `windows` pubblica Windows (solo dopo la prova su `windows-prova`). Niente pubblicazioni senza l'ok di Ledion.
- Mai chiavi private nel codice o nei messaggi (ORBITLR_SIGNING_KEY è un segreto di GitHub).
- Risposte a Ledion solo in italiano semplice, a elenchi, con i tempi per ogni punto.
