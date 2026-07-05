import SwiftUI
import Observation
import AppKit
import ImageIO

@MainActor
@Observable
final class GalleryViewModel {
    // Every write is a wholesale assignment (reload/delete paths swap in a fresh store snapshot),
    // so ONE facet rebuild per assignment keeps the filter-bar facets exact — see rebuildFacets().
    var generations: [Generation] = [] { didSet { rebuildFacets() } }
    var selected: Generation? = nil
    // Multi-select (#9): Shift-click range + batch delete / export.
    var selectionMode = false
    var selectedIDs: Set<Generation.ID> = []
    private var lastTappedID: Generation.ID? = nil
    /// Why the last delete was refused (shown inline by GalleryView). The buttons' cosmetic
    /// `.disabled(UpscaleService.isBusy)` reads a non-OBSERVABLE static — a batch upscale that
    /// starts after the last body pass leaves them enabled, so the real gate lives in the
    /// delete methods below and this explains the refusal instead of a silently dead click.
    var errorMessage: String? = nil

    /// Action-time delete gate: a delete racing a running upscale would resurrect the "deleted"
    /// image when its finished _x2/_x4 output lands AFTER the sweep (an un-indexed orphan on
    /// disk). isBusy (not isRunning) also covers the one-time upscaler download phase.
    /// Returns true when it's safe to proceed; false sets the user-facing refusal.
    private func guardNotUpscaling() -> Bool {
        if UpscaleService.isBusy {
            errorMessage = "An upscale is writing into the gallery — try again in a moment."
            return false
        }
        errorMessage = nil
        return true
    }

    private let store: GenerationStore
    private var reloadTask: Task<Void, Never>?

    init(store: GenerationStore) { self.store = store }

    // MARK: Search & filters

    // Changing any filter while multi-selecting prunes the selection to what's SHOWN —
    // otherwise Delete/Export acted on hidden selected items the count and grid no longer show.
    var searchText = ""              { didSet { pruneSelectionToVisible() } }
    var filterTier: String? = nil    { didSet { pruneSelectionToVisible() } }   // ModelTier.rawValue
    var filterLoRA: String? = nil    { didSet { pruneSelectionToVisible() } }   // adapter file name (LoRAUse.name)
    var filterQuality: String? = nil { didSet { pruneSelectionToVisible() } }   // QualityPreset.rawValue

    private func pruneSelectionToVisible() {
        guard selectionMode else { return }
        let shown = Set(visible.map(\.id))
        selectedIDs.formIntersection(shown)
        if let t = lastTappedID, !shown.contains(t) { lastTappedID = nil }
    }

    var hasActiveFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
            || filterTier != nil || filterLoRA != nil || filterQuality != nil
    }

    func clearFilters() {
        searchText = ""; filterTier = nil; filterLoRA = nil; filterQuality = nil
    }

    /// LoRA names a record used — the multi field, falling back to the legacy single field
    /// (pre-multi-LoRA records would otherwise be invisible to the filter and the ledger).
    nonisolated static func loraNames(of gen: Generation) -> [String] {
        if let l = gen.loras, !l.isEmpty { return l.map(\.name) }
        if let n = gen.loraName { return [n] }
        return []
    }

    /// What the grid shows: records surviving the search text + filter chips.
    /// Search matches prompt, enhanced prompt, LoRA names, and — when the text is a number —
    /// the exact seed.
    var visible: [Generation] {
        let s = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let seedQuery = UInt64(s)
        return generations.filter { gen in
            if let t = filterTier, gen.modelTier != t { return false }
            if let q = filterQuality, gen.quality != q { return false }
            if let l = filterLoRA, !Self.loraNames(of: gen).contains(l) { return false }
            if !s.isEmpty {
                let hit = gen.prompt.localizedCaseInsensitiveContains(s)
                    || (gen.enhancedPrompt?.localizedCaseInsensitiveContains(s) ?? false)
                    || Self.loraNames(of: gen).contains { $0.localizedCaseInsensitiveContains(s) }
                    || (seedQuery != nil && gen.seed == seedQuery)
                if !hit { return false }
            }
            return true
        }
    }

    /// Filter-chip facets, derived from what actually exists in the gallery. STORED and rebuilt
    /// once per `generations` assignment — as computed properties each was a full scan/flatMap
    /// over every record, and the filter bar read all three on EVERY body pass.
    private(set) var tiersPresent: [String] = []
    private(set) var lorasPresent: [String] = []
    private(set) var qualitiesPresent: [String] = []

    private func rebuildFacets() {
        var seenTiers = Set<String>()
        tiersPresent = generations.map(\.modelTier).filter { seenTiers.insert($0).inserted }
        lorasPresent = Set(generations.flatMap { Self.loraNames(of: $0) }).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        var seenQualities = Set<String>()
        qualitiesPresent = generations.compactMap(\.quality).filter { seenQualities.insert($0).inserted }
    }

    /// Per-adapter usage ledger for the LoRA tab: how many renders used it + when last.
    struct LoRAUsage { var count = 0; var lastUsed = Date.distantPast }
    var loraUsage: [String: LoRAUsage] {
        var out: [String: LoRAUsage] = [:]
        for gen in generations {
            for name in Self.loraNames(of: gen) {
                var u = out[name] ?? LoRAUsage()
                u.count += 1
                u.lastUsed = max(u.lastUsed, gen.createdAt)
                out[name] = u
            }
        }
        return out
    }

    func reload() {
        // Overlapping reloads (a queue bumps savedImageCount per saved image) have no ordering
        // guarantee — an older snapshot could land after a newer one, flashing "ghost"/missing
        // images. Cancel the prior reload so only the latest result is applied.
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let list = await self.store.all()
            guard !Task.isCancelled else { return }
            self.generations = list
            self.pruneSelection()
        }
    }

    /// Drop selection state pointing at records no longer present (after a delete/reload), so the
    /// "N selected" count stays honest and a stale shift-anchor can't break range-select.
    private func pruneSelection() {
        let live = Set(generations.map(\.id))
        selectedIDs.formIntersection(live)
        if let t = lastTappedID, !live.contains(t) { lastTappedID = nil }
    }

    func delete(_ gen: Generation) {
        guard guardNotUpscaling() else { return }   // enforced HERE — the view's .disabled goes stale mid-batch
        // Cancel any in-flight reload so its pre-delete snapshot can't land afterward and resurrect
        // the card; run the delete + refresh AS the single live reloadTask (one writer of generations).
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.store.delete(gen.id)
            try? FileManager.default.removeItem(at: Self.thumbnailURL(for: gen))
            // A past drag-out leaves a lazy file promise on the drag pasteboard; once the
            // file is gone the system tries to materialize it at quit, fails, and writes the
            // deleted file's full path into the unified log. Drop the stale promise instead.
            NSPasteboard(name: .drag).clearContents()
            if self.selected?.id == gen.id { self.selected = nil }
            guard !Task.isCancelled else { return }
            self.generations = await self.store.all()
            self.pruneSelection()   // a context-menu delete in selection mode must not leave a ghost id
        }
    }

    func deleteAll() {
        guard guardNotUpscaling() else { return }   // enforced HERE — the view's .disabled goes stale mid-batch
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.store.deleteAll()
            // Drop the whole thumbnail cache along with the images.
            let fm = FileManager.default
            if let files = try? fm.contentsOfDirectory(at: AppPaths.thumbnails, includingPropertiesForKeys: nil) {
                for f in files { try? fm.removeItem(at: f) }
            }
            NSPasteboard(name: .drag).clearContents()  // same stale drag-promise cleanup as delete(_:)
            self.selected = nil
            guard !Task.isCancelled else { return }
            self.generations = await self.store.all()
            self.pruneSelection()
        }
    }

    // MARK: Multi-select (#9)

    func enterSelectionMode() { selectionMode = true; selectedIDs = []; lastTappedID = nil }
    func exitSelectionMode() { selectionMode = false; selectedIDs = []; lastTappedID = nil }
    /// Selects what's SHOWN — with filters active that's the filtered set, which is the point
    /// (filter to one LoRA's renders, select all, batch-delete the failures).
    func selectAll() { selectedIDs = Set(visible.map(\.id)) }

    /// A Shift/⌘-click on a cell while NOT yet in selection mode: switch into selection mode
    /// and select the clicked image. Lets multi-select start straight from the grid (Finder /
    /// Photos muscle memory) without the user having to find the "Select" button first.
    func beginSelection(with gen: Generation) {
        selectionMode = true
        selectedIDs = [gen.id]
        lastTappedID = gen.id
    }

    /// Toggle one image, or — with Shift — select the contiguous range from the last tap
    /// (range runs over the VISIBLE order, matching what the user sees under active filters).
    func toggleSelection(_ gen: Generation, shift: Bool) {
        // `visible` is a full filter scan of the store — evaluate it ONLY for a Shift range-walk;
        // a plain toggle used to pay that scan on every single click (`case let` short-circuits).
        if shift, let anchor = lastTappedID,
           case let shown = visible,
           let a = shown.firstIndex(where: { $0.id == anchor }),
           let b = shown.firstIndex(where: { $0.id == gen.id }) {
            for i in min(a, b)...max(a, b) { selectedIDs.insert(shown[i].id) }
        } else if selectedIDs.contains(gen.id) {
            selectedIDs.remove(gen.id)
        } else {
            selectedIDs.insert(gen.id)
        }
        lastTappedID = gen.id
    }

    func deleteSelected() {
        guard guardNotUpscaling() else { return }   // enforced HERE — the view's .disabled goes stale mid-batch
        let ids = Array(selectedIDs)
        guard !ids.isEmpty else { return }
        let thumbs = generations.filter { selectedIDs.contains($0.id) }
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.store.deleteMany(ids)
            for gen in thumbs { try? FileManager.default.removeItem(at: Self.thumbnailURL(for: gen)) }
            NSPasteboard(name: .drag).clearContents()
            self.selectedIDs = []
            self.lastTappedID = nil
            self.selectionMode = false
            self.selected = nil
            guard !Task.isCancelled else { return }
            self.generations = await self.store.all()
        }
    }

    /// Copy the selected images into a folder the user picks (collision-safe naming).
    func exportSelected() {
        let victims = generations.filter { selectedIDs.contains($0.id) }
        guard !victims.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Export \(victims.count) image\(victims.count == 1 ? "" : "s")"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        // The file loop runs OFF the MainActor (ModelsViewModel.directorySize pattern) — copying
        // dozens of full-size PNGs plus per-file exists-probing blocked the whole UI on big
        // multi-selects. Only the summary/alerts come back to the MainActor.
        Task { @MainActor [weak self] in
            let copied = await Self.copyForExport(victims, into: dir)
            AppLog.info("Exported \(copied) of \(victims.count) image(s)")
            // Surface the outcome instead of a silent (partial) failure: opening an empty Finder window
            // on a total failure read as success, and a partial copy previously gave no hint at all.
            if copied == 0 {
                let a = NSAlert()
                a.messageText = "Export failed"
                a.informativeText = "Couldn't export any of the \(victims.count) image\(victims.count == 1 ? "" : "s") — the source files may be missing or the destination isn't writable. See the log for details."
                a.alertStyle = .warning
                a.runModal()
            } else {
                if copied < victims.count {
                    let a = NSAlert()
                    a.messageText = "Exported \(copied) of \(victims.count)"
                    a.informativeText = "\(victims.count - copied) image\(victims.count - copied == 1 ? "" : "s") couldn't be copied (see the log)."
                    a.alertStyle = .informational
                    a.runModal()
                }
                NSWorkspace.shared.activateFileViewerSelecting([dir])
                self?.exitSelectionMode()
            }
        }
    }

    /// Detached copy loop for exportSelected: collision-safe naming + copy, returns how many
    /// landed. Per-file failures log exactly as before; the caller reports the summary on main.
    private static func copyForExport(_ victims: [Generation], into dir: URL) async -> Int {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var copied = 0
            for gen in victims {
                let stem = (gen.imageFileName as NSString).deletingPathExtension
                let ext = (gen.imageFileName as NSString).pathExtension
                var dest = dir.appendingPathComponent(gen.imageFileName)
                var i = 1
                while fm.fileExists(atPath: dest.path) {
                    dest = dir.appendingPathComponent("\(stem)_\(i).\(ext)"); i += 1
                }
                do { try fm.copyItem(at: gen.imageURL, to: dest); copied += 1 }
                catch { AppLog.error("Export failed for \(gen.imageFileName): \(error.localizedDescription)") }
            }
            return copied
        }.value
    }

    // Detail-sheet navigation — the sheet is item-bound, so moving `selected` flips the
    // sheet to the neighbouring image in grid order (newest first). Navigates the VISIBLE
    // (filtered) set: ‹ › steps through exactly what the grid shows.
    var canSelectPrevious: Bool {
        guard let idx = selectedIndex else { return false }
        return idx > 0
    }
    var canSelectNext: Bool {
        guard let idx = selectedIndex else { return false }
        return idx < visible.count - 1
    }
    func selectPrevious() {
        guard let idx = selectedIndex, idx > 0 else { return }
        selected = visible[idx - 1]
    }
    func selectNext() {
        let shown = visible
        guard let idx = selectedIndex, idx < shown.count - 1 else { return }
        selected = shown[idx + 1]
    }
    /// "3 of 12" for the detail sheet (position within the filtered view).
    func positionText(of gen: Generation) -> String? {
        guard let idx = visible.firstIndex(where: { $0.id == gen.id }) else { return nil }
        return "\(idx + 1) of \(visible.count)"
    }
    private var selectedIndex: Int? {
        guard let cur = selected else { return nil }
        return visible.firstIndex { $0.id == cur.id }
    }

    func revealInFinder(_ gen: Generation) {
        NSWorkspace.shared.activateFileViewerSelecting([gen.imageURL])
    }

    /// Open the output (Images) folder itself in Finder (gallery "Open folder") — shows the
    /// generated PNGs directly, instead of selecting Images inside the parent app-data folder
    /// (which exposed Models/LoRAs and confused users).
    func revealFolder() {
        NSWorkspace.shared.open(AppPaths.images)
    }

    /// Full image — only for the detail view. `nonisolated async` so the multi-MB PNG
    /// decode runs off the MainActor (arrow-key navigation re-decodes per step; a sync
    /// main-thread read would hitch the whole UI).
    nonisolated func image(for gen: Generation) async -> NSImage? {
        NSImage(contentsOf: gen.imageURL)
    }

    /// Fast DOWNSAMPLED thumbnail for the grid — decodes to ~`maxPixel` px (tiny memory),
    /// not the full 1024–1536 px image. `nonisolated async` so the decode genuinely runs OFF
    /// the MainActor (a synchronous nonisolated call would still run inline on the caller's
    /// actor); awaited per-cell from `.task` so the grid never blocks the main thread.
    ///
    /// Backed by a disk cache in AppPaths.thumbnails (keyed by the image's unique file name —
    /// PNGs are immutable, so no further invalidation is needed): scrolling and relaunches
    /// reload the small cached file instead of re-decoding the full PNG. "Clear cache" on the
    /// System tab reclaims these; a corrupt/partial cache file just falls through to re-decode.
    nonisolated func thumbnail(for gen: Generation, maxPixel: Int = 340) async -> NSImage? {
        let cacheURL = Self.thumbnailURL(for: gen)
        if let cached = NSImage(contentsOf: cacheURL) { return cached }
        guard let src = CGImageSourceCreateWithURL(gen.imageURL as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        _ = try? ImageSaver.savePNG(cg, into: AppPaths.thumbnails, name: gen.imageFileName)
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private nonisolated static func thumbnailURL(for gen: Generation) -> URL {
        AppPaths.thumbnails.appendingPathComponent(gen.imageFileName)
    }
}
