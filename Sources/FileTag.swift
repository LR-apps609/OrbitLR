import Foundation

// ════════════════════════════════════════════════════════════════════
//  4.2.1 · Le parole nei nomi dei file creati («foto (più leggera).jpg»): in inglese «photo (smaller).jpg».
//  Le stesse parole valgono per il motore classico (LR_LANG nel suo ambiente).
// ════════════════════════════════════════════════════════════════════

enum FileTag {
    static let english: [String: String] = [
        "con musica": "with music", "suoneria": "ringtone", "montaggio": "edit", "voce": "voice",
        "taglio": "trimmed", "normalizzato": "normalized", "pezzo": "clip", "più leggero": "smaller",
        "più leggera": "smaller", "senza metadati": "no metadata", "compresso": "compressed",
        "senza logo": "no watermark", "senza sfondo": "no background", "trascrizione": "transcript",
        "ricercabile": "searchable", "raddrizzato": "straightened", "migliorata": "enhanced",
        "oscurato": "redacted", "firmato": "signed", "compilato": "filled", "scatti": "shots",
        "video uniti": "merged videos", "audio uniti": "merged audio", "IA": "AI", "vettoriale": "vector", "pacchetto logo": "logo pack",
    ]

    /// La parola nella lingua dell'app (in italiano resta com'è).
    static func t(_ it: String) -> String {
        AppLanguage.active == "en" ? (english[it] ?? it) : it
    }

    /// Tutte le forme di una parola (per riconoscerla in un nome già creato, in qualsiasi lingua).
    static func all(_ it: String) -> [String] { [it] + (english[it].map { [$0] } ?? []) }
}
