import Foundation
import MLX
import Flux2Core
import FluxTextEncoders

/// Logs + cache cleanup. Never touches the Models directory (that is the Model-management
/// feature's job) so a cache-clear can't cost a multi-GB re-download.
enum MaintenanceService {
    /// Clear the app log file. Returns bytes freed AND bytes still on disk afterwards.
    static func clearLogs() -> (freed: Int64, remaining: Int64) {
        AppLog.shared.clear()
    }

    /// Clear caches (everything under AppPaths.caches) + the MLX GPU buffer pool.
    /// Returns bytes freed on disk plus the item names that could NOT be deleted (each is
    /// AppLog.error'd) — the UI must not report a clean clear over a locked/undeletable item.
    static func clearCaches() -> (freed: Int64, failures: [String]) {
        let fm = FileManager.default
        var freed: Int64 = 0
        var failures: [String] = []
        if let items = try? fm.contentsOfDirectory(at: AppPaths.caches, includingPropertiesForKeys: nil) {
            for item in items {
                let sz = directorySize(item)
                // Count bytes as freed ONLY when the remove actually succeeds — a locked/undeletable
                // file must not be reported as reclaimed (matches clearLogs' honest accounting).
                do { try fm.removeItem(at: item); freed += sz }
                catch {
                    AppLog.error("Clear caches: couldn't delete \(item.lastPathComponent): \(error.localizedDescription)")
                    failures.append(item.lastPathComponent)
                }
            }
        }
        return (freed, failures)   // NB: the MLX pool is flushed separately via clearMLXPool(), re-gated on idle.
    }

    /// Flush the MLX GPU buffer pool. Kept OUT of clearCaches()/removeAllData() (which run their
    /// file walk off-actor) so the caller can re-check "not busy" right before it — flushing the
    /// pool while a generation is in flight could corrupt its GPU buffers (a TOCTOU race).
    static func clearMLXPool() { Memory.clearCache() }

    // MARK: Hugging Face cache (scoped to THIS app's entries)

    /// The SHARED Hugging Face cache root — the hf CLI, Python tools and other MLX apps store
    /// their downloads here too, so the app must NEVER wipe this tree wholesale (it used to,
    /// costing other apps their multi-GB caches).
    static var hfCacheRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface", isDirectory: true)
    }

    /// Every HuggingFace repo id this app can EVER pull, enumerated from the engine's own
    /// registries (Flux transformers, the shared VAE, Mistral + Qwen3 / Qwen3-VL / Qwen3.5
    /// encoders/VLMs) — so a new engine variant is covered automatically, with no string list
    /// here to drift. These are the only `hub/models--…` entries we may delete.
    static func appHubRepoIds() -> Set<String> {
        var ids = Set<String>()
        ids.formUnion(ModelRegistry.TransformerVariant.allCases.map(\.huggingFaceRepo))
        ids.formUnion(ModelRegistry.TextEncoderVariant.allCases.map(\.huggingFaceRepo))
        ids.formUnion(ModelRegistry.VAEVariant.allCases.map(\.huggingFaceRepo))
        ids.formUnion(Qwen3Variant.allCases.map(\.repoId))
        ids.formUnion(Qwen3VLVariant.allCases.map(\.repoId))
        ids.formUnion(Qwen35Variant.allCases.map(\.repoId))
        return ids
    }

    /// THIS app's existing entries in the shared cache: `hub/models--{org}--{repo}` (the
    /// huggingface_hub layout the engine's HubApi/HubCache writes) plus the matching
    /// `hub/.locks/…` dir, for each known repo id. Anything we can't positively attribute to
    /// this app — other tools' models, the CLI token, xet chunk caches — is left in place;
    /// the user-facing copy says "this app's entries" accordingly.
    static func appHFCacheEntryURLs() -> [URL] {
        let fm = FileManager.default
        let hub = hfCacheRoot.appendingPathComponent("hub", isDirectory: true)
        var out: [URL] = []
        for repo in appHubRepoIds().sorted() {   // sorted → deterministic logs
            let entry = "models--" + repo.replacingOccurrences(of: "/", with: "--")
            for url in [hub.appendingPathComponent(entry, isDirectory: true),
                        hub.appendingPathComponent(".locks", isDirectory: true)
                           .appendingPathComponent(entry, isDirectory: true)]
            where fm.fileExists(atPath: url.path) {
                out.append(url)
            }
        }
        return out
    }

    /// Total bytes of this app's HF-cache entries — drives the Models tab storage row
    /// (which therefore counts ONLY what "Clear" would actually delete).
    static func appHFCacheBytes() -> Int64 {
        appHFCacheEntryURLs().reduce(Int64(0)) { $0 + directorySize($1) }
    }

    /// Delete this app's HF-cache entries (and nothing else in the shared tree).
    /// Returns bytes actually freed + the paths that couldn't be deleted (each logged).
    static func clearAppHFCacheEntries() -> (freed: Int64, failures: [String]) {
        let fm = FileManager.default
        var freed: Int64 = 0
        var failures: [String] = []
        for url in appHFCacheEntryURLs() {
            let sz = directorySize(url)
            do { try fm.removeItem(at: url); freed += sz }
            catch {
                AppLog.error("HF cache: couldn't delete \(url.path): \(error.localizedDescription)")
                failures.append(url.path)
            }
        }
        return (freed, failures)
    }

    // MARK: Remove all data

    /// Outcome of `removeAllData()` — honest accounting behind the "nothing is left behind"
    /// claim: bytes actually freed, plus every target that could NOT be deleted (each one was
    /// AppLog.error'd with its underlying error) so the UI can say so instead of lying.
    struct RemovalReport: Sendable {
        var freed: Int64 = 0
        var failures: [String] = []
    }

    /// Nuke EVERY trace of the app's data on disk — models + encoders, gallery images, LoRAs,
    /// presets, caches, logs, AND this app's own entries in the shared HuggingFace download
    /// cache (scoped by repo id — ~/.cache/huggingface is shared with other HF tools on this
    /// Mac, whose files are deliberately left alone). For the user to run BEFORE trashing the
    /// .app, since macOS can't clean a trashed app's files. Returns bytes freed plus the
    /// targets that couldn't be deleted, so the caller can report a partial wipe honestly.
    static func removeAllData() -> RemovalReport {
        let fm = FileManager.default
        let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let bid = "com.personal.typhoonminigen"
        var targets: [URL] = [
            AppPaths.appSupport,                                        // Models, Images, LoRAs, generations.json, presets
            AppPaths.caches,                                            // thumbnails
            lib.appendingPathComponent("Logs/Typhoonminigen", isDirectory: true),
            lib.appendingPathComponent("Caches/\(bid)", isDirectory: true),
            lib.appendingPathComponent("HTTPStorages/\(bid)", isDirectory: true),
        ]
        // Scoped, NOT the whole ~/.cache/huggingface — other apps share that tree.
        targets += appHFCacheEntryURLs()
        var report = RemovalReport()
        var seen = Set<String>()
        for url in targets where seen.insert(url.standardizedFileURL.path).inserted {
            guard fm.fileExists(atPath: url.path) else { continue }
            let sz = directorySize(url)
            // Count bytes only when the remove actually succeeds — don't bill a tree as "freed"
            // (and claim "nothing is left behind") if the delete failed. The failure is logged
            // AND returned: the System tab tells the user "N items couldn't be deleted — see
            // the log", and this error line is that log entry.
            do { try fm.removeItem(at: url); report.freed += sz }
            catch {
                AppLog.error("Remove all data: couldn't delete \(url.path): \(error.localizedDescription)")
                report.failures.append(url.path)
            }
        }
        // The Keychain HF token + ALL the app's UserDefaults are NOT files — they survive a disk
        // wipe, so "Remove all data" (sold as a clean uninstall: "nothing is left behind") must
        // clear the secret credential AND every stored setting/flag, not just the legacy token key.
        HFToken.delete()
        // Clear the WHOLE settings domain. Fall back to the hardcoded bundle id when
        // Bundle.main.bundleIdentifier is nil (a non-bundled `swift run` dev binary) so even a dev
        // run wipes everything, not just the legacy token key.
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? bid)
        // No Memory.clearCache() here: the caller (SystemViewModel.removeAllData) already unloaded the
        // model via engine.freeMemory(), which flushed the pool while holding the engine actor.
        return report
    }

    // MARK: Launch temp-residue sweep

    /// How old a crash temp must be before the sweep may delete it — a user relaunching out of
    /// a crash-loop could have an import/bake temp that is seconds old and about to be retried.
    private static let crashTempMaxAge: TimeInterval = 60 * 60           // 1 hour
    /// `.url-import` staging holds resumable `.part` downloads — keep those for two weeks
    /// before deciding nobody is ever going to resume them.
    private static let stagingMaxAge: TimeInterval = 14 * 24 * 60 * 60   // 14 days

    /// Sweep crash/quit residue that NO other code path cleans (run at launch, when none of
    /// the producers can be mid-write — mirrors the CFNetworkDownload sweep in
    /// TyphoonminigenApp.applicationDidFinishLaunching):
    ///  • `LoRAs/.import-<UUID>.tmp`  — LoRAStore.importLoRA's copy-then-swap temp
    ///  • `LoRAs/.tmp-<UUID>-…`       — SafetensorsInspector.saveViaTemp bake/merge temps
    ///  • `Training/Runs/smoke`       — TrainingService.smokeRun's throwaway dir (deleted on
    ///    every normal exit; only a crash/force-quit strands it — can be GBs of latents)
    ///  • `LoRAs/.url-import/*`       — URL-import staging: stale-empty dirs, plus dirs whose
    ///    newest content is older than the resume-retention window
    /// All of these are dot-prefixed / internal, so they're invisible in the app AND in Finder.
    /// Safety rules: exact name patterns only, everything age-gated, symlinks never followed
    /// (attributesOfItem doesn't resolve links; the enumerator doesn't descend into them).
    /// Silent — one AppLog.info only when something was actually freed.
    static func sweepTempResidue() {
        let fm = FileManager.default
        let now = Date()
        var freed: Int64 = 0

        /// Newest modification date of the item and (for a real directory) everything under
        /// it, without following symlinks. nil = couldn't stat → treated as recent, kept.
        func newestWrite(_ url: URL) -> Date? {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }
            var newest = (attrs[.modificationDate] as? Date) ?? .distantPast
            if attrs[.type] as? FileAttributeType == .typeDirectory,
               let en = fm.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey]) {
                for case let f as URL in en {
                    if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                       d > newest { newest = d }
                }
            }
            return newest
        }

        func isOlder(_ url: URL, than age: TimeInterval) -> Bool {
            guard let newest = newestWrite(url) else { return false }
            return now.timeIntervalSince(newest) > age
        }

        func remove(_ url: URL) {
            let sz = directorySize(url)
            do { try fm.removeItem(at: url); freed += sz } catch { /* in use or gone — leave it */ }
        }

        // LoRA-folder crash temps. Both patterns are dot-prefixed → LoRAStore.discover never
        // sees them, so without this they'd sit there forever.
        if let items = try? fm.contentsOfDirectory(at: AppPaths.loras, includingPropertiesForKeys: nil) {
            for f in items {
                let name = f.lastPathComponent
                let isImportTmp = name.hasPrefix(".import-") && name.hasSuffix(".tmp")
                let isEditTmp = name.hasPrefix(".tmp-")      // .tmp-<UUID>-<destName>
                guard isImportTmp || isEditTmp, isOlder(f, than: crashTempMaxAge) else { continue }
                remove(f)
            }
        }

        // Stranded smoke-run dir. Age-gated like the rest for consistency (nothing can be
        // smoke-running seconds after launch, but the stat is cheap and the rule is uniform).
        let smoke = AppPaths.trainingRunsDir.appendingPathComponent("smoke", isDirectory: true)
        if fm.fileExists(atPath: smoke.path), isOlder(smoke, than: crashTempMaxAge) {
            remove(smoke)
        }

        // URL-import staging: an EMPTY per-repo dir has nothing to resume (gate it on the
        // short age anyway, in case a sweep ever runs concurrently with a starting download);
        // a dir with content survives until its newest `.part` write is past retention.
        let staging = AppPaths.loras.appendingPathComponent(".url-import", isDirectory: true)
        if let dirs = try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
            for dir in dirs {
                guard (try? fm.attributesOfItem(atPath: dir.path))?[.type] as? FileAttributeType == .typeDirectory
                else { continue }
                let isEmpty = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? ["…"]).isEmpty
                if isOlder(dir, than: isEmpty ? crashTempMaxAge : stagingMaxAge) {
                    remove(dir)
                }
            }
            // Drop the empty root too — frees ~nothing, so it isn't counted.
            if ((try? fm.contentsOfDirectory(atPath: staging.path)) ?? ["…"]).isEmpty {
                try? fm.removeItem(at: staging)
            }
        }

        if freed > 0 { AppLog.info("Removed stale temp residue: \(ByteFormat.string(freed))") }
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        if let en = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
            for case let f as URL in en {
                let sz = (try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
                total += Int64(sz)
            }
        }
        if total == 0 {
            let sz = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(sz)
        }
        return total
    }
}
