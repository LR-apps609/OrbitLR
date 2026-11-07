// M07 · Quali simboli SF usati da OrbitLR non esistono su questo macOS (NSImage restituisce nil).
// Legge i nomi da stdin, uno per riga; stampa «MANCA nome» o «ok nome».
import AppKit
var miss = 0, ok = 0
while let l = readLine() {
    let n = l.trimmingCharacters(in: .whitespaces)
    if n.isEmpty { continue }
    if NSImage(systemSymbolName: n, accessibilityDescription: nil) == nil { print("MANCA \(n)"); miss += 1 } else { print("ok \(n)"); ok += 1 }
}
print("TOTALE ok=\(ok) mancanti=\(miss) macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
