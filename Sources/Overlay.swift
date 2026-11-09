import AppKit
import QuartzCore

/// Fenêtre transparente plein écran, au-dessus de la barre des menus et du Dock,
/// sous les menus déroulants. Les clics la traversent toujours : l'interaction passe
/// par la position du curseur et la touche ⌥, lues sans capturer la souris.
final class OverlayWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class SnowView: NSView {
    let metalLayer = CAMetalLayer()
    /// Échelle du tampon de rendu (1 par défaut = 4x moins de mémoire qu'en Retina).
    var renderScale: CGFloat = 1 { didSet { updateDrawableSize() } }
    /// Échelle de l'écran. La couche DOIT la porter, même si on rend en 1x :
    /// sinon WindowServer alloue deux tampons Retina plein écran (~50 Mo de plus).
    /// AppKit la réécrit parfois, d'où la vérification à chaque frame (enforceScale).
    var screenScale: CGFloat = 2 { didSet { enforceScale() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        metalLayer.device = MetalContext.shared?.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = NSColor.clear.cgColor
        metalLayer.maximumDrawableCount = 2
        metalLayer.allowsNextDrawableTimeout = true
        wantsLayer = true
        updateDrawableSize()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override func makeBackingLayer() -> CALayer { metalLayer }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); updateDrawableSize() }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        enforceScale()
        updateDrawableSize()
    }

    @inline(__always) func enforceScale() {
        if metalLayer.contentsScale != screenScale { metalLayer.contentsScale = screenScale }
    }
    /// Par défaut on rend en 1x : 4 fois moins de mémoire vidéo qu'en Retina,
    /// et la neige (formes douces) n'en souffre presque pas.
    func updateDrawableSize() {
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * renderScale),
                                         height: max(1, bounds.height * renderScale))
    }
}

/// Un écran = une fenêtre + une simulation + un renderer + une display link.
final class Overlay: NSObject {
    let displayID: CGDirectDisplayID
    let field: Snowfield
    private let window: OverlayWindow
    private let view: SnowView
    private let renderer: Renderer
    private var link: CADisplayLink?
    private var lastTime: CFTimeInterval = 0
    private(set) var hiddenForFullscreen = false
    private var paused = true
    private unowned let app: AppDelegate
    private var screenScale: CGFloat

    init(screen: NSScreen, displayID: CGDirectDisplayID, app: AppDelegate) {
        self.displayID = displayID
        self.app = app
        screenScale = screen.backingScaleFactor
        window = OverlayWindow(screen: screen)
        view = SnowView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window.contentView = view
        field = Snowfield(screen: screen, seed: UInt64(CACurrentMediaTime() * 1000) ^ UInt64(displayID) &* 0x9E37_79B9)
        renderer = Renderer(layer: view.metalLayer)
        super.init()
        applyRenderScale()
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.isPaused = true
        l.add(to: .main, forMode: .common)
        link = l
    }

    func updateScreen(_ screen: NSScreen) {
        screenScale = screen.backingScaleFactor
        window.setFrame(screen.frame, display: false)
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        field.setGeometry(screen)
        applyRenderScale()
    }

    func applyRenderScale() {
        view.screenScale = screenScale
        view.renderScale = app.settings.retina ? screenScale : 1
    }

    func setFPS(_ fps: Int) {
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: Float(min(fps, 30)),
                                                         maximum: Float(fps), preferred: Float(fps))
    }

    func setPaused(_ p: Bool) {
        guard p != paused else { return }
        paused = p
        refreshVisibility()
    }

    func setFullscreenHidden(_ h: Bool) {
        guard h != hiddenForFullscreen else { return }
        hiddenForFullscreen = h
        refreshVisibility()
    }

    private func refreshVisibility() {
        if !paused && !hiddenForFullscreen {
            window.orderFrontRegardless()
            lastTime = CACurrentMediaTime()
            link?.isPaused = false
        } else {
            link?.isPaused = true
            window.orderOut(nil)
        }
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        var dt = Float(now - lastTime)
        lastTime = now
        if dt <= 0 || dt > 0.1 { dt = 1.0 / 60.0 }

        app.tracker.refreshIfNeeded(now: now)
        if field.updateWindows(tracker: app.tracker, now: now) { app.tracker.lastMovement = now }
        if field.coveredByFullscreen && !app.settings.fullscreenSnow { setFullscreenHidden(true); return }
        view.enforceScale()

        // ⌥ seule (sans ⌘ ⌃ ⇧, pour ne pas réagir aux raccourcis ni aux caractères spéciaux)
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let option = flags.contains(.maskAlternate)
            && flags.intersection([.maskCommand, .maskControl, .maskShift]).isEmpty
        field.step(dt: dt, mouse: NSEvent.mouseLocation, option: option,
                   settings: app.settings, energyFactor: app.energyFactor)
        renderer.draw(field, scale: Float(view.renderScale))
    }

    func invalidate() {
        link?.invalidate()
        link = nil
        window.orderOut(nil)
        window.close()
    }
}
