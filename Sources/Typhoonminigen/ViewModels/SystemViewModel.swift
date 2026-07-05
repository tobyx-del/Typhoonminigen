import SwiftUI
import Observation
import AppKit

@MainActor
@Observable
final class SystemViewModel {
    let telemetry: TelemetryService     // shared, app-lifetime (status bar + rail also read it)
    var logLines: [String] = []
    var lastAction: ActionMessage? = nil

    private let engine: FluxEngine
    private let store: GenerationStore   // wiped by removeAllData so the gallery keeps no "missing" ghosts
    // C-5: injected by TyphoonminigenApp so clearCaches() can guard against mid-gen calls
    @ObservationIgnored var isBusyProvider: (() -> Bool)?
    /// Fired after freeMemory() so the header model chip re-syncs immediately.
    @ObservationIgnored var onModelStateChange: (() -> Void)? = nil
    /// Fired after removeAllData() clears the gallery store so the Gallery view refreshes to empty.
    @ObservationIgnored var onDataRemoved: (() -> Void)? = nil
    /// Arms AppDelegate's quit-confirm bypass (wired in TyphoonminigenApp.wireQuitGuard) —
    /// called right before removeAllData()'s self-initiated terminate so the quit-guard modal
    /// can't re-interrogate the user over freshly-wiped state.
    @ObservationIgnored var bypassQuitGuard: (() -> Void)? = nil

    init(engine: FluxEngine, telemetry: TelemetryService, store: GenerationStore) {
        self.engine = engine
        self.telemetry = telemetry
        self.store = store
    }

    func onAppear() {
        telemetry.start()   // idempotent; the shared sampler is already running
        refreshLogs()
    }

    /// Telemetry intentionally keeps sampling after leaving the System screen — the bottom
    /// status bar and the Generation rail rely on it everywhere.
    func onDisappear() {}

    func refreshLogs() {
        logLines = Array(AppLog.shared.recent().suffix(200).reversed())
    }

    func clearLogs() {
        let result = MaintenanceService.clearLogs()
        refreshLogs()
        if result.remaining == 0 {
            lastAction = .ok("Logs cleared — freed \(ByteFormat.string(result.freed)) (0 bytes left).")
        } else {
            // These logs hold seeds / file names / LoRA names — don't claim erasure that didn't happen.
            lastAction = .error("Logs only partially cleared — \(ByteFormat.string(result.remaining)) still on disk. Try again.")
        }
    }

    func clearCaches() {
        // C-5: clearing the MLX buffer pool during generation can corrupt in-flight GPU buffers
        if isBusyProvider?() == true {
            lastAction = .error("Busy — a render, describe, download, import or upscale is running. Try again when it finishes.")
            return
        }
        lastAction = .ok("Clearing cache…")
        Task { @MainActor in
            // Walk + delete the caches tree OFF the main actor so the window doesn't beachball.
            let result = await Task.detached(priority: .userInitiated) { MaintenanceService.clearCaches() }.value
            // Re-gate the GPU-pool flush: the FS walk ran off-actor, so a generation could have begun
            // in the gap. Only flush if still idle (closes the TOCTOU window that v0.63 opened).
            if isBusyProvider?() != true { MaintenanceService.clearMLXPool() }
            // Don't report a clean clear over a locked/undeletable item — every failure was
            // already AppLog.error'd by MaintenanceService, so "see the log" actually works.
            if result.failures.isEmpty {
                lastAction = .ok(result.freed > 0
                    ? "Cache cleared — freed \(ByteFormat.string(result.freed))."
                    : "Cache already empty — 0 bytes.")
            } else {
                lastAction = .error("Cache partially cleared — freed \(ByteFormat.string(result.freed)), \(result.failures.count) item\(result.failures.count == 1 ? "" : "s") couldn't be deleted (see the log below).")
            }
            AppLog.info("Cache cleared: \(ByteFormat.string(result.freed))"
                        + (result.failures.isEmpty ? "" : " (\(result.failures.count) failed)"))
            refreshLogs()
        }
    }

    /// Repair Library: reconcile the gallery index with the images folder (adopt recipe-bearing
    /// strays, quarantine unreadable ones, prune dead records). Safe while idle only — a render
    /// mid-save could race the scan.
    func repairLibrary() {
        if isBusyProvider?() == true {
            lastAction = .error("Busy — a render, describe, download, import or upscale is running. Try again when it finishes.")
            return
        }
        lastAction = .ok("Repairing library…")
        Task { @MainActor in
            let r = await store.repairLibrary()
            onDataRemoved?()   // reload the gallery view from the repaired index
            if r.adopted == 0, r.quarantined == 0, r.pruned == 0 {
                lastAction = .ok("Library is already in sync — nothing to repair.")
            } else {
                var parts: [String] = []
                if r.adopted > 0 { parts.append("\(r.adopted) image\(r.adopted == 1 ? "" : "s") adopted from their embedded recipes") }
                if r.pruned > 0 { parts.append("\(r.pruned) dead record\(r.pruned == 1 ? "" : "s") removed") }
                if r.quarantined > 0 { parts.append("\(r.quarantined) file\(r.quarantined == 1 ? "" : "s") without a recipe moved to Images/Quarantine") }
                lastAction = .ok("Repaired — " + parts.joined(separator: ", ") + ".")
            }
            refreshLogs()
        }
    }

    func freeMemory() {
        Task { @MainActor in
            let freed = await engine.freeMemory()
            if freed {
                AppLog.info("Model unloaded from memory (System)")
                lastAction = .ok("Model unloaded from memory.")
            } else {
                lastAction = .error("The model is in use (a render or describe is running) — try again when it finishes.")
            }
            refreshLogs()
            onModelStateChange?()
        }
    }

    /// Delete EVERYTHING the app stored (System "Remove all data…") — for use right before
    /// trashing the .app. Unloads any resident model first, then wipes all data + this app's
    /// entries in the shared HuggingFace cache (other tools' cache entries are left alone).
    func removeAllData() {
        if isBusyProvider?() == true {
            lastAction = .error("Busy — a render, describe, download, import or upscale is running. Try again when it finishes.")
            return
        }
        Task { @MainActor in
            // Unload any resident model so nothing is mid-read. `false` means the engine latch
            // is HELD — a render/describe/cold load slipped in between the isBusyProvider check
            // above and this suspension point (the check itself can't see a cold load that
            // started this instant). Proceeding would wipe the Models tree under an in-flight
            // read; the old `_ =` discard did exactly that. Bail honestly instead.
            let unloaded = await engine.freeMemory()
            if !unloaded, isBusyProvider?() == true {
                lastAction = .error("Busy — a render, describe or model load started just now. Nothing was deleted; try again when it finishes.")
                return
            }
            // Walk + delete the multi-GB Models/HF-cache tree OFF the main actor (it used to
            // beachball the window for seconds-to-minutes).
            let report = await Task.detached(priority: .userInitiated) { MaintenanceService.removeAllData() }.value
            // Disk is wiped; now clear the in-memory gallery + rewrite a clean empty index so the
            // Gallery shows 0 (not N "missing" ghosts) and a later save can still persist.
            await store.reset()
            // Also drop the in-memory custom-preset state (its JSON + UserDefaults were just wiped)
            // so the live UI can't keep showing — or re-persisting — chips that no longer exist.
            CustomPresetStore.shared.reset()
            // Same for the Library delete/restore state + the user's own cards (their JSON + the
            // hidden-id UserDefaults keys were just wiped) so the live UI can't resurrect them.
            LibraryVisibilityStore.shared.reset()
            CustomRecipeStore.shared.reset()
            CustomStudioStore.shared.reset()
            onDataRemoved?()
            AppLog.info("Removed ALL app data — freed \(ByteFormat.string(report.freed))"
                        + (report.failures.isEmpty ? "" : " (\(report.failures.count) target(s) failed)"))
            // Honest outcome: a partial wipe must not be sold as "nothing is left behind".
            // Each failed path was AppLog.error'd inside removeAllData — the in-app log below
            // (fed from the in-memory buffer) still shows them even though the log FILE was
            // part of the wipe.
            if report.failures.isEmpty {
                lastAction = .ok("Removed all models & data — freed \(ByteFormat.string(report.freed)). Quitting now so nothing is left behind — then drag the app to the Trash.")
            } else {
                lastAction = .error("Removed \(ByteFormat.string(report.freed)) — \(report.failures.count) item\(report.failures.count == 1 ? "" : "s") couldn't be deleted (see the log below). Quitting anyway — check those paths before trashing the app.")
            }
            onModelStateChange?()
            refreshLogs()
            // Purge the settings domain LAST. MaintenanceService already removed it, but the resets
            // above (CustomPresetStore etc.) write defaults AFTER that — and a write after
            // removePersistentDomain flushes cfprefsd's cached pre-wipe dictionary back to disk,
            // resurrecting old flags (live-tested: hasSeenTutorial survived the wipe, so the welcome
            // tour never re-showed on fresh data). Removing key-by-key also scrubs the in-process
            // cache so nothing can bring the old values back before we quit.
            let domain = Bundle.main.bundleIdentifier ?? "com.personal.typhoonminigen"
            let std = UserDefaults.standard
            std.persistentDomain(forName: domain)?.keys.forEach { std.removeObject(forKey: $0) }
            std.removePersistentDomain(forName: domain)
            // Quit after a moment (so the message is readable): any in-memory @AppStorage value would
            // otherwise re-write the just-cleared settings domain on the next interaction, leaving
            // stale flags behind — contradicting "nothing is left behind". A partial wipe gets a
            // longer beat: the failure message (and the log lines behind it) need to be readable.
            let delay: TimeInterval = report.failures.isEmpty ? 1.6 : 4.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                // Arm the bypass at the LAST moment (not when scheduling): the quit-guard
                // modal must never appear over the wiped app, but a manual quit during the
                // delay window still goes through the normal guard until this fires.
                self?.bypassQuitGuard?()
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
