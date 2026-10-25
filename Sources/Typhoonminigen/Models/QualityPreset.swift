import Foundation
import Flux2Core
import FluxTextEncoders

// The original four 4B quality levels stay untouched. Klein 9B offers one
// low-memory preset: a pre-quantized native MLX Int4 transformer plus
// Qwen3-8B 4-bit. The 9B inference path never loads BF16 weights.

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
        case .standard: return "MLX Int4"
        }
    }
}

/// The concrete quant pair a (tier, quality) resolves to.
struct QualitySpec: Sendable {
    let transformer: TransformerQuantization   // .qint8 / .bf16 / .int4
    let encoder: MistralQuantization           // .mlx8bit / .mlx4bit (Qwen3)
}

extension ModelTier {
    /// Four 4B quality rungs; a single MLX Int4 rung for 9B.
    var qualityPresets: [QualityPreset] {
        switch self {
        case .klein4B: return [.low, .medium, .better, .best]
        case .klein9B: return [.standard]
        }
    }

    /// The 4B default is unchanged. 9B defaults to Int4 + 4-bit Qwen3.
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
        // Int4 9B uses a native pre-quantized transformer, never BF16.
        // Legacy 9B Best/unknown stored settings must never re-enable BF16.
        case (.klein9B, _):         return QualitySpec(transformer: .int4, encoder: .mlx4bit)
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
        let diff = s.transformer == .bf16 ? "Full (bf16)" : (s.transformer == .int4 ? "4-bit (MLX Int4)" : "8-bit (qint8)")
        return "\(name) · LLM: \(llm) · Diffuser: \(diff)"
    }
}
