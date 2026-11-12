import AppKit
import simd

// MARK: - Données envoyées au GPU

struct Sprite {
    var a: SIMD4<Float>      // x, y, rayon, rotation
    var color: SIMD4<Float>
    var b: SIMD4<Float>      // type, ratio hauteur/largeur, texture (0/1), rayon des coins (rect)
}

struct PileVert {
    var pos: SIMD2<Float>
    var info: SIMD2<Float>   // teinte (0 blanc → 1 bleuté), alpha
}

enum SpriteType: Float { case soft = 0, ball = 1, rect = 2, tri = 3, crystal = 4, disc = 5, glow = 6 }

@inline(__always)
func mkSprite(_ x: Float, _ y: Float, _ r: Float, _ rot: Float, _ c: SIMD4<Float>,
              _ t: SpriteType, aspect: Float = 1, textured: Bool = false, radius: Float = 0) -> Sprite {
    Sprite(a: SIMD4(x, y, r, rot), color: c, b: SIMD4(t.rawValue, aspect, textured ? 1 : 0, radius))
}

// MARK: - Aléatoire rapide

struct RNG {
    private var s: UInt64
    init(seed: UInt64) { s = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    @inline(__always) mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
    @inline(__always) mutating func f() -> Float { Float(next() >> 40) * (1.0 / 16_777_216.0) }
    @inline(__always) mutating func r(_ a: Float, _ b: Float) -> Float { a + (b - a) * f() }
}

// MARK: - Entités

struct Flake {
    var x: Float, y: Float, vx: Float, vy: Float
    var r: Float, depth: Float, fall: Float, phase: Float, freq: Float
    var rot: Float, spin: Float
    var kind: UInt8          // 0 flocon doux, 1 cristal, 2 paquet de neige (gravité), 3 poudre
    var collide: Bool
    var mass: Float
    var immune: Float        // paquets : temps sans collision avec les fenêtres ; poudre : durée de vie
    var alive: Bool
}

/// Une surface où la neige se pose : le haut d'une fenêtre, ou le Dock (id 0).
final class WinPile {
    static let dockID: CGWindowID = 0
    static let floorID: CGWindowID = .max     // bas de l'écran, en plein écran (Dock caché)
    let id: CGWindowID
    let cornerR: Float
    var minX: Float = 0, minY: Float = 0, w: Float = 0, hgt: Float = 0
    let pile: Pile
    var base: [Float] = []
    var occluded: [Bool] = []
    var visible = true
    var noSnow = false        // fenêtre en plein écran : sa neige est mise de côté
    var isGround: Bool { id == WinPile.dockID || id == WinPile.floorID }
    var lastSeen: CFTimeInterval
    var spillL: Float = 0, spillR: Float = 0

    init(id: CGWindowID, rect: CGRect, now: CFTimeInterval, maxH: Float = 16, cornerR: Float = 12) {
        self.id = id
        self.cornerR = cornerR
        lastSeen = now
        pile = Pile(width: Float(rect.width), maxH: maxH)
        minX = Float(rect.minX); minY = Float(rect.minY); hgt = Float(rect.height); w = Float(rect.width)
        rebuildBase()
    }

    var maxX: Float { minX + w }

    /// Fenêtre réapparue (Space, dé-minimisée) : on garde sa neige, mise à l'échelle.
    func setRectKeepingSnow(_ r: CGRect) {
        minX = Float(r.minX); minY = Float(r.minY); hgt = Float(r.height)
        if Float(r.width) != w {
            w = Float(r.width)
            pile.resize(width: w)
            rebuildBase()
        }
    }

    /// Les coins arrondis : la neige suit la courbe.
    func rebuildBase() {
        let n = pile.count, R = cornerR
        base = (0..<n).map { i in
            let cx = (Float(i) + 0.5) * Pile.binW
            let d = max(0, min(cx, w - cx))
            if d >= R { return 0 }
            let q = R - d
            return R - max(0, R * R - q * q).squareRoot()
        }
        occluded = [Bool](repeating: false, count: n)
    }

    @inline(__always) func bin(_ x: Float) -> Int? {
        let fx = (x - minX) / Pile.binW
        guard fx >= 0 else { return nil }
        let i = Int(fx)
        return i < pile.count ? i : nil
    }

    /// y de la surface de neige à l'abscisse x (absolue), nil hors de la surface.
    @inline(__always) func surface(_ x: Float) -> Float? {
        guard let i = bin(x) else { return nil }
        return minY + base[i] - pile.h[i]
    }
}

struct Snowman {
    var x: Float
    var baseY: Float
    var r1: Float, r2: Float, r3: Float
    var t: Float = 0
    var wobble: Float = 0
    var wobbleV: Float = 0
    var cursorInside = false
    var auto: Bool
    var support: CGWindowID
    var relX: Float
    var hidden = false

    /// Échelle des accessoires (yeux, chapeau…), proportionnelle à la tête.
    var sc: Float { r3 / 10 }

    struct Geo { let r1, r2, r3, c1, c2, c3: Float }
    func geo(_ p1: Float = 1, _ p2: Float = 1, _ p3: Float = 1) -> Geo {
        let a = r1 * p1, b = r2 * p2, c = r3 * p3
        let c1 = -a * 0.94          // à peine enfoncé dans la neige
        let c2 = c1 - a * 0.82 - b * 0.72
        let c3 = c2 - b * 0.78 - c * 0.8
        return Geo(r1: a, r2: b, r3: c, c1: c1, c2: c2, c3: c3)
    }
}

/// Boule de neige roulée par l'utilisateur (⌥ + curseur sur la neige), empilable.
struct Snowball {
    enum State { case rolling, carried, falling, resting }
    /// Distance centre → surface de la neige, en rayons (la boule s'enfonce à peine).
    static let sink: Float = 0.96
    /// Au-delà de cette vitesse d'impact (≈ 200 pt de chute), la boule éclate.
    static let breakSpeed: Float = 620
    let id: Int
    var x: Float, y: Float        // centre
    var r: Float
    var vx: Float = 0             // élan horizontal (lancer, roulement)
    var vy: Float = 0
    var spin: Float = 0
    var state: State
    var restOn: Int? = nil        // id de la boule en dessous
    var support: CGWindowID? = nil
    var relX: Float = 0
    var hidden = false
    var dead = false
}

/// La tractopelle de « Déblayer toute la neige ».
struct Plow {
    var x: Float                  // centre de la carrosserie
    var load: Float = 0           // aire de neige dans le godet (pt²)
    var t: Float = 0
    var wheel: Float = 0
    var waiting = true            // attend que la neige des fenêtres ait fini de tomber
    var waited: Float = 0
}

// MARK: - Simulation d'un écran

final class Snowfield {
    private(set) var W: Float = 0, H: Float = 0
    private var origin = CGPoint.zero       // coin haut-gauche de l'écran, en Quartz global
    private var cocoaFrame = CGRect.zero
    private var visTop: Float = 0          // hauteur de la barre des menus / de l'encoche
    private var landP: [Float] = []        // probabilité qu'un flocon se pose, par rang de surface

    private var flakes: [Flake] = []
    private var piles: [CGWindowID: WinPile] = [:]
    private var dock: WinPile?
    private var floorPile: WinPile?           // sol au bas de l'écran, utilisé en plein écran
    /// Là où tombe la neige « au sol » : le Dock, ou le bas de l'écran en plein écran.
    private var ground: WinPile? {
        if let d = dock, d.visible { return d }
        if let f = floorPile, f.visible { return f }
        return nil
    }
    private var winOrder: [WinPile] = []     // fenêtres visibles, de l'avant vers l'arrière
    private var order: [WinPile] = []        // Dock (toujours devant) + fenêtres
    private var rects: [SIMD4<Float>] = []   // minX, minY, maxX, maxY
    private var snowmen: [Snowman] = []
    private var snowballs: [Snowball] = []
    private var grabbedID: Int? = nil
    private var nextBallID = 1
    private var colliders: [SIMD3<Float>] = []   // boules (bonshommes + boules libres) pour les flocons
    private var plow: Plow?

    private(set) var coveredByFullscreen = false
    var isPlowing: Bool { plow != nil }

    private var rng: RNG
    private var t: Float = 0
    private var prefilled = false
    private var lastWinUpdate: CFTimeInterval = 0
    private var lastTrackerVersion = -1
    private var snowmanTimer: Float = 0

    private var cursor = SIMD2<Float>(-9999, -9999)
    private var cursorV = SIMD2<Float>(0, 0)
    private var cursorValid = false
    private var option = false

    // Géométrie de la frame (lue par le Renderer)
    private(set) var sprites: [Sprite] = []
    private(set) var pileVerts: [PileVert] = []
    private(set) var spriteSplit = 0   // [0, split) = bonshommes et boules (devant la neige), puis le reste
    private(set) var pileSplit = 0     // toute la neige, dessinée avant les bonshommes

    init(screen: NSScreen, seed: UInt64) {
        rng = RNG(seed: seed)
        setGeometry(screen)
    }

    func setGeometry(_ screen: NSScreen) {
        let primaryH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let f = screen.frame, v = screen.visibleFrame
        cocoaFrame = f
        origin = CGPoint(x: f.minX, y: primaryH - f.maxY)
        W = Float(f.width); H = Float(f.height)
        visTop = Float(f.maxY - v.maxY)
        if floorPile?.w != W {
            floorPile = WinPile(id: WinPile.floorID, rect: CGRect(x: 0, y: CGFloat(H), width: CGFloat(W), height: 1),
                                now: 0, maxH: 22, cornerR: 10)
            floorPile?.visible = coveredByFullscreen
        }
        lastTrackerVersion = -1
    }

    @inline(__always) private func pileFor(_ id: CGWindowID) -> WinPile? {
        switch id {
        case WinPile.dockID: return dock
        case WinPile.floorID: return floorPile
        default: return piles[id]
        }
    }

    // MARK: Dock

    /// rect en Quartz global (du haut du Dock au bas de l'écran), nil = pas de Dock ici.
    func setDock(_ q: CGRect?) {
        guard let q else {
            if let d = dock { dumpAll(d); dock = nil; rebuildOrder() }
            return
        }
        let r = q.offsetBy(dx: -origin.x, dy: -origin.y)
        let rect = CGRect(x: r.minX, y: r.minY, width: r.width, height: max(1, CGFloat(H) - r.minY))
        if let d = dock {
            if abs(Float(rect.minX) - d.minX) < 0.5 && abs(Float(rect.width) - d.w) < 0.5
                && abs(Float(rect.minY) - d.minY) < 0.5 { return }
            _ = applyRect(d, rect, dt: 1)
        } else {
            dock = WinPile(id: WinPile.dockID, rect: rect, now: 0, maxH: 22, cornerR: 16)
        }
        updateDockVisibility()
        rebuildOrder()
    }

    // MARK: Fenêtres

    /// Renvoie true si une fenêtre a bougé ou changé de taille.
    @discardableResult
    func updateWindows(tracker: WindowTracker, now: CFTimeInterval) -> Bool {
        guard tracker.version != lastTrackerVersion else { return false }
        lastTrackerVersion = tracker.version
        let dt = Float(max(1.0 / 240.0, min(0.5, now - lastWinUpdate)))
        lastWinUpdate = now

        let bounds = CGRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H))
        var newOrder: [WinPile] = []
        var seen = Set<CGWindowID>()
        var moved = false
        var full = false

        for tw in tracker.windows {
            let r = tw.frame.offsetBy(dx: -origin.x, dy: -origin.y)
            guard r.intersects(bounds) else { continue }
            // App en plein écran : toute la largeur, jusqu'en bas de l'écran, et depuis le haut
            // (ou juste sous l'encoche sur les MacBook qui en ont une).
            let isFull = r.minX <= 1 && Float(r.minY) <= max(visTop, 40) + 2 && Float(r.width) >= W - 2
                && Float(r.maxY) >= H - 2
            if isFull { full = true }
            seen.insert(tw.id)
            let wp: WinPile
            if let existing = piles[tw.id] {
                wp = existing
                if wp.visible {
                    if applyRect(wp, r, dt: dt) { moved = true }
                } else {
                    wp.setRectKeepingSnow(r)
                    wp.visible = true
                }
                wp.lastSeen = now
            } else {
                wp = WinPile(id: tw.id, rect: r, now: now)
                piles[tw.id] = wp
            }
            // Pas de neige sur la fenêtre plein écran (son haut est collé à l'encoche) :
            // on la met de côté, elle revient en sortant du plein écran.
            wp.noSnow = isFull
            newOrder.append(wp)
        }
        for (id, wp) in piles where !seen.contains(id) { wp.visible = false }
        if piles.count > newOrder.count + 40 || Int(now) % 30 == 0 {
            piles = piles.filter { now - $0.value.lastSeen < 900 }
        }

        winOrder = newOrder
        coveredByFullscreen = full
        updateDockVisibility()
        rebuildOrder()
        return moved
    }

    /// Le Dock reste au-dessus des fenêtres, même de celles qui descendent sous lui :
    /// on ne le considère masqué que quand macOS le dit (setDock(nil) : masquage
    /// automatique, Dock sur le côté) ou en plein écran (tout l'overlay est alors caché).
    private func updateDockVisibility() {
        dock?.visible = !coveredByFullscreen
        floorPile?.visible = coveredByFullscreen
    }

    private func rebuildOrder() {
        order.removeAll(keepingCapacity: true)
        if let g = ground { order.append(g) }
        order.append(contentsOf: winOrder)
        rects = order.map { SIMD4($0.minX, $0.minY, $0.maxX, $0.minY + $0.hgt) }
        // La fenêtre de devant attrape la plupart des flocons, celles du fond de moins en moins
        // (les flocons passent devant elles). Le Dock attrape tout ce qui arrive jusqu'à lui.
        landP.removeAll(keepingCapacity: true)
        var rank = 0
        for wp in order {
            if wp.isGround { landP.append(1) } else { landP.append(0.85 * powf(0.55, Float(rank))); rank += 1 }
        }
        computeOcclusion()
    }

    /// Nouvelle position/taille d'une surface.
    /// Déplacement → la neige glisse (shed). Redimensionnement → la neige reste à sa place
    /// à l'écran, et ce qui dépasse du nouveau bord tombe.
    private func applyRect(_ wp: WinPile, _ r: CGRect, dt: Float) -> Bool {
        let nMinX = Float(r.minX), nW = Float(r.width), nMinY = Float(r.minY), nH = Float(r.height)
        let dl = nMinX - wp.minX, dr = (nMinX + nW) - wp.maxX
        let dtop = nMinY - wp.minY, dbot = (nMinY + nH) - (wp.minY + wp.hgt)
        let tx: Float = dl * dr > 0 ? (dl > 0 ? min(dl, dr) : max(dl, dr)) : 0
        let ty: Float = dtop * dbot > 0 ? (dtop > 0 ? min(dtop, dbot) : max(dtop, dbot)) : 0
        if abs(nW - wp.w) > 0.5 { reanchor(wp, newMinX: nMinX, newW: nW, shiftX: tx) }
        wp.minX = nMinX; wp.minY = nMinY; wp.hgt = nH
        if abs(tx) > 0.5 || abs(ty) > 0.5 { shed(wp, dx: tx, dy: ty, dt: dt) }
        return abs(dl) > 0.5 || abs(dr) > 0.5 || abs(dtop) > 0.5 || abs(dbot) > 0.5
    }

    private func reanchor(_ wp: WinPile, newMinX: Float, newW: Float, shiftX: Float) {
        let bw = Pile.binW
        let old = wp.pile.h
        let oldMin = wp.minX + shiftX
        let n = Pile.bins(for: newW)
        var nh = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let fo = (newMinX + (Float(i) + 0.5) * bw - oldMin) / bw
            if fo >= 0 { let oi = Int(fo); if oi < old.count { nh[i] = old[oi] } }
        }
        // Ce qui dépasse tombe, par paquets.
        let newMax = newMinX + newW
        var acc: Float = 0, accX: Float = 0, cnt = 0
        func emit() {
            guard cnt > 0, acc > 0.2, flakes.count < 3500 else { acc = 0; accX = 0; cnt = 0; return }
            let x = accX / Float(cnt)
            let out: Float = x < newMinX ? -1 : 1
            spawnClump(x: x, y: wp.minY - acc / Float(cnt) * 0.5 - 0.5,
                       vx: out * rng.r(5, 30), vy: rng.r(-15, 10), mass: acc, immune: 0.12)
            acc = 0; accX = 0; cnt = 0
        }
        for (oi, h) in old.enumerated() {
            let ax = oldMin + (Float(oi) + 0.5) * bw
            if (ax >= newMinX && ax < newMax) || h < 0.05 { emit(); continue }
            acc += h; accX += ax; cnt += 1
            if cnt == 3 { emit() }
        }
        emit()
        wp.pile.h = nh
        wp.w = newW
        wp.rebuildBase()
        wp.pile.awake = 60
        // Bonshommes et boules restent à leur place à l'écran.
        let shift = oldMin - newMinX
        for k in snowmen.indices where snowmen[k].support == wp.id { snowmen[k].relX += shift }
        for k in snowballs.indices where snowballs[k].support == wp.id { snowballs[k].relX += shift }
    }

    /// Masque les colonnes de neige cachées par une fenêtre (ou le Dock) placée devant.
    private func computeOcclusion() {
        var candidates: [Int] = []
        for (k, wp) in order.enumerated() {
            let n = wp.pile.count
            if wp.occluded.count != n { wp.occluded = [Bool](repeating: false, count: n) }
            candidates.removeAll(keepingCapacity: true)
            let top = wp.minY - wp.pile.maxH - 2, bottom = wp.minY + wp.cornerR
            for j in 0..<k {
                let r = rects[j]
                if r.z >= wp.minX && r.x <= wp.maxX && r.w >= top && r.y <= bottom { candidates.append(j) }
            }
            if candidates.isEmpty {
                for i in 0..<n { wp.occluded[i] = false }
                continue
            }
            for i in 0..<n {
                let x = wp.minX + (Float(i) + 0.5) * Pile.binW
                let y1 = wp.minY + wp.base[i] - 0.5
                let y2 = y1 - wp.pile.h[i]
                var occ = false
                for j in candidates {
                    let r = rects[j]
                    if x >= r.x && x <= r.z && ((y1 >= r.y && y1 <= r.w) || (y2 >= r.y && y2 <= r.w)) { occ = true; break }
                }
                wp.occluded[i] = occ
            }
        }
    }

    /// Une fenêtre déplacée perd sa neige, d'autant plus vite qu'on la bouge vite.
    private func shed(_ wp: WinPile, dx: Float, dy: Float, dt: Float) {
        let speed = (dx * dx + dy * dy).squareRoot() / dt
        guard speed > 35 else { return }
        if speed > 260 { dropBalls(on: wp.id) }
        if speed > 520 { collapseSnowmen(on: wp.id, vx: dx / dt * 0.3) }
        let n = wp.pile.count
        var any = false
        for i in 0..<n where wp.pile.h[i] > 0.05 { any = true; break }
        guard any else { return }
        let f = min(1, (speed - 35) / 600)
        let vx = dx / dt, vy = dy / dt
        var i = 0
        let step = 3
        while i < n {
            let e = min(n, i + step)
            var m: Float = 0, hs: Float = 0
            for k in i..<e {
                let take = wp.pile.h[k] * f
                hs += wp.pile.h[k]
                wp.pile.h[k] -= take
                m += take
            }
            if m > 0.2 && flakes.count < 3500 {
                let cx = wp.minX + (Float(i) + 1.5) * Pile.binW
                let avgH = hs / Float(e - i)
                let b = wp.base[min(i + 1, n - 1)]
                spawnClump(x: cx, y: wp.minY + b - avgH * 0.5,
                           vx: vx * 0.45 + rng.r(-30, 30),
                           vy: min(vy * 0.35, 40) - rng.r(10, 70),
                           mass: m, immune: 0.3)
            }
            i += step
        }
        wp.pile.awake = 60
    }

    /// Toute la neige d'une surface tombe (fenêtre agrandie, déblayage…).
    private func dumpAll(_ wp: WinPile) {
        dropBalls(on: wp.id)
        collapseSnowmen(on: wp.id, vx: 0)
        let n = wp.pile.count
        var i = 0
        while i < n {
            let e = min(n, i + 3)
            var m: Float = 0, hs: Float = 0
            for k in i..<e { m += wp.pile.h[k]; hs += wp.pile.h[k]; wp.pile.h[k] = 0 }
            if m > 0.2 && flakes.count < 3600 {
                let b = wp.base[min(i + 1, n - 1)]
                spawnClump(x: wp.minX + (Float(i) + 1.5) * Pile.binW, y: wp.minY + b - hs / Float(e - i) * 0.5,
                           vx: rng.r(-20, 20), vy: -rng.r(0, 40), mass: m, immune: 0.35)
            }
            i += 3
        }
    }

    // MARK: Création

    private func spawnFlake(y: Float, windBase: Float) {
        let d = powf(rng.f(), 1.3)
        var f = Flake(x: rng.r(-60 - windBase * 8, W + 60), y: y, vx: 0, vy: 0,
                      r: 1.1 + d * 2.9 + rng.r(0, 0.4), depth: d,
                      fall: 22 + d * 48 + rng.r(-5, 8),
                      phase: rng.r(0, 6.283), freq: rng.r(0.6, 1.6),
                      rot: rng.r(0, 6.283), spin: rng.r(-1.2, 1.2),
                      kind: 0, collide: d > 0.3, mass: 0, immune: 0, alive: true)
        if d > 0.82 && rng.f() < 0.25 {
            f.kind = 1
            f.r = 4.5 + rng.r(0, 3)
            f.fall *= 0.85
        }
        f.vy = f.fall
        flakes.append(f)
    }

    private func spawnClump(x: Float, y: Float, vx: Float, vy: Float, mass: Float, immune: Float) {
        let r = min(4.5, max(1.2, mass.squareRoot() * 0.9))
        flakes.append(Flake(x: x, y: y, vx: vx, vy: vy, r: r, depth: 1, fall: 0, phase: 0, freq: 0,
                            rot: 0, spin: 0, kind: 2, collide: true, mass: mass, immune: immune, alive: true))
    }

    /// Fine poudre : légère, éphémère, ne s'accumule pas.
    private func spawnPowder(x: Float, y: Float, vx: Float, vy: Float) {
        flakes.append(Flake(x: x, y: y, vx: vx, vy: vy, r: rng.r(0.7, 1.4), depth: 1, fall: 0, phase: 0, freq: 0,
                            rot: 0, spin: 0, kind: 3, collide: false, mass: 0, immune: rng.r(0.35, 0.7), alive: true))
    }

    /// Un bonhomme sur le Dock (ou, sans Dock, sur la plus grande fenêtre libre).
    func buildSnowman(auto: Bool, at fixedX: Float? = nil) {
        let candidates = winOrder.filter { !$0.noSnow && $0.w >= 160 }
        guard let wp = ground ?? candidates.max(by: { $0.w < $1.w }) else { return }
        let onDock = wp.isGround
        let sc = onDock ? rng.r(0.85, 1.1) : rng.r(0.7, 0.9)
        let margin = 30 * sc
        guard wp.w > margin * 2 + 10 else { return }
        var x = wp.minX + wp.w * 0.5
        for _ in 0..<(fixedX == nil ? 24 : 0) {
            let c = rng.r(wp.minX + margin, wp.maxX - margin)
            if snowmen.allSatisfy({ abs($0.x - c) > 110 }) { x = c; break }
        }
        if let fx = fixedX { x = min(max(fx, wp.minX + margin), wp.maxX - margin) }
        if snowmen.count >= 4 { snowmen.removeFirst() }
        // On ramasse la neige autour pour le construire.
        let span = 40 * sc
        if let c = wp.bin(x) {
            let s = Int(span / Pile.binW)
            for i in max(0, c - s)...min(wp.pile.count - 1, c + s) {
                let d = abs(wp.minX + (Float(i) + 0.5) * Pile.binW - x) / span
                wp.pile.h[i] *= 0.45 + 0.55 * min(1, d)
            }
            wp.pile.awake = 90
        }
        snowmen.append(Snowman(x: x, baseY: wp.surface(x) ?? wp.minY,
                               r1: 20 * sc, r2: 14 * sc, r3: 10 * sc, auto: auto,
                               support: wp.id, relX: x - wp.minX))
    }

    /// Menu : tous les bonshommes s'effondrent.
    func knockDownSnowmen() {
        for i in snowmen.indices.reversed() {
            if snowmen[i].hidden { snowmen.remove(at: i) } else { collapseSnowman(i, vx: rng.r(-40, 40)) }
        }
    }

    private func collapseSnowmen(on id: CGWindowID, vx: Float) {
        for i in snowmen.indices.reversed() where snowmen[i].support == id { collapseSnowman(i, vx: vx) }
    }

    /// Le bonhomme s'effondre en paquets de neige.
    private func collapseSnowman(_ i: Int, vx: Float) {
        let m = snowmen[i], g = m.geo()
        for (c, r) in [(g.c1, g.r1), (g.c2, g.r2), (g.c3, g.r3)] where flakes.count < 3700 {
            let n = Int(r / 3.5) + 2
            for _ in 0..<n {
                spawnClump(x: m.x + rng.r(-r, r) * 0.7, y: m.baseY + c + rng.r(-r, r) * 0.6,
                           vx: vx + rng.r(-60, 60), vy: -rng.r(10, 110), mass: r * 0.5, immune: 0.25)
            }
        }
        snowmen.remove(at: i)
    }

    private func dropBalls(on id: CGWindowID) {
        for k in snowballs.indices where snowballs[k].support == id && snowballs[k].id != grabbedID {
            snowballs[k].support = nil
            snowballs[k].restOn = nil
            snowballs[k].state = .falling
            snowballs[k].vy = 0
        }
    }

    // MARK: Déblayage (tractopelle)

    func startPlow() {
        for wp in winOrder { dumpAll(wp) }
        let gid = ground?.id
        for g in [dock, floorPile] {        // sol caché : sa neige disparaît simplement
            guard let g, g.id != gid else { continue }
            g.pile.clear()
            snowmen.removeAll { $0.support == g.id }
            snowballs.removeAll { $0.support == g.id }
        }
        for (_, wp) in piles where !wp.visible { wp.pile.clear() }
        for i in snowmen.indices.reversed() where snowmen[i].support != gid { collapseSnowman(i, vx: 0) }
        grabbedID = nil
        // Les boules hors du Dock éclatent en paquets de neige.
        for k in snowballs.indices where snowballs[k].support == nil || snowballs[k].support != gid {
            let b = snowballs[k]
            for _ in 0..<(Int(b.r / 4) + 2) where flakes.count < 3700 {
                spawnClump(x: b.x + rng.r(-b.r, b.r) * 0.6, y: b.y + rng.r(-b.r, b.r) * 0.6,
                           vx: rng.r(-50, 50), vy: -rng.r(10, 90), mass: b.r * 0.5, immune: 0.4)
            }
            snowballs[k].dead = true
        }
        snowballs.removeAll { $0.dead }
        plow = Plow(x: W + 120)
    }

    /// Hauteur du bas du godet : au niveau de la neige du Dock, sinon au sol.
    private var bucketBottom: Float { min(ground?.minY ?? H, H - 2) }

    private func updatePlow(dt: Float) {
        guard var p = plow else { return }
        if p.waiting {
            // Elle n'entre que quand plus aucun paquet n'est en l'air au-dessus du sol
            // (au plus 6 s, pour ne jamais rester bloquée).
            p.waited += dt
            let top = (ground?.minY ?? H) - 6
            var inAir = 0     // quelques paquets qui débordent encore des bords ne comptent pas
            for fl in flakes where fl.kind == 2 && fl.mass > 1.5 && fl.y < top && fl.x > -20 && fl.x < W + 20 { inAir += 1 }
            if (inAir <= 3 && p.waited > 0.4) || p.waited > 6 { p.waiting = false }
            plow = p
            return
        }
        let speed: Float = 240
        p.t += dt
        p.x -= speed * dt
        p.wheel += speed * dt
        let front = p.x - 56
        if let d = ground {
            // Tout ce qui est derrière le bord du godet est poussé.
            let start = max(0, Int(max(0, front - d.minX) / Pile.binW))
            if start < d.pile.count {
                for i in start..<d.pile.count where d.pile.h[i] > 0 {
                    p.load += d.pile.h[i] * Pile.binW
                    d.pile.h[i] = 0
                }
            }
            d.pile.awake = 30
            for i in snowmen.indices.reversed() where snowmen[i].support == d.id
                && snowmen[i].x + snowmen[i].r1 * 0.6 > front {
                let m = snowmen[i]
                p.load += Float.pi * (m.r1 * m.r1 + m.r2 * m.r2 + m.r3 * m.r3) * 0.6
                for _ in 0..<10 where flakes.count < 3800 {
                    spawnPowder(x: m.x + rng.r(-m.r1, m.r1), y: m.baseY - rng.r(0, m.r1 * 3),
                                vx: -rng.r(30, 140), vy: -rng.r(20, 120))
                }
                snowmen.remove(at: i)
            }
            for k in snowballs.indices where snowballs[k].support == d.id
                && snowballs[k].x + snowballs[k].r * 0.5 > front {
                p.load += Float.pi * snowballs[k].r * snowballs[k].r
                snowballs[k].dead = true
            }
            snowballs.removeAll { $0.dead }
        }
        let R = moundRadius(p.load)
        if R > 3 && flakes.count < 3800 && rng.f() < 0.6 {
            spawnPowder(x: front - R * 1.2, y: bucketBottom - rng.r(0, R * 1.2),
                        vx: -speed * 0.4 - rng.r(10, 80), vy: -rng.r(20, 90))
        }
        plow = p.x < -230 - R * 2 ? nil : p
    }

    @inline(__always) private func moundRadius(_ load: Float) -> Float { min(30, (load / Float.pi).squareRoot()) }

    // MARK: Interaction (⌥ + curseur, sans clic)

    private func ballIndex(_ id: Int) -> Int? { snowballs.firstIndex { $0.id == id } }

    /// Le point p est-il sur un bonhomme visible (avec une petite marge) ?
    private func snowmanIndex(at p: SIMD2<Float>) -> Int? {
        snowmen.firstIndex { m in
            let g = m.geo()
            return !m.hidden && abs(p.x - m.x) < g.r1 * 1.15 && p.y < m.baseY + 4 && p.y > m.baseY + g.c3 - g.r3 - 6
        }
    }

    /// Surface enneigée (non cachée) juste sous le point p, à `slack` pt près.
    private func surfacePile(near p: SIMD2<Float>, slack: Float) -> WinPile? {
        for wp in order where !wp.noSnow {
            guard let li = wp.bin(p.x), !wp.occluded[li] else { continue }
            let b = wp.minY + wp.base[li]
            let s = b - wp.pile.h[li]
            if p.y >= s - slack && p.y <= b + 6 { return wp }
        }
        return nil
    }

    private func updateGrab() {
        guard option && cursorValid else {
            if let id = grabbedID { release(id) }
            return
        }
        guard grabbedID == nil else { return }
        // Attraper une boule (celle du dessus d'une pile)
        if let i = snowballs.indices.reversed().first(where: { k in
            let b = snowballs[k]
            return b.state == .resting && simd_distance(SIMD2(b.x, b.y), cursor) < b.r + 4
                && !snowballs.contains { $0.restOn == b.id }
        }) {
            snowballs[i].state = .carried
            snowballs[i].restOn = nil
            snowballs[i].support = nil
            grabbedID = snowballs[i].id
            return
        }
        // Commencer une boule en glissant le long de la neige (pas sur un bonhomme :
        // là, ⌥ + un coup de curseur sert à le faire tomber)
        guard abs(cursorV.x) > 25, snowmanIndex(at: cursor) == nil, let wp = surfacePile(near: cursor, slack: 12),
              let c = wp.bin(cursor.x), wp.pile.h[c] > 1.5 else { return }
        var area: Float = 0
        for i in max(0, c - 3)...min(wp.pile.count - 1, c + 3) {
            let take = wp.pile.h[i] * 0.5
            wp.pile.h[i] -= take
            area += take * Pile.binW
        }
        wp.pile.awake = 90
        let r = max(3.5, (area / Float.pi).squareRoot())
        if snowballs.count >= 12, let old = snowballs.firstIndex(where: { $0.state == .resting && $0.restOn == nil }) {
            snowballs.remove(at: old)
        }
        let b = Snowball(id: nextBallID, x: cursor.x, y: (wp.surface(cursor.x) ?? wp.minY) - r * Snowball.sink, r: r,
                         state: .rolling, support: wp.id, relX: cursor.x - wp.minX)
        nextBallID += 1
        snowballs.append(b)
        grabbedID = b.id
    }

    private func release(_ id: Int) {
        grabbedID = nil
        guard let i = ballIndex(id) else { return }
        // Elle garde l'élan du curseur : lancée en l'air, ou qui continue de rouler.
        snowballs[i].vx = max(-1100, min(1100, snowballs[i].vx))
        if snowballs[i].state == .rolling, let sid = snowballs[i].support, let wp = pileFor(sid) {
            snowballs[i].state = .resting
            snowballs[i].relX = snowballs[i].x - wp.minX
            snowballs[i].vy = 0
        } else {
            snowballs[i].state = .falling
            snowballs[i].support = nil
            snowballs[i].vy = max(-600, min(900, snowballs[i].vy))
        }
    }

    /// La boule éclate : une partie redevient de la neige sur la surface, le reste en paquets.
    private func breakBall(_ b: Snowball, on wp: WinPile?, surface: Float) {
        let units = Float.pi * b.r * b.r / Pile.binW          // en « hauteur × colonnes »
        if let wp {
            let n = max(3, Int(b.r / 2))
            for k in 0..<n {
                let x = b.x + (Float(k) / Float(n - 1) - 0.5) * 1.8 * b.r + b.vx * 0.03
                if x >= wp.minX && x < wp.maxX { wp.pile.add(at: x - wp.minX, mass: units * 0.55 / Float(n)) }
            }
            wp.pile.awake = 90
        }
        let count = min(14, Int(b.r / 2) + 4)
        for _ in 0..<count where flakes.count < 3800 {
            spawnClump(x: b.x + rng.r(-b.r, b.r) * 0.5, y: surface - rng.r(1, b.r * 0.6),
                       vx: b.vx * 0.35 + rng.r(-130, 130), vy: -rng.r(60, 260),
                       mass: units * 0.45 / Float(count), immune: 0.12)
        }
        for _ in 0..<10 where flakes.count < 3800 {
            spawnPowder(x: b.x + rng.r(-b.r, b.r), y: surface - rng.r(0, b.r),
                        vx: b.vx * 0.2 + rng.r(-90, 90), vy: -rng.r(40, 160))
        }
    }

    private func updateSnowballs(dt: Float) {
        guard !snowballs.isEmpty else { return }

        // Boule tenue : elle roule sur la neige sous le curseur, sinon on la porte.
        if let id = grabbedID, let i = ballIndex(id) {
            var b = snowballs[i]
            let ox = b.x, oy = b.y
            let overBall = snowballs.contains { $0.id != id && $0.state == .resting && abs($0.x - cursor.x) < $0.r }
            let wp = overBall ? nil : surfacePile(near: cursor, slack: b.r * 1.4)
            if let wp {
                b.state = .rolling
                b.support = wp.id
                let maxStep = 900 * dt
                let tx = min(max(cursor.x, wp.minX + 2), wp.maxX - 2)
                let nx = b.x + max(-maxStep, min(maxStep, tx - b.x))
                // Ramasse la neige sur le chemin (et laisse une trace).
                // Pas plus grosse que la place au-dessus (fenêtre collée à la barre des menus).
                let maxR = max(4, min(30, (wp.surface(b.x) ?? wp.minY) / 1.95))
                if abs(nx - b.x) > 0.01 && b.r < maxR, let a = wp.bin(min(b.x, nx)), let z = wp.bin(max(b.x, nx)) {
                    var area = Float.pi * b.r * b.r
                    for k in a...z {
                        let take = min(wp.pile.h[k], wp.pile.h[k] * 0.6 + 0.3)
                        wp.pile.h[k] -= take
                        area += take * Pile.binW
                    }
                    wp.pile.awake = 90
                    b.r = min(maxR, (area / Float.pi).squareRoot())
                }
                b.spin += (nx - b.x) / max(b.r, 1)
                b.x = nx
                let target = (wp.surface(b.x) ?? wp.minY) - b.r * Snowball.sink
                b.y += (target - b.y) * min(1, 18 * dt)
                b.relX = b.x - wp.minX
            } else {
                b.state = .carried
                b.support = nil
                b.x += (cursor.x - b.x) * min(1, 32 * dt)
                b.y += (cursor.y - b.y) * min(1, 32 * dt)
            }
            // Vitesse de la boule (lissée) : c'est l'élan qu'elle garde quand on la lâche.
            b.vx = b.vx * 0.5 + (b.x - ox) / max(dt, 0.001) * 0.5
            b.vy = b.state == .carried ? b.vy * 0.5 + (b.y - oy) / max(dt, 0.001) * 0.5 : 0
            snowballs[i] = b
        }

        // Les autres : chute, repos, empilement
        var stacked = false
        for i in snowballs.indices where snowballs[i].id != grabbedID {
            var b = snowballs[i]
            switch b.state {
            case .falling:
                let prevBottom = b.y + b.r * Snowball.sink
                b.vy += 900 * dt
                b.vx -= b.vx * min(1, 0.3 * dt)
                b.x += b.vx * dt
                b.y += b.vy * dt
                // Atterrit sur une boule au repos assez grosse ?
                for j in snowballs.indices where j != i && snowballs[j].state == .resting {
                    let o = snowballs[j]
                    let topOfO = o.y - o.r * 0.8
                    if abs(b.x - o.x) < o.r * 0.9 + b.r * 0.6 && b.y + b.r >= topOfO && b.y < o.y && b.r <= o.r * 1.1
                        && !snowballs.contains(where: { $0.restOn == o.id }) {
                        if b.vy > Snowball.breakSpeed {      // trop vite : elle éclate sur l'autre boule
                            breakBall(b, on: o.support.flatMap { pileFor($0) }, surface: topOfO)
                            b.dead = true
                            break
                        }
                        b.state = .resting
                        b.restOn = o.id
                        b.support = o.support
                        b.x = o.x
                        b.y = o.y - o.r * 0.82 - b.r * 0.72
                        b.vy = 0
                        b.vx = 0
                        stacked = true
                        break
                    }
                }
                if b.state == .falling && !b.dead {
                    // Contre le flanc d'une autre boule : elle glisse à côté au lieu de s'y enfoncer.
                    for j in snowballs.indices where j != i && snowballs[j].state == .resting {
                        let o = snowballs[j]
                        let dx = b.x - o.x, dy = b.y - o.y, minD = o.r + b.r * 0.85
                        if dx * dx + dy * dy < minD * minD {
                            b.x = o.x + (dx >= 0 ? 1 : -1) * (minD + 0.5)
                        }
                    }
                    // …ou sur une surface enneigée (Dock, haut d'une fenêtre)
                    for wp in order where !wp.noSnow {
                        guard let li = wp.bin(b.x), !wp.occluded[li] else { continue }
                        let s = wp.minY + wp.base[li] - wp.pile.h[li]
                        if prevBottom <= s + 1 && b.y + b.r * Snowball.sink >= s {
                            if b.vy > Snowball.breakSpeed {   // tombée de haut : elle éclate
                                breakBall(b, on: wp, surface: s)
                                b.dead = true
                                break
                            }
                            // Pas assez haut : elle se pose et garde un peu de son élan.
                            b.y = s - b.r * Snowball.sink
                            b.state = .resting
                            b.support = wp.id
                            b.relX = b.x - wp.minX
                            b.vy = 0
                            b.vx = b.vx * 0.7 + (b.vx >= 0 ? 1 : -1) * min(abs(b.vx) * 0.1, 40)
                            break
                        }
                    }
                }
                if b.y - b.r > H + 20 || b.x < -b.r - 60 || b.x > W + b.r + 60 { b.dead = true }
            case .resting:
                if let below = b.restOn {
                    if let j = ballIndex(below) {
                        let o = snowballs[j]
                        b.x = o.x
                        b.y = o.y - o.r * 0.82 - b.r * 0.72
                        b.support = o.support
                    } else {
                        b.restOn = nil; b.state = .falling; b.support = nil
                    }
                } else if let sid = b.support, let wp = pileFor(sid), !wp.visible || wp.noSnow {
                    _ = wp                   // support caché : la boule attend, invisible
                } else if let sid = b.support, let wp = pileFor(sid), wp.visible, !wp.noSnow,
                          b.relX >= 0, b.relX <= wp.w {
                    if abs(b.vx) > 4 {
                        // Elle roule encore : ralentit, tourne, ramasse un peu de neige.
                        let ox = wp.minX + b.relX
                        let nx = ox + b.vx * dt
                        let maxR = max(4, min(30, (wp.surface(ox) ?? wp.minY) / 1.95))
                        if b.r < maxR, let a = wp.bin(min(ox, nx)), let z = wp.bin(max(ox, nx)) {
                            var area = Float.pi * b.r * b.r
                            for k in a...z {
                                let take = wp.pile.h[k] * 0.35
                                wp.pile.h[k] -= take
                                area += take * Pile.binW
                            }
                            wp.pile.awake = 90
                            b.r = min(maxR, (area / Float.pi).squareRoot())
                        }
                        b.spin += (nx - ox) / max(b.r, 1)
                        b.relX += nx - ox
                        b.vx -= b.vx * min(1, 2.6 * dt) + (b.vx > 0 ? 1 : -1) * min(abs(b.vx), 70 * dt)
                        // Elle bute contre une autre boule posée là
                        if snowballs.contains(where: { $0.id != b.id && $0.support == sid && $0.restOn == nil
                            && $0.state == .resting && abs($0.x - nx) < ($0.r + b.r) * 0.9 && ($0.x - nx) * b.vx > 0 }) {
                            b.vx = 0
                        }
                    } else {
                        b.vx = 0
                    }
                    if b.relX < 0 || b.relX > wp.w {
                        b.state = .falling; b.support = nil      // roule au-delà du bord : elle tombe
                    } else {
                        b.x = wp.minX + b.relX
                        let target = (wp.surface(b.x) ?? wp.minY) - b.r * Snowball.sink
                        if abs(target - b.y) > 3 { b.y = target } else { b.y += (target - b.y) * min(1, 3 * dt) }
                    }
                } else {
                    b.state = .falling; b.support = nil
                }
            default:
                b.state = .falling
            }
            b.hidden = false
            if let sid = b.support, let wp = pileFor(sid) {
                b.hidden = !wp.visible || (wp.bin(b.x).map { wp.occluded[$0] } ?? false)
            }
            snowballs[i] = b
        }
        snowballs.removeAll { $0.dead }

        // Trois boules empilées → un bonhomme de neige
        if stacked {
            for base in snowballs where base.restOn == nil && base.state == .resting {
                guard let sid = base.support,
                      let mid = snowballs.first(where: { $0.restOn == base.id }),
                      let head = snowballs.first(where: { $0.restOn == mid.id }) else { continue }
                var m = Snowman(x: base.x, baseY: base.y + base.r * 0.94, r1: base.r, r2: mid.r, r3: head.r,
                                auto: false, support: sid, relX: base.relX)
                m.t = 2.4   // le corps est déjà là : on passe directement au visage
                if snowmen.count >= 4 { snowmen.removeFirst() }
                snowmen.append(m)
                let ids: Set<Int> = [base.id, mid.id, head.id]
                snowballs.removeAll { ids.contains($0.id) }
                break
            }
        }
    }

    // MARK: Pas de simulation

    func step(dt: Float, mouse: NSPoint, option opt: Bool, settings s: Settings, energyFactor: Float) {
        t += dt
        updateCursor(mouse, dt: dt)
        option = opt && s.cursorInteraction

        let accumOn = s.accumulation > 0
        let accumRate: Float = [0, 2.5, 6.0, 14.0][min(3, max(0, s.accumulation))]
        let windBase: Float = [0, 22, 65][min(2, max(0, s.wind))]
        let gust = windBase * (0.75 + 0.35 * sin(t * 0.21) + 0.25 * sin(t * 0.53 + 1.7))
            + (windBase > 0 ? 6 * sin(t * 0.9) : 0)

        // Apparition des flocons
        let baseCounts: [Float] = [130, 300, 620, 1050]
        let area = max(0.3, (W * H) / (1512 * 982))
        let target = Int(baseCounts[min(3, max(0, s.intensity))] * area * energyFactor)
        var normal = 0
        for f in flakes where f.kind < 2 { normal += 1 }
        if !prefilled {
            prefilled = true
            for _ in 0..<target { spawnFlake(y: -rng.r(0, H), windBase: windBase) }
            normal = target
        }
        var budget = max(2, target / 60)
        while normal < target && budget > 0 {
            spawnFlake(y: -rng.r(4, 30), windBase: windBase)
            normal += 1; budget -= 1
        }

        // Mouvement + collisions
        let cursorOn = s.cursorInteraction && cursorValid
        let speed = simd_length(cursorV)
        let wake = cursorOn && speed > 30
        let R: Float = 45, R2 = R * R
        let k = min(1, 2.5 * dt)
        for i in 0..<flakes.count {
            var f = flakes[i]
            switch f.kind {
            case 2:
                f.vy += 900 * dt
                f.vx -= f.vx * min(1, 1.2 * dt)
                f.immune -= dt
            case 3:
                f.vy += 260 * dt
                f.vx -= f.vx * min(1, 2.5 * dt)
                f.immune -= dt
                if f.immune <= 0 { f.alive = false }
            default:
                let sway = sin(t * f.freq + f.phase) * (6 + 12 * f.depth)
                let tvx = gust * (0.35 + 0.65 * f.depth) + sway
                f.vx += (tvx - f.vx) * k
                f.vy += (f.fall - f.vy) * k
                // Le sillage de la souris emporte les flocons proches (rien si elle est immobile).
                if wake {
                    let dx = f.x - cursor.x, dy = f.y - cursor.y
                    let d2 = dx * dx + dy * dy
                    if d2 < R2 && d2 > 0.01 {
                        let d = d2.squareRoot()
                        let w = (1 - d / R) * min(1, 8 * dt)
                        f.vx += (cursorV.x * 0.5 - f.vx) * w + dx / d * speed * 0.12 * w
                        f.vy += (cursorV.y * 0.5 - f.vy) * w * 0.6 + dy / d * speed * 0.12 * w
                    }
                }
                f.rot += f.spin * dt
            }
            let prevY = f.y
            f.x += f.vx * dt
            f.y += f.vy * dt
            if f.collide && land(f, prevY: prevY, accumOn: accumOn, rate: accumRate) { f.alive = false }
            if f.y > H + 30 || f.x < -140 - windBase * 10 || f.x > W + 140 { f.alive = false }
            flakes[i] = f
        }
        flakes.removeAll { !$0.alive }

        // Tassement + débordement sur les bords (fenêtres et Dock)
        for wp in order where !wp.noSnow {
            let (l, r) = wp.pile.relax(base: wp.base, maxSlope: 0.9, edgeMax: 1.2)
            wp.spillL += l; wp.spillR += r
            if wp.spillL > 1.0 {
                spawnClump(x: wp.minX + 1, y: wp.minY + wp.base[0] - 1, vx: -rng.r(10, 30), vy: 0,
                           mass: wp.spillL, immune: 0.05)
                wp.spillL = 0
            }
            if wp.spillR > 1.0 {
                spawnClump(x: wp.maxX - 1, y: wp.minY + wp.base[wp.base.count - 1] - 1,
                           vx: rng.r(10, 30), vy: 0, mass: wp.spillR, immune: 0.05)
                wp.spillR = 0
            }
        }

        // ⌥ : rouler / porter une boule
        updateGrab()

        // Le curseur trace un sillon dans la neige
        if cursorOn && grabbedID == nil {
            for wp in order where !wp.noSnow && cursor.x >= wp.minX && cursor.x <= wp.maxX
                && cursor.y > wp.minY - wp.pile.maxH - 10 && cursor.y < wp.minY + 8 {
                carve(wp, speed: speed)
                break
            }
        }

        updateSnowballs(dt: dt)
        updateSnowmen(dt: dt, settings: s, cursorOn: cursorOn)
        updatePlow(dt: dt)
        buildGeometry()
    }

    private func updateCursor(_ m: NSPoint, dt: Float) {
        let lx = Float(m.x - cocoaFrame.minX), ly = Float(cocoaFrame.maxY - m.y)
        if lx >= 0 && lx <= W && ly >= 0 && ly <= H {
            let p = SIMD2(lx, ly)
            if cursorValid { cursorV = cursorV * 0.6 + ((p - cursor) / max(dt, 0.001)) * 0.4 }
            cursor = p
            cursorValid = true
        } else {
            cursorValid = false
            cursorV = .zero
        }
    }

    @inline(__always)
    private func land(_ f: Flake, prevY: Float, accumOn: Bool, rate: Float) -> Bool {
        let mass = f.kind == 2 ? f.mass : (0.6 + f.r * 0.8) * rate
        if f.immune <= 0 {
            for k in 0..<rects.count {
                let rc = rects[k]
                if f.x < rc.x || f.x >= rc.z { continue }
                let wp = order[k]
                if wp.noSnow { continue }
                // Seuls les flocons du premier plan se posent sur les fenêtres ; les autres
                // passent derrière et vont jusqu'au Dock.
                if !wp.isGround && f.kind < 2 && f.depth < 0.55 { continue }
                let li = Int((f.x - rc.x) / Pile.binW)
                if li < 0 || li >= wp.pile.count { continue }
                let surf = rc.y + wp.base[li] - wp.pile.h[li]
                if prevY <= surf && f.y >= surf {
                    if wp.occluded[li] { continue }
                    if f.kind < 2 && rng.f() > landP[k] { continue }   // passe devant cette fenêtre
                    if accumOn || f.kind == 2 { wp.pile.add(at: f.x - rc.x, mass: mass) }
                    return true
                }
            }
        }
        for b in colliders {
            let dx = f.x - b.x, dy = f.y - b.y
            if dx * dx + dy * dy < b.z * b.z { return true }
        }
        return false
    }

    /// Le curseur agit comme un doigt : la neige au-dessus de sa pointe est repoussée
    /// sur les côtés (petits bourrelets, surtout dans le sens du mouvement).
    private func carve(_ wp: WinPile, speed: Float) {
        let pile = wp.pile
        let r: Float = 6
        let n = pile.count
        let ci = Int((cursor.x - wp.minX) / Pile.binW)
        let span = Int(r / Pile.binW) + 1
        let i0 = max(0, ci - span), i1 = min(n - 1, ci + span)
        guard i0 <= i1 else { return }
        var removed: Float = 0
        var topY = Float.greatestFiniteMagnitude
        for i in i0...i1 where !wp.occluded[i] {
            let dxp = wp.minX + (Float(i) + 0.5) * Pile.binW - cursor.x
            let prof = max(0, r * r - dxp * dxp).squareRoot()
            let b = wp.minY + wp.base[i]
            let limit = max(0, b - (cursor.y + prof))     // hauteur max sous la pointe
            if pile.h[i] > limit {
                topY = min(topY, b - pile.h[i])
                removed += pile.h[i] - limit
                pile.h[i] = limit
            }
        }
        guard removed > 0.01 else { return }
        pile.awake = 90
        // Bourrelets de part et d'autre
        let right = max(0.15, min(0.85, 0.5 + cursorV.x / 500))
        let w: [Float] = [0.5, 0.3, 0.2]
        for (k, wk) in w.enumerated() {
            let l = i0 - 1 - k, rr = i1 + 1 + k
            if l >= 0 { pile.h[l] = min(pile.maxH, pile.h[l] + removed * (1 - right) * wk) }
            if rr < n { pile.h[rr] = min(pile.maxH, pile.h[rr] + removed * right * wk) }
        }
        // Un peu de poudre si on va vite
        if speed > 80 && flakes.count < 3800 {
            let cnt = min(4, Int(removed * speed / 400) + 1)
            for _ in 0..<cnt {
                spawnPowder(x: cursor.x + rng.r(-4, 4), y: topY - 1,
                            vx: cursorV.x * 0.25 + rng.r(-25, 25), vy: -rng.r(25, 75))
            }
        }
    }

    // MARK: Bonshommes de neige

    private func updateSnowmen(dt: Float, settings s: Settings, cursorOn: Bool) {
        snowmanTimer += dt
        if snowmanTimer > 4 {
            snowmanTimer = 0
            let autos = snowmen.filter { $0.auto }.count
            if s.autoSnowman && s.accumulation > 0 && autos < 2 && snowmen.count < 3 && plow == nil, let d = ground {
                let avg = d.pile.total / Float(max(1, d.pile.count))
                if avg > 9 + Float(snowmen.count) * 4 { buildSnowman(auto: true) }
            }
        }

        colliders.removeAll(keepingCapacity: true)
        var i = snowmen.count - 1
        while i >= 0 {
            var m = snowmen[i]
            guard let wp = pileFor(m.support), m.relX >= 0, m.relX <= wp.w else {
                collapseSnowman(i, vx: 0)
                i -= 1
                continue
            }
            if !wp.visible || wp.noSnow {   // fenêtre minimisée, Dock masqué, plein écran : il attend
                m.hidden = true
                snowmen[i] = m
                i -= 1
                continue
            }
            m.t += dt
            m.x = wp.minX + m.relX
            let target = wp.surface(m.x) ?? wp.minY
            if abs(target - m.baseY) > 3 { m.baseY = target } else { m.baseY += (target - m.baseY) * min(1, dt * 2) }
            m.hidden = wp.bin(m.x).map { wp.occluded[$0] } ?? false
            // ⌥ + un coup de curseur rapide à travers le bonhomme, ou une boule qu'on fait
            // rouler contre lui : il tombe.
            if option && cursorOn && !m.hidden && abs(cursorV.x) > 180 {
                let gg = m.geo()
                var hit = abs(cursor.x - m.x) < gg.r1 * 1.15 && cursor.y < m.baseY + 4 && cursor.y > m.baseY + gg.c3 - gg.r3 - 6
                if !hit, let id = grabbedID, let bi = ballIndex(id) {
                    let b = snowballs[bi]
                    hit = abs(b.x - m.x) < b.r + gg.r1 * 0.9 && abs(b.y - (m.baseY + gg.c1)) < b.r + gg.r1
                }
                if hit {
                    collapseSnowman(i, vx: cursorV.x * 0.25)
                    i -= 1
                    continue
                }
            }
            m.wobbleV += (-70 * m.wobble - 3.5 * m.wobbleV) * dt
            m.wobble = max(-0.4, min(0.4, m.wobble + m.wobbleV * dt))

            let g = m.geo()
            if cursorOn {
                let inside = abs(cursor.x - m.x) < g.r1 && cursor.y < m.baseY && cursor.y > m.baseY + g.c3 - g.r3 - 14 * m.sc
                if inside && !m.cursorInside && abs(cursorV.x) > 120 {
                    m.wobbleV += (cursorV.x > 0 ? 1 : -1) * min(3.5, abs(cursorV.x) / 450)
                }
                m.cursorInside = inside
            }
            snowmen[i] = m

            if !m.hidden {
                let ca = cos(m.wobble), sa = sin(m.wobble)
                func P(_ ly: Float) -> SIMD2<Float> { SIMD2(m.x - ly * sa, m.baseY + ly * ca) }
                if m.t > 0.9 { let p = P(g.c1); colliders.append(SIMD3(p.x, p.y, g.r1)) }
                if m.t > 1.7 { let p = P(g.c2); colliders.append(SIMD3(p.x, p.y, g.r2)) }
                if m.t > 2.4 { let p = P(g.c3); colliders.append(SIMD3(p.x, p.y, g.r3)) }
            }
            i -= 1
        }
        for b in snowballs where !b.hidden { colliders.append(SIMD3(b.x, b.y, b.r)) }
    }

    // MARK: Géométrie

    private func buildGeometry() {
        sprites.removeAll(keepingCapacity: true)
        pileVerts.removeAll(keepingCapacity: true)

        // 1. Neige des fenêtres et du Dock
        for wp in order.reversed() where !wp.noSnow {
            appendPile(wp.pile, x0: wp.minX, baseY: wp.minY, base: wp.base, occluded: wp.occluded)
        }
        pileSplit = pileVerts.count

        // 2. Bonshommes et boules, posés sur la neige (devant elle)
        let white = SIMD4<Float>(1, 1, 1, 1)
        for m in snowmen where !m.hidden { appendSnowman(m) }
        for b in snowballs where !b.hidden { sprites.append(mkSprite(b.x, b.y, b.r, b.spin, white, .ball, textured: true)) }
        spriteSplit = sprites.count

        // 3. Tractopelle, puis flocons devant
        if let p = plow { appendPlow(p) }
        for f in flakes {
            switch f.kind {
            case 1:
                sprites.append(mkSprite(f.x, f.y, f.r, f.rot, SIMD4(1, 1, 1, 0.95), .crystal))
            case 2:
                sprites.append(mkSprite(f.x, f.y, f.r, 0, white, f.r > 2.2 ? .ball : .soft))
            case 3:
                sprites.append(mkSprite(f.x, f.y, f.r * 1.3, 0, SIMD4(1, 1, 1, min(1, f.immune * 3) * 0.9), .soft))
            default:
                sprites.append(mkSprite(f.x, f.y, f.r * 1.25, 0, SIMD4(1, 1, 1, 0.45 + 0.55 * f.depth), .soft))
            }
        }
    }

    private func appendPile(_ pile: Pile, x0: Float, baseY: Float, base: [Float]?, occluded: [Bool]?) {
        let n = pile.count
        guard n >= 2 else { return }
        let bw = Pile.binW
        for i in 0..<(n - 1) {
            let ha = pile.h[i], hb = pile.h[i + 1]
            if ha < 0.05 && hb < 0.05 { continue }
            if let o = occluded, o[i] || o[i + 1] { continue }
            let xa = x0 + (Float(i) + 0.5) * bw
            let ba = baseY + (base?[i] ?? 0), bb = baseY + (base?[i + 1] ?? 0)
            appendColumnPair(xa, ba, ha, xa + bw, bb, hb)
        }
    }

    /// 3 bandes par colonne : bord doux, fine crête légèrement bleutée, corps blanc → ombre en bas.
    @inline(__always)
    private func appendColumnPair(_ xa: Float, _ ba: Float, _ ha: Float, _ xb: Float, _ bb: Float, _ hb: Float) {
        let ca = min(1, ha / 0.8), cb = min(1, hb / 0.8)
        let ta = ba - ha, tb = bb - hb
        let crest: Float = 0.32
        let a0 = PileVert(pos: SIMD2(xa, ta - 1.0), info: SIMD2(crest, 0))
        let a1 = PileVert(pos: SIMD2(xa, ta), info: SIMD2(crest, ca))
        let a2 = PileVert(pos: SIMD2(xa, min(ta + 2.5, ba)), info: SIMD2(0, ca))
        let a3 = PileVert(pos: SIMD2(xa, ba), info: SIMD2(0.42, ca))
        let b0 = PileVert(pos: SIMD2(xb, tb - 1.0), info: SIMD2(crest, 0))
        let b1 = PileVert(pos: SIMD2(xb, tb), info: SIMD2(crest, cb))
        let b2 = PileVert(pos: SIMD2(xb, min(tb + 2.5, bb)), info: SIMD2(0, cb))
        let b3 = PileVert(pos: SIMD2(xb, bb), info: SIMD2(0.42, cb))
        pileVerts.append(a0); pileVerts.append(b0); pileVerts.append(a1)
        pileVerts.append(b0); pileVerts.append(b1); pileVerts.append(a1)
        pileVerts.append(a1); pileVerts.append(b1); pileVerts.append(a2)
        pileVerts.append(b1); pileVerts.append(b2); pileVerts.append(a2)
        pileVerts.append(a2); pileVerts.append(b2); pileVerts.append(a3)
        pileVerts.append(b2); pileVerts.append(b3); pileVerts.append(a3)
    }

    /// Tractopelle vue de profil, tournée vers la gauche. Dessin vectoriel original.
    private func appendPlow(_ p: Plow) {
        let x = p.x, gy = H - 1, by = bucketBottom
        let yellow = SIMD4<Float>(0.97, 0.73, 0.11, 1)
        let yellowDark = SIMD4<Float>(0.80, 0.55, 0.06, 1)
        let dark = SIMD4<Float>(0.17, 0.17, 0.19, 1)
        let steel = SIMD4<Float>(0.56, 0.58, 0.62, 1)
        let tire = SIMD4<Float>(0.10, 0.10, 0.11, 1)
        let glass = SIMD4<Float>(0.62, 0.80, 0.93, 0.95)
        let white = SIMD4<Float>(1, 1, 1, 1)

        func box(_ cx: Float, _ cy: Float, _ hw: Float, _ hh: Float, _ c: SIMD4<Float>, rot: Float = 0, r: Float = 0) {
            sprites.append(mkSprite(cx, cy, hw, rot, c, .rect, aspect: hh / hw, radius: r))
        }
        func bar(_ ax: Float, _ ay: Float, _ bx: Float, _ by: Float, _ th: Float, _ c: SIMD4<Float>) {
            let dx = bx - ax, dy = by - ay
            let half = max(1, (dx * dx + dy * dy).squareRoot() * 0.5)
            sprites.append(mkSprite((ax + bx) * 0.5, (ay + by) * 0.5, half, atan2(dy, dx), c, .rect,
                                    aspect: th / half, radius: th * 0.9))
        }
        func wheel(_ cx: Float, _ r: Float) {
            let cy = gy - r
            sprites.append(mkSprite(cx, cy, r, 0, tire, .disc))
            sprites.append(mkSprite(cx, cy, r * 0.5, 0, yellow, .disc))
            let a = -p.wheel / r
            box(cx, cy, r * 0.42, r * 0.09, yellowDark, rot: a)
            box(cx, cy, r * 0.42, r * 0.09, yellowDark, rot: a + Float.pi / 2)
            sprites.append(mkSprite(cx, cy, r * 0.17, 0, dark, .disc))
        }

        // Pelle arrière repliée
        bar(x + 32, gy - 30, x + 46, gy - 60, 2.8, yellowDark)
        bar(x + 46, gy - 60, x + 56, gy - 32, 2.3, yellowDark)
        box(x + 56, gy - 28, 4.5, 4, steel, rot: 0.3, r: 1.5)

        // Carrosserie
        box(x + 16, gy - 50, 13, 17, yellow, r: 3)                 // cabine
        box(x + 14, gy - 52, 9.5, 11.5, glass, r: 2)               // vitre
        box(x + 16, gy - 68, 15.5, 2.2, dark, r: 1.5)              // toit
        box(x - 24, gy - 46, 1.6, 7, dark, r: 1)                   // pot d'échappement
        box(x - 16, gy - 33, 16, 7, yellow, r: 3)                  // capot
        box(x - 16, gy - 33, 11, 0.8, yellowDark)
        box(x, gy - 22, 36, 7, yellow, r: 3)                       // châssis
        box(x + 24, gy - 37, 19, 2.4, yellowDark, r: 2)            // garde-boue

        wheel(x + 24, 17)
        wheel(x - 22, 12)

        // Gyrophare
        let pulse = 0.5 + 0.5 * sin(p.t * 9)
        sprites.append(mkSprite(x + 18, gy - 72, 11, 0, SIMD4(1, 0.55, 0.1, 0.55 * pulse), .glow))
        sprites.append(mkSprite(x + 18, gy - 72, 2.8, 0, SIMD4(1, 0.6 + 0.2 * pulse, 0.15, 1), .disc))

        // Neige poussée devant le godet
        let R = moundRadius(p.load)
        let front = x - 56
        if R > 2 {
            sprites.append(mkSprite(front - R * 0.5, by - R * 0.55, R, p.t * 0.2, white, .ball, textured: true))
            sprites.append(mkSprite(front - R * 1.15, by - R * 0.35, R * 0.62, p.t * 0.3 + 1, white, .ball, textured: true))
            sprites.append(mkSprite(front - R * 0.1, by - R * 1.05, R * 0.55, 2, white, .ball, textured: true))
        }

        // Bras du chargeur + godet (au niveau de la neige du Dock)
        bar(x - 4, gy - 38, front + 6, by - 9, 2.8, yellowDark)
        bar(x - 10, gy - 26, front + 8, by - 4, 1.6, steel)        // vérin
        box(front + 4, by - 9.5, 5.5, 9.5, steel, r: 2)
        box(front - 0.5, by - 9.5, 1.5, 9.5, dark, r: 1)
    }

    private func appendSnowman(_ m: Snowman) {
        let sc = m.sc, t = m.t
        func prog(_ a: Float, _ d: Float) -> Float { min(1, max(0, (t - a) / d)) }
        func pop(_ p: Float) -> Float {
            if p <= 0 { return 0 }
            if p >= 1 { return 1 }
            let c1: Float = 1.70158, c3 = c1 + 1, q = p - 1
            return 1 + c3 * q * q * q + c1 * q * q
        }
        let ca = cos(m.wobble), sa = sin(m.wobble)
        func P(_ lx: Float, _ ly: Float) -> (Float, Float) {
            (m.x + lx * ca - ly * sa, m.baseY + lx * sa + ly * ca)
        }
        let p1 = pop(prog(0, 0.9)), p2 = pop(prog(0.9, 0.8)), p3 = pop(prog(1.7, 0.7))
        let g = m.geo(p1, p2, p3)
        let white = SIMD4<Float>(1, 1, 1, 1)
        let coal = SIMD4<Float>(0.09, 0.09, 0.11, 1)
        let wood = SIMD4<Float>(0.40, 0.25, 0.13, 1)
        let red = SIMD4<Float>(0.80, 0.15, 0.17, 1)
        let rot = m.wobble

        // Corps
        if p1 > 0 { let (x, y) = P(0, g.c1); sprites.append(mkSprite(x, y, g.r1, rot, white, .ball, textured: true)) }
        if p2 > 0 { let (x, y) = P(0, g.c2); sprites.append(mkSprite(x, y, g.r2, rot + 1.3, white, .ball, textured: true)) }
        if p3 > 0 { let (x, y) = P(0, g.c3); sprites.append(mkSprite(x, y, g.r3, rot + 2.1, white, .ball, textured: true)) }
        guard p3 >= 1 else { return }

        // Bras (branches)
        let arms = prog(3.1, 0.4)
        if arms > 0 {
            for side: Float in [-1, 1] {
                let th: Float = side < 0 ? Float.pi + 0.45 : -0.45
                let dir = SIMD2<Float>(cos(th), sin(th))
                let sh = SIMD2<Float>(side * g.r2 * 0.8, g.c2 - g.r2 * 0.15)
                let L = 17 * sc * arms
                let c = sh + dir * (L * 0.5)
                let (x, y) = P(c.x, c.y)
                sprites.append(mkSprite(x, y, L * 0.5, th + rot, wood, .rect, aspect: (0.9 * sc) / max(0.5, L * 0.5)))
                if arms >= 1 {
                    let tw = th + (side < 0 ? 0.6 : -0.6)
                    let td = SIMD2<Float>(cos(tw), sin(tw))
                    let tc = sh + dir * (L * 0.68) + td * (2.5 * sc)
                    let (tx, ty) = P(tc.x, tc.y)
                    sprites.append(mkSprite(tx, ty, 2.5 * sc, tw + rot, wood, .rect, aspect: 0.3))
                }
            }
        }

        // Visage
        let face = prog(2.4, 0.4)
        if face > 0 {
            var c = coal; c.w = face
            for sx: Float in [-3.4, 3.4] {
                let (x, y) = P(sx * sc, g.c3 - 2.2 * sc)
                sprites.append(mkSprite(x, y, 1.35 * sc, 0, c, .disc))
            }
            for k in -2...2 {
                let a = Float(k) * 0.3
                let (x, y) = P(5 * sc * sin(a), g.c3 + 1.2 * sc + 3.6 * sc * cos(a))
                sprites.append(mkSprite(x, y, 0.75 * sc, 0, c, .disc))
            }
            let (nx, ny) = P(g.r3 * 0.15 + 4.2 * sc, g.c3 + 0.6 * sc)
            sprites.append(mkSprite(nx, ny, 4.2 * sc, rot + 0.08, SIMD4(0.98, 0.55, 0.12, face), .tri, aspect: 0.36))
        }

        // Boutons
        let btn = prog(2.8, 0.3)
        if btn > 0 {
            var c = coal; c.w = btn
            for ly in [g.c2 - g.r2 * 0.3, g.c2 + g.r2 * 0.12, g.c1 - g.r1 * 0.4] {
                let (x, y) = P(0, ly)
                sprites.append(mkSprite(x, y, 1.3 * sc, 0, c, .disc))
            }
        }

        // Écharpe
        let scarf = prog(3.9, 0.3)
        if scarf > 0 {
            var c = red; c.w = scarf
            let (x, y) = P(0, g.c2 - g.r2 * 0.72)
            sprites.append(mkSprite(x, y, g.r2 * 0.82, rot, c, .rect, aspect: (2.4 * sc) / (g.r2 * 0.82)))
            let (tx, ty) = P(5 * sc, g.c2 - g.r2 * 0.72 + 4.5 * sc)
            sprites.append(mkSprite(tx, ty, 4.5 * sc, rot + Float.pi / 2 + 0.15, c, .rect, aspect: 0.42))
        }

        // Chapeau (tombe du ciel)
        let hat = prog(3.5, 0.4)
        if hat > 0 {
            let drop = (1 - hat) * 20 * sc
            var c = SIMD4<Float>(0.12, 0.12, 0.14, 1); c.w = hat
            var band = red; band.w = hat
            let brimY = g.c3 - g.r3 * 0.82 - drop
            let (bx, by) = P(0, brimY)
            sprites.append(mkSprite(bx, by, 9 * sc, rot, c, .rect, aspect: 1.1 / 9))
            let (cx, cy) = P(0, brimY - 6.5 * sc)
            sprites.append(mkSprite(cx, cy, 6.2 * sc, rot, c, .rect, aspect: 5.5 / 6.2))
            let (rx, ry) = P(0, brimY - 2.2 * sc)
            sprites.append(mkSprite(rx, ry, 6.25 * sc, rot, band, .rect, aspect: 1.1 / 6.25))
        }
    }

    #if FLOCON_TESTS
    struct Debug { let balls: [(r: Float, state: String, support: String)]; let snowmen: Int; let dockSnow: Float
                   let winSnow: [CGWindowID: Float]; let clumps: Int; let plowing: Bool }
    var debug: Debug {
        Debug(balls: snowballs.map { ($0.r, "\($0.state)@x\(Int($0.x))", $0.support.map { "\($0)" } ?? "-") },
              snowmen: snowmen.count, dockSnow: dock?.pile.total ?? -1,
              winSnow: piles.mapValues { $0.pile.total }, clumps: flakes.filter { $0.kind == 2 }.count,
              plowing: plow != nil)
    }
    var plowVisibleDebug: Bool { plow.map { !$0.waiting } ?? false }
    func debugFill(_ h: Float) {
        for wp in order where !wp.noSnow { for i in wp.pile.h.indices { wp.pile.h[i] = min(h, wp.pile.maxH) } }
    }
    #endif
}
