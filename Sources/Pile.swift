import Foundation

/// Tas de neige 1D : une hauteur par colonne de 2 pt.
final class Pile {
    static let binW: Float = 2

    var h: [Float]
    let maxH: Float
    /// Nombre de frames pendant lesquelles le tas doit encore se tasser.
    var awake = 0
    private var flip = false

    init(width: Float, maxH: Float) {
        self.maxH = maxH
        h = [Float](repeating: 0, count: Pile.bins(for: width))
    }

    static func bins(for width: Float) -> Int { max(2, Int((width / binW).rounded(.up))) }

    var count: Int { h.count }
    var total: Float { h.reduce(0, +) }

    func clear() { for i in h.indices { h[i] = 0 } }

    func resize(width: Float) {
        let n = Pile.bins(for: width)
        guard n != h.count else { return }
        var nh = [Float](repeating: 0, count: n)
        let ratio = Float(h.count) / Float(n)
        for i in 0..<n { nh[i] = h[min(h.count - 1, Int(Float(i) * ratio))] }
        h = nh
        awake = 60
    }

    @inline(__always) func height(at x: Float) -> Float {
        guard x >= 0 else { return 0 }
        let i = Int(x / Pile.binW)
        return i < h.count ? h[i] : 0
    }

    private static let kernel: [Float] = [0.05, 0.12, 0.2, 0.26, 0.2, 0.12, 0.05]

    func add(at x: Float, mass: Float) {
        let c = Int(x / Pile.binW)
        guard c >= 0, c < h.count else { return }
        for k in 0..<7 {
            let i = c + k - 3
            if i >= 0 && i < h.count { h[i] = min(maxH, h[i] + mass * Pile.kernel[k]) }
        }
        awake = 90
    }

    /// Fait glisser la neige là où la pente est trop forte (modèle « tas de sable »).
    /// `base` = décalage vertical du support (coins arrondis des fenêtres).
    /// Renvoie la neige qui déborde à gauche / à droite.
    func relax(base: [Float], maxSlope s: Float, edgeMax: Float) -> (left: Float, right: Float) {
        guard awake > 0, h.count >= 2, base.count == h.count else { return (0, 0) }
        awake -= 1
        let n = h.count
        flip.toggle()
        var i = flip ? 0 : n - 2
        let dir = flip ? 1 : -1
        for _ in 0..<(n - 1) {
            let j = i + 1
            let d = (h[i] - base[i]) - (h[j] - base[j])
            if d > s {
                let m = min((d - s) * 0.5, h[i]); h[i] -= m; h[j] += m
            } else if d < -s {
                let m = min((-d - s) * 0.5, h[j]); h[j] -= m; h[i] += m
            } else if d > 0 {
                // Légère diffusion : arrondit les bosses (pas de dents de scie).
                let m = min(d * 0.06, h[i]); h[i] -= m; h[j] += m
            } else {
                let m = min(-d * 0.06, h[j]); h[j] -= m; h[i] += m
            }
            i += dir
        }
        var l: Float = 0, r: Float = 0
        if h[0] > edgeMax { l = h[0] - edgeMax; h[0] = edgeMax }
        if h[n - 1] > edgeMax { r = h[n - 1] - edgeMax; h[n - 1] = edgeMax }
        return (l, r)
    }
}
