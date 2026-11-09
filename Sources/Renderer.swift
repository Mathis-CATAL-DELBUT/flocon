import AppKit
import Metal
import QuartzCore

struct Uniforms {
    var viewSize: SIMD2<Float>
    var scale: Float
    var pad: Float = 0
}

/// Device, file et pipelines partagés par tous les écrans.
final class MetalContext {
    static let shared: MetalContext? = MetalContext()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let spritePSO: MTLRenderPipelineState
    let pilePSO: MTLRenderPipelineState

    private init?() {
        // Sur les Mac Intel à deux GPU, on reste sur le GPU intégré (batterie).
        let all = MTLCopyAllDevices()
        guard let dev = all.first(where: { $0.isLowPower }) ?? MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else { return nil }
        do {
            let lib = try dev.makeLibrary(source: shaderSource, options: nil)
            spritePSO = try MetalContext.pso(dev, lib, "sprite_vs", "sprite_fs")
            pilePSO = try MetalContext.pso(dev, lib, "pile_vs", "pile_fs")
        } catch {
            NSLog("Flocon: erreur Metal \(error)")
            return nil
        }
        device = dev
        queue = q
    }

    private static func pso(_ dev: MTLDevice, _ lib: MTLLibrary, _ vs: String, _ fs: String) throws -> MTLRenderPipelineState {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: vs)
        d.fragmentFunction = lib.makeFunction(name: fs)
        let ca = d.colorAttachments[0]!
        ca.pixelFormat = .bgra8Unorm
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .add
        ca.alphaBlendOperation = .add
        ca.sourceRGBBlendFactor = .one
        ca.sourceAlphaBlendFactor = .one
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try dev.makeRenderPipelineState(descriptor: d)
    }
}

/// Un renderer par écran. Deux tampons en rotation, aucune allocation par frame.
final class Renderer {
    private let ctx = MetalContext.shared!
    private let layer: CAMetalLayer
    private var spriteBufs: [MTLBuffer?] = [nil, nil]
    private var pileBufs: [MTLBuffer?] = [nil, nil]
    private var slot = 0
    private let inflight = DispatchSemaphore(value: 2)
    private var lastWasEmpty = false

    init(layer: CAMetalLayer) { self.layer = layer }

    private func ensure(_ buf: inout MTLBuffer?, _ bytes: Int) -> MTLBuffer? {
        if let b = buf, b.length >= bytes { return b }
        var cap = 64 * 1024
        while cap < bytes { cap *= 2 }
        buf = ctx.device.makeBuffer(length: cap, options: .storageModeShared)
        return buf
    }

    func draw(_ f: Snowfield, scale: Float) {
        let empty = f.sprites.isEmpty && f.pileVerts.isEmpty
        if empty && lastWasEmpty { return }
        // Si le GPU a du retard, on saute une frame plutôt que bloquer.
        guard inflight.wait(timeout: .now()) == .success else { return }
        guard let drawable = layer.nextDrawable() else { inflight.signal(); return }
        lastWasEmpty = empty
        slot = (slot + 1) % 2

        let sStride = MemoryLayout<Sprite>.stride, pStride = MemoryLayout<PileVert>.stride
        var sbuf: MTLBuffer?
        var pbuf: MTLBuffer?
        if !f.sprites.isEmpty, let b = ensure(&spriteBufs[slot], f.sprites.count * sStride) {
            f.sprites.withUnsafeBytes { src in b.contents().copyMemory(from: src.baseAddress!, byteCount: src.count) }
            sbuf = b
        }
        if !f.pileVerts.isEmpty, let b = ensure(&pileBufs[slot], f.pileVerts.count * pStride) {
            f.pileVerts.withUnsafeBytes { src in b.contents().copyMemory(from: src.baseAddress!, byteCount: src.count) }
            pbuf = b
        }

        guard let cb = ctx.queue.makeCommandBuffer() else { inflight.signal(); return }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { inflight.signal(); return }

        var u = Uniforms(viewSize: SIMD2(f.W, f.H), scale: scale)
        let uLen = MemoryLayout<Uniforms>.stride

        func drawPiles(_ start: Int, _ count: Int) {
            guard count > 0, let pb = pbuf else { return }
            enc.setRenderPipelineState(ctx.pilePSO)
            enc.setVertexBuffer(pb, offset: start * pStride, index: 0)
            enc.setVertexBytes(&u, length: uLen, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
        }
        func drawSprites(_ start: Int, _ count: Int) {
            guard count > 0, let sb = sbuf else { return }
            enc.setRenderPipelineState(ctx.spritePSO)
            enc.setVertexBuffer(sb, offset: start * sStride, index: 0)
            enc.setVertexBytes(&u, length: uLen, index: 1)
            enc.setFragmentBytes(&u, length: uLen, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: count)
        }

        // Ordre : neige des fenêtres, bonshommes, neige au sol (cache leur base), flocons devant.
        drawPiles(0, f.pileSplit)
        drawSprites(0, f.spriteSplit)
        drawPiles(f.pileSplit, f.pileVerts.count - f.pileSplit)
        drawSprites(f.spriteSplit, f.sprites.count - f.spriteSplit)
        enc.endEncoding()

        let sem = inflight
        cb.addCompletedHandler { _ in sem.signal() }
        cb.present(drawable)
        cb.commit()
    }
}

// MARK: - Shaders

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Sprite { float4 a; float4 color; float4 b; };
struct PileVert { float2 pos; float2 info; };
struct Uniforms { float2 viewSize; float scale; float pad; };

constant float2 corners[6] = { float2(-1,-1), float2(1,-1), float2(-1,1),
                               float2(1,-1),  float2(1,1),  float2(-1,1) };

static float4 toClip(float2 p, constant Uniforms& u) {
    return float4(p.x / u.viewSize.x * 2.0 - 1.0, 1.0 - p.y / u.viewSize.y * 2.0, 0.0, 1.0);
}

struct SpriteOut {
    float4 position [[position]];
    float2 local;
    float2 halfSize;
    float4 color;
    float type;
    float textured;
    float radius;
};

vertex SpriteOut sprite_vs(uint vid [[vertex_id]], uint iid [[instance_id]],
                           const device Sprite* sprites [[buffer(0)]],
                           constant Uniforms& u [[buffer(1)]]) {
    Sprite s = sprites[iid];
    float2 q = corners[vid];
    float2 hs = float2(s.a.z, s.a.z * s.b.y);
    float2 local = q * (hs + 1.5);
    float c = cos(s.a.w), sn = sin(s.a.w);
    float2 p = s.a.xy + float2(local.x * c - local.y * sn, local.x * sn + local.y * c);
    SpriteOut o;
    o.position = toClip(p, u);
    o.local = local;
    o.halfSize = hs;
    o.color = s.color;
    o.type = s.b.x;
    o.textured = s.b.z;
    o.radius = s.b.w;
    return o;
}

fragment float4 sprite_fs(SpriteOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    int t = int(in.type + 0.5);
    float2 p = in.local;
    float2 hs = in.halfSize;
    float px = 1.0 / u.scale;
    float a = 0.0;
    float3 col = in.color.rgb;

    if (t == 0) {                       // flocon doux, liseré gris pour rester visible sur fond blanc
        float d = length(p) / max(hs.x, 0.5);
        a = 1.0 - smoothstep(0.55, 1.0, d);
        col = mix(col, float3(0.52, 0.58, 0.70), smoothstep(0.5, 0.95, d));
    } else if (t == 1 || t == 5) {      // boule de neige ombrée / disque plein
        float r = length(p);
        a = clamp((hs.x - r) / px + 0.5, 0.0, 1.0);
        if (t == 1) {
            float2 n = p / hs.x;
            float z = sqrt(max(0.0, 1.0 - dot(n, n)));
            float3 N = float3(n, z);
            float3 L = normalize(float3(-0.45, -0.65, 0.62));
            float diff = clamp(dot(N, L), 0.0, 1.0);
            col = mix(float3(0.66, 0.73, 0.85), float3(1.0), 0.30 + 0.70 * diff);
            col = mix(col, float3(0.60, 0.67, 0.80), smoothstep(0.82, 1.0, length(n)) * 0.6);
            if (in.textured > 0.5) {
                // Grain de neige tassée : petites taches qui tournent avec la boule.
                float cell = max(hs.x * 0.28, 2.0);
                float2 g = floor(p / cell);
                float2 f = fract(p / cell) - 0.5;
                float n1 = fract(sin(dot(g, float2(12.9898, 78.233))) * 43758.5453);
                float n2 = fract(sin(dot(g, float2(39.346, 11.135))) * 24634.6345);
                float2 o = (float2(n1, n2) - 0.5) * 0.5;
                float spot = 1.0 - smoothstep(0.12, 0.30, length(f - o));
                col *= 1.0 - spot * step(0.55, n1) * 0.07;
            }
        }
    } else if (t == 2) {                // rectangle (coins arrondis optionnels)
        float rr = min(in.radius, min(hs.x, hs.y));
        float2 d = abs(p) - hs + rr;
        float dist = length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - rr;
        a = clamp(0.5 - dist / px, 0.0, 1.0);
    } else if (t == 3) {                // triangle (carotte), pointe vers +x
        float k = clamp((p.x + hs.x) / (2.0 * hs.x), 0.0, 1.0);
        float halfH = hs.y * (1.0 - k);
        float dist = max(abs(p.y) - halfH, abs(p.x) - hs.x);
        a = clamp(0.5 - dist / px, 0.0, 1.0);
        col *= 0.85 + 0.15 * step(0.0, -p.y);
    } else if (t == 4) {                // cristal à 6 branches
        float len = length(p);
        float ang = atan2(p.y, p.x);
        const float sector = M_PI_F / 3.0;
        ang -= sector * round(ang / sector);
        float2 q = float2(cos(ang), sin(ang)) * len;
        float w = 0.08 * hs.x + 0.45 * px;
        float arm = max(abs(q.y) - w, q.x - hs.x);
        float2 b = q - float2(0.55 * hs.x, 0.0);
        b.y = abs(b.y);
        float2 dir = float2(0.5, 0.8660254);
        float tt = clamp(dot(b, dir), 0.0, 0.32 * hs.x);
        float branch = length(b - dir * tt) - w;
        float center = len - 0.16 * hs.x;
        float dist = min(min(arm, branch), center);
        a = clamp(0.5 - dist / px, 0.0, 1.0);
        a = max(a, (1.0 - smoothstep(0.0, 1.0, len / hs.x)) * 0.18);
        col = mix(float3(0.80, 0.86, 0.95), col, a);
    } else if (t == 6) {                // halo (gyrophare)
        float d = clamp(length(p) / max(hs.x, 0.5), 0.0, 1.0);
        a = (1.0 - d) * (1.0 - d);
    }
    a *= in.color.a;
    return float4(col * a, a);
}

struct PileOut { float4 position [[position]]; float2 info; };

vertex PileOut pile_vs(uint vid [[vertex_id]], const device PileVert* v [[buffer(0)]],
                       constant Uniforms& u [[buffer(1)]]) {
    PileOut o;
    o.position = toClip(v[vid].pos, u);
    o.info = v[vid].info;
    return o;
}

fragment float4 pile_fs(PileOut in [[stage_in]]) {
    float3 col = mix(float3(1.0), float3(0.70, 0.77, 0.88), in.info.x);
    float a = in.info.y;
    return float4(col * a, a);
}
"""
