import SwiftUI
import AppKit
import Flux2Core
import FluxTextEncoders

@main
struct TyphoonminigenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var generateVM: GenerateViewModel
    @State private var galleryVM: GalleryViewModel
    @State private var modelsVM: ModelsViewModel
    @State private var loraVM: LoRAViewModel
    @State private var trainingVM: TrainingViewModel
    @State private var systemVM: SystemViewModel

    @State private var telemetry: TelemetryService
    @State private var sessionStats: SessionStats

    init() {
        let engine = FluxEngine()
        let store = GenerationStore()       // shared: Generate saves into it, Gallery reads it
        let loraStore = LoRAStore()         // shared: LoRA tab manages, Generate picks
        let trainingStore = TrainingStore() // LoRA-training workshops + runs
        let telemetry = TelemetryService()  // shared: status bar + rail + System screen
        let stats = SessionStats()
        let gvm = GenerateViewModel(engine: engine, store: store, loraStore: loraStore, sessionStats: stats)
        let svm = SystemViewModel(engine: engine, telemetry: telemetry, store: store)
        let mvm = ModelsViewModel(engine: engine)
        let lvm = LoRAViewModel(store: loraStore)
        let tvm = TrainingViewModel(store: trainingStore, engine: engine, loraStore: loraStore)
        // C-5: SystemViewModel needs to know if a generation OR a VLM describe is in flight
        // before clearing the MLX cache (both hold the global pool).
        // Also block while a model download/import is in flight: removeAllData/clearCaches delete
        // the Models tree the downloader is still writing into (the quit-guard already checks these).
        // A LoRA training also holds the global MLX pool — never clear the cache under it.
        svm.isBusyProvider = { [weak gvm, weak mvm, weak tvm, weak lvm] in
            (gvm?.isBusy ?? false) || (gvm?.isDescribing ?? false)
            // queueRunning: between queue items isBusy flickers false — a wipe/cache-clear
            // landing in that gap would run under a queue that immediately resumes rendering.
            || (gvm?.queueRunning ?? false)
            || (mvm?.downloadingID != nil) || (mvm?.importing ?? false)
            || (tvm?.isTrainingActive ?? false)
            // Caption jobs and smoke runs hold the engine latch and the MLX pool just like a full
            // training; a forge is mid-write in the Training tree removeAllData would delete.
            || (tvm?.captioning ?? false) || (tvm?.smokeRunning ?? false) || (tvm?.forging ?? false)
            // LoRA URL-import streams into LoRAs/.url-import, and a bake/merge is mid-write of
            // a new adapter file — both trees are exactly what removeAllData deletes.
            || (lvm?.urlDownloading ?? false) || (lvm?.editBusy ?? false)
            || UpscaleService.isBusy
        }
        // Cross-queue handoff: "Run all" during a training arms the generation queue; the trainer
        // pings back the moment its runs/queue/captioning are all idle and the queue auto-starts.
        gvm.isTrainingBusy = { [weak tvm] in !(tvm?.fullyIdle ?? true) }
        tvm.onFullyIdle = { [weak gvm] in gvm?.trainingDidBecomeIdle() }
        // Reverse handoff: the engine latch is exclusive, so a queued training/caption job bails
        // (re-queued at the head) when Describe/Ask/Compare hold it — re-drain when they finish.
        gvm.onDescribeIdle = { [weak tvm] in tvm?.generationDescribeDidEnd() }
        // …and the same re-drain when a generation queue ends: a training/caption job queued
        // while a render ran would otherwise stall at the trainer's queue head forever.
        gvm.onGenerationIdle = { [weak tvm] in tvm?.generationQueueDidEnd() }
        // …and the forward guard for the same seam: between two queue items the engine latch is
        // briefly open — the trainer must PARK there, not claim (it would burn the rest of the
        // render queue and evict the model mid-run).
        tvm.generationQueueBusy = { [weak gvm] in gvm?.queueRunning ?? false }
        // The header model chip reads GenerateViewModel — re-sync it the moment the
        // Models/System tabs unload, download, or delete a model.
        let syncChip: () -> Void = { [weak gvm] in Task { @MainActor in await gvm?.syncModelState() } }
        mvm.onModelStateChange = syncChip
        svm.onModelStateChange = syncChip
        // Deleting a model/adapter the composed queue still references deserves a warning, not silence.
        mvm.queueUsesTier = { [weak gvm] tier in gvm?.queuedItemsReference(tier: tier) ?? false }
        lvm.queueUsesAdapter = { [weak gvm] name in gvm?.queuedItemsReference(loraFileName: name) ?? false }
        // Created early so System's "Remove all data" can refresh it to empty after wiping the store.
        let gallery = GalleryViewModel(store: store)
        svm.onDataRemoved = { [weak gallery] in gallery?.reload() }
        _generateVM = State(initialValue: gvm)
        _galleryVM = State(initialValue: gallery)
        _modelsVM = State(initialValue: mvm)
        _loraVM = State(initialValue: lvm)
        _trainingVM = State(initialValue: tvm)
        _systemVM = State(initialValue: svm)
        _telemetry = State(initialValue: telemetry)
        _sessionStats = State(initialValue: stats)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(generateVM: generateVM, galleryVM: galleryVM,
                        modelsVM: modelsVM, loraVM: loraVM, trainingVM: trainingVM,
                        systemVM: systemVM,
                        telemetry: telemetry, sessionStats: sessionStats)
                // 1200 so the Generate screen's three columns (sidebar + 360 controls + ~300
                // canvas + 250 rail + gaps/padding ≈ 1194) never overflow at the minimum width.
                .frame(minWidth: 1200, minHeight: 720)
                .preferredColorScheme(.dark)
                .background(Color.fxBg)
                .task { wireQuitGuard() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            // Single-window app: ⌘N opened a second window that re-ran the onboarding gating
            // (duplicate Tutorial/What's-new sheets, last-writer-wins consent). Remove it.
            CommandGroup(replacing: .newItem) {}
            // The macOS menu-bar Help searched for a Help Book this app doesn't ship, so
            // "Typhoonminigen Help" opened a modal "Help isn't available" error. Drop the
            // system item — in-app help lives on the Help tab instead.
            CommandGroup(replacing: .help) {}
            // Keep the native About panel (icon + name + version), but add clickable
            // project + Ko-fi links to its credits area.
            CommandGroup(replacing: .appInfo) {
                Button("About Typhoonminigen") { showAboutPanel() }
            }
        }
    }

    /// The standard macOS About panel with a credits block holding the two links the
    /// user asked for. `.credits` takes an NSAttributedString; the `.link` attribute makes
    /// each line clickable, and `.foregroundColor` pins them to the brand amber.
    private func showAboutPanel() {
        let accent = NSColor(srgbRed: 0xD8/255.0, green: 0xA0/255.0, blue: 0x6E/255.0, alpha: 1)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = 3

        let credits = NSMutableAttributedString()
        func line(_ text: String, _ url: String, last: Bool = false) {
            credits.append(NSAttributedString(string: text, attributes: [
                .link: URL(string: url)!,
                .foregroundColor: accent,
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .paragraphStyle: para,
            ]))
            if !last { credits.append(NSAttributedString(string: "\n")) }
        }
        line("Project on GitHub", "https://github.com/abgitdev/Typhoonminigen")
        line("Support on Ko-fi", "https://ko-fi.com/abgitdev", last: true)

        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Quit-confirmation: name the work Cmd-Q would kill (it used to drop everything
    /// silently). Wired through the adaptor's instance — `NSApp.delegate` is SwiftUI's
    /// own wrapper under @NSApplicationDelegateAdaptor, so casting it to AppDelegate
    /// returns nil and the guard would be dead code.
    private func wireQuitGuard() {
        // "Remove all data" ends in a self-initiated terminate — it must skip the quit-confirm
        // modal (the guard would re-interrogate the user over freshly-wiped state, and
        // isBusyProvider reads stores that were just reset).
        systemVM.bypassQuitGuard = { [weak appDelegate] in appDelegate?.bypassNextQuitConfirmation() }
        appDelegate.busyWorkDescription = { [generateVM, modelsVM, trainingVM, loraVM] in
            if trainingVM.isTrainingActive {
                let step = trainingVM.activeRun?.runtime.currentStep ?? 0
                return "A LoRA training is running (step \(step)) — quitting now loses progress since the last checkpoint."
            }
            if trainingVM.smokeRunning {
                return "A smoke test is running — quitting now abandons it."
            }
            if trainingVM.captioning {
                return "Auto-captioning is running — finished captions are kept, the current image's is lost."
            }
            if trainingVM.forging {
                return "A dataset is being frozen for training — quitting now abandons the run being forged."
            }
            if generateVM.queueRunning || generateVM.isBusy {
                let pending = generateVM.queue.count
                return pending > 1
                    ? "A render queue is running (\(pending) items) — the work in progress will be lost."
                    : "A render is in progress — the image being made will be lost."
            }
            if modelsVM.downloadingID != nil {
                return "A model download is running — it stops if you quit (finished files are kept and reused)."
            }
            if modelsVM.importing {
                return "A weights import is in progress — quitting now can leave a half-imported model."
            }
            if loraVM.urlDownloading {
                return "An adapter download is running — it stops if you quit (partial file is kept for resume)."
            }
            if loraVM.editBusy {
                return "A LoRA bake/merge is writing a new adapter file — quitting now abandons it."
            }
            // Covers BOTH upscale entry points (canvas and gallery detail) — the child
            // process is global to the app.
            if UpscaleService.isBusy { return "An upscale is running — it will be terminated." }
            if generateVM.isDescribing { return "The AI is describing your references — the result will be lost." }
            return nil
        }
        appDelegate.installCloseGuard()
    }
}

/// Handles launch-time setup that needs AppKit / the engine.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Wired from ContentView: returns a human description of work that would be lost by
    /// quitting now (render in flight / queue / download / upscale), or nil when idle.
    var busyWorkDescription: (@MainActor () -> String?)? = nil

    /// Set just before WE trigger termination from the close-button guard, so we don't prompt twice.
    private var bypassQuitConfirm = false

    /// For SELF-INITIATED terminations outside the close-button path (SystemViewModel's
    /// "Remove all data" delayed quit): arm the same bypass so applicationShouldTerminate
    /// doesn't raise the "Quit anyway?" modal over an app whose data was just wiped — the
    /// user already confirmed the wipe, and the busy probe reads freshly-reset stores.
    @MainActor func bypassNextQuitConfirmation() { bypassQuitConfirm = true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if bypassQuitConfirm { return .terminateNow }
        guard let describe = busyWorkDescription, let work = describe() else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Typhoonminigen?"
        alert.informativeText = work
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Keep Working")   // was "Cancel" — users read that as "cancel the render"
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// Re-route the red close button so a click with work in progress confirms BEFORE the window
    /// closes. The default order closes the window first, then asks — so "Keep Working" left the
    /// app running with no visible window (it looked like it quit). Intercepting the button keeps
    /// the window open when the user declines.
    @MainActor func installCloseGuard() {
        guard let window = NSApp.windows.first(where: { $0.standardWindowButton(.closeButton) != nil }),
              let closeButton = window.standardWindowButton(.closeButton) else { return }
        closeButton.target = self
        closeButton.action = #selector(handleCloseButton(_:))
    }

    @objc @MainActor private func handleCloseButton(_ sender: NSButton) {
        guard let describe = busyWorkDescription, let work = describe() else {
            NSApp.terminate(nil)   // idle: the X quits, same as before
            return
        }
        let alert = NSAlert()
        alert.messageText = "Close Typhoonminigen?"
        alert.informativeText = work
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Keep Working")
        if alert.runModal() == .alertFirstButtonReturn {
            bypassQuitConfirm = true
            NSApp.terminate(nil)
        }
        // "Keep Working" → do nothing: the window stays open and the render keeps going.
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched from a SwiftPM executable, force a proper foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Create all storage directories.
        AppPaths.bootstrap()

        // Redirect the engine's model cache to our app folder — identical wiring to the
        // flux2 CLI (Flux2CLI.swift:15-17) — so we reuse already-downloaded weights and
        // download new ones into the right place. MUST run before any model check.
        ModelRegistry.customModelsDirectory = AppPaths.models
        TextEncoderModelDownloader.customModelsDirectory = AppPaths.models
        TextEncoderModelDownloader.reconfigureHubApi()

        // Queue-finished banners should show even when the app is frontmost.
        QueueNotifier.installDelegate()

        // Aborted multi-GB model downloads strand CFNetworkDownload_*.tmp files in the
        // container temp dir (no resume support in the engine) — reclaim them at launch.
        // Age-gated (1 h, mtime — same rule as MaintenanceService's sweeps): "no download can
        // possibly be running" only holds for THIS instance; a second running instance of the
        // app shares the container temp dir, and an ungated sweep would delete its in-flight
        // temp mid-stream. An unreadable mtime counts as recent → kept.
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(
                at: fm.temporaryDirectory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            ) else { return }
            var freed: Int64 = 0
            for f in files where f.lastPathComponent.hasPrefix("CFNetworkDownload") {
                let values = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard let mtime = values?.contentModificationDate,
                      Date().timeIntervalSince(mtime) > 3600 else { continue }
                let size = Int64(values?.fileSize ?? 0)
                do {
                    try fm.removeItem(at: f)
                    freed += size
                } catch { /* in use or gone — leave it */ }
            }
            if freed > 0 { AppLog.info("Removed stale download temps: \(ByteFormat.string(freed))") }
        }

        // Same idea for OUR OWN crash residue: stranded LoRA import/bake temps, the smoke-run
        // dir and stale .url-import staging — age-gated, exact-name-matched, symlink-safe
        // (see MaintenanceService.sweepTempResidue).
        Task.detached(priority: .utility) {
            MaintenanceService.sweepTempResidue()
        }

        AppLog.info("Typhoonminigen launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Don't orphan a GPU-heavy realesrgan child to launchd if the user quits mid-upscale.
        UpscaleService.terminateCurrent()
        // Drag promises are useless after exit; left in place, the pasteboard server tries to
        // materialize them during teardown (and logs the file's path if the image was deleted).
        NSPasteboard(name: .drag).clearContents()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
