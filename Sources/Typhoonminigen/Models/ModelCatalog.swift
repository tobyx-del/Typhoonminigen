import Foundation
import Flux2Core
import FluxTextEncoders

// ============================================================
//  Models tab catalog — component-level, grouped like Fluxforge.
//
//  Each row the Models tab shows is a REAL engine variant with a real
//  HuggingFace repo (see ModelRegistry.TransformerVariant / Qwen3Variant),
//  so every Download button performs an actual download — no placeholders.
// ============================================================

/// One downloadable weight: a Flux.2 transformer variant or a Qwen3 text-encoder variant.
enum ComponentKind: Hashable, Sendable {
    case transformer(ModelRegistry.TransformerVariant)
    case encoder(Qwen3Variant)
}

/// View-friendly description of one component row (with live on-disk status).
struct ComponentInfo: Identifiable, Sendable {
    let id: String              // stable per variant — the "currently downloading" key
    let kind: ComponentKind
    let title: String           // "Full Precision (bf16)" / "Qwen3 4B (8-bit)"
    let rawTag: String          // "klein4b-bf16" / "qwen3-4b-8bit"
    let sizeGB: Int
    let isGated: Bool
    let repoURL: String
    let isDownloaded: Bool
    let downloadedBytes: Int64
}

/// One tier card: a transformer sub-group + a text-encoder sub-group, rendered collapsible.
struct ModelGroupInfo: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let ramBadge: String
    let nonCommercial: Bool
    let encoderHeader: String   // "Qwen3 4B" / "Qwen3 8B"
    let transformers: [ComponentInfo]
    let encoders: [ComponentInfo]

    var allComponents: [ComponentInfo] { transformers + encoders }
    var total: Int { allComponents.count }
    var downloaded: Int { allComponents.filter(\.isDownloaded).count }
}

/// Static declaration of which variants belong in which group. The store turns each spec
/// into a `ModelGroupInfo` with live on-disk status.
struct ModelGroupSpec: Sendable {
    let id: String
    let title: String
    let subtitle: String
    let ramBadge: String
    let nonCommercial: Bool
    let encoderHeader: String
    let transformers: [ModelRegistry.TransformerVariant]
    let encoders: [Qwen3Variant]
}

enum ModelCatalog {
    /// Inference models (Text-to-Image). Component counts match Fluxforge: 4B = 4, 9B = 3.
    static let imageGeneration: [ModelGroupSpec] = [
        ModelGroupSpec(
            id: "klein4b",
            title: "Flux Klein (4B)",
            subtitle: "Lightweight model, requires ~8 GB RAM",
            ramBadge: "8 GB",
            nonCommercial: false,
            encoderHeader: "Qwen3 4B",
            // Both 4B transformers: 8-bit (qint8, 4 GB, the Low/Medium default) and Full bf16
            // (8 GB, Apache/tokenless) — the latter is what the Quality preset's Better/Best
            // rungs feed to the pipeline (transformer .bf16 → klein4B_bf16). bf16 is no longer
            // dead weight now that QualityPreset actually selects it.
            transformers: [.klein4B_8bit, .klein4B_bf16],
            encoders: [.qwen3_4B_8bit, .qwen3_4B_4bit]
        ),
        ModelGroupSpec(
            id: "klein9b",
            title: "Flux Klein (9B)",
            // LIVE-MEASURED generation footprint, not the engine's optimistic estimate: 9B
            // peaks at ~19–20 GB while generating, which needs a 32 GB Mac in practice
            // (macOS + the app + encoder headroom) — "16 GB" undersold it badly.
            subtitle: "Quality model, ~19–20 GB RAM while generating",
            ramBadge: "32 GB Mac",
            nonCommercial: true,
            encoderHeader: "Qwen3 8B",
            transformers: [.klein9B_bf16],
            encoders: [.qwen3_8B_8bit, .qwen3_8B_4bit]
        ),
    ]

    /// Base (non-distilled) weights LoRA training needs — a download manager for the Training tab.
    /// RAM badges = LIVE-MEASURED training peaks (2026-07-02), NOT the engine's optimistic
    /// estimates: 4B trains at ~22 GB (verified on a 32 GB M4); 9B demands ~34 GB and FROZE a
    /// 32 GB machine — it needs a 48 GB+ Mac. Do not soften these numbers.
    static let loraTraining: [ModelGroupSpec] = [
        ModelGroupSpec(
            id: "klein4b-base",
            title: "Klein 4B Base",
            subtitle: "Non-distilled base + its text encoder — what a LoRA trains on.",
            ramBadge: "trains at ~22 GB · 32 GB Mac OK",
            nonCommercial: false,
            encoderHeader: "Qwen3 4B",
            transformers: [.klein4B_base_bf16],
            encoders: [.qwen3_4B_4bit]
        ),
        ModelGroupSpec(
            id: "klein9b-base",
            title: "Klein 9B Base",
            subtitle: "Non-distilled base + its text encoder — what a LoRA trains on.",
            ramBadge: "trains at ~34 GB · needs 48 GB+ Mac",
            nonCommercial: true,
            encoderHeader: "Qwen3 8B",
            transformers: [.klein9B_base_bf16],
            encoders: [.qwen3_8B_4bit]
        ),
    ]

    /// Display title for a transformer variant row.
    static func title(for v: ModelRegistry.TransformerVariant) -> String {
        switch v {
        case .bf16, .klein4B_bf16, .klein9B_bf16:        return "Full Precision (bf16)"
        case .qint8, .klein4B_8bit:                      return "8-bit (qint8)"
        case .klein4B_base_bf16, .klein9B_base_bf16:     return "Non-distilled (bf16)"
        case .klein9B_kv_bf16:                           return "KV cache (bf16)"
        }
    }
}
