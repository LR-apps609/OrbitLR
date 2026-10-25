import AppKit
import Carbon

/// Scorciatoie globali: ⌥⌘C apre il menu sui file selezionati nel Finder; ⌃⌥1…9 lanciano i preset.
final class Hotkey {
    static let shared = Hotkey()
    var action: (() -> Void)?
    var presetAction: ((Int) -> Void)?
    private var mainRef: EventHotKeyRef?
    private var presetRefs: [EventHotKeyRef] = []
    private var installed = false
    private let signature = OSType(0x4C52_4356)   // "LRCV"
    private let digitKeys: [Int] = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                    kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    private func installHandler() {
        guard !installed else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = Int(hk.id)
            DispatchQueue.main.async {
                if id == 1 { Hotkey.shared.action?() }
                else if id > 100 { Hotkey.shared.presetAction?(id - 100) }
            }
            return noErr
        }, 1, &spec, nil, nil)
        installed = true
    }

    /// 4.1.5 · ⌥⌘C vale solo mentre il Finder è in primo piano: nelle altre app (Pages, Mail, TextEdit…)
    /// resta la loro scorciatoia («Copia stile»). `enabled` = l'opzione in Opzioni.
    private var enabled = false
    private var activationObserver: NSObjectProtocol?

    func setEnabled(_ on: Bool) {
        enabled = on
        if activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
                let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.follow(app?.bundleIdentifier)
            }
        }
        follow(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    private func follow(_ front: String?) {
        if enabled && front == "com.apple.finder" { register() } else { unregister() }
    }

    func register() {
        installHandler()
        guard mainRef == nil else { return }
        let id = EventHotKeyID(signature: signature, id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &mainRef)
    }

    func unregister() {
        if let r = mainRef { UnregisterEventHotKey(r) }
        mainRef = nil
    }

    func registerPresets(_ numbers: [Int]) {
        installHandler()
        for r in presetRefs { UnregisterEventHotKey(r) }
        presetRefs = []
        for n in Set(numbers) where n >= 1 && n <= 9 {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: signature, id: UInt32(100 + n))
            RegisterEventHotKey(UInt32(digitKeys[n - 1]), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
            if let ref { presetRefs.append(ref) }
        }
    }
}

enum FinderSelection {
    /// I file selezionati nel Finder (la prima volta macOS chiede il permesso di controllare il Finder).
    static func current() -> [URL] {
        let source = """
        tell application "Finder"
            set out to ""
            repeat with i in (get selection)
                set out to out & POSIX path of (i as alias) & linefeed
            end repeat
            return out
        end tell
        """
        var err: NSDictionary?
        guard let script = NSAppleScript(source: source),
              let text = script.executeAndReturnError(&err).stringValue else { return [] }
        return text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }
}
