import SwiftUI
import Observation
import AppKit
import Flux2Core
import FluxTextEncoders   // Qwen3Variant — the encoder→tier mapping below matches its cases

/// A download waiting its turn. Tier components and shared (aux) components share the ONE download
/// slot, so the queue holds either kind — that's what lets a shared component be queued behind a
/// model download instead of being refused.
enum PendingDownload: Identifiable {
    case component(ComponentInfo)
    case aux(AuxComponent)

    var id: String {
        switch self {
        case .component(let c): return c.id
        case .aux(let a):       return a.id
        }
    }
    var title: String {
        switch self {
        case .component(let c): return c.title
        case .aux(let a):       return a.title
        }
    }
}

@MainActor
@Observable
final class ModelsViewModel {
    var imageGenGroups: [ModelGroupInfo] = []
    var loraGroups: [ModelGroupInfo] = []
    var auxComponents: [AuxComponent] = []      // shared VAE + Describe VLM
    var hfToken: String = ""
    var downloadingID: String? = nil            // ComponentInfo/AuxComponent.id currently downloading
    var downloadQueue: [PendingDownload] = []   // components (tier or shared) waiting their turn (sequential)
    var downloadProgress: Double = 0
    var downloadMessage: String = ""
    var lastAction: ActionMessage? = nil
    var loadedTier: ModelTier? = nil            // which tier is resident in RAM (nil = none)
    var pendingImport: [FoundComponent]? = nil  // non-nil = the import confirmation dialog is up
    var importing: Bool = false
    /// Bytes of THIS APP's entries in the shared HuggingFace download cache
    /// (~/.cache/huggingface/hub/models--… for repos the engine can pull) — the number shown
    /// next to "Clear" counts only what Clear would actually delete.
    var hfCacheBytes: Int64 = 0
    /// id → on-disk bytes of a NOT-downloaded component (a cancelled download's `.part`
    /// residue kept for resume). Drives the "partial" label + "Delete partial" in ModelsView.
    var partialBytes: [String: Int64] = [:]

    private let store = ModelStore()
    private let engine: FluxEngine
    private var downloadTask: Task<Void, Never>? = nil
    private var reloadTask: Task<Void, Never>? = nil    // single-slot: newest reload wins

    /// Fired after unload/download/delete so the header model chip (driven by
    /// GenerateViewModel) re-syncs immediately instead of waiting for a tab switch.
    @ObservationIgnored var onModelStateChange: (() -> Void)? = nil

    /// Wired in TyphoonminigenApp: true when the composed render queue still references the
    /// given tier — deleting its weights then deserves an explicit warning in the confirm
    /// dialog (the queued renders will fail or silently re-download GBs), not silence.
    @ObservationIgnored var queueUsesTier: ((ModelTier) -> Bool)? = nil

    /// A token is actually PERSISTED (Keychain / env) — drives the "saved" pills.
    var tokenSaved: Bool = false

    init(engine: FluxEngine) {
        self.engine = engine
        hfToken = HFToken.current(for: .klein9B) ?? ""  // 9B = the only gated inference tier
        tokenSaved = !hfToken.isEmpty
    }

    var hasToken: Bool { !hfToken.trimmingCharacters(in: .whitespaces).isEmpty }

    func reload() {
        // Single-slot cancel (mirrors GalleryViewModel.reload): reload fires on every Models-tab
        // appear and the multi-GB directory walks make it slow — without the cancel, an OLDER
        // run's snapshot could land after a NEWER one and show stale rows/bytes.
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshCatalog()
            guard !Task.isCancelled else { return }
            self.loadedTier = await self.engine.loadedTier
            // Scoped: size only this app's hub entries, off the main actor (multi-GB walk).
            let bytes = await Task.detached(priority: .utility) {
                MaintenanceService.appHFCacheBytes()
            }.value
            guard !Task.isCancelled else { return }
            self.hfCacheBytes = bytes
        }
    }

    private func refreshCatalog() async {
        self.imageGenGroups = await store.groups(ModelCatalog.imageGeneration)
        self.loraGroups = await store.groups(ModelCatalog.loraTraining)
        self.auxComponents = await store.auxComponents()
        // After the groups, so cancelled-download residue is computed for the same snapshot.
        self.partialBytes = await store.partialSizes(for: self.imageGenGroups + self.loraGroups)
    }

    // MARK: Download

    /// Public entry: download now if the slot is free, otherwise QUEUE it (starts automatically
    /// when the current download finishes). A repeat click on an active/queued item is ignored.
    func download(_ comp: ComponentInfo) {
        guard !importing else {
            lastAction = .error("Can't download — wait for the import to finish.")
            return
        }
        if downloadingID == comp.id || isQueued(comp.id) { return }
        if downloadingID != nil {
            downloadQueue.append(.component(comp))
            lastAction = .ok("\(comp.title) queued — starts when the current download finishes.")
            return
        }
        startDownload(comp)
    }

    /// True while a component is waiting in the download queue (not yet started).
    func isQueued(_ id: String) -> Bool { downloadQueue.contains { $0.id == id } }

    /// Drop a not-yet-started download from the queue.
    func removeFromQueue(_ id: String) { downloadQueue.removeAll { $0.id == id } }

    /// Start the next queued download when the active slot frees up. Handles either kind.
    private func startNextInQueue() {
        guard downloadingID == nil, !downloadQueue.isEmpty else { return }
        switch downloadQueue.removeFirst() {
        case .component(let c): startDownload(c)
        case .aux(let a):       startAuxDownload(a)
        }
    }

    private func startDownload(_ comp: ComponentInfo) {
        // Pre-flight 1: a gated download without a token fails minutes in with a raw HTTP error.
        if comp.isGated, hfToken.trimmingCharacters(in: .whitespaces).isEmpty {
            lastAction = .error("\(comp.title) is gated — paste your HuggingFace token above and accept the model license on its HuggingFace page first.")
            startNextInQueue()   // skip this one, try the next queued
            return
        }
        // Pre-flight 2: don't start a multi-GB download that's guaranteed to fill the disk
        // (component size + a few GB headroom). Re-checked per item, since a queue eats space.
        let needed = Int64(comp.sizeGB + 3) * SystemRAM.bytesPerGiB
        if let free = Self.freeDiskBytes(), free < needed {
            lastAction = .error("Not enough disk space: \(comp.title) needs ~\(ByteFormat.string(needed)) free (download + headroom), only \(ByteFormat.string(free)) available.")
            startNextInQueue()
            return
        }
        // Clear stale message BEFORE the token-save step so a Keychain failure raised below survives.
        lastAction = nil
        if comp.isGated, !hfToken.isEmpty {
            if HFToken.save(hfToken) {
                tokenSaved = true
            } else {
                lastAction = .error("Couldn't save the token to the Keychain — using it for this download only.")
            }
        }
        downloadingID = comp.id
        downloadProgress = 0
        downloadMessage = "Preparing…"
        let token = comp.isGated ? (hfToken.isEmpty ? nil : hfToken) : nil
        let kind = comp.kind
        let title = comp.title
        let rawTag = comp.rawTag

        downloadTask = Task { @MainActor in
            do {
                try await store.download(kind: kind, hfToken: token) { p, m in
                    Task { @MainActor in
                        self.downloadProgress = p
                        self.downloadMessage = m
                    }
                }
                // Integrity pin for community transformer repos (seconds, streaming SHA-256).
                // Verify BEFORE honoring a cancel: a cancel landing between download and verify
                // must not leave an UNVERIFIED-but-complete transformer the generate path loads
                // unchecked. No-ops for unpinned variants (only klein4B-8bit is pinned).
                if case .transformer(let v) = kind {
                    self.downloadMessage = "Verifying file integrity…"
                    try await store.verifyTransformerIntegrity(variant: v)
                }
                self.lastAction = .ok("\(title) downloaded.")
                AppLog.info("Component downloaded: \(rawTag)")
            } catch {
                // URLSession surfaces cancellation as URLError(.cancelled), not CancellationError.
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self.lastAction = .ok("Download cancelled. Already-fetched files are reused next time.")
                    AppLog.info("Component download cancelled: \(rawTag)")
                } else {
                    self.lastAction = .error("Download error: \(error.localizedDescription)")
                    AppLog.error("Component download: \(error.localizedDescription)")
                }
            }
            self.downloadingID = nil
            self.downloadTask = nil
            await self.refreshCatalog()
            self.onModelStateChange?()
            self.startNextInQueue()   // chain the next queued download, if any
        }
    }

    /// Abort the in-flight download (the Task cancellation propagates into URLSession).
    func cancelDownload() {
        guard downloadTask != nil else { return }
        downloadMessage = "Cancelling…"
        downloadTask?.cancel()
    }

    /// Public entry for a shared component (the Describe / Auto-caption VLM): download now if the slot
    /// is free, otherwise QUEUE it — same as tier components. Shares the single download slot + progress
    /// UI, so it shows the same progress bar and Cancel.
    func downloadAux(_ comp: AuxComponent) {
        guard comp.downloadable else { return }
        guard !importing else {
            lastAction = .error("Can't download — wait for the import to finish."); return
        }
        if downloadingID == comp.id || isQueued(comp.id) { return }
        if downloadingID != nil {
            downloadQueue.append(.aux(comp))
            lastAction = .ok("\(comp.title) queued — starts when the current download finishes.")
            return
        }
        startAuxDownload(comp)
    }

    private func startAuxDownload(_ comp: AuxComponent) {
        let needed = Int64(comp.sizeGB + 3) * SystemRAM.bytesPerGiB
        if let free = Self.freeDiskBytes(), free < needed {
            lastAction = .error("Not enough disk space: \(comp.title) needs ~\(ByteFormat.string(needed)) free, only \(ByteFormat.string(free)) available.")
            startNextInQueue()   // skip this one, try the next queued
            return
        }
        lastAction = nil
        downloadingID = comp.id
        downloadProgress = 0
        downloadMessage = "Preparing…"
        let title = comp.title
        let id = comp.id
        downloadTask = Task { @MainActor in
            do {
                try await store.downloadAux(id: id) { p, m in
                    Task { @MainActor in self.downloadProgress = p; self.downloadMessage = m }
                }
                self.lastAction = .ok("\(title) downloaded.")
                AppLog.info("Aux component downloaded: \(title)")
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self.lastAction = .ok("Download cancelled. Already-fetched files are reused next time.")
                } else {
                    self.lastAction = .error("Download error: \(error.localizedDescription)")
                    AppLog.error("Aux download: \(error.localizedDescription)")
                }
            }
            self.downloadingID = nil
            self.downloadTask = nil
            self.auxComponents = await store.auxComponents()
            self.onModelStateChange?()
            self.startNextInQueue()
        }
    }

    /// Switch which downloaded VLM quantization Describe / Auto-caption use.
    func setActiveVLM(_ comp: AuxComponent) {
        Task { @MainActor in
            await store.setActiveVLM(id: comp.id)
            self.auxComponents = await store.auxComponents()
            self.lastAction = .ok("\(comp.title) is now used for Describe & Auto-caption.")
            self.onModelStateChange?()
        }
    }

    // MARK: Delete

    /// The Klein tier a component's weights serve, for the queue-reference warning. Dev
    /// variants (.bf16/.qint8) aren't exposed by any tier the app ships — nil, no warning.
    private static func tier(of kind: ComponentKind) -> ModelTier? {
        switch kind {
        case .transformer(let v):
            switch v {
            case .klein4B_8bit, .klein4B_bf16: return .klein4B
            case .klein9B_bf16, .klein9B_kv_bf16: return .klein9B
            // Base (non-distilled) weights exist ONLY for LoRA training — queued RENDERS never
            // load them, so warning "queued renders still use this model" there would be false.
            case .klein4B_base_bf16, .klein9B_base_bf16: return nil
            case .bf16, .qint8: return nil
            }
        case .encoder(let v):
            // The encoder families are tier-bound: Qwen3 4B ↔ Klein 4B, Qwen3 8B ↔ Klein 9B.
            // Explicit cases, no string sniffing — "qwen3-4b-8bit" contains "8b" too.
            switch v {
            case .qwen3_4B_8bit, .qwen3_4B_4bit: return .klein4B
            case .qwen3_8B_8bit, .qwen3_8B_4bit: return .klein9B
            }
        }
    }

    /// Extra line for the delete-confirmation dialog when the composed render queue still
    /// references this component's tier (wired from GenerateViewModel via `queueUsesTier`).
    func deleteQueueWarning(for comp: ComponentInfo) -> String? {
        guard let tier = Self.tier(of: comp.kind), queueUsesTier?(tier) == true else { return nil }
        return "Queued renders still use this model — they'll fail or re-download it."
    }

    func delete(_ comp: ComponentInfo) {
        Task { @MainActor in
            if self.downloadingID == comp.id {
                self.lastAction = .error("Can't delete — this one is downloading now. Cancel the download first.")
                return
            }
            guard !self.importing else {
                self.lastAction = .error("Can't delete — wait for the import to finish.")
                return
            }
            // A generation/cold-load in flight may be reading these files (loadedTier still nil
            // during the load), so block on the real busy signal.
            if await engine.isWorking {
                self.lastAction = .error("Can't delete — the engine is busy. Try again in a moment.")
                return
            }
            if await engine.loadedTier != nil {
                self.lastAction = .error("Can't delete — a model is in memory. Unload it first (System tab).")
                return
            }
            // TOCTOU re-check: the engine guards above are actor hops — the MainActor was free
            // while they suspended, so the user could have STARTED (or queued) a download for
            // this very id in the gap; the stale pass below would then delete the directory
            // under the live stream. Re-validate on the near side of the store call.
            if self.downloadingID == comp.id || self.isQueued(comp.id) {
                self.lastAction = .error("Can't delete — this one is downloading now. Cancel the download first.")
                return
            }
            do {
                if let freed = try await store.delete(kind: comp.kind) {
                    self.lastAction = .ok("\(comp.title) deleted — freed \(ByteFormat.string(freed)).")
                } else {
                    self.lastAction = .ok("\(comp.title): link removed — the original files were not touched.")
                }
                AppLog.info("Component deleted: \(comp.rawTag)")
            } catch {
                self.lastAction = .error("Delete error: \(error.localizedDescription)")
            }
            await self.refreshCatalog()
            self.onModelStateChange?()
        }
    }

    /// Delete a NOT-downloaded component's partial residue (cancelled download `.part`s kept
    /// for resume). Milder guards than delete(): the engine never loads a non-downloaded
    /// component that's already resident, but it CAN be lazily downloading one mid-generation —
    /// hence the isWorking check; and deleting the dir under our own active download for this
    /// very id would corrupt the stream — hence the downloadingID check.
    func deletePartial(_ comp: ComponentInfo) {
        Task { @MainActor in
            if self.downloadingID == comp.id {
                self.lastAction = .error("Can't delete — this one is downloading now. Cancel the download first.")
                return
            }
            guard !self.importing else {
                self.lastAction = .error("Can't delete — wait for the import to finish.")
                return
            }
            if await engine.isWorking {
                self.lastAction = .error("Can't delete — the engine is busy. Try again in a moment.")
                return
            }
            // TOCTOU re-check after the engine.isWorking suspension — a download for this id
            // started meanwhile would have its .part stream deleted from under it (see delete()).
            if self.downloadingID == comp.id || self.isQueued(comp.id) {
                self.lastAction = .error("Can't delete — this one is downloading now. Cancel the download first.")
                return
            }
            do {
                let freed = try await store.deletePartial(kind: comp.kind)
                self.lastAction = .ok("Partial download of \(comp.title) deleted — freed \(ByteFormat.string(freed)). The next download starts from the beginning.")
                AppLog.info("Partial download deleted: \(comp.rawTag) (\(ByteFormat.string(freed)))")
            } catch {
                self.lastAction = .error("Delete error: \(error.localizedDescription)")
            }
            await self.refreshCatalog()
        }
    }

    func deleteAux(_ comp: AuxComponent) {
        Task { @MainActor in
            guard downloadingID != comp.id else {
                self.lastAction = .error("Can't delete — this one is downloading now. Cancel the download first.")
                return
            }
            guard !importing else {
                self.lastAction = .error("Can't delete — wait for the import to finish.")
                return
            }
            if await engine.isWorking {
                self.lastAction = .error("Can't delete — the engine is busy. Try again in a moment.")
                return
            }
            if await engine.loadedTier != nil {
                self.lastAction = .error("Can't delete — a model is in memory. Unload it first.")
                return
            }
            // TOCTOU re-check after the engine actor hops — same reasoning as delete().
            if self.downloadingID == comp.id || self.isQueued(comp.id) {
                self.lastAction = .error("Can't delete — this one is downloading now. Cancel the download first.")
                return
            }
            do {
                if let freed = try await store.deleteAux(comp.id) {
                    self.lastAction = .ok("\(comp.title) deleted — freed \(ByteFormat.string(freed)).")
                } else {
                    self.lastAction = .ok("\(comp.title): link removed — the original files were not touched.")
                }
                AppLog.info("Component deleted: \(comp.title)")
            } catch {
                self.lastAction = .error("Delete error: \(error.localizedDescription)")
            }
            self.auxComponents = await store.auxComponents()
            self.onModelStateChange?()
        }
    }

    /// Delete a shared (aux) component's PARTIAL residue — a cancelled Qwen3.5-VLM download
    /// leaves GBs in Models/<repo> that read as "not downloaded" (the engine's completeness
    /// check fails), so the row used to show "~3 GB", no size, no delete: invisible AND
    /// unreclaimable. Mirrors deletePartial(): milder guards than deleteAux — no loadedTier
    /// gate (a resident Klein tier never reads VLM files), but isWorking still blocks
    /// (Describe/Auto-caption can be lazily RE-downloading this very repo mid-flight).
    func deleteAuxPartial(_ comp: AuxComponent) {
        Task { @MainActor in
            if self.downloadingID == comp.id {
                self.lastAction = .error("Can't delete — this one is downloading now. Cancel the download first.")
                return
            }
            guard !self.importing else {
                self.lastAction = .error("Can't delete — wait for the import to finish.")
                return
            }
            if await engine.isWorking {
                self.lastAction = .error("Can't delete — the engine is busy. Try again in a moment.")
                return
            }
            // TOCTOU re-check after the engine.isWorking suspension — same reasoning as delete().
            if self.downloadingID == comp.id || self.isQueued(comp.id) {
                self.lastAction = .error("Can't delete — this one is downloading now. Cancel the download first.")
                return
            }
            do {
                // deleteAux removes the whole component dir regardless of completeness —
                // exactly what "delete the partial residue" needs (nil = symlink import).
                if let freed = try await store.deleteAux(comp.id) {
                    self.lastAction = .ok("Partial download of \(comp.title) deleted — freed \(ByteFormat.string(freed)). The next download starts from the beginning.")
                    AppLog.info("Aux partial download deleted: \(comp.title) (\(ByteFormat.string(freed)))")
                } else {
                    self.lastAction = .ok("\(comp.title): link removed — the original files were not touched.")
                }
            } catch {
                self.lastAction = .error("Delete error: \(error.localizedDescription)")
            }
            self.auxComponents = await store.auxComponents()
            self.onModelStateChange?()
        }
    }

    // (The old unload() lived here — dead code with ZERO call sites; System tab unloads via
    // SystemViewModel.freeMemory(). Removed rather than left to drift out of sync with it.)

    // MARK: Import existing weights

    /// Survives the dialog binding flipping to false — confirmationDialog clears isPresented
    /// (which nils pendingImport) BEFORE running the chosen button's action.
    @ObservationIgnored private var stagedImport: [FoundComponent] = []

    func pickAndScanImportFolder() {
        guard !importing else { return }
        guard downloadingID == nil else {
            lastAction = .error("Can't import while a download is running — wait for it to finish.")
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a folder with MLX model weights (the model directory itself, or a parent that contains several)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true
        Task { @MainActor in
            let found = await Task.detached(priority: .userInitiated) {
                ModelImportService.scan(folder: url)
            }.value
            self.importing = false
            if found.isEmpty {
                self.lastAction = .error("No MLX components recognized in \u{201C}\(url.lastPathComponent)\u{201D} — the folder must contain complete MLX-format weights (config.json or model_index.json inside). ComfyUI single-file checkpoints are not supported.")
            } else {
                self.stagedImport = found
                self.pendingImport = found
            }
        }
    }

    func cancelImport() {
        pendingImport = nil
        stagedImport = []
    }

    func performImport(mode: ImportMode) {
        let items = pendingImport ?? stagedImport
        pendingImport = nil
        stagedImport = []
        guard !items.isEmpty, !importing else { return }
        guard downloadingID == nil else {
            lastAction = .error("Can't import while a download is running — wait for it to finish.")
            return
        }
        let todo = items.filter { !$0.alreadyInstalled }
        guard !todo.isEmpty else {
            lastAction = .ok("Nothing to import — every found component is already installed.")
            return
        }
        importing = true
        lastAction = nil
        Task { @MainActor in
            let (okCount, failures) = await Task.detached(priority: .userInitiated) { () -> (Int, [String]) in
                var ok = 0
                var fails: [String] = []
                for item in todo {
                    do {
                        try ModelImportService.install(item, mode: mode)
                        ok += 1
                    } catch {
                        fails.append("\(item.component.displayName): \(error.localizedDescription)")
                    }
                }
                return (ok, fails)
            }.value
            let skipped = items.count - todo.count
            let verb = mode == .copy ? "copied" : "linked"
            if failures.isEmpty {
                var text = "Imported \(okCount) component\(okCount == 1 ? "" : "s") (\(verb))."
                if skipped > 0 { text += " Skipped \(skipped) already installed." }
                self.lastAction = .ok(text)
                AppLog.info("Weights import: \(okCount) \(verb), \(skipped) skipped")
            } else {
                self.lastAction = .error("Import finished with errors — \(okCount) ok, \(failures.count) failed. \(failures.joined(separator: " "))")
                AppLog.error("Weights import: \(failures.joined(separator: "; "))")
            }
            self.importing = false
            await self.refreshCatalog()
            self.onModelStateChange?()
        }
    }

    // MARK: Token

    func persistToken() {
        let ok = HFToken.save(hfToken)  // Keychain, not plaintext UserDefaults
        tokenSaved = hasToken && ok     // empty save = delete (always succeeds)
        if !hasToken {
            lastAction = .ok("Token removed.")
        } else if ok {
            lastAction = .ok("Token saved to the Keychain.")
        } else {
            lastAction = .error("Couldn't save the token to the Keychain — please try again.")
        }
    }

    // MARK: Free space

    /// Free space the way Finder counts it (importantUsage = purgeable space macOS frees on demand;
    /// plain capacity under-reports by tens of GB when Time Machine snapshots exist). nil = couldn't
    /// stat; don't block on that.
    private static func freeDiskBytes() -> Int64? {
        let values = try? AppPaths.models.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: Storage locations (clear)

    /// The shared HF cache root (other tools use it too) — kept for display/reference;
    /// deletion is always scoped to this app's entries via MaintenanceService.
    static var hfCacheURL: URL { MaintenanceService.hfCacheRoot }

    func clearHFCache() {
        Task { @MainActor in
            guard downloadingID == nil else {
                self.lastAction = .error("Can't clear the cache while a download is running.")
                return
            }
            // Scoped wipe: only the `hub/models--…` entries this app's engine can have created.
            // ~/.cache/huggingface is SHARED with every other HF tool on this Mac — the old
            // code removed the entire tree and cost other apps their caches. Runs off the
            // main actor (a multi-GB walk + delete).
            let result = await Task.detached(priority: .userInitiated) {
                MaintenanceService.clearAppHFCacheEntries()
            }.value
            if result.failures.isEmpty {
                self.lastAction = .ok("Cleared this app's HuggingFace cache entries — freed \(ByteFormat.string(result.freed)).")
                AppLog.info("HuggingFace cache (app entries) cleared: \(ByteFormat.string(result.freed))")
            } else {
                // Failures were AppLog.error'd with paths inside clearAppHFCacheEntries.
                self.lastAction = .error("Cleared \(ByteFormat.string(result.freed)), but \(result.failures.count) cache entr\(result.failures.count == 1 ? "y" : "ies") couldn't be deleted — see the log (System tab).")
            }
            self.hfCacheBytes = await Task.detached(priority: .utility) {
                MaintenanceService.appHFCacheBytes()
            }.value
            // The legacy hub cache is a VALID model location (the engine's findModelPath falls
            // back to it) — weights that only lived there were just deleted, so without this
            // refresh the rows keep claiming "on disk" until the next tab switch, and the
            // header model chip stays stale too.
            await self.refreshCatalog()
            self.onModelStateChange?()
        }
    }
}
