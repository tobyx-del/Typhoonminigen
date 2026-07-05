import Foundation
import MLX

/// Result of reading a LoRA's safetensors header (no tensor data loaded).
struct LoRAInspection: Sendable {
    let tier: ModelTier?
    let note: String
    let trigger: String?   // auto-detected from metadata, if the file stored one
}

/// Readable failures from the bake / merge weight editing below.
enum LoRAEditError: LocalizedError {
    case notALoRA(String)
    case keyLayoutMismatch
    case shapeMismatch(String)
    case nothingToMerge

    var errorDescription: String? {
        switch self {
        case .notALoRA(let f):
            return "\(f) has no lora_B weight tensors — not a standard LoRA."
        case .keyLayoutMismatch:
            return "These adapters use different key layouts (BFL vs diffusers naming) — they can't be aligned layer-for-layer. Merge like-formatted adapters only."
        case .shapeMismatch(let layer):
            return "Tensor shapes differ at \(layer) — the adapters don't target the same architecture."
        case .nothingToMerge:
            return "No LoRA weight pairs were found to merge."
        }
    }
}

/// Reads a `.safetensors` JSON header (8-byte little-endian length + JSON) WITHOUT loading
/// tensor data, classifies the Klein tier, and tries to read a trigger keyword.
enum SafetensorsInspector {
    static func inspect(at url: URL) -> LoRAInspection {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return LoRAInspection(tier: nil, note: "couldn't open file", trigger: nil)
        }
        defer { try? handle.close() }

        guard let lenData = try? handle.read(upToCount: 8), lenData.count == 8 else {
            return LoRAInspection(tier: nil, note: "corrupt header", trigger: nil)
        }
        let headerLen = lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        guard headerLen > 0, headerLen < 50_000_000 else {
            return LoRAInspection(tier: nil, note: "invalid header", trigger: nil)
        }
        guard let headerData = try? handle.read(upToCount: Int(headerLen)),
              headerData.count == Int(headerLen) else {
            return LoRAInspection(tier: nil, note: "couldn't parse header", trigger: nil)
        }
        return inspect(headerData: headerData)
    }

    /// Classify from raw safetensors header JSON bytes — same gate as `inspect(at:)`, but the
    /// header can come from anywhere (the URL importer range-fetches just the header so a
    /// wrong-architecture file is rejected BEFORE the multi-hundred-MB download).
    static func inspect(headerData: Data) -> LoRAInspection {
        guard let json = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any] else {
            return LoRAInspection(tier: nil, note: "couldn't parse header", trigger: nil)
        }
        var (tier, note) = classify(json)
        // Cross-check the ecosystem tier tag (ai-toolkit writes ss_base_model_version =
        // "flux2_klein_4b"/"flux2_klein_9b"). The block scan stays authoritative; a mismatch
        // is surfaced in the note so a mislabeled file isn't trusted silently.
        if let metaTier = metadataTier(json), let scanned = tier, metaTier != scanned {
            note += " — but its metadata claims \(metaTier.shortName)"
        }
        return LoRAInspection(tier: tier, note: note, trigger: readTrigger(json))
    }

    /// Tier recorded in the file's own metadata (ai-toolkit arch names), if any.
    private static func metadataTier(_ json: [String: Any]) -> ModelTier? {
        guard let meta = json["__metadata__"] as? [String: Any],
              let v = (meta["ss_base_model_version"] as? String)?.lowercased() else { return nil }
        if v.contains("klein_9b") || v.contains("klein-9b") { return .klein9B }
        if v.contains("klein_4b") || v.contains("klein-4b") { return .klein4B }
        return nil
    }

    /// PRIMARY: classify by the MAX block index across double/single stream blocks. Handles BFL
    /// (`double_blocks`/`single_blocks`) and Diffusers (`transformer_blocks`/`single_transformer_blocks`)
    /// naming with any prefix (e.g. `diffusion_model.`). Block counts identify the exact architecture
    /// (4B = 5/20, 9B = 8/24; Dev/FLUX.1 rejected) — the inner dim alone CANNOT, since FLUX.1 and
    /// Klein 4B can both be 3072. Both audits (Codex + Sonnet) independently recommended this.
    private static func classify(_ json: [String: Any]) -> (ModelTier?, String) {
        // Engine-loadability gate FIRST: the engine's LoRALoader parses ONLY diffusers
        // `.lora_A.weight` / `.lora_B.weight` keys and silently skips everything else —
        // a kohya/sd-scripts file (lora_down/lora_up, the dominant Civitai naming) would
        // merge as a NO-OP, so any "compatible" badge for it is a lie. FLUX.1 kohya files
        // also dodge the block scan (underscore separators) and land on dim 3072 ＝ Klein 4B,
        // which is exactly the false-accept this gate prevents.
        let keys = json.keys.filter { $0 != "__metadata__" }
        if !keys.contains(where: { $0.contains(".lora_A.") || $0.contains(".lora_B.") }) {
            // LyCORIS variants store a different math (LoKr = Kronecker w1⊗w2, LoHa = Hadamard),
            // not the A·B low-rank the engine merges — name them so the rejection is understandable.
            if keys.contains(where: { $0.contains("lokr_") }) {
                return (nil, "LoKr / LyCORIS adapter — this app loads standard LoRA only")
            }
            if keys.contains(where: { $0.contains("hada_") }) {
                return (nil, "LoHa / LyCORIS adapter — this app loads standard LoRA only")
            }
            if keys.contains(where: { $0.contains("lora_down") || $0.contains("lora_up") }) {
                return (nil, "kohya-format LoRA — the engine needs diffusers lora_A/lora_B naming")
            }
            return (nil, "no lora_A/lora_B tensors — not a diffusers-format LoRA")
        }
        var maxDouble = -1, maxSingle = -1
        for key in json.keys where key != "__metadata__" {
            // single first (its name contains "transformer_blocks" too — avoid miscount)
            if let n = blockIndex(key, "single_blocks.") ?? blockIndex(key, "single_transformer_blocks.") {
                maxSingle = max(maxSingle, n)
            } else if let n = blockIndex(key, "double_blocks.") ?? blockIndex(key, "transformer_blocks.") {
                maxDouble = max(maxDouble, n)
            }
        }
        switch (maxDouble, maxSingle) {
        case (4, 19): return (.klein4B, "Klein 4B (5 double / 20 single)")
        case (7, 23): return (.klein9B, "Klein 9B (8 double / 24 single)")
        case (7, 47): return (nil, "FLUX.2 Dev — not supported")
        default:
            // No EXACT block match. A LoRA that only trains a SUBSET of blocks (attention-only,
            // first-N layers — common on Civitai/HF) never reaches the last block, so its max is
            // below (7,23)/(4,19) and the old code wrongly rejected it as "incompatible". The inner
            // dim is architecture-defining and reliable even for partial LoRAs: dim 4096 is
            // UNAMBIGUOUS (FLUX.1 never uses it) → accept 9B outright. dim 3072 is shared with
            // FLUX.1, so still require the block counts to stay within Klein 4B's range
            // (≤4 double / ≤19 single); a higher count means FLUX.1's larger transformer.
            let (dimTier, dimNote) = classifyByDim(json)
            if dimTier == .klein9B { return (.klein9B, dimNote) }
            if dimTier == .klein4B, maxDouble <= 4, maxSingle <= 19 { return (.klein4B, dimNote) }
            if maxDouble < 0, maxSingle < 0 { return (dimTier, dimNote) }   // unusual naming: trust the dim verdict
            return (nil, "incompatible (blocks \(maxDouble)/\(maxSingle)) — likely FLUX.1 / another model")
        }
    }

    private static func blockIndex(_ key: String, _ marker: String) -> Int? {
        guard let r = key.range(of: marker) else { return nil }
        return Int(key[r.upperBound...].prefix(while: { $0.isNumber }))
    }

    /// Fallback: dominant inner dim of lora_A tensors (4B=3072, 9B=4096, Dev=6144).
    private static func classifyByDim(_ json: [String: Any]) -> (ModelTier?, String) {
        var dims: [Int: Int] = [:]
        for (key, value) in json {
            guard key != "__metadata__",
                  key.contains("lora_A") || key.contains("lora_down"),
                  let obj = value as? [String: Any],
                  let shape = obj["shape"] as? [NSNumber], !shape.isEmpty else { continue }
            dims[shape.map { $0.intValue }.max() ?? 0, default: 0] += 1
        }
        switch dims.max(by: { $0.value < $1.value })?.key ?? 0 {
        case 4096: return (.klein9B, "Klein 9B (dim 4096)")
        case 3072: return (.klein4B, "Klein 4B (dim 3072)")
        case 6144, 15360: return (nil, "FLUX.2 Dev — not supported")
        default: return (nil, "doesn't look like a FLUX.2 Klein LoRA")
        }
    }

    private static func readTrigger(_ json: [String: Any]) -> String? {
        guard let meta = json["__metadata__"] as? [String: Any] else { return nil }
        for k in ["modelspec.trigger_phrase", "activation_text", "trigger_words",
                  "ss_trigger_words", "trigger", "instance_prompt"] {
            if let v = meta[k] as? String {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                // Cap untrusted metadata: this string is auto-appended to the generation prompt.
                if !t.isEmpty, t.lowercased() != "none", t != "[]" { return String(t.prefix(200)) }
            }
        }
        // ai-toolkit / kohya store it inside ss_tag_frequency — a JSON STRING (safetensors
        // metadata values must be strings) of {"1_<trigger>": {"<trigger>": count, …}} where
        // the outer key carries a kohya-style "N_" repeat prefix. Strip the prefix.
        if let raw = meta["ss_tag_frequency"] as? String,
           let data = raw.data(using: .utf8),
           let freq = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let outer = freq.keys.sorted().first {
            var name = outer
            if let r = name.range(of: "^\\d+_", options: .regularExpression) {
                name = String(name[r.upperBound...])
            }
            let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, t.lowercased() != "none" { return String(t.prefix(200)) }
        }
        return nil
    }

    // MARK: - Metadata write (publish round-trip)

    /// Copy a `.safetensors` file while MERGING extra string keys into its `__metadata__`, so a
    /// LoRA published from the in-app trainer carries its trigger + tier in the same ecosystem
    /// keys ai-toolkit/kohya use — outside this app too (ComfyUI, auto1111, another Mac).
    /// Existing keys (incl. the engine-consumed lora_alpha/lora_rank) are preserved; `extra` wins
    /// on collision. Tensor data is streamed through untouched — offsets stay valid because they
    /// are relative to the data section, not the file start.
    static func copyAddingMetadata(from src: URL, to dest: URL, extra: [String: String]) throws {
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        guard let lenData = try input.read(upToCount: 8), lenData.count == 8 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let headerLen = lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        guard headerLen > 0, headerLen < 50_000_000,
              let headerData = try input.read(upToCount: Int(headerLen)), headerData.count == Int(headerLen),
              var json = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Coerce PER KEY, not the whole dict: `as? [String: String]` returns nil the moment a
        // single value is non-string (tools do write numbers/bools/objects into __metadata__
        // despite the spec saying strings-only), which silently dropped EVERY existing key —
        // including the engine-consumed lora_alpha/lora_rank — from the published copy.
        // Keeping whatever IS a string preserves them; non-string oddballs are the only loss.
        var meta = ((json["__metadata__"] as? [String: Any]) ?? [:]).compactMapValues { $0 as? String }
        for (k, v) in extra { meta[k] = v }
        json["__metadata__"] = meta
        let newHeader = try JSONSerialization.data(withJSONObject: json)

        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let output = try FileHandle(forWritingTo: dest)
        defer { try? output.close() }
        var newLen = UInt64(newHeader.count).littleEndian
        try output.write(contentsOf: Data(bytes: &newLen, count: 8))
        try output.write(contentsOf: newHeader)
        while let chunk = try input.read(upToCount: 8 << 20), !chunk.isEmpty {   // 8 MB chunks
            try output.write(contentsOf: chunk)
        }
    }

    // MARK: - Weight editing (bake / merge)

    // Pure tensor math on MB-scale adapter files via MLX (CPU stream — the GPU and any loaded
    // model stay untouched). Both operations write a NEW file and never modify the source.
    //
    // Math: the engine's LoRALoader applies deltaW = strength × (lora_alpha/lora_rank) × B·A,
    // reading alpha/rank from the file's __metadata__ (ratio defaults to 1 when absent). Every
    // edit here FOLDS the user strength AND the source's alpha/rank ratio into the lora_B
    // tensors, then declares a neutral ratio (lora_alpha == lora_rank) — so the output is exact
    // at strength 1.0 in this app and in any other alpha-honoring loader (ComfyUI etc.).

    /// alpha/rank multiplier stored in a file's metadata (1.0 when absent — engine default).
    private static func alphaOverRank(_ meta: [String: String]) -> Float {
        guard let a = meta["lora_alpha"].flatMap(Float.init),
              let r = meta["lora_rank"].flatMap(Float.init), r > 0 else { return 1.0 }
        return a / r
    }

    /// Write a copy of `src` whose effect at strength 1.0 equals `src` at `scale` — the
    /// sweet-spot strength becomes the new neutral. Metadata is carried over, plus a bake tag.
    /// `async` so the (fast, but file-IO) tensor pass runs off the MainActor.
    static func bakeStrength(_ scale: Float, from src: URL, to dest: URL) async throws {
        let (arrays, meta) = try loadArraysAndMetadata(url: src, stream: .cpu)
        let factor = scale * alphaOverRank(meta)
        var out: [String: MLXArray] = [:]
        var ranks: [Int: Int] = [:]           // rank histogram from lora_A shapes
        var scaledB = 0
        for (key, arr) in arrays {
            if key.hasSuffix(".lora_B.weight") {
                // Compute in float32, store back in the source dtype (bf16 for trained adapters).
                let f32 = arr.asType(.float32, stream: .cpu)
                out[key] = multiply(f32, MLXArray(factor), stream: .cpu).asType(arr.dtype, stream: .cpu)
                scaledB += 1
            } else {
                if key.hasSuffix(".lora_A.weight"), let r = arr.shape.first { ranks[r, default: 0] += 1 }
                out[key] = arr
            }
        }
        guard scaledB > 0 else { throw LoRAEditError.notALoRA(src.lastPathComponent) }
        var newMeta = meta
        if let rank = ranks.max(by: { $0.value < $1.value })?.key {
            newMeta["lora_alpha"] = String(rank)      // neutral ratio — factor already folded into B
            newMeta["lora_rank"] = String(rank)
        }
        newMeta["tm_baked_from"] = src.lastPathComponent
        newMeta["tm_baked_scale"] = String(format: "%.2f", scale)
        try saveViaTemp(arrays: out, metadata: newMeta, dest: dest)
    }

    /// Save to a dot-prefixed temp in the destination folder (invisible to LoRAStore.discover),
    /// then move into place — a crash/force-quit mid-write must not leave a truncated
    /// .safetensors registered in the library (its intact leading header would even pass
    /// inspection and only fail at engine load time).
    private static func saveViaTemp(arrays: [String: MLXArray], metadata: [String: String], dest: URL) throws {
        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)-\(dest.lastPathComponent)")
        do {
            try save(arrays: arrays, metadata: metadata, url: tmp, stream: .cpu)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tmp, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// Merge 2+ same-tier adapters into one file at the given per-file strengths — exact
    /// rank concatenation (deltaW = Σ sᵢ·Bᵢ·Aᵢ = [sᵢ-folded Bᵢ | …]·[Aᵢ / …] stacked along the
    /// rank axis), so the output rank is the SUM of the source ranks. Layer keys are aligned
    /// after stripping the loader's known prefixes; caller supplies ecosystem metadata
    /// (tier tag, trigger). Returns the dominant output rank for the provenance note.
    static func mergeAdapters(_ sources: [(url: URL, scale: Float)], to dest: URL,
                              extraMetadata: [String: String]) async throws -> Int {
        struct Loaded {
            let name: String
            let factor: Float                          // user strength × its own alpha/rank
            var pairs: [String: (a: MLXArray?, b: MLXArray?)] = [:]   // canon path → halves
            var isBFL = false
        }
        var loaded: [Loaded] = []
        var emitBase: [String: String] = [:]           // canon path → original base path to emit
        for s in sources {
            let (arrays, meta) = try loadArraysAndMetadata(url: s.url, stream: .cpu)
            var l = Loaded(name: s.url.lastPathComponent, factor: s.scale * alphaOverRank(meta))
            for (key, arr) in arrays {
                let isA = key.hasSuffix(".lora_A.weight")
                let isB = key.hasSuffix(".lora_B.weight")
                guard isA || isB else { continue }     // engine skips non-pair keys; so do we
                let base = String(key.dropLast(".lora_A.weight".count))   // same length for _B
                let canon = canonicalLayerPath(base)
                if l.pairs[canon] == nil { l.pairs[canon] = (nil, nil) }
                if isA { l.pairs[canon]?.a = arr } else { l.pairs[canon]?.b = arr }
                if emitBase[canon] == nil { emitBase[canon] = base }
                if canon.contains("double_blocks.") || canon.contains("single_blocks.") { l.isBFL = true }
            }
            guard !l.pairs.isEmpty else { throw LoRAEditError.notALoRA(l.name) }
            loaded.append(l)
        }
        // BFL and diffusers name the SAME layers differently — a mixed merge can't align them
        // (the engine would remap both onto one module and drop a contribution). Refuse readably.
        guard Set(loaded.map(\.isBFL)).count == 1 else { throw LoRAEditError.keyLayoutMismatch }

        var out: [String: MLXArray] = [:]
        var ranks: [Int: Int] = [:]
        for canon in emitBase.keys.sorted() {
            var aParts: [MLXArray] = []
            var bParts: [MLXArray] = []
            for l in loaded {
                guard let pair = l.pairs[canon], let a = pair.a, let b = pair.b else { continue }
                if let first = aParts.first,
                   first.shape.last != a.shape.last || bParts.first?.shape.first != b.shape.first {
                    throw LoRAEditError.shapeMismatch(canon)
                }
                aParts.append(a.asType(.float32, stream: .cpu))
                bParts.append(multiply(b.asType(.float32, stream: .cpu), MLXArray(l.factor), stream: .cpu))
            }
            guard !aParts.isEmpty, let base = emitBase[canon] else { continue }
            // A: [rank, in] stacks along axis 0; B: [out, rank] along axis 1. bf16 output
            // (what trained Klein adapters ship as; ai-toolkit's merge saves bf16 too).
            let a = concatenated(aParts, axis: 0, stream: .cpu).asType(.bfloat16, stream: .cpu)
            let b = concatenated(bParts, axis: 1, stream: .cpu).asType(.bfloat16, stream: .cpu)
            out[base + ".lora_A.weight"] = a
            out[base + ".lora_B.weight"] = b
            if let r = a.shape.first { ranks[r, default: 0] += 1 }
        }
        guard !out.isEmpty, let rank = ranks.max(by: { $0.value < $1.value })?.key else {
            throw LoRAEditError.nothingToMerge
        }
        var meta = extraMetadata
        meta["lora_alpha"] = String(rank)              // neutral ratio — strengths folded into B
        meta["lora_rank"] = String(rank)
        try saveViaTemp(arrays: out, metadata: meta, dest: dest)
        return rank
    }

    /// Strip the prefixes the engine's LoRALoader strips, so files that name the same layer
    /// "transformer.X", "base_model.model.X" or plain "X" align during a merge.
    private static func canonicalLayerPath(_ base: String) -> String {
        var p = base
        for prefix in ["base_model.model.", "transformer.", "diffusion_model."] where p.hasPrefix(prefix) {
            p = String(p.dropFirst(prefix.count))
        }
        return p
    }

    /// The ecosystem metadata a published adapter should carry.
    static func publishMetadata(trigger: String, tier: ModelTier, outputName: String) -> [String: String] {
        var m: [String: String] = [
            "ss_base_model_version": tier == .klein9B ? "flux2_klein_9b" : "flux2_klein_4b",
            "ss_output_name": outputName,
        ]
        let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty {
            m["modelspec.trigger_phrase"] = t
            // Byte-shape ai-toolkit's own ss_tag_frequency ({"1_<trigger>": {"<trigger>": 1}}),
            // JSON-encoded to a string as safetensors metadata requires.
            if let data = try? JSONSerialization.data(withJSONObject: ["1_\(t)": [t: 1]]) {
                m["ss_tag_frequency"] = String(data: data, encoding: .utf8) ?? ""
            }
        }
        return m
    }
}
