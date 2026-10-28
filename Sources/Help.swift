import SwiftUI
import AppKit

// ════════════════════════════════════════════════════════════════════
//  2.8.3 · Aiuto: le domande frequenti, con la ricerca.
//  Risposte brevi, con il percorso esatto da seguire nell’app.
// ════════════════════════════════════════════════════════════════════

struct FAQ: Identifiable, Equatable {
    let id: String
    let section: String
    let question: String
    let answer: String
    /// Dove si fa: la scheda da aprire con «Vai».
    var place: SidebarItem? = nil

    static let sections = ["Conversione", "Video", "Immagini e File", "Audio", "Aggiornamenti e problemi"]

    static let all: [FAQ] = [
        // Conversione
        FAQ(id: "convert", section: "Conversione", question: String(localized: "Come converto un file?"),
            answer: String(localized: "Trascina il file in Converti (oppure clicca e sceglilo), poi clicca il formato che ti serve. Il file nuovo viene creato senza toccare l’originale."), place: .workspace),
        FAQ(id: "edit", section: "Conversione", question: String(localized: "Dove sono le modifiche, come ridimensionare o tagliare?"),
            answer: String(localized: "Nel menu a torta ci sono solo le conversioni, per scegliere al volo. Lo spicchio «Modifica» porta il file nella sua scheda (Immagini, PDF e documenti, Video o Audio), dove trovi tutto il resto."), place: .workspace),
        FAQ(id: "where", section: "Conversione", question: String(localized: "Dove finiscono i file creati?"),
            answer: String(localized: "Nella cartella scelta in Opzioni → «Dove salvarli» (di base, la stessa cartella dell’originale). Alla fine la barra in basso dice in che cartella è, e «Mostra nel Finder» la apre.")),
        FAQ(id: "many", section: "Conversione", question: String(localized: "Posso convertire tanti file insieme?"),
            answer: String(localized: "Sì: trascinane quanti vuoi. Con file dello stesso tipo basta un solo spicchio per tutti; con tipi diversi compare una torta per ogni tipo."), place: .workspace),
        FAQ(id: "weight", section: "Conversione", question: String(localized: "Cosa vuol dire «≈ 1,2 MB» sotto uno spicchio?"),
            answer: String(localized: "È il peso previsto del risultato, prima di scegliere: verde se il file diventa più leggero, color ottone se diventa più pesante. Compare solo dove la stima è affidabile.")),
        FAQ(id: "keys", section: "Conversione", question: String(localized: "Posso scegliere senza mouse?"),
            answer: String(localized: "Sì: i tasti da 1 a 9 scelgono lo spicchio con quel numero, Invio quello con la stella, Esc chiude. Puoi anche scrivere per cercare un’azione.")),
        FAQ(id: "undo", section: "Conversione", question: String(localized: "Come annullo una conversione?"),
            answer: String(localized: "In Attività premi ⋯ accanto al lavoro e scegli «Elimina i file creati…»: vanno nel Cestino, da dove si possono recuperare. «Togli dalla cronologia» invece toglie solo la voce dall’elenco."), place: .activity),
        FAQ(id: "finder", section: "Conversione", question: String(localized: "Si può usare direttamente dal Finder?"),
            answer: String(localized: "Sì: seleziona i file nel Finder e premi ⌥⌘C, oppure clic destro → OrbitLR. La torta si apre lì dove sei.")),
        // Video
        FAQ(id: "vstart", section: "Video", question: String(localized: "Come inizio un montaggio?"),
            answer: String(localized: "Apri Video e premi «Editor» in alto (⇧⌘E), poi «Nuovo progetto» e trascina i tuoi video: si mettono in fila nell’ordine in cui li aggiungi. Se avevi già messo dei video nella scheda, l’editor li prende da solo."), place: .video),
        FAQ(id: "vresume", section: "Video", question: String(localized: "Come riprendo un progetto?"),
            answer: String(localized: "Apri Video, premi «Editor» e clicca la copertina del progetto: riparte da dove eri rimasto. Il progetto si salva da solo mentre lavori."), place: .video),
        FAQ(id: "vtrim", section: "Video", question: String(localized: "Come accorcio o divido una clip?"),
            answer: String(localized: "Clicca la clip e trascina i suoi bordi d’ottone per accorciarla. Per dividerla, porta la linea nel punto giusto e premi S.")),
        FAQ(id: "vremove", section: "Video", question: String(localized: "Come tolgo una clip?"),
            answer: String(localized: "Clicca la clip e premi la ✕ nel suo angolo, oppure il tasto ⌫. Se ti sbagli, ⌘Z la rimette.")),
        FAQ(id: "vtools", section: "Video", question: String(localized: "Voglio solo comprimere, tagliare o fare una GIF"),
            answer: String(localized: "Apri Video e trascina uno o più video: scegli cosa fare (comprimi senza perdere qualità o per Discord, WhatsApp ed email, taglia, cambia grandezza, GIF e altro). L’editor completo serve solo per i montaggi."), place: .video),
        FAQ(id: "vsilence", section: "Video", question: String(localized: "Come tolgo le pause da un video in cui parlo?"),
            answer: String(localized: "Nell’editor clicca la clip e premi «Togli i silenzi»: OrbitLR ascolta e lascia solo i pezzi in cui si parla, con tagli netti. Se non ti piace, ⌘Z."), place: .video),
        FAQ(id: "vsubs", section: "Video", question: String(localized: "Come aggiungo i sottotitoli automatici?"),
            answer: String(localized: "Nel montaggio apri «Testi» e premi «Sottotitoli automatici»: OrbitLR ascolta le clip e scrive le frasi in basso, al momento giusto. Poi li correggi come gli altri testi; ⌘Z li toglie tutti."), place: .video),
        FAQ(id: "voiceclean", section: "Audio", question: String(localized: "La voce si sente con un ronzio o un fruscio di fondo"),
            answer: String(localized: "Scegli «Voce più pulita» (nella scheda Audio, o nel menu di un video): OrbitLR attenua il ronzio e il fruscio costante e rende il volume uniforme. Il video non viene ricompresso. Funziona bene sui rumori costanti (ventola, condizionatore, traffico lontano), meno su voci o musica di sottofondo."), place: .audio),
        FAQ(id: "wordsubs", section: "Video", question: String(localized: "Posso far accendere le parole una alla volta, come sui social?"),
            answer: String(localized: "Sì: i sottotitoli automatici si accendono parola per parola. Su qualsiasi testo puoi scegliere l’animazione «Parola per parola»."), place: .video),
        FAQ(id: "recipes", section: "Conversione", question: String(localized: "Posso rifare più passi con un clic?"),
            answer: String(localized: "Sì, con le ricette. Quando lavori un file appena creato (per esempio converti in MP3, poi tagli), in Attività compare «Salva come ricetta». Da quel momento la ricetta è nel menu a torta di quel tipo di file e fa tutti i passi da sola."), place: .activity),
        FAQ(id: "menudrop", section: "Conversione", question: String(localized: "Posso convertire senza aprire la finestra?"),
            answer: String(localized: "Sì: clicca l’icona di OrbitLR nella barra in alto e trascina il file nel riquadro: la torta si apre accanto al puntatore. Oppure selezionalo nel Finder e premi ⌥⌘C.")),
        FAQ(id: "vapply", section: "Video", question: String(localized: "Cosa fanno «Applica» e «Scarta»?"),
            answer: String(localized: "Ogni modifica si vede subito nell’anteprima. «Applica» la rende definitiva, «Scarta» torna all’ultima versione applicata. Tieni premuto «Prima / dopo» per confrontare.")),
        FAQ(id: "vmute", section: "Video", question: String(localized: "Come tolgo l’audio da un pezzo del video?"),
            answer: String(localized: "In «Clip» porta la linea dove deve finire l’audio e premi «Spegni da qui». Per una clip intera usa «Spegni»; per un tratto in mezzo, dividi prima con S.")),
        FAQ(id: "vduck", section: "Video", question: String(localized: "Come faccio abbassare la musica quando qualcuno parla?"),
            answer: String(localized: "In «Audio» attiva «Abbassa quando si parla»: OrbitLR trova le voci e abbassa la musica solo in quei momenti.")),
        FAQ(id: "vformat", section: "Video", question: String(localized: "Come faccio un video verticale per Reels o TikTok?"),
            answer: String(localized: "In «Formato» scegli 9:16. Con «Inquadra le persone» l’inquadratura tiene al centro chi si muove.")),
        FAQ(id: "vexport", section: "Video", question: String(localized: "Come salvo il video finito?"),
            answer: String(localized: "Premi «Esporta» (⌘E). I tuoi video originali non vengono mai modificati.")),
        FAQ(id: "vclose", section: "Video", question: String(localized: "Come chiudo un progetto?"),
            answer: String(localized: "Con la ✕ in alto a destra nel montaggio: il progetto resta salvato e torni ai progetti.")),
        // Immagini e File
        FAQ(id: "isome", section: "Immagini e File", question: String(localized: "Posso lavorare solo su alcune foto o file?"),
            answer: String(localized: "Sì: clicca un file per sceglierlo, ⌘-clic per sceglierne altri. Senza scelta si lavora su tutti. «Tutte» o «Tutti» toglie la scelta."), place: .images),
        FAQ(id: "ibg", section: "Immagini e File", question: String(localized: "Come tolgo lo sfondo da una foto?"),
            answer: String(localized: "Apri Immagini, trascina la foto e nel pannello a destra scegli «Rimuovi lo sfondo»."), place: .images),
        FAQ(id: "fmerge", section: "Immagini e File", question: String(localized: "Come unisco più PDF in uno solo?"),
            answer: String(localized: "Apri File, trascina i PDF e scegli «Unisci in un PDF». L’ordine è quello dei file nella scheda."), place: .files),
        FAQ(id: "fprotect", section: "Immagini e File", question: String(localized: "Come metto una password a un PDF?"),
            answer: String(localized: "Apri File, trascina il PDF e scegli «Proteggi con password»: ti chiede la password due volte."), place: .files),
        // Audio
        FAQ(id: "acut", section: "Audio", question: String(localized: "Come taglio un audio?"),
            answer: String(localized: "Apri Audio, trascina il file, scegli «Taglia» e sposta le maniglie sul pezzo che vuoi tenere."), place: .audio),
        FAQ(id: "atts", section: "Audio", question: String(localized: "Come trasformo un testo in voce?"),
            answer: String(localized: "Apri Audio, scegli «Testo in voce», scrivi o incolla il testo e scegli la voce. Le voci «Premium» di macOS sono le più naturali."), place: .audio),
        FAQ(id: "aextract", section: "Audio", question: String(localized: "Come prendo l’audio da un video?"),
            answer: String(localized: "Trascina il video in Converti e scegli MP3 (o M4A)."), place: .workspace),
        // Aggiornamenti e problemi
        FAQ(id: "update", section: "Aggiornamenti e problemi", question: String(localized: "Come aggiorno OrbitLR?"),
            answer: String(localized: "Dal menu OrbitLR → «Controlla aggiornamenti…». OrbitLR controlla anche da sola una volta al giorno e ti avvisa se c’è una versione nuova.")),
        FAQ(id: "dock", section: "Aggiornamenti e problemi", question: String(localized: "Nel Dock vedo ancora l’icona vecchia"),
            answer: String(localized: "Dopo l’aggiornamento il Dock si ridisegna da solo. Se resta vecchia, togli OrbitLR dal Dock e riaprila dalla cartella Applicazioni.")),
        FAQ(id: "error", section: "Aggiornamenti e problemi", question: String(localized: "Una conversione non è riuscita: cosa faccio?"),
            answer: String(localized: "Accanto all’errore c’è un pulsante che prova a risolverlo (Riprova, Libera spazio, Scegli un’altra cartella…). Se non basta, usa «Segnala un problema» qui sotto.")),
        FAQ(id: "undoall", section: "Aggiornamenti e problemi", question: String(localized: "Ho sbagliato una modifica nel montaggio"),
            answer: String(localized: "Premi ⌘Z per tornare indietro, anche più volte; ⇧⌘Z rifà quello che hai annullato.")),
    ]

    /// La ricerca guarda domanda e risposta, senza badare a maiuscole e accenti.
    static func search(_ query: String, in list: [FAQ] = all) -> [FAQ] {
        let words = fold(query).split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return list }
        return list.filter { f in
            let text = fold(f.question + " " + f.answer + " " + f.section)
            return words.allSatisfy { text.contains($0) }
        }
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "it_IT"))
    }
}

struct HelpView: View {
    @EnvironmentObject var app: AppState
    @State private var query = ""
    @State private var open: Set<String> = []

    private var results: [FAQ] { FAQ.search(query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                TitleAccent(color: Theme.brass)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Aiuto").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("Le domande più frequenti. Scrivi una parola per cercare.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Feedback.show() } label: { Label("Suggerisci un’idea", systemImage: "lightbulb") }
                Button { app.showBugReport = true } label: { Label("Segnala un problema", systemImage: "ladybug") }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Cerca: video verticale, password, unire PDF…", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 13.5))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("Cancella la ricerca")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .card(radius: 10)

            if results.isEmpty {
                Text("Nessuna risposta per «\(query)». Prova con un’altra parola, oppure scrivici con «Segnala un problema».")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(FAQ.sections, id: \.self) { sec in
                            let items = results.filter { $0.section == sec }
                            if !items.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    SectionLabel(text: String(localized: String.LocalizationValue(sec)))
                                    ForEach(items) { f in row(f) }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        .navigationTitle("Aiuto")
    }

    private func row(_ f: FAQ) -> some View {
        let isOpen = open.contains(f.id) || !query.isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Motion.quick) {
                    if open.contains(f.id) { open.remove(f.id) } else { open.insert(f.id) }
                }
            } label: {
                HStack {
                    Text(f.question).font(.system(size: 13.5, weight: .semibold)).multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                Text(f.answer).font(.system(size: 12.5)).foregroundStyle(Theme.ink.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                if let p = f.place {
                    Button { app.selection = p } label: { Text("Vai a \(String(localized: String.LocalizationValue(p.rawValue))) ›").font(.system(size: 12, weight: .semibold)) }
                        .buttonStyle(.borderless).foregroundStyle(Theme.accent)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .card(radius: 10)
    }
}
