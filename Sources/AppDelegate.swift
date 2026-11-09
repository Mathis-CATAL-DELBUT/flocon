import AppKit
import IOKit.ps
import ServiceManagement
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let tracker = WindowTracker()
    let settings = Settings.shared
    private var statusItem: NSStatusItem!
    private var overlays: [CGDirectDisplayID: Overlay] = [:]
    private var housekeeping: Timer?
    private var onBattery = false
    private var sleeping = false
    private var tickCount = 0
    private var hotKey: EventHotKeyRef?

    var energySaving: Bool {
        settings.batterySaver && (onBattery || ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
    var energyFactor: Float { energySaving ? 0.5 : 1 }
    var fps: Int { energySaving ? 30 : 60 }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard MetalContext.shared != nil else {
            let a = NSAlert()
            a.messageText = "Flocon ne peut pas démarrer"
            a.informativeText = "Metal n'est pas disponible sur ce Mac."
            a.runModal()
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Flocon")
        statusItem.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        onBattery = AppDelegate.isOnBattery()
        rebuildOverlays()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(screensChanged),
                       name: NSApplication.didChangeScreenParametersNotification, object: nil)
        nc.addObserver(self, selector: #selector(powerChanged),
                       name: .NSProcessInfoPowerStateDidChange, object: nil)
        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(self, selector: #selector(didSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        wnc.addObserver(self, selector: #selector(didWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        wnc.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        // Une app qui s'ouvre ou se ferme change la largeur du Dock.
        wnc.addObserver(self, selector: #selector(appsChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        wnc.addObserver(self, selector: #selector(appsChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        let timer = Timer(timeInterval: 1, target: self, selector: #selector(housekeep), userInfo: nil, repeats: true)
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        housekeeping = timer

        applyState()
        registerPlowHotKey()

        // Mode démo (captures d'écran) : un bonhomme de neige dès le lancement.
        if ProcessInfo.processInfo.environment["FLOCON_DEMO"] != nil {
            let x = Float(ProcessInfo.processInfo.environment["FLOCON_DEMO_X"] ?? "") 
            updateDock()
            for o in overlays.values { o.field.buildSnowman(auto: false, at: x) }
        }
    }

    // MARK: Raccourci ⌥C

    /// ⌥C, depuis n'importe quelle app : la tractopelle passe.
    /// Raccourci global Carbon : aucune autorisation nécessaire.
    private func registerPlowHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.clearSnow() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x464C_434E), id: 1)   // 'FLCN'
        RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    // MARK: Écrans

    private func rebuildOverlays() {
        var alive = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(num.uint32Value)
            alive.insert(id)
            if let o = overlays[id] {
                o.updateScreen(screen)
            } else {
                overlays[id] = Overlay(screen: screen, displayID: id, app: self)
            }
        }
        for (id, o) in overlays where !alive.contains(id) {
            o.invalidate()
            overlays[id] = nil
        }
        updateDock()
    }

    /// La neige du sol se pose sur le Dock, et seulement là où il est.
    private func updateDock() {
        for screen in NSScreen.screens {
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let o = overlays[CGDirectDisplayID(num.uint32Value)] else { continue }
            o.field.setDock(DockLocator.frame(for: screen))
        }
    }

    @objc private func appsChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.updateDock() }
    }

    private func applyState() {
        let pause = !settings.enabled || sleeping
        for o in overlays.values {
            o.setFPS(fps)
            o.setPaused(pause)
        }
    }

    private func overlayUnderMouse() -> Overlay? {
        let m = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }),
           let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return overlays[CGDirectDisplayID(num.uint32Value)]
        }
        return overlays.values.first
    }

    @objc private func screensChanged() { rebuildOverlays(); applyState() }
    @objc private func didSleep() { sleeping = true; applyState() }
    @objc private func didWake() { sleeping = false; applyState() }
    @objc private func spaceChanged() { housekeep() }
    @objc private func powerChanged() {
        DispatchQueue.main.async { self.applyState() }
    }

    /// Toutes les secondes : retour après une app plein écran, état de la batterie.
    @objc private func housekeep() {
        tickCount += 1
        if tickCount % 10 == 0 {
            let b = AppDelegate.isOnBattery()
            if b != onBattery { onBattery = b; applyState() }
        }
        guard settings.enabled, !sleeping else { return }
        if tickCount % 2 == 0 { updateDock() }
        let hidden = overlays.values.filter { $0.hiddenForFullscreen }
        guard !hidden.isEmpty else { return }
        let now = CACurrentMediaTime()
        tracker.refresh(now: now)
        for o in hidden {
            o.field.updateWindows(tracker: tracker, now: now)
            if !o.field.coveredByFullscreen || settings.fullscreenSnow { o.setFullscreenHidden(false) }
        }
    }

    static func isOnBattery() -> Bool {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snap)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = settings

        menu.addItem(item(s.enabled ? "Mettre la neige en pause" : "Faire neiger", #selector(toggleEnabled)))
        menu.addItem(.separator())
        menu.addItem(choice("Intensité", ["Légère", "Moyenne", "Forte", "Blizzard"], s.intensity, #selector(setIntensity(_:))))
        menu.addItem(choice("Vent", ["Aucun", "Léger", "Fort"], s.wind, #selector(setWind(_:))))
        menu.addItem(choice("Accumulation", ["Désactivée", "Lente", "Normale", "Rapide"], s.accumulation, #selector(setAccumulation(_:))))
        menu.addItem(.separator())
        let tip = NSMenuItem(title: "Astuce : maintiens ⌥ et glisse le curseur le long de la neige pour rouler une boule", action: nil, keyEquivalent: "")
        tip.isEnabled = false
        menu.addItem(tip)
        menu.addItem(item("Construire un bonhomme de neige", #selector(buildSnowman)))
        menu.addItem(item("Faire tomber les bonshommes de neige", #selector(knockDownSnowmen)))
        menu.addItem(check("Bonshommes de neige automatiques", s.autoSnowman, #selector(toggleAutoSnowman)))
        menu.addItem(check("Interaction avec le curseur", s.cursorInteraction, #selector(toggleCursor)))
        let plow = item("Déblayer toute la neige", #selector(clearSnow))
        plow.keyEquivalent = "c"
        plow.keyEquivalentModifierMask = [.option]
        menu.addItem(plow)
        menu.addItem(.separator())
        menu.addItem(check("Neige en plein écran", s.fullscreenSnow, #selector(toggleFullscreenSnow)))
        menu.addItem(check("Économie d'énergie sur batterie", s.batterySaver, #selector(toggleBatterySaver)))
        menu.addItem(check("Rendu Retina (plus net, plus de mémoire)", s.retina, #selector(toggleRetina)))
        menu.addItem(check("Ouvrir au démarrage", SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))
        if !DockLocator.isExact {
            menu.addItem(item("Ajuster la neige à la taille exacte du Dock…", #selector(askDockAccess)))
        }
        if energySaving {
            let info = NSMenuItem(title: "Mode économie actif (30 i/s, moitié moins de flocons)", action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quitter Flocon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func check(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let i = item(title, action)
        i.state = on ? .on : .off
        return i
    }

    private func choice(_ title: String, _ options: [String], _ selected: Int, _ action: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (idx, name) in options.enumerated() {
            let i = item(name, action)
            i.tag = idx
            i.state = idx == selected ? .on : .off
            sub.addItem(i)
        }
        parent.submenu = sub
        return parent
    }

    @objc private func toggleEnabled() { settings.enabled.toggle(); applyState() }
    @objc private func setIntensity(_ sender: NSMenuItem) { settings.intensity = sender.tag }
    @objc private func setWind(_ sender: NSMenuItem) { settings.wind = sender.tag }
    @objc private func setAccumulation(_ sender: NSMenuItem) { settings.accumulation = sender.tag }
    @objc private func toggleAutoSnowman() { settings.autoSnowman.toggle() }
    @objc private func toggleCursor() { settings.cursorInteraction.toggle() }
    @objc private func toggleFullscreenSnow() { settings.fullscreenSnow.toggle(); housekeep() }
    @objc private func toggleBatterySaver() { settings.batterySaver.toggle(); applyState() }
    @objc private func toggleRetina() {
        settings.retina.toggle()
        for o in overlays.values { o.applyRenderScale() }
    }
    @objc private func buildSnowman() {
        if !settings.enabled { settings.enabled = true; applyState() }
        overlayUnderMouse()?.field.buildSnowman(auto: false)
    }
    /// Une tractopelle passe en bas de l'écran et pousse la neige dehors.
    @objc private func clearSnow() {
        if !settings.enabled { settings.enabled = true; applyState() }
        for o in overlays.values where !o.field.isPlowing { o.field.startPlow() }
    }

    @objc private func knockDownSnowmen() { for o in overlays.values { o.field.knockDownSnowmen() } }

    @objc private func askDockAccess() {
        let a = NSAlert()
        a.messageText = "Neige à la taille exacte du Dock"
        a.informativeText = "Sans autorisation, Flocon estime la largeur du Dock. Avec l'accès Accessibilité, il lit sa taille exacte (et rien d'autre).\n\nAutorise Flocon dans Réglages Système › Confidentialité et sécurité › Accessibilité."
        a.addButton(withTitle: "Ouvrir les réglages")
        a.addButton(withTitle: "Annuler")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { DockLocator.requestExactAccess() }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let a = NSAlert()
            a.messageText = "Impossible de modifier l'ouverture au démarrage"
            a.informativeText = "\(error.localizedDescription)\n\nAstuce : place Flocon.app dans le dossier Applications puis réessaie."
            a.runModal()
        }
    }
}
