import Foundation
import CryptoKit
import Flux2Core
import FluxTextEncoders

/// An auxiliary on-disk model component that doesn't belong to a generation tier group
/// (the shared VAE and the Describe VLM). The tier-group encoders are listed inside their
/// groups now; these two are shown in the "Shared components" section.
struct AuxComponent: Identifiable, Sendable {
    let id: String       // relative path under the app's Models dir
    let title: String
    let note: String     // role + what happens after delete
    let bytes: Int64     // on-disk size (0 when not downloaded)
    let isDownloaded: Bool
    let sizeGB: Int      // estimated download size — shown before download + used for the disk preflight
    let downloadable: Bool  // true → the Models tab can pre-download it (the Describe / Auto-caption VLM)
    let recommended: Bool   // the default pick (the 4-bit VLM) — gets a "Recommended" badge
    let isActive: Bool      // this downloaded VLM is the one Describe / Auto-caption currently use
}

enum ModelStoreError: LocalizedError {
    case integrityMismatch(expected: String, actual: String)
    case pinnedFileMissing

    var errorDescription: String? {
        switch self {
        case .integrityMismatch(let expected, let actual):
            return "Downloaded weights failed the integrity check (SHA-256 \(actual.prefix(12))… ≠ pinned \(expected.prefix(12))…). The file was removed — try again; if it repeats, the upstream repo has changed and needs re-review."
        case .pinnedFileMissing:
            return "The downloaded model is missing its pinned weight file — the upstream repo layout has changed and needs re-review before use."
        }
    }
}

/// Wraps the engine's downloaders for every Klein component the Models tab manages:
/// per-variant download (with progress + integrity pin), status, on-disk size and delete.
actor ModelStore {
    // MARK: Shared (non-tier) components — VAE + Describe VLM

    /// Components that aren't part of an Image-Generation tier group. The tier encoders moved
    /// into their groups; the shared VAE (decodes for BOTH tiers — never auto-delete it) and the
    /// Describe VLM live here. All re-download automatically when next needed.
    private static let auxDefs: [(rel: String, title: String, note: String, sizeGB: Int, downloadable: Bool, alwaysShow: Bool, recommended: Bool)] = [
        ("black-forest-labs/FLUX.2-klein-4B-vae",
         "Shared VAE (latents → pixels)",
         "Required for every generation — BOTH Klein tiers decode through it (the \u{201C}klein-4B\u{201D} name is just the repo BFL hosts it in). Re-downloads automatically (~160 MB, no token).",
         1, false, false, false),
        ("mlx-community/Qwen3.5-4B-MLX-4bit",
         "Qwen3.5-VLM 4B (4-bit) · Describe & Auto-caption",
         "The vision model that reads an image and writes a description. Used by Describe (Generate) and Auto-caption (LoRA Training) — it is NOT the Qwen3 text encoder. ~3 GB, no token. The lighter, recommended choice; auto-downloads on first use if neither variant is present.",
         3, true, true, true),
        ("mlx-community/Qwen3.5-4B-MLX-8bit",
         "Qwen3.5-VLM 4B (8-bit) · higher quality",
         "The SAME vision model, less compressed — slightly sharper, more detailed captions for ~5 GB and a bit more RAM. Optional: download it and captioning/Describe use it automatically instead of the 4-bit. Independent of the 4B/9B training tier.",
         5, true, true, false),
    ]

    /// The Qwen3.5-VLM variant a shared-component row maps to (matched by HuggingFace repo id),
    /// or nil for the VAE.
    private static func qwen35Variant(forRel rel: String) -> Qwen35Variant? {
        Qwen35Variant.allCases.first { $0.repoId == rel }
    }

    /// The shared components. Both VLM quantizations are ALWAYS listed (downloaded or not) so they can
    /// be seen and pre-downloaded before first use; the VAE only appears once present (auto-ships with Klein).
    func auxComponents() -> [AuxComponent] {
        ModelImportService.sweepDanglingLinks(under: AppPaths.models)
        let activeRepo = DescribeService.variant.repoId   // which VLM Describe/Auto-caption use right now
        return Self.auxDefs.compactMap { def in
            let url = AppPaths.models.appendingPathComponent(def.rel, isDirectory: true)
            let present = FileManager.default.fileExists(atPath: url.path)
            guard present || def.alwaysShow else { return nil }
            // A VLM row uses the engine's completeness check (a half-finished download must read as
            // "not downloaded" so the row offers Download/resume, not a false "on disk").
            let downloaded = Self.qwen35Variant(forRel: def.rel)
                .map { TextEncoderModelDownloader.isQwen35ModelDownloaded(variant: $0) } ?? present
            return AuxComponent(id: def.rel, title: def.title, note: def.note,
                                bytes: present ? Self.directorySize(url) : 0,
                                isDownloaded: downloaded, sizeGB: def.sizeGB,
                                downloadable: def.downloadable, recommended: def.recommended,
                                isActive: def.downloadable && downloaded && def.rel == activeRepo)
        }
    }

    /// Make a downloaded VLM the active one for Describe / Auto-caption (the "Use" action).
    func setActiveVLM(id: String) {
        guard let v = Self.qwen35Variant(forRel: id) else { return }
        DescribeService.setPreferred(v)
    }

    /// Pre-download a shared VLM component (4-bit or 8-bit) — the exact same fetch its first use would
    /// trigger, just initiated deliberately from the Models tab.
    func downloadAux(id: String, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard let v = Self.qwen35Variant(forRel: id) else { return }
        progress(0, "Preparing…")
        _ = try await TextEncoderModelDownloader().downloadQwen35(variant: v) { p, _ in
            progress(p, p < 1 ? "Downloading Qwen3.5-VLM… \(Int(p * 100))%" : "Finishing…")
        }
    }

    /// Delete one shared component. Returns bytes reclaimed, or nil when the target was a
    /// symlink-import — removing the link frees ~nothing, so no freed-bytes figure.
    func deleteAux(_ id: String) throws -> Int64? {
        guard Self.auxDefs.contains(where: { $0.rel == id }) else { return 0 }
        let url = AppPaths.models.appendingPathComponent(id, isDirectory: true)
        if Self.isSymlink(url) {
            try FileManager.default.removeItem(at: url)  // removes the link, never the originals
            return nil
        }
        let size = Self.directorySize(url)
        try FileManager.default.removeItem(at: url)
        return size
    }

    // MARK: Group catalog (component-level, with live status)

    /// Build the live `ModelGroupInfo` list for a set of specs (Image Generation / LoRA Training).
    func groups(_ specs: [ModelGroupSpec]) -> [ModelGroupInfo] {
        ModelImportService.sweepDanglingLinks(under: AppPaths.models)
        return specs.map { s in
            ModelGroupInfo(
                id: s.id, title: s.title, subtitle: s.subtitle, ramBadge: s.ramBadge,
                nonCommercial: s.nonCommercial, encoderHeader: s.encoderHeader,
                transformers: s.transformers.map { info(.transformer($0)) } + (s.id == "klein9b" ? [info(.quantizedKlein9B)] : []),
                encoders: s.encoders.map { info(.encoder($0)) }
            )
        }
    }

    private func info(_ kind: ComponentKind) -> ComponentInfo {
        switch kind {
        case .quantizedKlein9B:
            let ok = Klein9BMLXInt4Model.isAvailable
            return ComponentInfo(id: "tf-klein9b-int4", kind: kind,
                title: "MLX 9B Int4 (pre-quantized)", rawTag: "klein9b-int4",
                sizeGB: 5, isGated: false,
                repoURL: "https://huggingface.co/mlx-community/flux2-klein-9b-4bit",
                isDownloaded: ok,
                downloadedBytes: ok ? Self.directorySize(Klein9BMLXInt4Model.transformerDirectory) : 0)
        case .transformer(let v):
            let comp = ModelRegistry.ModelComponent.transformer(v)
            let dl = Flux2ModelDownloader.isDownloaded(comp)
            return ComponentInfo(
                id: "tf-\(v.rawValue)", kind: kind, title: ModelCatalog.title(for: v),
                rawTag: v.rawValue, sizeGB: v.estimatedSizeGB, isGated: v.isGated,
                repoURL: v.huggingFaceURL, isDownloaded: dl,
                downloadedBytes: dl ? Self.transformerBytes(v) : 0)
        case .encoder(let v):
            let dl = Self.encoderDownloaded(v)
            return ComponentInfo(
                id: "enc-\(v.rawValue)", kind: kind, title: v.displayName,
                rawTag: v.rawValue, sizeGB: v.estimatedSizeGB, isGated: false,
                repoURL: v.huggingFaceURL, isDownloaded: dl,
                downloadedBytes: dl ? Self.directorySize(AppPaths.models.appendingPathComponent(v.repoId, isDirectory: true)) : 0)
        }
    }

    // MARK: Partial downloads (cancelled/interrupted residue)

    /// The dir a component downloads into — where its `.part` streams + `.chunks` sidecars
    /// live. MUST mirror `download(kind:)` exactly, or the partial-bytes report and the
    /// "Delete partial" action would look at the wrong place.
    private static func destDir(_ kind: ComponentKind) -> URL {
        switch kind {
        case .quantizedKlein9B: return Klein9BMLXInt4Model.transformerDirectory
        case .transformer(let v):
            return ModelRegistry.localPath(for: .transformer(v))
        case .encoder(let v):
            return AppPaths.models.appendingPathComponent(v.repoId, isDirectory: true)
        }
    }

    /// id → on-disk bytes of every NOT-downloaded component in `groups`. A cancelled multi-GB
    /// download keeps its `.part` files for resume, but the row used to report 0 bytes and
    /// offer no Delete — the space was invisible AND unreclaimable. Everything in the dir
    /// counts (finished files, `.part`, sidecars): until the component reads as downloaded,
    /// the whole dir is resume residue. Symlink imports report nothing — a "Delete partial"
    /// must never be able to touch a user's original files.
    func partialSizes(for groups: [ModelGroupInfo]) -> [String: Int64] {
        let fm = FileManager.default
        var out: [String: Int64] = [:]
        for comp in groups.flatMap(\.allComponents) where !comp.isDownloaded {
            let dir = Self.destDir(comp.kind)
            guard fm.fileExists(atPath: dir.path), !Self.isSymlink(dir) else { continue }
            let size = Self.directorySize(dir)
            if size > 0 { out[comp.id] = size }
        }
        return out
    }

    /// Delete a NOT-downloaded component's partial residue. Returns bytes reclaimed; throws so
    /// the UI can report a real failure. The caller guards against a download currently running
    /// for this id (deleting the dir under an active writer would corrupt the stream).
    func deletePartial(kind: ComponentKind) throws -> Int64 {
        let dir = Self.destDir(kind)
        guard FileManager.default.fileExists(atPath: dir.path), !Self.isSymlink(dir) else { return 0 }
        let size = Self.directorySize(dir)
        try FileManager.default.removeItem(at: dir)
        return size
    }

    // MARK: Download / delete (per component)

    func download(
        kind: ComponentKind,
        hfToken: String?,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        // Route through our resumable downloader (HTTP Range → .part), NOT the engine's
        // whole-file-temp downloaders — so a cancel / app-quit / stall keeps the bytes already
        // fetched and continues from there. We write into the SAME dirs the engine reads back.
        switch kind {
        case .quantizedKlein9B:
            try await ResumableDownloader.download(
                repoId: Klein9BMLXInt4Model.repository, subfolder: "transformer",
                destDir: Klein9BMLXInt4Model.transformerDirectory,
                token: nil, onProgress: onProgress)
            guard Klein9BMLXInt4Model.isAvailable else {
                throw ResumableDownloadError.incomplete("Klein 9B MLX Int4 transformer")
            }
        case .transformer(let v):
            try await ResumableDownloader.download(
                repoId: v.huggingFaceRepo,
                subfolder: v.huggingFaceSubfolder,
                destDir: ModelRegistry.localPath(for: .transformer(v)),
                token: hfToken,
                onProgress: onProgress)
        case .encoder(let v):
            try await ResumableDownloader.download(
                repoId: v.repoId,
                subfolder: nil,   // Qwen3 encoder repos keep weights at root
                destDir: AppPaths.models.appendingPathComponent(v.repoId, isDirectory: true),
                token: hfToken,   // encoders are ungated; harmless if nil
                onProgress: onProgress)
        }
    }

    /// Delete one component. Returns bytes reclaimed, or nil for a symlink-import.
    func delete(kind: ComponentKind) throws -> Int64? {
        switch kind {
        case .quantizedKlein9B:
            let dir = Klein9BMLXInt4Model.transformerDirectory
            guard FileManager.default.fileExists(atPath: dir.path) else { return 0 }
            if Self.isSymlink(dir) {
                try FileManager.default.removeItem(at: dir)
                return nil
            }
            let size = Self.directorySize(dir)
            try FileManager.default.removeItem(at: dir)
            return size
        case .transformer(let v):
            let comp = ModelRegistry.ModelComponent.transformer(v)
            // findModelPath keeps the unresolved URL, so removeItem deletes only the link.
            if let path = Flux2ModelDownloader.findModelPath(for: comp), Self.isSymlink(path) {
                try FileManager.default.removeItem(at: path)
                return nil
            }
            let before = Flux2ModelDownloader.isDownloaded(comp) ? Self.transformerBytes(v) : 0
            try Flux2ModelDownloader.delete(comp)
            return before
        case .encoder(let v):
            let url = AppPaths.models.appendingPathComponent(v.repoId, isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
            if Self.isSymlink(url) {
                try FileManager.default.removeItem(at: url)
                return nil
            }
            let size = Self.directorySize(url)
            try FileManager.default.removeItem(at: url)
            return size
        }
    }

    // MARK: Integrity pin

    /// SHA-256 pins for transformers fetched from COMMUNITY repos. The engine downloads from the
    /// mutable `main` branch and verifies file PRESENCE only — the repo owner could swap weights
    /// at any time (v0.38 policy). BFL's own gated repos are deliberately not pinned.
    private static let pinnedTransformerSHA256: [ModelRegistry.TransformerVariant: String] = [
        // aydin99/FLUX.2-klein-4B-int8 · diffusion_pytorch_model.safetensors (3,877,645,084 bytes)
        // Verified on download 2026-06-10; size byte-matched the HF API listing.
        .klein4B_8bit: "fb6e95fd62f2af89151cef9f22a99da842a0968ecec35bdeaf8d58403ad14f8d",
    ]

    /// Throws (and removes the directory) when a pinned variant's main weight file doesn't match
    /// its recorded hash. No-op for unpinned variants or missing files.
    func verifyTransformerIntegrity(variant: ModelRegistry.TransformerVariant) throws {
        guard let expected = Self.pinnedTransformerSHA256[variant],
              expected.count == 64 else { return }   // unpinned → nothing to check
        let comp = ModelRegistry.ModelComponent.transformer(variant)
        guard let dir = Flux2ModelDownloader.findModelPath(for: comp) else {
            throw ModelStoreError.pinnedFileMissing
        }
        let file = dir.appendingPathComponent("diffusion_pytorch_model.safetensors")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw ModelStoreError.pinnedFileMissing
        }
        let actual = try Self.sha256(of: file)
        guard actual == expected else {
            try? FileManager.default.removeItem(at: dir)
            throw ModelStoreError.integrityMismatch(expected: expected, actual: actual)
        }
        AppLog.info("Transformer integrity OK (\(variant.rawValue), SHA-256 \(actual.prefix(12))…)")
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            // The SHA-256 pin is the ONLY integrity gate, so the hash is deliberately NOT
            // cancellable: a Cancel landing mid-hash must not leave a complete-but-UNVERIFIED
            // transformer on disk. The pass is only seconds for the pinned 4B weight.
            guard let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: 8 * 1024 * 1024) }),
                  !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: On-disk helpers

    /// True when the variant's Qwen3 encoder is on disk under the app's Models dir — config.json
    /// plus all index shards (config alone is NOT proof: an interrupted download leaves config
    /// without weights, and the engine would then lazy-fetch GBs silently).
    private static func encoderDownloaded(_ v: Qwen3Variant) -> Bool {
        let fm = FileManager.default
        let dir = AppPaths.models.appendingPathComponent(v.repoId, isDirectory: true)
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

    private static func transformerBytes(_ v: ModelRegistry.TransformerVariant) -> Int64 {
        guard let path = Flux2ModelDownloader.findModelPath(for: .transformer(v)) else { return 0 }
        return directorySize(path)
    }

    /// attributesOfItem does NOT follow links — exactly what the delete paths need.
    private static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        // Imported components may be SYMLINKS to the user's originals — an enumerator rooted at a
        // link yields zero items. Resolve first; delete paths keep the unresolved URL.
        let resolved = url.resolvingSymlinksInPath()
        if let en = fm.enumerator(at: resolved, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
            for case let f as URL in en {
                total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
            }
        }
        return total
    }
}
