import SwiftUI
import Observation
import AppKit

@MainActor
@Observable
final class LoRAViewModel {
    var items: [LoRAItem] = []
    var lastAction: ActionMessage? = nil

    /// CONTRACT (wired in the App to GenerateViewModel): does any PENDING queue item still
    /// reference this adapter file name? Deleting the .safetensors doesn't touch the queue —
    /// those renders fail at start when the engine can't find the file — so the delete
    /// confirmation (LoRAView) extends its message when this returns true. nil until wired;
    /// callers treat nil as "unknown → no extra warning".
    var queueUsesAdapter: ((String) -> Bool)? = nil

    /// A bake/merge tensor pass is running (buttons disable; the files are MBs, so it's brief).
    var editBusy = false

    // URL import (Hugging Face) — sheet state.
    var urlRepoID = ""
    var urlRevision = "main"
    var urlFiles: [ResumableDownloader.RemoteFile] = []
    var urlBusy = false                    // listing or pre-flight check in flight
    var urlDownloading = false
    var urlProgress: Double = 0
    var urlStatus: String? = nil           // info/error line inside the sheet
    var urlStatusIsError = false
    var urlCheck: RemoteCheck? = nil       // pre-flight verdict for the clicked file
    private var urlTask: Task<Void, Never>?
    /// Generation counter for the URL-import sheet. Cancellation is COOPERATIVE: a cancelled
    /// listing/preflight suspended in a URLSession await unwinds AFTER its replacement started,
    /// and its late writes (defer'd urlBusy=false, error text, a stale urlCheck) used to land
    /// on top of the replacement's live state. Every started task captures the counter and
    /// checks `run == urlRun` before each state write; only the newest owner may write.
    private var urlRun = 0

    /// Pre-flight result: the remote file's header inspected BEFORE the big download.
    struct RemoteCheck: Sendable {
        let path: String
        let inspection: LoRAInspection
    }

    private let store: LoRAStore
    private var reloadTask: Task<Void, Never>?
    init(store: LoRAStore) { self.store = store }

    /// Stored HF token (env → Keychain). The accessor is tier-gated; 9B is the gated tier.
    private var hfToken: String? { HFToken.current(for: .klein9B) }

    func reload() {
        // Cancel a prior reload so an older discover() snapshot can't land after a newer one
        // (reload fires on appear and can overlap an import/delete). [weak self] = no retain cycle.
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let items = await self.store.discover()
            guard !Task.isCancelled else { return }
            self.items = items
        }
    }

    func importLoRA() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose a .safetensors LoRA file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importLoRA(from: url)
    }

    /// Import from a concrete URL — used by both the file picker and drag-and-drop.
    func importLoRA(from url: URL) {
        guard url.pathExtension.lowercased() == "safetensors" else {
            lastAction = .error("A .safetensors file is required")
            return
        }
        Task { @MainActor in
            do {
                let item = try await store.importLoRA(from: url, provenance: "Imported manually")
                lastAction = item.isCompatible
                    ? .ok("Imported: \(item.fileName) — \(item.note)")
                    : .error("Imported, but \(item.note)")
                AppLog.info("LoRA imported: \(item.fileName) (\(item.note))")
            } catch {
                lastAction = .error("Import error: \(error.localizedDescription)")
            }
            reload()   // refresh via the single cancellable slot so an older discover() snapshot can't land late
        }
    }

    func delete(_ item: LoRAItem) {
        Task { @MainActor in
            do {
                try await store.delete(item)
                lastAction = .ok("Deleted: \(item.fileName)")
                AppLog.info("LoRA deleted: \(item.fileName)")
            } catch {
                lastAction = .error("Couldn't delete \(item.fileName): \(error.localizedDescription)")
                AppLog.error("LoRA delete failed: \(error.localizedDescription)")
            }
            reload()   // refresh via the single cancellable slot so an older discover() snapshot can't land late
        }
    }

    func setTrigger(_ trigger: String, for item: LoRAItem) {
        Task { @MainActor in
            let cleared = trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let ok = await store.setTrigger(trigger, forFileName: item.fileName)
            reload()   // refresh via the single cancellable slot so an older discover() snapshot can't land late
            if ok {
                lastAction = .ok(cleared ? "Trigger cleared for \(item.fileName)"
                                         : "Trigger saved for \(item.fileName)")
            } else {
                lastAction = .error("Couldn't save the trigger for \(item.fileName) — please try again.")
            }
        }
    }

    /// Reveal the adapter's `.safetensors` file in Finder.
    func revealInFinder(_ item: LoRAItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    /// Copy this LoRA's trigger word to the clipboard (reports if it has none).
    func copyTrigger(_ item: LoRAItem) {
        let t = item.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            lastAction = .error("\(item.fileName) has no trigger word to copy.")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
        lastAction = .ok("Copied trigger: \(t)")
    }

    // MARK: Identity card (description / default strength)

    /// Save (or clear, if empty) the free-text description on the adapter's card.
    func setAbout(_ text: String, for item: LoRAItem) {
        Task { @MainActor in
            let cleared = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let ok = await store.setAbout(text, forFileName: item.fileName)
            reload()   // refresh via the single cancellable slot so an older discover() snapshot can't land late
            lastAction = ok
                ? .ok(cleared ? "Description cleared for \(item.fileName)"
                              : "Description saved for \(item.fileName)")
                : .error("Couldn't save the description for \(item.fileName) — please try again.")
        }
    }

    /// Save (or clear, if empty) the default strength Generate pre-selects on MANUAL add —
    /// recipe/remix restores keep their recorded scales (GenerateViewModel.applyLoRAUses).
    func setDefaultScale(_ text: String, for item: LoRAItem) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        if t.isEmpty {
            Task { @MainActor in
                let ok = await store.setDefaultScale(nil, forFileName: item.fileName)
                reload()
                lastAction = ok ? .ok("Default strength cleared — \(item.fileName) adds at 1.00 again.")
                                : .error("Couldn't update \(item.fileName)'s default strength — please try again.")
            }
            return
        }
        guard let v = Float(t), v > 0, v <= 1.5 else {
            lastAction = .error("Default strength must be a number between 0 and 1.5 (e.g. 0.8).")
            return
        }
        Task { @MainActor in
            let ok = await store.setDefaultScale(v, forFileName: item.fileName)
            reload()
            lastAction = ok ? .ok(String(format: "\u{201C}%@\u{201D} now defaults to strength %.2f.", item.fileName, v))
                            : .error("Couldn't update \(item.fileName)'s default strength — please try again.")
        }
    }

    // MARK: Model card export

    /// Write a shareable package folder: the .safetensors + card.html + the validation images
    /// snapshotted at publish time — everything a stranger (or future you on a fresh Mac) needs
    /// to use the adapter correctly. Only offered for adapters that have a model card.
    func exportPackage(_ item: LoRAItem) {
        guard let card = ModelCardStore.load(forLibraryFile: item.fileName) else {
            lastAction = .error("\(item.fileName) has no model card — cards are created when a training checkpoint is published.")
            return
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = String(item.fileName.dropLast(".safetensors".count)) + "-package"
        panel.message = "A folder is created with the adapter, card.html and its validation images"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let adapterURL = item.url
        let adapterName = item.fileName
        let cardDir = ModelCardStore.dir(forLibraryFile: item.fileName)
        let scale = item.defaultScale
        Task { @MainActor in
            do {
                try await Task.detached(priority: .userInitiated) {
                    let fm = FileManager.default
                    try? fm.removeItem(at: dest)   // the save panel already confirmed the replace
                    try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                    try fm.copyItem(at: adapterURL, to: dest.appendingPathComponent(adapterName))
                    for entry in card.validation {
                        let src = cardDir.appendingPathComponent(entry.fileName)
                        guard fm.fileExists(atPath: src.path) else { continue }
                        try? fm.copyItem(at: src, to: dest.appendingPathComponent(entry.fileName))
                    }
                    let html = ModelCardStore.html(for: card, recommendedScale: scale)
                    try Data(html.utf8).write(to: dest.appendingPathComponent("card.html"), options: .atomic)
                }.value
                lastAction = .ok("Exported “\(dest.lastPathComponent)” — adapter, card.html and \(card.validation.count) validation image\(card.validation.count == 1 ? "" : "s").")
                NSWorkspace.shared.activateFileViewerSelecting([dest])
                AppLog.info("LoRA package exported: \(dest.lastPathComponent)")
            } catch {
                lastAction = .error("Export failed: \(error.localizedDescription)")
                AppLog.error("LoRA package export failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: File toolbox (bake / merge)

    /// Write a rescaled COPY whose strength 1.00 matches this adapter at `strength` —
    /// makes a sweet spot (e.g. 0.8) permanent and portable. The original is never touched.
    func bake(_ item: LoRAItem, strength: Float) {
        let s = min(max(strength, 0.05), 1.5)
        guard abs(s - 1.0) > 0.004 else {
            lastAction = .error("1.00 is already neutral — enter the strength that actually looks right (e.g. 0.8).")
            return
        }
        guard !editBusy else { return }
        let stem = String(item.fileName.dropLast(".safetensors".count))
        let newName = uniqueLoRAName(String(format: "%@-x%.2f", stem, s))
        editBusy = true
        Task { @MainActor in
            defer { editBusy = false }
            do {
                let dest = AppPaths.loras.appendingPathComponent(newName)
                try await SafetensorsInspector.bakeStrength(s, from: item.url, to: dest)
                if !item.trigger.isEmpty { _ = await store.setTrigger(item.trigger, forFileName: newName) }
                _ = await store.annotate(fileName: newName,
                                         about: item.about.isEmpty ? nil : item.about,
                                         provenance: String(format: "Baked ×%.2f from %@", s, item.fileName))
                lastAction = .ok(String(format: "Baked: %@ — strength 1.00 now matches %@ at %.2f.",
                                        newName, item.fileName, s))
                AppLog.info("LoRA baked: \(newName) (×\(String(format: "%.2f", s)) from \(item.fileName))")
            } catch {
                lastAction = .error("Bake failed: \(error.localizedDescription)")
                AppLog.error("LoRA bake failed: \(error.localizedDescription)")
            }
            reload()
        }
    }

    /// Merge 2+ same-tier adapters (each at its chosen strength) into ONE portable file —
    /// checkpoint averaging (1/n each) or flattening a tuned stack. Sources are never touched.
    func merge(_ selections: [(item: LoRAItem, scale: Float)], outputName: String) {
        guard selections.count >= 2 else {
            lastAction = .error("Select at least two adapters to merge.")
            return
        }
        if let bad = selections.first(where: { !$0.item.isCompatible }) {
            lastAction = .error("\(bad.item.fileName) can't be merged — \(bad.item.note).")
            return
        }
        let tiers = Set(selections.compactMap { $0.item.tier })
        guard tiers.count == 1, let tier = tiers.first else {
            lastAction = .error("All merged adapters must target the same Klein tier — 9B (dim 4096) and 4B (dim 3072) weights can't be combined.")
            return
        }
        // Sanitize: no path separators, and no leading dot (dot-files are invisible to discover).
        var cleaned = outputName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        guard !cleaned.isEmpty, cleaned != "safetensors" else {
            lastAction = .error("Give the merged file a name.")
            return
        }
        guard !editBusy else { return }
        let newName = uniqueLoRAName(cleaned)
        let recipe = selections.map { String(format: "%@ \u{00D7}%.2f", $0.item.fileName, $0.scale) }
            .joined(separator: " + ")
        // Carry every distinct trigger over so the merged stack still activates all its parts.
        var seen = Set<String>()
        let trigger = selections.compactMap { sel -> String? in
            let t = sel.item.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty || !seen.insert(t.lowercased()).inserted ? nil : t
        }.joined(separator: ", ")
        var extra = SafetensorsInspector.publishMetadata(
            trigger: trigger, tier: tier, outputName: String(newName.dropLast(".safetensors".count)))
        extra["tm_merged_from"] = recipe
        let sources = selections.map { (url: $0.item.url, scale: $0.scale) }
        editBusy = true
        Task { @MainActor in
            defer { editBusy = false }
            do {
                let dest = AppPaths.loras.appendingPathComponent(newName)
                let rank = try await SafetensorsInspector.mergeAdapters(sources, to: dest, extraMetadata: extra)
                if !trigger.isEmpty { _ = await store.setTrigger(trigger, forFileName: newName) }
                _ = await store.annotate(fileName: newName, provenance: "Merged: \(recipe) (rank \(rank))")
                lastAction = .ok("Merged \(selections.count) adapters into \(newName) (rank \(rank)).")
                AppLog.info("LoRA merged: \(newName) ← \(recipe)")
            } catch {
                lastAction = .error("Merge failed: \(error.localizedDescription)")
                AppLog.error("LoRA merge failed: \(error.localizedDescription)")
            }
            reload()
        }
    }

    /// Next free filename in the LoRA folder ("name.safetensors", "name-2.safetensors", …) —
    /// edits always produce a NEW file, never overwrite an existing adapter.
    private func uniqueLoRAName(_ base: String) -> String {
        var name = base.hasSuffix(".safetensors") ? base : base + ".safetensors"
        let stem = String(name.dropLast(".safetensors".count))
        var n = 2
        while FileManager.default.fileExists(atPath: AppPaths.loras.appendingPathComponent(name).path) {
            name = "\(stem)-\(n).safetensors"
            n += 1
        }
        return name
    }

    // MARK: Import from a Hugging Face URL

    /// Accepts "owner/repo", a huggingface.co repo page URL, or a direct file URL
    /// (/blob/ or /resolve/). Returns repo id + revision + the file path when given directly.
    nonisolated static func parseHFInput(_ raw: String) -> (repo: String, revision: String, filePath: String?)? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let q = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<q]) }
        if s.contains("://") {
            guard let url = URL(string: s), let host = url.host?.lowercased(),
                  host == "huggingface.co" || host == "www.huggingface.co" || host == "hf.co" else { return nil }
            var comps = url.path.split(separator: "/").map(String.init)
            guard comps.count >= 2, comps[0] != "datasets", comps[0] != "spaces" else { return nil }
            let repo = comps[0] + "/" + comps[1]
            comps.removeFirst(2)
            if comps.count >= 2, comps[0] == "resolve" || comps[0] == "blob" {
                let rest = comps.dropFirst(2).joined(separator: "/")
                return (repo, comps[1], rest.isEmpty ? nil : rest)
            }
            if comps.count >= 2, comps[0] == "tree" { return (repo, comps[1], nil) }
            return (repo, "main", nil)
        }
        let parts = s.split(separator: "/").map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (s, "main", nil)
    }

    /// List the repo's .safetensors files (root of the tree; direct file links skip the listing).
    func fetchRemoteList(_ input: String) {
        guard !urlDownloading else { return }
        guard let parsed = Self.parseHFInput(input) else {
            urlStatus = "Paste an owner/repo id or a huggingface.co link."
            urlStatusIsError = true
            return
        }
        urlRepoID = parsed.repo
        urlRevision = parsed.revision
        urlFiles = []
        urlCheck = nil
        urlStatusIsError = false
        urlBusy = true
        urlStatus = "Fetching file list…"
        urlTask?.cancel()          // cancel FIRST so the old task can't race the state below
        urlRun += 1
        let run = urlRun
        urlTask = Task { @MainActor in
            // A superseded task must NOT clear the flag — its replacement set urlBusy=true and
            // owns it now (the old defer used to blank the flag under a live successor).
            defer { if run == urlRun { urlBusy = false } }
            // Superseded before this task even got scheduled (rapid double-submit): bail before
            // the pre-await status writes below can clobber the successor's.
            guard run == urlRun else { return }
            do {
                if let direct = parsed.filePath {
                    guard direct.lowercased().hasSuffix(".safetensors") else {
                        urlStatus = "That link points to \((direct as NSString).lastPathComponent) — a .safetensors file is required."
                        urlStatusIsError = true
                        return
                    }
                    // Size lookup is best-effort (the tree API lists one folder level).
                    let folder = (direct as NSString).deletingLastPathComponent
                    let listed = (try? await ResumableDownloader.listFiles(
                        repoId: parsed.repo, revision: parsed.revision,
                        subfolder: folder.isEmpty ? nil : folder, token: hfToken)) ?? []
                    guard run == urlRun else { return }   // superseded while awaiting — don't write
                    let size = listed.first(where: { $0.path == direct })?.size ?? 0
                    urlFiles = [ResumableDownloader.RemoteFile(path: direct, size: size)]
                } else {
                    let all = try await ResumableDownloader.listFiles(
                        repoId: parsed.repo, revision: parsed.revision, subfolder: nil, token: hfToken)
                    guard run == urlRun else { return }   // superseded while awaiting — don't write
                    urlFiles = all.filter { $0.path.lowercased().hasSuffix(".safetensors") }
                    guard !urlFiles.isEmpty else {
                        urlStatus = "No .safetensors files at the top level of \(parsed.repo)."
                        urlStatusIsError = true
                        return
                    }
                }
                urlStatus = urlFiles.count == 1
                    ? "1 file — it's checked for compatibility before anything downloads."
                    : "\(urlFiles.count) files — click one to check compatibility before downloading."
                // One candidate: run the pre-flight right away, no extra click (same task —
                // spawning preflightRemote here would cancel this very task mid-flight).
                if urlFiles.count == 1 { await runPreflight(urlFiles[0], run: run) }
            } catch is CancellationError {
            } catch {
                guard run == urlRun else { return }   // stale error must not clobber the successor's status
                urlStatus = error.localizedDescription
                urlStatusIsError = true
            }
        }
    }

    /// Pre-flight compatibility gate: range-fetch JUST the safetensors header and run the same
    /// inspection as drag-drop import — an incompatible file is rejected BEFORE the download.
    func preflightRemote(_ file: ResumableDownloader.RemoteFile) {
        guard !urlDownloading else { return }
        urlTask?.cancel()          // cancel FIRST so the old task can't race the state below
        urlRun += 1
        let run = urlRun
        urlBusy = true
        urlTask = Task { @MainActor in
            // Superseded → the replacement owns urlBusy; clearing it here blanked the busy gate
            // under a live successor (letting a second request start mid-flight).
            defer { if run == urlRun { urlBusy = false } }
            await runPreflight(file, run: run)
        }
    }

    /// `run`: the caller's identity token — every write is guarded so a preflight that lost the
    /// race (user clicked another file / pressed Download / re-fetched) can't paint stale state.
    private func runPreflight(_ file: ResumableDownloader.RemoteFile, run: Int) async {
        guard run == urlRun else { return }
        urlCheck = nil
        urlStatusIsError = false
        urlStatus = "Checking \((file.path as NSString).lastPathComponent)…"
        do {
            let header = try await ResumableDownloader.fetchSafetensorsHeader(
                repoId: urlRepoID, revision: urlRevision, filePath: file.path, token: hfToken)
            guard run == urlRun else { return }   // superseded while awaiting — a late verdict/status is a lie
            urlCheck = RemoteCheck(path: file.path, inspection: SafetensorsInspector.inspect(headerData: header))
            urlStatus = nil   // the sheet renders the verdict from urlCheck
        } catch is CancellationError {
        } catch {
            guard run == urlRun else { return }
            urlStatus = error.localizedDescription
            urlStatusIsError = true
        }
    }

    /// Download the pre-flight-approved file (resumable) and register it in the library.
    func downloadRemote() {
        guard let check = urlCheck, check.inspection.tier != nil, !urlDownloading else { return }
        let path = check.path
        let repo = urlRepoID
        let revision = urlRevision
        let size = urlFiles.first(where: { $0.path == path })?.size ?? 0
        // Cancel any in-flight listing/preflight FIRST — an orphaned preflight's late
        // urlStatus/urlCheck write used to land mid-download and blank the progress line.
        urlTask?.cancel()
        urlRun += 1
        let run = urlRun
        // The superseded preflight's defer no longer owns urlBusy (run mismatch) — reset it
        // here or the sheet stays stuck "busy" for the whole download.
        urlBusy = false
        urlDownloading = true
        urlProgress = 0
        urlStatusIsError = false
        urlStatus = "Starting download…"
        urlTask = Task { @MainActor in
            defer { if run == urlRun { urlDownloading = false } }
            // Hidden staging dir inside the LoRA folder (dot-prefixed → invisible to discover);
            // `.part` files persist here, so a cancelled download resumes on the next attempt.
            // Staged PER repo+revision: the downloader keys artifacts by basename and resumes any
            // leftover `.part` — with one shared folder, repo A's cancelled half of
            // "lora.safetensors" would get repo B's tail appended (a silently corrupt adapter).
            let staging = AppPaths.loras.appendingPathComponent(".url-import", isDirectory: true)
                .appendingPathComponent(Self.stagingKey(repo: repo, revision: revision), isDirectory: true)
            do {
                let fileURL = try await ResumableDownloader.downloadSingleFile(
                    repoId: repo, revision: revision, filePath: path,
                    expectedSize: size, destDir: staging, token: hfToken
                ) { p, m in
                    Task { @MainActor in
                        // run check + downloading check: a stale tick (or a tick from a download
                        // whose sheet state was superseded) must not overwrite the
                        // cancel/error/success line.
                        guard run == self.urlRun, self.urlDownloading else { return }
                        self.urlProgress = p
                        self.urlStatus = m
                    }
                }
                // Never silently replace an existing library adapter: HF repos overwhelmingly name
                // their file "lora.safetensors"/"pytorch_lora_weights.safetensors", and importLoRA's
                // replace path permanently wipes the old adapter + its trigger/strength/cards.
                var importURL = fileURL
                let unique = uniqueLoRAName(fileURL.lastPathComponent)
                if unique != fileURL.lastPathComponent {
                    let renamed = fileURL.deletingLastPathComponent().appendingPathComponent(unique)
                    try? FileManager.default.removeItem(at: renamed)
                    try FileManager.default.moveItem(at: fileURL, to: renamed)
                    importURL = renamed
                }
                let item = try await store.importLoRA(from: importURL, provenance: "Hugging Face: \(repo)")
                try? FileManager.default.removeItem(at: importURL)
                // The staging dir has served its purpose — sweep now-empty per-repo dirs (and
                // the `.url-import` root when it empties out) so finished imports stop accreting
                // invisible dot-dirs forever. Abandoned staging with stale `.part`s nobody ever
                // resumes is aged out by the launch sweep (MaintenanceService.sweepTempResidue).
                Task.detached(priority: .utility) { Self.sweepEmptyURLImportStaging() }
                // lastAction/log always report the import (it DID land in the library);
                // sheet-local status is identity-guarded like every other urlTask write.
                lastAction = item.isCompatible
                    ? .ok("Imported from \(repo): \(item.fileName) — \(item.note)")
                    : .error("Imported, but \(item.note)")
                AppLog.info("LoRA imported from HF: \(item.fileName) (\(repo))")
                guard run == urlRun else { reload(); return }   // stale sheet writes forbidden; still refresh the list
                urlProgress = 1
                // Leave the outcome IN the sheet too — lastAction renders behind it, and a blank
                // status here made a finished download look like it never happened.
                urlStatus = item.isCompatible
                    ? "Imported “\(item.fileName)” to your library."
                    : "Imported “\(item.fileName)”, but \(item.note)"
                urlStatusIsError = !item.isCompatible
            } catch {
                guard run == urlRun else { reload(); return }   // stale writes forbidden; still refresh the list
                // URLSession surfaces cancellation as URLError(.cancelled), not CancellationError.
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    urlStatus = "Cancelled — fetched bytes are kept, the download resumes if you try again."
                    urlStatusIsError = false
                } else {
                    urlStatus = error.localizedDescription
                    urlStatusIsError = true
                    AppLog.error("LoRA URL import: \(error.localizedDescription)")
                }
            }
            reload()
        }
    }

    /// Filesystem-safe staging subfolder for one repo+revision — a cancelled download from repo A
    /// must never be resumed with repo B's bytes just because the basenames match.
    nonisolated static func stagingKey(repo: String, revision: String) -> String {
        String("\(repo)@\(revision)".map {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "-"
        })
    }

    /// Delete EMPTY per-repo staging dirs under `LoRAs/.url-import` (and the root itself once
    /// it's empty). Empty ONLY — a dir still holding a `.part`/`.chunks` is a resumable
    /// download and must survive. These dirs are dot-prefixed (invisible to LoRAStore.discover
    /// and to Finder), so nothing else would ever clean them. Never follows symlinks:
    /// attributesOfItem doesn't resolve links, and only genuinely empty dirs are removed.
    nonisolated static func sweepEmptyURLImportStaging() {
        let fm = FileManager.default
        let root = AppPaths.loras.appendingPathComponent(".url-import", isDirectory: true)
        guard let subdirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for dir in subdirs {
            guard (try? fm.attributesOfItem(atPath: dir.path))?[.type] as? FileAttributeType == .typeDirectory,
                  ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? ["…"]).isEmpty else { continue }
            try? fm.removeItem(at: dir)
        }
        if ((try? fm.contentsOfDirectory(atPath: root.path)) ?? ["…"]).isEmpty {
            try? fm.removeItem(at: root)
        }
    }

    /// Abort the in-flight listing / check / download (partial `.part` data is kept for resume).
    func cancelURLImport() {
        urlTask?.cancel()
    }

    /// Clear the sheet state on open so a stale listing from last time doesn't show.
    func resetURLImport() {
        guard !urlDownloading, !urlBusy else { return }
        urlFiles = []
        urlCheck = nil
        urlStatus = nil
        urlStatusIsError = false
        urlProgress = 0
    }
}
