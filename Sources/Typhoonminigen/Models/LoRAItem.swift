import Foundation

/// A LoRA adapter file on disk + the result of inspecting its safetensors header.
struct LoRAItem: Identifiable, Sendable, Hashable {
    let id: String          // fileName
    let fileName: String
    let url: URL
    let tier: ModelTier?    // detected target tier; nil = incompatible / unknown
    let note: String        // human-readable detection result
    var trigger: String     // activation keyword; "" if none (auto-added to prompt at generation)
    /// User-saved sweet-spot strength (e.g. 0.8 for an adapter that mutates at 1.0). Applied when
    /// the adapter is MANUALLY added in Generate; recipe/remix restores keep their recorded scale.
    var defaultScale: Float? = nil
    /// Free-text description ("my product shots, photoreal, pairs well with studio prompts"); "" if none.
    var about: String = ""
    /// When the adapter entered the library (sidecar-recorded; FS creation date as fallback).
    var addedAt: Date? = nil
    /// Where it came from ("Hugging Face: user/repo", "Baked ×0.80 from …", publish heuristic…).
    var provenance: String? = nil

    var isCompatible: Bool { tier != nil }
}

/// Per-adapter identity card persisted in the `.cards.json` sidecar (same pattern as the
/// `.triggers.json` / `.default-scales.json` sidecars: keyed by fileName, self-healed on
/// discover, pruned on delete/replace so a re-imported different adapter never inherits it).
struct LoRACardInfo: Codable, Sendable, Hashable {
    var about: String? = nil
    var addedAt: Date? = nil
    var provenance: String? = nil
    var sourceRunID: String? = nil   // training-run linkage for published adapters (future jump-link)

    var isEmpty: Bool {
        (about?.isEmpty ?? true) && addedAt == nil
            && (provenance?.isEmpty ?? true) && (sourceRunID?.isEmpty ?? true)
    }
}

/// One LoRA applied to a generation. The engine fuses adapters sequentially and their
/// weight deltas SUM with no count cap, so any number can be combined; each carries its own scale.
/// Codable because gallery records persist the applied set (path is informational —
/// like referenceImagePaths, it may go stale if the file is later deleted).
struct LoRAUse: Sendable, Hashable, Codable {
    let path: String
    let name: String
    let scale: Float
}
