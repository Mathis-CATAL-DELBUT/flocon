import AppKit

struct TrackedWindow {
    let id: CGWindowID
    /// Coordonnées Quartz globales (origine en haut à gauche de l'écran principal).
    let frame: CGRect
}

/// Liste des fenêtres visibles, de l'avant vers l'arrière.
/// N'utilise que les positions des fenêtres : aucune permission
/// « Enregistrement de l'écran » n'est nécessaire.
final class WindowTracker {
    private(set) var windows: [TrackedWindow] = []
    private(set) var version = 0
    private var lastRefresh: CFTimeInterval = 0
    /// Mis à jour quand une fenêtre bouge : on interroge alors à chaque frame.
    var lastMovement: CFTimeInterval = 0
    private let myPID = ProcessInfo.processInfo.processIdentifier

    func refreshIfNeeded(now: CFTimeInterval) {
        let busy = NSEvent.pressedMouseButtons != 0 || now - lastMovement < 0.6
        let interval: CFTimeInterval = busy ? 1.0 / 90.0 : 1.0 / 12.0
        if now - lastRefresh >= interval { refresh(now: now) }
    }

    func refresh(now: CFTimeInterval) {
        lastRefresh = now
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return }
        var out: [TrackedWindow] = []
        out.reserveCapacity(32)
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0 else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != myPID else { continue }
            if let a = info[kCGWindowAlpha as String] as? Double, a < 0.05 { continue }
            guard let bd = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd as CFDictionary) else { continue }
            guard r.width >= 60, r.height >= 30 else { continue }
            guard let num = info[kCGWindowNumber as String] as? Int else { continue }
            out.append(TrackedWindow(id: CGWindowID(num), frame: r))
        }
        windows = out
        version &+= 1
    }

    #if FLOCON_TESTS
    func inject(_ w: [TrackedWindow]) { windows = w; version += 1 }
    #endif
}
