import Foundation
import Observation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Owns the user's own Library cards — add / update / delete / persist to custom-recipes.json.
///
/// A custom card IS a `SceneRecipe` (so it drives Generate + the queue through the exact same
/// `loadScene`/`enqueueScene` path as a built-in, with zero render-path changes). Its id is a fresh
/// `custom.rcp.<UUID>` — namespaced, filesystem-safe, and used verbatim as its preview filename.
/// Unlike built-ins (which are hidden, never destroyed — see `LibraryVisibilityStore`), a custom
/// card is DELETED permanently. Mirrors `CustomPresetStore` for chips.
@MainActor
@Observable
final class CustomRecipeStore {
    static let shared = CustomRecipeStore()

    private(set) var items: [SceneRecipe] = []

    /// Bumped whenever a card's preview jpg is written or removed. The Library keys its decoded-
    /// preview cache entries AND per-card load tasks on this, so a cover changed mid-session
    /// (card editor, "Use last render") self-invalidates without a manual cache flush — built-in
    /// previews ship read-only in the bundle and always key on 0.
    private(set) var previewStamp = 0

    private var fileURL: URL { AppPaths.customRecipesIndex }

    init() {
        // Per-record salvage + timestamped quarantine (CustomStoreJSON.load, below) — the old
        // whole-array decode wiped EVERY card over one malformed record, and its single fixed-name
        // backup was clobbered by each subsequent corruption event (evidence destroyed).
        let loaded = CustomStoreJSON.load([SceneRecipe].self, from: fileURL, label: "custom-recipes")
        // Namespace gate: ids are minted as "custom.rcp.<UUID>" (newID below) and the Library's
        // ForEach mixes custom cards with built-ins by id — a hand-edited record carrying a
        // built-in "rcp.*" id would produce DUPLICATE ForEach ids (undefined SwiftUI behavior)
        // and shadow the built-in card. Drop (and log) anything outside the custom namespace.
        items = loaded.filter { Self.isCustom($0.id) }
        let dropped = loaded.count - items.count
        if dropped > 0 {
            AppLog.error("custom-recipes.json: dropped \(dropped) record(s) whose id is outside the 'custom.' namespace (would collide with built-in cards)")
        }
        sweepOrphanPreviews()
    }

    /// Self-heal the previews folder: delete jpgs whose recipe id is no longer in the index.
    /// A force-quit with the card editor open strands its staged preview ("Save as card" writes
    /// the jpg BEFORE the recipe exists — see GenerateViewModel.draftCardFromCurrentState), and
    /// nothing else ever reclaims it. Age-gated to 1h so we never race a LIVE editor session:
    /// a preview written seconds ago for a draft that hasn't been saved yet must survive.
    private func sweepOrphanPreviews() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: AppPaths.customRecipePreviews,
                                                      includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let live = Set(items.map(\.id))
        var swept = 0
        for f in files where f.pathExtension.lowercased() == "jpg" {
            let id = f.deletingPathExtension().lastPathComponent
            guard !live.contains(id),
                  let mod = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  Date().timeIntervalSince(mod) > 3600 else { continue }
            if (try? fm.removeItem(at: f)) != nil { swept += 1 }
        }
        if swept > 0 { AppLog.info("Card previews: swept \(swept) orphan jpg(s) with no matching recipe") }
    }

    static func isCustom(_ id: String) -> Bool { id.hasPrefix("custom.") }
    /// A fresh, filesystem-safe card id (dots/hex/hyphens only) that doubles as its preview filename.
    static func newID() -> String { "custom.rcp.\(UUID().uuidString)" }

    /// The user's own cards filed under a studio.
    func recipes(in studioID: String) -> [SceneRecipe] {
        items.filter { $0.studio == studioID }
    }

    func add(_ recipe: SceneRecipe) {
        items.append(recipe)
        if persist() {
            AppLog.info("Custom card added: \(recipe.title.prefix(40))")
        } else {
            // Don't claim a success the relaunch will silently contradict.
            AppLog.error("Custom card NOT saved (write failed) — it will be lost on relaunch: \(recipe.title.prefix(40))")
        }
    }

    func update(_ recipe: SceneRecipe) {
        guard let i = items.firstIndex(where: { $0.id == recipe.id }) else { return }
        items[i] = recipe
        if !persist() { AppLog.error("Custom card update not persisted: \(recipe.title.prefix(40))") }
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        Self.removePreview(for: id)   // drop the sidecar jpg too (also bumps previewStamp)
        if !persist() { AppLog.error("Custom card removal not persisted — it may reappear on relaunch") }
    }

    /// Drop in-memory cards for Remove-all-data (the JSON + preview dir were just wiped on disk).
    func reset() { items = [] }

    @discardableResult
    private func persist() -> Bool {
        guard let data = try? JSONEncoder().encode(items) else { return false }
        do { try data.write(to: fileURL, options: .atomic); return true }
        catch { return false }
    }

    // MARK: Card previews (writable sidecar jpgs — built-in previews ship read-only in the bundle)

    /// Write an image as a card's 320px preview jpg (matches the built-in ScenePreviews convention).
    static func writePreview(_ image: CGImage, for id: String) {
        let maxDim = 320.0
        let scale = min(1.0, maxDim / Double(max(image.width, image.height)))
        let tw = max(1, Int(Double(image.width) * scale)), th = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let scaled = ctx.makeImage() else { return }
        let dest = AppPaths.customRecipePreview(for: id)
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let out = CGImageDestinationCreateWithURL(dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            AppLog.error("Card preview: destination create failed for \(id)")
            return
        }
        CGImageDestinationAddImage(out, scaled, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        if CGImageDestinationFinalize(out) {
            shared.previewStamp += 1   // invalidate cached decodes of this card's old cover
            AppLog.info("Card preview written \(tw)x\(th) for \(id)")
        } else {
            AppLog.error("Card preview finalize failed for \(id)")
        }
    }

    /// Set a card's preview from an image file on disk (a gallery PNG, a dropped image…).
    static func writePreview(fromFile url: URL, for id: String) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            AppLog.error("Card preview: could not read image \(url.lastPathComponent)")
            return
        }
        writePreview(cg, for: id)
    }

    static func removePreview(for id: String) {
        try? FileManager.default.removeItem(at: AppPaths.customRecipePreview(for: id))
        shared.previewStamp += 1   // a removed cover must not keep serving from the decoded cache
    }

    /// The most recent gallery render's PNG, for the editor's "Use last render" button — the
    /// reliable way to put a render on a card without a file dialog. nil if the gallery is empty.
    static func latestGalleryImageURL() -> URL? {
        guard let data = try? Data(contentsOf: AppPaths.generationsIndex),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let newest = arr.max { (($0["createdAt"] as? Double) ?? 0) < (($1["createdAt"] as? Double) ?? 0) }
        guard let name = newest?["imageFileName"] as? String else { return nil }
        let u = AppPaths.images.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
}

/// Shared decode-with-salvage for the small custom-content JSON stores (recipes / presets /
/// studios). Mirrors `TrainingStore.loadIndex` / `GenerationStore.loadFromDisk`:
///  • a clean file decodes whole, zero extra cost;
///  • a corrupt one is QUARANTINED under a timestamped name (the old single fixed-name
///    "<label>.corrupt.json" backup was silently clobbered by every later corruption event);
///  • only the newest 3 quarantines per label are kept (bounded disk, enough evidence);
///  • every still-decodable record is SALVAGED and the clean result rewritten immediately —
///    one malformed record can no longer wipe the user's whole store.
enum CustomStoreJSON {
    /// Decodes ONE array element, capturing a per-record decode failure as nil instead of
    /// aborting the whole array (the TrainingStore `Failable<T>` pattern).
    private struct Failable<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    static func load<T: Codable>(_ type: [T].Type, from url: URL, label: String) -> [T] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        if let list = try? JSONDecoder().decode([T].self, from: data) { return list }
        let stamp = Int(Date().timeIntervalSince1970)
        let dir = url.deletingLastPathComponent()
        let quarantine = dir.appendingPathComponent("\(label).corrupt.\(stamp).json")
        try? FileManager.default.moveItem(at: url, to: quarantine)
        pruneQuarantines(in: dir, label: label)
        if let lenient = try? JSONDecoder().decode([Failable<T>].self, from: data) {
            let salvaged = lenient.compactMap(\.value)
            if !salvaged.isEmpty {
                // Persist the salvage NOW — it must survive a crash before the next user-driven save.
                if let clean = try? JSONEncoder().encode(salvaged) { try? clean.write(to: url, options: .atomic) }
                AppLog.error("\(label).json: salvaged \(salvaged.count) of \(lenient.count) record(s) — original saved as \(quarantine.lastPathComponent)")
                return salvaged
            }
        }
        AppLog.error("\(label).json unreadable — kept as \(quarantine.lastPathComponent)")
        return []
    }

    /// Keep only the newest `keep` quarantine files per label — the epoch stamp is fixed-width
    /// until 2286, so a lexicographic name sort is newest-first.
    private static func pruneQuarantines(in dir: URL, label: String, keep: Int = 3) {
        let fm = FileManager.default
        let prefix = "\(label).corrupt."
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let quarantines = entries
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in quarantines.dropFirst(keep) { try? fm.removeItem(at: old) }
    }
}
