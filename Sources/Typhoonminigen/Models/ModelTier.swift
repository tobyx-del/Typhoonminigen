import Foundation
import Flux2Core
import FluxTextEncoders

/// The inference models the app ships: **FLUX.2 Klein 4B** (light tier for 16–24 GB Macs,
/// Apache 2.0, tokenless) and **FLUX.2 Klein 9B** (quality ceiling, 32 GB+, gated).
/// Thin bridge over `Flux2Model`.
///
/// Kept as an enum so the model identity keeps flowing unchanged through the gallery
/// records, model manager and LoRA matching. The engine supports other variants (Dev),
/// but the app deliberately exposes only the two Klein tiers — Dev would make Mistral 24B
/// the text encoder, which cannot fit alongside generation on consumer RAM.
enum ModelTier: String, CaseIterable, Identifiable, Sendable, Codable {
    case klein4B
    case klein9B

    var id: String { rawValue }

    /// The underlying engine model variant.
    var flux2Model: Flux2Model {
        switch self {
        case .klein4B: return .klein4B
        case .klein9B: return .klein9B
        }
    }

    var displayName: String { flux2Model.displayName }

    /// Short label for chips / pickers / status bar ("Klein 4B").
    var shortName: String {
        switch self {
        case .klein4B: return "Klein 4B"
        case .klein9B: return "Klein 9B"
        }
    }

    var license: String { flux2Model.license }

    /// Klein defaults: 4 steps, guidance 1.0 (NOT the engine's Dev-oriented 50/4.0 init defaults).
    var defaultSteps: Int { flux2Model.defaultSteps }
    var defaultGuidance: Float { flux2Model.defaultGuidance }

    /// The downloadable transformer variant. 4B uses the pre-quantized 8-bit repo
    /// (aydin99/FLUX.2-klein-4B-int8, ~4 GB, tokenless); 9B downloads bf16 (~17 GB, gated)
    /// and quantizes to qint8 on load.
    var transformerVariant: ModelRegistry.TransformerVariant {
        switch self {
        case .klein4B: return .klein4B_8bit
        case .klein9B: return .klein9B_bf16
        }
    }

    /// Whether downloading needs an HF token (9B is gated; 4B is Apache, tokenless).
    var isGated: Bool { transformerVariant.isGated }

    /// Verifies a Qwen3 encoder is FULLY on disk at {models}/lmstudio-community/{name}. Mirrors the
    /// engine's findQwen3ModelPath location AND its shard verification: config.json alone is NOT
    /// proof — an interrupted download leaves config without weights (seen live 2026-06-10), and the
    /// engine would then lazy-fetch GBs silently.
    private static func qwenEncoderPresent(_ name: String) -> Bool {
        let fm = FileManager.default
        let dir = AppPaths.models.appendingPathComponent("lmstudio-community/\(name)", isDirectory: true)
        guard fm.fileExists(atPath: dir.appendingPathComponent("config.json").path) else { return false }
        if let data = try? Data(contentsOf: dir.appendingPathComponent("model.safetensors.index.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let map = obj["weight_map"] as? [String: String] {
            let shards = Set(map.values)
            return !shards.isEmpty && shards.allSatisfy {
                fm.fileExists(atPath: dir.appendingPathComponent($0).path)
            }
        }
        return fm.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path)
    }

    /// Per-variant on-disk status of this tier's two Qwen3 encoders (8-bit, 4-bit). The engine
    /// loads whichever is present, PREFERRING 8-bit — so when both are on disk the encoder-only
    /// quality rungs (Klein 9B Standard vs Best) resolve to the SAME render. Drives the honest 9B
    /// note on the Generate panel.
    var encodersOnDisk: (eightBit: Bool, fourBit: Bool) {
        let names = self == .klein4B ? ("Qwen3-4B-MLX-8bit", "Qwen3-4B-MLX-4bit")
                                     : ("Qwen3-8B-MLX-8bit", "Qwen3-8B-MLX-4bit")
        return (Self.qwenEncoderPresent(names.0), Self.qwenEncoderPresent(names.1))
    }

    /// True when SOME usable Qwen3 encoder for this tier is on disk (the engine accepts 8-bit or 4-bit).
    var isEncoderDownloaded: Bool {
        let e = encodersOnDisk
        return e.eightBit || e.fourBit
    }
}
