import XCTest

/// 6.0.4 · Apertura, chiusura e salvataggio dei progetti video lavorano in sottofondo:
/// nei test si aspetta che abbiano finito, come farebbe la finestra.
@MainActor
extension VideoProjectStore {
    func openAndWait(_ id: UUID, undo: UndoManager?) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in openProject(id, undo: undo) { c.resume() } }
    }
    func closeAndWait(_ undo: UndoManager?) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in closeProject(undo) { c.resume() } }
    }
    func saveAndWait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in saveNow { c.resume() } }
    }
}
