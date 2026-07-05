import Foundation
import Flux2Core
import FluxTextEncoders

// ============================================================
//  Render-quality presets — the Fluxforge "Quality" dropdown.
//
//  Quality = an (encoder-quant × transformer-quant) combination. Klein 4B exposes FOUR
//  rungs (Low/Medium/Better/Best); Klein 9B exposes TWO (Standard/Best) because its
//  transformer ships only as one bf16 repo.
//
//  ⚠ Honesty note: the TRANSFORMER quant (qint8 ↔ bf16) is the load-bearing axis — the
//  engine honours it deterministically (loads the pre-quantized 4B-8bit repo, or quantizes
//  the bf16 weights on the fly). The ENCODER quant (Qwen3 8-bit ↔ 4-bit) is the softer
//  rung: the engine prefers whichever Qwen3 variant is already on disk, so it only takes
//  effect when that level's encoder is the one present. The two transformer-distinct rungs
//  per tier are therefore always real; the encoder split adds the extra 4B granularity.
// ============================================================

enum QualityPreset: String, CaseIterable, Identifiable, Sendable, Codable {
    case low, medium, better, best     // Klein 4B ladder
    case standard                      // Klein 9B lower rung

    var id: String { rawValue }

    var label: String {
        switch self {
        case .low:      return "Low"
        case .medium:   return "Medium"
        case .better:   return "Better"
        case .best:     return "Best"
        case .standard: return "Standard"
        }
    }
}

/// The concrete quant pair a (tier, quality) resolves to.
struct QualitySpec: Sendable {
    let transformer: TransformerQuantization   // .qint8 (lighter) / .bf16 (full precision)
    let encoder: MistralQuantization           // .mlx8bit / .mlx4bit (Qwen3)
}

extension ModelTier {
    /// Quality rungs this tier offers (Fluxforge parity: 4B = 4, 9B = 2).
    var qualityPresets: [QualityPreset] {
        switch self {
        case .klein4B: return [.low, .medium, .better, .best]
        case .klein9B: return [.standard, .best]
        }
    }

    /// Default rung per tier: 4B = Medium (qint8 transformer + 8-bit encoder); 9B = Standard
    /// (Full bf16 transformer — 9B ships only bf16 — + 4-bit encoder).
    var defaultQuality: QualityPreset {
        switch self {
        case .klein4B: return .medium
        case .klein9B: return .standard
        }
    }

    /// The quant pair for a (tier, quality). Unsupported combos fall back to the safe default.
    func qualitySpec(for q: QualityPreset) -> QualitySpec {
        switch (self, q) {
        case (.klein4B, .low):      return QualitySpec(transformer: .qint8, encoder: .mlx4bit)
        case (.klein4B, .medium):   return QualitySpec(transformer: .qint8, encoder: .mlx8bit)
        case (.klein4B, .better):   return QualitySpec(transformer: .bf16,  encoder: .mlx4bit)
        case (.klein4B, .best):     return QualitySpec(transformer: .bf16,  encoder: .mlx8bit)
        // 9B (Fluxforge parity): both rungs run the Full bf16 transformer (9B ships only bf16);
        // the rung is the encoder bit-depth (Standard 4-bit → Best 8-bit), so the LLM changes.
        case (.klein9B, .standard): return QualitySpec(transformer: .bf16, encoder: .mlx4bit)
        case (.klein9B, .best):     return QualitySpec(transformer: .bf16, encoder: .mlx8bit)
        default:                    return QualitySpec(transformer: .qint8, encoder: .mlx8bit)
        }
    }

    /// The quant config fed to the pipeline for this quality.
    func quantConfig(for q: QualityPreset) -> Flux2QuantizationConfig {
        let s = qualitySpec(for: q)
        return Flux2QuantizationConfig(textEncoder: s.encoder, transformer: s.transformer)
    }

    /// The downloadable transformer file this quality resolves to (download/status gating).
    func transformerVariant(for q: QualityPreset) -> ModelRegistry.TransformerVariant {
        ModelRegistry.TransformerVariant.variant(for: flux2Model, quantization: qualitySpec(for: q).transformer)
    }

    /// The Qwen3 encoder variant this quality prefers (for the "needs download" hint / sub-line).
    func encoderVariant(for q: QualityPreset) -> Qwen3Variant {
        switch (self, qualitySpec(for: q).encoder) {
        case (.klein4B, .mlx4bit): return .qwen3_4B_4bit
        case (.klein4B, _):        return .qwen3_4B_8bit
        case (.klein9B, .mlx4bit): return .qwen3_8B_4bit
        case (.klein9B, _):        return .qwen3_8B_8bit
        }
    }

    /// Human sub-line like "Qwen3 4B · LLM: 8-bit · Diffuser: 8-bit (qint8)" (mirrors Fluxforge).
    func qualitySummary(for q: QualityPreset) -> String {
        let s = qualitySpec(for: q)
        let name = self == .klein4B ? "Qwen3 4B" : "Qwen3 8B"
        let llm = s.encoder == .mlx4bit ? "4-bit" : "8-bit"
        let diff = s.transformer == .bf16 ? "Full (bf16)" : "8-bit (qint8)"
        return "\(name) · LLM: \(llm) · Diffuser: \(diff)"
    }
}
