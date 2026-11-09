import Foundation

/// Réglages persistés (UserDefaults), mis en cache en mémoire pour être lus à chaque frame.
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private init() {
        enabled = Settings.bool(d, "enabled", true)
        intensity = Settings.int(d, "intensity", 1)
        wind = Settings.int(d, "wind", 1)
        accumulation = Settings.int(d, "accumulation", 2)
        autoSnowman = Settings.bool(d, "autoSnowman", true)
        cursorInteraction = Settings.bool(d, "cursorInteraction", true)
        batterySaver = Settings.bool(d, "batterySaver", true)
        retina = Settings.bool(d, "retina", false)
        fullscreenSnow = Settings.bool(d, "fullscreenSnow", true)
    }

    private static func int(_ d: UserDefaults, _ k: String, _ def: Int) -> Int {
        d.object(forKey: k) == nil ? def : d.integer(forKey: k)
    }
    private static func bool(_ d: UserDefaults, _ k: String, _ def: Bool) -> Bool {
        d.object(forKey: k) == nil ? def : d.bool(forKey: k)
    }

    var enabled: Bool { didSet { d.set(enabled, forKey: "enabled") } }
    /// 0 légère, 1 moyenne, 2 forte, 3 blizzard
    var intensity: Int { didSet { d.set(intensity, forKey: "intensity") } }
    /// 0 aucun, 1 léger, 2 fort
    var wind: Int { didSet { d.set(wind, forKey: "wind") } }
    /// 0 désactivée, 1 lente, 2 normale, 3 rapide
    var accumulation: Int { didSet { d.set(accumulation, forKey: "accumulation") } }
    var autoSnowman: Bool { didSet { d.set(autoSnowman, forKey: "autoSnowman") } }
    var cursorInteraction: Bool { didSet { d.set(cursorInteraction, forKey: "cursorInteraction") } }
    var batterySaver: Bool { didSet { d.set(batterySaver, forKey: "batterySaver") } }
    var retina: Bool { didSet { d.set(retina, forKey: "retina") } }
    /// Neige aussi par-dessus les apps en plein écran (elle s'accumule alors au bas de l'écran).
    var fullscreenSnow: Bool { didSet { d.set(fullscreenSnow, forKey: "fullscreenSnow") } }
}
