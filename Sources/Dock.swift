import AppKit
import ApplicationServices

/// Où est le Dock ? Rectangle en coordonnées Quartz globales (origine en haut à gauche),
/// du haut du Dock jusqu'au bas de l'écran. nil si le Dock n'est pas en bas ou se masque.
///
/// Avec l'autorisation Accessibilité, la taille est exacte. Sans, elle est estimée
/// à partir des réglages du Dock et des apps ouvertes (aucune permission nécessaire).
enum DockLocator {
    static var isExact: Bool { AXIsProcessTrusted() }

    static func requestExactAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func frame(for screen: NSScreen) -> CGRect? {
        let prefs = UserDefaults(suiteName: "com.apple.dock")
        if (prefs?.string(forKey: "orientation") ?? "bottom") != "bottom" { return nil }
        if prefs?.bool(forKey: "autohide") == true { return nil }

        let primaryH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let f = screen.frame, v = screen.visibleFrame
        guard v.minY - f.minY > 20 else { return nil }          // pas de Dock sur cet écran
        let bottomQ = primaryH - f.minY
        let topQ = primaryH - v.minY                            // haut de la zone réservée au Dock

        if AXIsProcessTrusted(), let r = axListFrame(), r.maxY > topQ - 4, r.minX >= f.minX - 2, r.maxX <= f.maxX + 2 {
            let top = max(r.minY, topQ - 8)
            return CGRect(x: r.minX - 4, y: top, width: r.width + 8, height: bottomQ - top)
        }
        return estimate(prefs: prefs, screen: f, top: topQ, bottom: bottomQ)
    }

    private static func axListFrame() -> CGRect? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &kids) == .success,
              let list = kids as? [AXUIElement] else { return nil }
        for el in list {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
            guard (role as? String) == (kAXListRole as String) else { continue }
            var pos: CFTypeRef?, size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pos) == .success,
                  AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &size) == .success,
                  let pv = pos, let sv = size else { continue }
            var p = CGPoint.zero, s = CGSize.zero
            AXValueGetValue(pv as! AXValue, .cgPoint, &p)
            AXValueGetValue(sv as! AXValue, .cgSize, &s)
            if s.width > 20 { return CGRect(origin: p, size: s) }
        }
        return nil
    }

    /// Nombre d'icônes × taille des icônes, borné à la largeur de l'écran.
    private static func estimate(prefs: UserDefaults?, screen f: CGRect, top: CGFloat, bottom: CGFloat) -> CGRect {
        let ts = prefs?.double(forKey: "tilesize") ?? 0
        let tile = CGFloat(ts > 0 ? ts : 48)
        let persistent = (prefs?.array(forKey: "persistent-apps") as? [[String: Any]]) ?? []
        func bundleID(_ e: [String: Any]) -> String? {
            (e["tile-data"] as? [String: Any])?["bundle-identifier"] as? String
        }
        let pinned = Set(persistent.compactMap(bundleID))
        var extra = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.bundleIdentifier })
            .subtracting(pinned)
        extra.remove("com.apple.finder")
        if prefs?.object(forKey: "show-recents") as? Bool ?? true {
            let recents = ((prefs?.array(forKey: "recent-apps") as? [[String: Any]]) ?? []).compactMap(bundleID)
            extra.formUnion(recents.filter { !pinned.contains($0) })
        }
        let others = prefs?.array(forKey: "persistent-others")?.count ?? 0
        let icons = 1 + persistent.count + extra.count + others + 1       // Finder … Corbeille
        let separators = (extra.isEmpty ? 0 : 1) + 1
        var width = CGFloat(icons) * tile + CGFloat(separators) * tile * 0.45 + tile * 0.5
        width = min(width, f.width - 12)
        return CGRect(x: f.midX - width / 2, y: top, width: width, height: bottom - top)
    }
}
