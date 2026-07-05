import SwiftUI
import Observation
import AppKit
import CoreGraphics
import Flux2Core
import FluxTextEncoders

/// One entry in the training queue: a run draft to train, or a workshop caption job (auto-caption
/// as a queued background job). A caption job resolves its target images at START time — not at
/// enqueue — so photos added while it waited are included, and an only-missing job skips images
/// captioned in the meantime.
enum TrainingQueueItem: Identifiable, Equatable, Hashable, Sendable {
    case run(UUID)                                                   // TrainingRun.id
    case caption(jobID: UUID, workshopID: UUID, onlyMissing: Bool)   // fresh jobID minted at enqueue

    /// Stable identity for queue rows/removal: the run's own id, or the caption job's ticket.
    var id: UUID {
        switch self {
        case .run(let id):              return id
        case .caption(let jobID, _, _): return jobID
        }
    }

    var runID: UUID? {
        if case .run(let id) = self { return id }
        return nil
    }
}

/// Drives the LoRA Training screens. Wraps the `TrainingStore` actor; UI binds to
/// the `@Observable` properties. Mirrors `LoRAViewModel`'s shape (cancellable reload
/// slot, `ActionMessage` outcomes).
@MainActor
@Observable
final class TrainingViewModel {
    var workshops: [Workshop] = []
    var runs: [TrainingRun] = []
    var lastAction: ActionMessage? = nil

    // Chunk-2 smoke run (throwaway): live status + last error + an explicit running flag.
    var smoke: TrainingService.Update? = nil
    var smokeError: String? = nil
    var smokeRunning = false

    // Chunk-3 workshop editor.
    /// Which workshop is open in the editor (nil → the list). The editor reads the LIVE workshop
    /// from `workshops` by this id so it always reflects the latest persisted state.
    var selectedWorkshopID: UUID? = nil
    var importing = false                 // a file copy is in flight → disable import controls
    // Auto-caption (single-flight on the shared VLM, mutually exclusive with generation + smoke run).
    var captioning = false
    var captionStatus: String? = nil      // streamed VLM status line ("Describing image 2 of 5…")
    var captionTotal = 0
    var captionDone = 0                   // captions committed so far → the n/total progress strip
    var captioningWorkshopID: UUID? = nil // which workshop the running caption job belongs to

    // Chunk-5 live run.
    var activeRunID: UUID? = nil          // the run currently training (gates single-flight + the live screen)
    var activeRun: TrainingRun? = nil     // live in-memory copy, updated every step for the run screen
    var stopRequested = false             // Stop pressed; a graceful stop takes ~a minute (checkpoint + validation)
    var runPhaseLine: String? = nil       // pre-training phase message (Preparing… / Loading base model…)
    var isTrainingActive: Bool { activeRunID != nil }
    /// The step the CURRENT session started stepping from (0 on a fresh start, the resume
    /// checkpoint's step after Resume/Extend). `runtime.startedAt` is session-local but
    /// `currentStep` is global — the ETA must divide elapsed time by the steps done THIS
    /// session, or a resume at 280/300 shows a per-step time ~20× too big.
    var activeSessionStartStep = 0
    /// True across a run's TEARDOWN window: from the moment `finalizeState` clears `activeRunID`
    /// until the engine latch is released + the MLX pool flushed (and, in the busy-bail path,
    /// until the queue re-insert lands). Those are separated by several awaits — without this
    /// flag `fullyIdle` flips true mid-teardown, a "Run all" pressed there passes the
    /// isTrainingBusy gate, and every generation-queue item instantly fails against the
    /// still-latched engine. Included in `fullyIdle` and the start gates below.
    private var finishingRun = false

    /// The run whose live monitor (RunView) is presented as a sheet. Set it to auto-open the monitor
    /// — on forge and from the run rows — and clear it when the sheet closes. Both the list and the
    /// workshop editor bind their run sheet to this, so only the mounted one ever presents.
    var presentedRunID: UUID? = nil
    func presentRun(_ id: UUID) { presentedRunID = id }

    /// FIFO of work items (run drafts AND caption jobs) waiting to auto-start once the trainer frees
    /// up. Single-flight is preserved — only one item is active at a time; the queue just chains the
    /// next one automatically, so "caption the new photos, then start the run" works unattended.
    var queue: [TrainingQueueItem] = []

    /// Cross-queue handoff: fires whenever the trainer becomes FULLY idle (no active run, empty
    /// training queue, no captioning/smoke/forge). The generation queue arms on it (wired in
    /// TyphoonminigenApp) so "Run all" during a training starts by itself when the GPU frees.
    var onFullyIdle: (() -> Void)? = nil
    /// Wired in TyphoonminigenApp → GenerateViewModel.queueRunning. Between two queue items the
    /// engine latch is briefly OPEN (gallery save + model-state sync), so a claim would SUCCEED —
    /// evicting the model mid-queue and burning every remaining queued render as an instant
    /// .busy failure. The trainer parks instead while the queue runs; generationQueueDidEnd()
    /// re-drains the moment it truly ends.
    var generationQueueBusy: (() -> Bool)? = nil
    var fullyIdle: Bool {
        activeRunID == nil && queue.isEmpty && !captioning && !smokeRunning && !forging && !finishingRun
    }
    /// One MainActor hop later, so flags reset in `defer` blocks (captioning) are already visible.
    private func notifyIfFullyIdle() {
        Task { @MainActor [weak self] in
            guard let self, self.fullyIdle else { return }
            self.onFullyIdle?()
        }
    }

    /// Reverse handoff (wired in TyphoonminigenApp): the Generate tab's VLM (Describe/Ask/Compare)
    /// just released the engine latch. A queued training/caption job that bailed against it was
    /// re-inserted at the queue head — drain it now instead of waiting for the next trainer event.
    func generationDescribeDidEnd() {
        startNextInQueue()
        notifyIfFullyIdle()
    }

    /// Reverse handoff #2 (wired in TyphoonminigenApp): the generation queue just ended and the
    /// engine is free. Same contract as `generationDescribeDidEnd` — a queued training/caption job
    /// that bailed against the render was re-inserted at the queue head; drain it now instead of
    /// stalling until the next trainer-side event.
    func generationQueueDidEnd() {
        startNextInQueue()
        notifyIfFullyIdle()
    }

    private let store: TrainingStore
    private let engine: FluxEngine
    private let loraStore: LoRAStore     // publish a checkpoint into the shared LoRA library
    private var reloadTask: Task<Void, Never>?
    private var smokeTask: Task<Void, Never>?
    private var identitySaveTask: Task<Void, Never>?
    private var workshopMutationTask: Task<Void, Never>?   // serializes mutateWorkshop (see there)
    private var captionTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var activeSession: TrainingSession?
    private var activeObserver: RunObserver?
    private var lastEngineStatus: String?

    init(store: TrainingStore, engine: FluxEngine, loraStore: LoRAStore) {
        self.store = store
        self.engine = engine
        self.loraStore = loraStore
    }

    /// All runs forged from a given workshop (newest first).
    func runs(for workshop: Workshop) -> [TrainingRun] {
        runs.filter { $0.workshopId == workshop.id }
    }

    func reload() {
        // Single cancellable slot so an older snapshot can't land after a newer one.
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let ws = await self.store.allWorkshops()
            let rs = await self.store.allRuns()
            guard !Task.isCancelled else { return }
            self.workshops = ws
            self.runs = rs
        }
    }

    /// Create a fresh, empty workshop and persist it. (Editing UI lands in a later chunk.)
    func newWorkshop() {
        Task { @MainActor in
            // First unused "New Workshop" / "New Workshop N" — a uniqueness loop, so deleting an
            // earlier one can't make the next create collide (a count-of-matches would).
            let existing = Set(workshops.map(\.name))
            var name = "New Workshop"
            var n = 1
            while existing.contains(name) { n += 1; name = "New Workshop \(n)" }
            do {
                _ = try await store.upsert(Workshop(name: name))
                lastAction = .ok("Created “\(name)”")
            } catch {
                lastAction = .error("Couldn't create workshop: \(error.localizedDescription)")
            }
            reload()
        }
    }

    /// True while this workshop owns the live trainer work: one of its runs is the ACTIVE
    /// training, or the running caption job is writing into it. Gates deletion — the store's
    /// cascade would `removeItem(run.outputDir)` under the engine mid-write, and the next
    /// `persistActive` would then resurrect the deleted run as a ghost record.
    func workshopIsBusy(_ workshop: Workshop) -> Bool {
        if captioningWorkshopID == workshop.id { return true }
        // A forge is seconds of freezeDataset COPYING FROM this workshop's images dir — deleting
        // it mid-copy silently shrinks the frozen dataset and strands the forged draft against a
        // vanished workshop. The flag is global (one forge at a time), so this briefly blocks
        // deleting OTHER workshops too — a few seconds of over-caution beats the corruption.
        if forging { return true }
        if let a = activeRun ?? runs.first(where: { $0.id == activeRunID }) {
            return a.workshopId == workshop.id
        }
        return false
    }

    func deleteWorkshop(_ workshop: Workshop) {
        // Refuse while busy (the trash button is disabled too — this is the race-proof backstop:
        // a queued training could have STARTED between the click and this call).
        guard !workshopIsBusy(workshop) else {
            lastAction = .error("“\(workshop.name)” is busy (training or captioning) — stop that first, then delete.")
            return
        }
        // Purge queued work owned by this workshop BEFORE the cascade delete: a queued run whose
        // record just vanished would linger as a "Deleted training" queue row (or get silently
        // skipped later), and a queued caption job would resolve zero targets against nothing.
        let runIDs = Set(runs(for: workshop).map(\.id))
        queue.removeAll {
            if case .caption(_, let wid, _) = $0 { return wid == workshop.id }
            return $0.runID.map(runIDs.contains) ?? false
        }
        Task { @MainActor in
            await store.deleteWorkshop(workshop.id)
            lastAction = .ok("Deleted “\(workshop.name)”")
            reload()
        }
    }

    func deleteRun(_ run: TrainingRun) {
        // VM-level backstop mirroring the UI's disabled trash: the store cascade rm -rf's
        // outputDir, which the engine is writing into for the active run.
        guard run.id != activeRunID else {
            lastAction = .error("“\(run.name)” is training right now — stop it first, then delete.")
            return
        }
        queue.removeAll { $0.id == run.id }   // a queued run that's deleted must leave the queue too
        Task { @MainActor in
            await store.deleteRun(run.id)
            lastAction = .ok("Deleted training “\(run.name)”")
            reload()
        }
    }

    // MARK: Workshop editor (Chunk 3)

    /// The workshop currently open in the editor, resolved live from `workshops`.
    var selectedWorkshop: Workshop? {
        guard let id = selectedWorkshopID else { return nil }
        return workshops.first { $0.id == id }
    }

    func openWorkshop(_ workshop: Workshop) { selectedWorkshopID = workshop.id }

    /// Leave the editor. Any pending debounced identity save is cancelled here; the editor's
    /// `.onDisappear` commits the final field values so nothing is lost.
    func closeEditor() {
        identitySaveTask?.cancel()
        selectedWorkshopID = nil
    }

    /// Read-modify-write a workshop by id, ALWAYS overlaying onto the freshest persisted copy so
    /// concurrent edits to different fields (identity text vs. an image import vs. captions) can't
    /// clobber each other. `transform` only touches its own fields.
    ///
    /// SERIALIZED: each mutation awaits the previous one before its read. The read→transform→write
    /// cycle spans two actor hops — two tasks spawned close together (a live per-image caption
    /// commit + the identity debounce firing) would otherwise both read the same snapshot, and the
    /// second upsert would silently revert the first one's field change (lost update).
    ///
    /// `onPersistFailure` fires when the upsert throws (the store rolled the record back) — for
    /// callers whose transform has SIDE EFFECTS on disk that the rollback strands (the image
    /// import's just-copied files). Runs on the main actor, after `lastAction` is set.
    private func mutateWorkshop(_ id: UUID, onPersistFailure: (@Sendable () -> Void)? = nil,
                                _ transform: @escaping @Sendable (inout Workshop) -> Void) {
        let previous = workshopMutationTask
        workshopMutationTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            guard var w = await self.store.workshop(id) else {
                // The workshop vanished mid-flight (deleted between the call and this serialized
                // turn) — the transform's disk side effects are stranded exactly as if the upsert
                // had failed (the image import's just-copied files), so fire the same cleanup.
                onPersistFailure?()
                return
            }
            transform(&w)
            do { _ = try await self.store.upsert(w) }
            catch {
                self.lastAction = .error("Couldn't save the workshop: \(error.localizedDescription)")
                onPersistFailure?()
            }
            self.reload()
        }
    }

    // MARK: Identity

    /// Persist identity edits 400 ms after the last keystroke (smooth typing, no churn). The editor
    /// also commits immediately on close so a quick edit-then-back never gets dropped.
    func scheduleIdentitySave(id: UUID, name: String, trigger: String, description: String,
                              conceptType: ConceptType, captionInstruction: String) {
        identitySaveTask?.cancel()
        identitySaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.commitIdentity(id: id, name: name, trigger: trigger, description: description,
                                conceptType: conceptType, captionInstruction: captionInstruction)
        }
    }

    func commitIdentity(id: UUID, name: String, trigger: String, description: String,
                        conceptType: ConceptType, captionInstruction: String) {
        identitySaveTask?.cancel()
        mutateWorkshop(id) { ws in
            ws.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            ws.triggerWord = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            ws.conceptDescription = description
            ws.conceptType = conceptType
            // Empty → nil, so the concept-type preset takes over again (and switching the type
            // updates the effective instruction instead of freezing a stale default).
            let instr = captionInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
            ws.captionInstruction = instr.isEmpty ? nil : instr
        }
    }

    // MARK: Images

    /// Copy files/folders into the workshop's image folder (off-main), then append the new refs.
    func importImages(into id: UUID, urls: [URL]) {
        guard !importing, !urls.isEmpty else { return }
        guard let workshop = workshops.first(where: { $0.id == id }) else { return }
        importing = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.importing = false }
            do {
                let refs = try await Task.detached(priority: .userInitiated) {
                    try WorkshopDatasetService.importImages(urls: urls, into: workshop)
                }.value
                guard !refs.isEmpty else {
                    self.lastAction = .error("No usable images found — supported: JPEG, PNG, HEIC, WEBP, TIFF.")
                    return
                }
                // On a persist failure the store rolls the refs back — the just-copied files would
                // then be invisible orphans in the workshop folder forever. Best-effort delete by
                // the names this batch minted (never touches pre-existing images).
                let names = refs.map(\.fileName)
                self.mutateWorkshop(id, onPersistFailure: {
                    Task.detached(priority: .utility) {
                        for name in names { WorkshopDatasetService.removeImageFile(named: name, in: workshop) }
                    }
                }) { ws in ws.images.append(contentsOf: refs) }
                self.lastAction = .ok("Added \(refs.count) image\(refs.count == 1 ? "" : "s").")
            } catch {
                self.lastAction = .error("Import failed: \(error.localizedDescription)")
            }
        }
    }

    func removeImage(_ ref: TrainingImageRef, from id: UUID) {
        guard let workshop = workshops.first(where: { $0.id == id }) else { return }
        WorkshopDatasetService.removeImageFile(named: ref.fileName, in: workshop)
        mutateWorkshop(id) { ws in
            ws.images.removeAll { $0.id == ref.id }
            if ws.coverImageFileName == ref.fileName { ws.coverImageFileName = nil }
        }
    }

    func setCaption(_ text: String, for refID: UUID, in id: UUID, source: CaptionSource = .manual) {
        mutateWorkshop(id) { ws in
            guard let j = ws.images.firstIndex(where: { $0.id == refID }) else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            ws.images[j].caption = trimmed
            ws.images[j].captionSource = trimmed.isEmpty ? .none : source
        }
    }

    /// Mark/unmark an image as the workshop's reference (used for VLM session evaluation + the card cover).
    func toggleReference(_ ref: TrainingImageRef, in id: UUID) {
        mutateWorkshop(id) { ws in
            ws.coverImageFileName = (ws.coverImageFileName == ref.fileName) ? nil : ref.fileName
        }
    }

    // MARK: Caption lint (trigger word must NOT be inside captions — the engine prepends it)

    /// Word-bounded, case-insensitive test used by the workshop lint. Lookarounds instead of \b:
    /// \b needs a word-char edge, so it silently never matches a trigger that starts/ends with
    /// punctuation (the workshop gate only rejects whitespace).
    nonisolated static func captionContainsTrigger(_ caption: String, trigger: String) -> Bool {
        let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let pattern = "(?i)(?<!\\w)" + NSRegularExpression.escapedPattern(for: t) + "(?!\\w)"
        return caption.range(of: pattern, options: .regularExpression) != nil
    }

    /// One-click lint fix: remove the trigger word from every caption (word-bounded, tidies the
    /// leftover commas/spaces). ONE store write for the whole dataset, not one per image.
    /// The trigger comes from the CALLER (the editor's live field) — the stored value can lag it
    /// by the 400 ms identity-save debounce, and the lint counted against the live one.
    func stripTriggerFromCaptions(id: UUID, trigger rawTrigger: String) {
        let trigger = rawTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty else { return }
        mutateWorkshop(id) { ws in
            for j in ws.images.indices where Self.captionContainsTrigger(ws.images[j].caption, trigger: trigger) {
                ws.images[j].caption = Self.removingTrigger(trigger, from: ws.images[j].caption)
            }
        }
        lastAction = .ok("Removed “\(trigger)” from the captions — it's added automatically at train time.")
    }

    /// Remove a word-bounded trigger occurrence + its joining comma, then collapse leftovers.
    /// Same lookaround bounds as captionContainsTrigger (see note there re: \b vs punctuation).
    nonisolated static func removingTrigger(_ trigger: String, from caption: String) -> String {
        let esc = NSRegularExpression.escapedPattern(for: trigger)
        let bounded = "(?<!\\w)\(esc)(?!\\w)"
        var s = caption
        s = s.replacingOccurrences(of: "(?i)\(bounded)\\s*,\\s*", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)\\s*,\\s*\(bounded)", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)\(bounded)", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Bulk caption tools (find & replace / append / prepend)

    /// Whether a caption contains `find` (plain substring, optionally case-insensitive) — the pure
    /// test behind both the live "affects N of M" preview and the actual replace.
    nonisolated static func captionMatches(_ caption: String, find: String, caseInsensitive: Bool) -> Bool {
        guard !find.isEmpty else { return false }
        return caption.range(of: find, options: caseInsensitive ? [.caseInsensitive] : []) != nil
    }

    /// Dataset-wide find & replace across all captions. ONE `mutateWorkshop` write for the whole
    /// dataset (NOT one setCaption per image — that'd be a hundred async upserts on a big set).
    /// Sources are left untouched for still-non-empty captions; a caption emptied out resets to .none.
    func bulkReplaceCaptions(id: UUID, find: String, replace: String, caseInsensitive: Bool) {
        guard !find.isEmpty else { return }
        // Count from the live copy for the outcome message (the write overlays the freshest state).
        let affected = workshops.first { $0.id == id }?.images
            .filter { Self.captionMatches($0.caption, find: find, caseInsensitive: caseInsensitive) }
            .count ?? 0
        guard affected > 0 else { lastAction = .ok("No caption contains “\(find)”."); return }
        mutateWorkshop(id) { ws in
            for j in ws.images.indices
            where Self.captionMatches(ws.images[j].caption, find: find, caseInsensitive: caseInsensitive) {
                var s = ws.images[j].caption.replacingOccurrences(
                    of: find, with: replace, options: caseInsensitive ? [.caseInsensitive] : [])
                s = s.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                ws.images[j].caption = s
                if s.isEmpty { ws.images[j].captionSource = .none }
            }
        }
        lastAction = .ok("Replaced “\(find)” in \(affected) caption\(affected == 1 ? "" : "s").")
    }

    /// Bulk append/prepend a phrase to every caption — ONE store write. An empty caption becomes
    /// just the phrase (and is marked .manual so the "captioned" state is honest).
    func bulkAmendCaptions(id: UUID, phrase raw: String, prepend: Bool) {
        let phrase = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return }
        let total = workshops.first { $0.id == id }?.images.count ?? 0
        guard total > 0 else { return }
        mutateWorkshop(id) { ws in
            for j in ws.images.indices {
                let current = ws.images[j].caption.trimmingCharacters(in: .whitespacesAndNewlines)
                if current.isEmpty {
                    ws.images[j].caption = phrase
                    ws.images[j].captionSource = .manual
                } else {
                    ws.images[j].caption = prepend ? Self.joiningCaption(phrase, current)
                                                   : Self.joiningCaption(current, phrase)
                }
            }
        }
        lastAction = .ok("\(prepend ? "Prepended" : "Appended") “\(phrase)” to \(total) caption\(total == 1 ? "" : "s").")
    }

    /// Join two caption fragments with ", " — unless the boundary already carries punctuation,
    /// then a plain space (so "…on grass." + "photo" doesn't become "…on grass., photo").
    nonisolated static func joiningCaption(_ a: String, _ b: String) -> String {
        guard let last = a.last else { return b }
        return a + (".,;:!?".contains(last) ? " " : ", ") + b
    }

    // MARK: Forge a training (Chunk 4)

    var forging = false

    /// Forge an immutable Draft training from a workshop: freeze the dataset (snapshot-on-forge) and
    /// persist the run with its locked parameters. Starting/running it is the next chunk.
    func forge(workshopID: UUID, name: String, params: TrainingParams) {
        guard !forging else { return }
        guard let workshop = workshops.first(where: { $0.id == workshopID }) else { return }
        forging = true
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let runName = trimmed.isEmpty ? "Training \(runs(for: workshop).count + 1)" : trimmed
        // The run id is minted UP FRONT so the dataset can be frozen first — with mirror
        // augmentation on, the run's imageCount must be what was ACTUALLY written to disk
        // (originals + flips), not the workshop's count.
        let runID = UUID()
        let outputDir = AppPaths.trainingRunsDir.appendingPathComponent(runID.uuidString, isDirectory: true)
        let datasetDir = outputDir.appendingPathComponent("dataset", isDirectory: true)
        let mirror = params.flipAugment == true
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Order matters: the flag resets FIRST so the chain/idle checks in the same defer pass.
            defer { self.forging = false; self.startNextInQueue(); self.notifyIfFullyIdle() }
            do {
                let (count, skipped) = try await Task.detached(priority: .userInitiated) {
                    try TrainingService.freezeDataset(from: workshop, to: datasetDir, mirror: mirror)
                }.value
                let run = TrainingRun(
                    id: runID,
                    workshopId: workshop.id,
                    name: runName,
                    triggerWord: workshop.triggerWord.trimmingCharacters(in: .whitespacesAndNewlines),
                    conceptType: workshop.conceptType,
                    imageCount: count,
                    params: params,
                    status: .draft)
                _ = try await self.store.upsert(run)
                self.runs.insert(run, at: 0)   // optimistic: the monitor we auto-open finds it instantly
                // Skips (missing/uncopyable files) are surfaced, not swallowed — the run trains on
                // FEWER images than the workshop shows, and the user must know that (Logs has details).
                self.lastAction = .ok("Forged “\(runName)” — \(count) image\(count == 1 ? "" : "s") frozen\(mirror ? " (incl. mirrored copies)" : "")\(skipped > 0 ? ", \(skipped) skipped (see Logs)" : ""). Ready to start.")
                self.presentedRunID = run.id   // auto-open the live monitor on the new Draft
                self.reload()
            } catch {
                try? FileManager.default.removeItem(at: outputDir)   // don't leave a half-frozen dataset
                self.lastAction = .error("Couldn't forge the training: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Duplicate a run as a new draft (A/B recipe experiments)

    /// Prefill payload for the forge sheet when cloning a run: same workshop, every locked
    /// parameter copied, "<name> copy" suggested. `Identifiable` so `.sheet(item:)` presents it
    /// (TrainingView and WorkshopEditorView both host the sheet; only the mounted one presents).
    struct ForgePrefill: Identifiable {
        let id = UUID()
        let workshop: Workshop
        let params: TrainingParams
        let suggestedName: String
    }
    var forgePrefill: ForgePrefill? = nil

    /// The workshop-editor readiness checklist, re-checked for paths that reach the forge sheet
    /// WITHOUT passing the editor's gate (duplicate-as-draft). Keep the thresholds in sync with
    /// WorkshopEditorView.Gate (private there) — a workshop emptied below the minimum since the
    /// original run would otherwise forge a draft that can only fail at start.
    nonisolated static func forgeBlocker(for w: Workshop) -> String? {
        let trigger = w.triggerWord.trimmingCharacters(in: .whitespacesAndNewlines)
        if trigger.isEmpty { return "it has no trigger word" }
        if trigger.contains(where: \.isWhitespace) { return "its trigger word has spaces" }
        if w.images.count < 10 { return "it has \(w.images.count) of the 10-image minimum" }
        if w.conceptDescription.trimmingCharacters(in: .whitespacesAndNewlines).count < 10 {
            return "its description is too short"
        }
        if w.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "it has no name" }
        return nil
    }

    /// A run can be duplicated whenever it isn't the active one and its workshop still exists
    /// AND still passes the readiness checklist (the clone re-snapshots the dataset from the
    /// workshop at forge time, so the CURRENT workshop state is what gets frozen).
    func canDuplicate(_ run: TrainingRun) -> Bool {
        guard run.id != activeRunID,
              let w = workshops.first(where: { $0.id == run.workshopId }) else { return false }
        return Self.forgeBlocker(for: w) == nil
    }

    /// Open the forge sheet pre-filled with this run's locked parameters — a sibling draft for
    /// the same workshop, for A/B recipe experiments (same dataset concept, different steps/rank).
    /// The dataset is re-snapshotted at forge time as usual, so caption edits made since the
    /// original run are picked up.
    func duplicateAsDraft(_ run: TrainingRun) {
        guard let workshop = workshops.first(where: { $0.id == run.workshopId }) else {
            lastAction = .error("The workshop this training came from no longer exists — nothing to duplicate into.")
            return
        }
        // Same readiness gate the editor enforces before its own forge button: without it a
        // workshop emptied since the original run forges a draft that can only fail at start.
        if let why = Self.forgeBlocker(for: workshop) {
            lastAction = .error("Can't duplicate — the workshop no longer passes the checklist (\(why)). Open it and complete the checklist first.")
            return
        }
        guard canDuplicate(run) else { return }
        let prefill = ForgePrefill(workshop: workshop, params: run.params,
                                   suggestedName: "\(run.name) copy")
        if presentedRunID != nil {
            // Called from inside the run monitor sheet: dismiss it first, THEN present the forge
            // sheet — swapping two sheets in the same tick makes SwiftUI drop one of them.
            presentedRunID = nil
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                self?.forgePrefill = prefill
            }
        } else {
            forgePrefill = prefill
        }
    }

    // MARK: Live run (Chunk 5)

    /// A run whose estimated peak exceeds this Mac's physical RAM — starting it froze a real
    /// machine (9B on 32 GB, 2026-07-02). Start/Resume/Extend/queue all refuse; the UI explains.
    func exceedsRAM(_ run: TrainingRun) -> Bool {
        TrainingService.exceedsPhysicalRAM(tier: run.tier, resolution: run.params.maxResolution,
                                           dopEnabled: run.params.dopEnabled)
    }

    /// Whether a run can be started (Draft, or a stopped/failed run can be resumed via autoResume).
    func canStart(_ run: TrainingRun) -> Bool {
        // finishingRun: the just-ended run still holds the engine latch — a Start pressed in
        // that window would bail-park into the queue for no reason; the tail drains it anyway.
        guard activeRunID == nil, !captioning, !smokeRunning, !forging, !finishingRun else { return false }
        // A run parked in the queue (e.g. Start pressed while a render held the engine) must show
        // its "Queued · position N" chip, not a live Start button — pressing Start again on it
        // bailed into a SECOND queue entry, which could later restart a stopped run unexpectedly.
        guard queuePosition(of: run.id) == nil else { return false }
        guard !exceedsRAM(run) else { return false }
        switch run.status {
        case .draft: return true
        case .paused, .failed, .cancelled, .completed:
            // Only if there's headroom left: the engine loop is `for step in (latest+1)...maxSteps`,
            // which is a CRASHING empty range when the latest checkpoint already sits at maxSteps —
            // reachable in ANY resumable state (e.g. Stop lands a checkpoint exactly on the final
            // step → .cancelled). Extend (+N steps) is the supported way to continue such a run.
            guard let latest = latestCheckpointStep(run) else { return true }   // no checkpoint → fresh start
            return latest < run.params.maxSteps
        default: return false
        }
    }

    // MARK: Extend a finished run (+N steps)

    /// Highest saved checkpoint step — the persisted mirror of the engine's on-disk
    /// `checkpoint_*` dirs (kept in sync by the checkpoint events + deleteCheckpoint).
    func latestCheckpointStep(_ run: TrainingRun) -> Int? {
        run.runtime.checkpoints.map(\.step).max()
    }

    /// Whether a terminal run can be continued with more steps. Needs a checkpoint to resume from;
    /// the engine's compatibility check (model/rank/alpha) passes because those params stay frozen.
    /// Also offered for stopped/failed runs whose checkpoint sits AT maxSteps (Resume is impossible
    /// there — the canStart headroom guard — so Extend is the only way forward).
    func canExtend(_ run: TrainingRun) -> Bool {
        guard activeRunID == nil, !captioning, !smokeRunning, !forging, !finishingRun,
              !exceedsRAM(run) else { return false }
        switch run.status {
        case .completed, .published: break
        case .paused, .failed, .cancelled:
            // Resumable states get Extend only when plain Resume is blocked (checkpoint == maxSteps).
            guard let latest = latestCheckpointStep(run), latest >= run.params.maxSteps else { return false }
        default: return false
        }
        return latestCheckpointStep(run) != nil
    }

    /// True while the latest checkpoint still has its optimizer state on disk — the resume then
    /// keeps AdamW momentum. Without it the engine silently resumes with fresh momentum (works,
    /// slightly lower quality) — the UI shows a note instead of blocking.
    func extendKeepsMomentum(_ run: TrainingRun) -> Bool {
        guard let step = latestCheckpointStep(run) else { return false }
        let url = run.outputDir.appendingPathComponent(
            "checkpoint_\(String(format: "%06d", step))/optimizer_state.safetensors")
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Raise the step target of a finished run and resume it from its last checkpoint —
    /// the loss curve and checkpoint list continue where they left off.
    func extendRun(_ run: TrainingRun, addSteps: Int) {
        guard canExtend(run), addSteps > 0, latestCheckpointStep(run) != nil else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Lost-update guard (mutateWorkshop's philosophy, run-side): `run` is the row's
            // snapshot from click time — computing on it and upserting would revert whatever
            // landed since (a publish's marker, a checkpoint delete). Re-read the freshest
            // record and apply ONLY the fields Extend owns to THAT copy.
            // nil = the run was DELETED while this task waited — falling back to the stale
            // snapshot would have upsert() re-INSERT a ghost record over a removed outputDir.
            guard var r = await self.store.run(run.id) else {
                self.lastAction = .error("“\(run.name)” was deleted — nothing to extend.")
                return
            }
            guard let latest = self.latestCheckpointStep(r) else {
                self.lastAction = .error("No checkpoint left to extend from.")
                return
            }
            // Round the new target UP to the checkpoint grid: the engine only saves checkpoints on
            // saveEveryNSteps multiples (plus lora_final), so an off-grid target would complete with
            // its last checkpoint BELOW maxSteps — blocking any further Extend behind a dead Resume.
            let save = max(1, r.params.saveEveryNSteps)
            let raw = max(r.params.maxSteps, latest) + addSteps
            r.params.maxSteps = ((raw + save - 1) / save) * save
            r.runtime.totalSteps = r.params.maxSteps
            r.runtime.message = "Extended by \(addSteps) steps"
            // Re-enter the resumable state so startRun's gate accepts it (a .published run isn't
            // directly startable). The published pill survives — publishedCheckpointStep is the SoT.
            r.status = .paused
            // Keep going on a failed persist (the in-memory copy still drives this session's
            // resume) — but leave a trace: a relaunch would silently forget the raised target.
            do { _ = try await self.store.upsert(r) }
            catch { AppLog.error("Extend “\(r.name)”: new step target not persisted (a relaunch forgets it): \(error.localizedDescription)") }
            if let i = self.runs.firstIndex(where: { $0.id == r.id }) { self.runs[i] = r }
            self.lastAction = .ok("“\(r.name)” extended to \(r.params.maxSteps) steps — resuming from step \(latest).")
            self.startRun(r)
        }
    }

    /// Start (or resume) a training run on the real engine. Owns the GPU single-flight bracket.
    func startRun(_ run: TrainingRun) {
        guard canStart(run) else { return }
        queue.removeAll { $0.id == run.id }   // starting it directly consumes any queued entry
        activeRunID = run.id
        lastEngineStatus = nil
        stopRequested = false
        // The step this session resumes from: the engine restarts at (latest checkpoint + 1),
        // or from 0 when no checkpoint survived. Drives the per-session ETA in RunView.
        let resumeStep = latestCheckpointStep(run) ?? 0
        activeSessionStartStep = resumeStep
        var live = run
        live.status = .preparing
        live.runtime.startedAt = Date()   // this run session's clock (elapsed/ETA count from now, not a prior attempt)
        live.runtime.finishedAt = nil
        live.runtime.message = "Preparing…"
        // Trim the loss history to the resume point (1 entry per step ⇒ prefix(resumeStep)):
        // entries PAST the checkpoint belong to the abandoned attempt — failed at 150, resuming
        // from 100 would duplicate 101–150; a fresh restart would duplicate the whole prefix.
        // The chart x-axis and the published model card inherit whatever is left here.
        if live.runtime.lossHistory.count > resumeStep {
            live.runtime.lossHistory = Array(live.runtime.lossHistory.prefix(resumeStep))
        }
        activeRun = live
        runPhaseLine = "Preparing…"

        // Observer → MainActor sink. The session is @unchecked Sendable so we hold it for pause/stop.
        let observer = RunObserver(sink: { [weak self] e in
            Task { @MainActor in self?.handleRunEvent(e) }
        })
        let session = TrainingSession(outputDirectory: run.outputDir)
        session.addObserver(observer)
        activeSession = session
        activeObserver = observer

        // Persist the "preparing" status so the list reflects it immediately.
        let snapshot = live
        Task { @MainActor in _ = try? await store.upsert(snapshot); reload() }

        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Between-items window: see generationQueueBusy's doc — a mid-queue claim would
            // succeed and burn the rest of the render queue, so park without touching the engine
            // (freeMemory here would also evict the model the next queue item is about to reuse).
            let generationQueueMidRun = self.generationQueueBusy?() == true
            // Evict the inference pipeline, then claim the global MLX pool (mirrors the smoke bracket).
            if !generationQueueMidRun { _ = await self.engine.freeMemory() }
            guard !generationQueueMidRun, await self.engine.setDescribing(true) else {
                // Engine busy = a DEFERRAL, not a failure: nothing ran, so the run must NOT land in
                // .failed ("Training failed…" over a run that never started). Restore the pre-start
                // snapshot — status and runtime exactly as before startRun touched them — and park
                // it back at the queue head; generationQueueDidEnd()/generationDescribeDidEnd()
                // re-drain it the moment the render/VLM frees the engine.
                // Deliberately NOT startNextInQueue() here: the engine is busy, so chaining would
                // cascade-fail every queued training in a second.
                // finishingRun brackets the teardown: activeRunID goes nil several awaits before
                // the queue re-insert below lands — fullyIdle must not flip true in between.
                self.finishingRun = true
                self.activeRunID = nil
                self.activeRun = nil
                self.activeSession = nil
                self.activeObserver = nil
                self.runTask = nil
                self.runPhaseLine = nil
                self.stopRequested = false
                self.lastEngineStatus = nil
                var parked = run
                parked.runtime.message = "Queued — starts when the engine frees up."
                do { _ = try await self.store.upsert(parked) }
                catch { AppLog.error("Queued run “\(parked.name)”: state not persisted: \(error.localizedDescription)") }
                self.reload()
                // Defensive: never park the same run twice (double-press protection also lives
                // in canStart's queue-membership guard, but a queued entry re-inserted here
                // would jump the line AND duplicate).
                if self.queuePosition(of: run.id) == nil { self.queue.insert(.run(run.id), at: 0) }
                self.finishingRun = false
                self.lastAction = .ok("Engine is busy (generating or describing) — “\(run.name)” is queued and starts when it frees up.")
                self.notifyIfFullyIdle()
                return   // nothing claimed → no latch to release
            }
            var ok = true
            var message = "Training completed"
            do {
                try await TrainingService.runTraining(
                    run: run, session: session,
                    onPhase: { ph, msg in Task { @MainActor in self.handleRunEvent(.phase(ph, msg)) } })
            } catch is CancellationError {
                ok = false; message = "Cancelled"
            } catch {
                ok = false; message = error.localizedDescription
            }
            // ONE authoritative finalizer. Persist + latch release are AWAITED so a quit can neither
            // lose the final state nor leave describing=true latched (which would brick generation).
            // finishingRun brackets the whole teardown: finalizeState clears activeRunID several
            // awaits BEFORE setDescribing(false) below — fullyIdle flipping true in that window
            // let a "Run all" pass the isTrainingBusy gate and cascade-fail every generation item
            // against the still-latched engine. Held until the latch AND pool flush are done.
            self.finishingRun = true
            self.finalizeState(success: ok, message: message)
            // A fully-completed run drops the big optimizer states EXCEPT the newest checkpoint's —
            // that one is what "Extend training" resumes from with momentum intact.
            let trimDir: URL? = (self.activeRun.map { $0.status == .completed && $0.runtime.currentStep >= $0.runtime.totalSteps } ?? false)
                ? self.activeRun?.outputDir : nil
            await self.persistFinal()
            self.activeRun = nil   // fall back to the persisted run so later publish/delete reflect immediately
            if let dir = trimDir {
                await Task.detached(priority: .utility) { TrainingService.trimOptimizerStates(in: dir, keepLatest: true) }.value
            }
            await self.engine.setDescribing(false)
            _ = observer   // kept the observer alive past start()
            // The run's big MLX allocations (the ~8 GB base transformer, latents, optimizer)
            // died inside runTraining's detached task — but freed buffers only return to the MLX
            // POOL, where they sit until something reclaims them (observed as "restart the app
            // before a 9B render after a training marathon"). Flush now: the latch is released,
            // the weights are already dead, and it runs BEFORE startNextInQueue()/notifyIfFullyIdle()
            // so it can't race a chained training or a handed-off generation claiming the pool.
            MaintenanceService.clearMLXPool()
            self.finishingRun = false   // teardown complete — the trainer is HONESTLY idle now
            self.startNextInQueue()   // auto-chain the next queued training now that the GPU is free
            self.notifyIfFullyIdle()  // nothing chained → hand the GPU to an armed generation queue
        }
    }

    // MARK: Training queue (auto-chain drafts + caption jobs)

    /// 1-based position of a queue item — a run id or a caption job's id — or nil if not queued.
    func queuePosition(of id: UUID) -> Int? { queue.firstIndex { $0.id == id }.map { $0 + 1 } }

    /// Whether a run is eligible to be added to the queue (a fresh draft or a stopped one, not the
    /// active run, and not already queued).
    func isQueueable(_ run: TrainingRun) -> Bool {
        guard run.id != activeRunID, queuePosition(of: run.id) == nil, !exceedsRAM(run) else { return false }
        switch run.status {
        case .draft: return true
        case .paused, .failed, .cancelled:
            // Same headroom rule as canStart: a run whose checkpoint already sits at maxSteps
            // can't be started when its turn comes (Extend is the way forward) — admitting it
            // here would have the queue silently drop it later.
            guard let latest = latestCheckpointStep(run) else { return true }
            return latest < run.params.maxSteps
        default: return false
        }
    }

    /// Add a run to the tail of the queue. If the engine is idle it starts right away; otherwise it
    /// waits and auto-starts when the current training (or caption job) finishes.
    func enqueue(_ run: TrainingRun) {
        guard isQueueable(run) else { return }
        queue.append(.run(run.id))
        lastAction = .ok("“\(run.name)” queued (position \(queue.count)) — it starts automatically when the current work finishes.")
        startNextInQueue()   // no-op while a training is active; starts immediately if the engine is idle
    }

    func dequeue(_ id: UUID) { queue.removeAll { $0.id == id } }
    func clearQueue()        { queue.removeAll() }

    /// The queued caption job for a workshop, if any (at most one per workshop at a time).
    func queuedCaptionJob(for workshopID: UUID) -> TrainingQueueItem? {
        queue.first {
            if case .caption(_, let wid, _) = $0 { return wid == workshopID }
            return false
        }
    }

    func dequeueCaptionJob(for workshopID: UUID) {
        queue.removeAll {
            if case .caption(_, let wid, _) = $0 { return wid == workshopID }
            return false
        }
    }

    /// Start the next eligible queued item if the trainer is free. Called after every run AND every
    /// caption job finishes, and on enqueue. Leading entries that were deleted or are no longer
    /// startable are dropped, not run.
    private func startNextInQueue() {
        // finishingRun: the reverse handoffs (generation*DidEnd) can fire during a run's
        // teardown window — draining then would bail every item against the still-latched
        // engine. No stall: every path that clears the flag calls startNextInQueue right after.
        guard activeRunID == nil, !captioning, !smokeRunning, !forging, !finishingRun else { return }
        while let next = queue.first {
            queue.removeFirst()
            switch next {
            case .run(let id):
                guard let run = runs.first(where: { $0.id == id }) else { continue }   // deleted meanwhile
                switch run.status {
                case .draft, .paused, .failed, .cancelled:
                    // Re-verify canStart HERE: a blind startRun would silently no-op on its own
                    // canStart guard (e.g. a Stop landed a checkpoint exactly on maxSteps), the
                    // item is already popped, and the `return` would stall everything behind it.
                    guard canStart(run) else {
                        lastAction = .error("Skipped queued “\(run.name)” — it can't start (its last checkpoint already sits at the step target; use Extend training). Continuing with the next queued item.")
                        continue
                    }
                    startRun(run)
                    return
                default:
                    continue   // no longer startable → skip and try the next
                }
            case .caption(_, let workshopID, let onlyMissing):
                // Resolve targets NOW, not at enqueue: photos added while the job waited are
                // included, and an only-missing job skips images captioned in the meantime.
                guard let w = workshops.first(where: { $0.id == workshopID }) else { continue }
                let targets = onlyMissing
                    ? w.images.filter { $0.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    : w.images
                guard !targets.isEmpty else { continue }   // nothing left to do → skip
                runCaptioning(id: workshopID, refIDs: targets.map(\.id), queueItem: next)
                return
            }
        }
    }

    func pauseRun()      { activeSession?.pause() }
    func resumeRun()     { activeSession?.resume() }
    func checkpointRun() { activeSession?.checkpoint() }
    /// Graceful stop — saves a checkpoint, then the run ends (its checkpoints stay usable/publishable).
    /// The engine finishes the in-flight step + checkpoint + validation first (~a minute), so the
    /// stopping state must be VISIBLE or the button reads as dead (live-test: everyone clicks twice).
    func stopRun() {
        guard activeSession != nil, !stopRequested else { return }
        stopRequested = true
        runPhaseLine = "Stopping — saving a checkpoint…"
        activeRun?.runtime.message = "Stopping…"
        activeSession?.stop()
    }

    /// Apply one engine/run event to the live in-memory run. Disk persistence is throttled to
    /// status changes + checkpoints + finish (NOT every step — that'd be thousands of JSON writes).
    private func handleRunEvent(_ event: TrainingService.RunEvent) {
        guard activeRun != nil else { return }   // ignore stragglers after finalize
        switch event {
        case .phase(_, let msg):
            if !stopRequested { runPhaseLine = msg }   // keep "Stopping…" visible over late phase events
            activeRun?.runtime.message = msg
        case .status(let s):
            lastEngineStatus = s
            if s == "running" { activeRun?.status = .training; if !stopRequested { runPhaseLine = nil } }
            else if s == "paused" { activeRun?.status = .paused }
            persistActive()
        case .step(let step, let total, let loss):
            if !stopRequested { runPhaseLine = nil }
            activeRun?.status = .training
            activeRun?.runtime.currentStep = step
            activeRun?.runtime.totalSteps = total
            activeRun?.runtime.lossHistory.append(loss)
        case .checkpoint(let step, let dir):
            if activeRun?.runtime.checkpoints.contains(where: { $0.step == step }) == false {
                activeRun?.runtime.checkpoints.append(TrainingCheckpoint(step: step, dirName: dir.lastPathComponent))
            }
            activeRun?.runtime.message = "Checkpoint saved (step \(step))"
            pruneCheckpointsIfNeeded()
            persistActive()
        case .validation(let step, let images):
            if let run = activeRun, let idx = run.runtime.checkpoints.firstIndex(where: { $0.step == step }) {
                let base = run.outputDir.path + "/"
                activeRun?.runtime.checkpoints[idx].validationImageNames = images.map {
                    $0.path.hasPrefix(base) ? String($0.path.dropFirst(base.count)) : $0.lastPathComponent
                }
                persistActive()
            }
        case .paused(let step):
            activeRun?.status = .paused
            activeRun?.runtime.currentStep = step
            persistActive()
        case .resumed(let step):
            activeRun?.status = .training
            activeRun?.runtime.currentStep = step
            // The engine DELETES the pause checkpoint dir it auto-saved once training resumes —
            // drop mirror entries whose directory is gone, or the review list / extend helpers
            // would trust a phantom checkpoint ("Adapter file not found" on publish).
            if let r = activeRun {
                activeRun?.runtime.checkpoints.removeAll { cp in
                    !FileManager.default.fileExists(atPath: r.outputDir.appendingPathComponent(cp.dirName).path)
                }
            }
            persistActive()
        case .finished(_, let message):
            activeRun?.runtime.message = message   // cosmetic; the run task is the authoritative finalizer
        }
    }

    /// Rolling retention (keep last N): after every checkpoint, strip the heavy weight/optimizer
    /// files from checkpoints beyond the window. Validation PNGs always stay (the compare grid
    /// stays complete), the published and best-loss checkpoints are exempt, and the newest N keep
    /// everything — Extend depends on the newest optimizer state. Detached (file IO); the freed
    /// bytes accumulate on the run so the review screen can show what retention reclaimed.
    private func pruneCheckpointsIfNeeded() {
        guard let run = activeRun, let keep = run.params.keepLastCheckpoints, keep > 0 else { return }
        var exempt = Set<Int>()
        if let published = run.publishedCheckpointStep, published >= 0 { exempt.insert(published) }
        let dir = run.outputDir
        Task { @MainActor [weak self] in
            let freed = await Task.detached(priority: .utility) { [dir, keep, exempt] in
                TrainingService.pruneCheckpoints(in: dir, keepLast: keep, exempt: exempt)
            }.value
            guard freed > 0, let self else { return }
            if self.activeRun?.id == run.id {
                self.activeRun?.runtime.reclaimedBytes = (self.activeRun?.runtime.reclaimedBytes ?? 0) + freed
                self.persistActive()
            } else if var r = await self.store.run(run.id) {
                // The run finalized while the detached prune was still deleting (a checkpoint on
                // the final step) — credit the freed bytes to the persisted record instead of
                // dropping them, or "Retention: … freed" under-reports forever.
                r.runtime.reclaimedBytes = (r.runtime.reclaimedBytes ?? 0) + freed
                _ = try? await self.store.upsert(r)
                self.reload()
            }
        }
    }

    /// False when retention pruned this checkpoint's weight file — it's PREVIEW-ONLY then: its
    /// validation images remain for comparing, but it can't be published or extended from.
    func checkpointHasWeights(run: TrainingRun, step: Int) -> Bool {
        FileManager.default.fileExists(atPath: run.outputDir
            .appendingPathComponent("checkpoint_\(String(format: "%06d", step))/lora.safetensors").path)
    }

    /// Set the terminal status + clear the active refs (SYNC). The run task owns the awaited latch
    /// release + final persist (see `startRun`), so this never touches the GPU or async I/O itself.
    private func finalizeState(success: Bool, message: String) {
        guard activeRunID != nil else { return }
        var message = message
        // A Stop during the Preparing phase interrupts the engine's encode mid-write, which surfaces
        // as a throw ("data couldn't be written…") rather than status "cancelled" — the user asked to
        // stop, so report a stop, not a failure.
        // A Stop MID-RUN is the opposite trap: this engine never emits status "cancelled" (verified —
        // only running/paused/completed/failed); a graceful stop saves its checkpoint + validation and
        // returns SUCCESS, so `stopRequested && success` short of the step target is a user stop, not a
        // completion — without this test a run stopped at 150/300 finalized as a green "Completed".
        // The step comparison reads the LIVE activeRun runtime (updated per .step event), not the
        // stale snapshot startRun was called with. The "cancelled" check stays as belt-and-braces.
        let stoppedShort = stopRequested && success
            && (activeRun.map { $0.runtime.currentStep < $0.runtime.totalSteps } ?? false)
        let stoppedByUser = lastEngineStatus == "cancelled" || (stopRequested && !success) || stoppedShort
        if stoppedShort, let r = activeRun {
            // The trainer's own message says "Training completed" here — override with the truth.
            message = "Stopped at step \(r.runtime.currentStep) of \(r.runtime.totalSteps) — checkpoints saved."
        }
        activeRun?.status = stoppedByUser ? .cancelled : (success ? .completed : .failed)
        activeRun?.runtime.finishedAt = Date()
        activeRun?.runtime.message = message
        // One existence sweep over the checkpoint mirror (same test as the .resumed prune): the
        // engine deletes its auto-saved pause-checkpoint dir AFTER firing .resumed, so the
        // event-time prune can run while the dir still exists — the phantom then survives into
        // the final persist and dies with "Adapter file not found" on publish. Re-checking here
        // also self-heals phantoms persisted by older sessions.
        if let r = activeRun {
            activeRun?.runtime.checkpoints.removeAll { cp in
                !FileManager.default.fileExists(atPath: r.outputDir.appendingPathComponent(cp.dirName).path)
            }
        }
        activeRunID = nil
        activeSession = nil
        activeObserver = nil
        runTask = nil
        runPhaseLine = nil
        lastEngineStatus = nil
        stopRequested = false
        if let r = activeRun {
            let n = r.runtime.checkpoints.count
            switch r.status {
            case .completed: lastAction = .ok("“\(r.name)” finished — \(n) checkpoint\(n == 1 ? "" : "s").")
            case .cancelled: lastAction = .ok("“\(r.name)” stopped — \(n) checkpoint\(n == 1 ? "" : "s") saved.")
            default:         lastAction = .error("Training failed: \(message)")
            }
        }
    }

    /// Persist the just-finalized run — AWAITED by the run task so a quit can't lose the final state.
    /// A failed write can't be retried meaningfully here (same disk, same instant), but it must
    /// leave a trace — a silently unsaved terminal state resurrects as "Paused" on relaunch.
    private func persistFinal() async {
        guard let r = activeRun else { return }
        do { _ = try await store.upsert(r) }
        catch { AppLog.error("Run “\(r.name)”: final state not persisted — it may show stale after a relaunch: \(error.localizedDescription)") }
        reload()
    }

    private func persistActive() {
        guard let r = activeRun else { return }
        Task { @MainActor in
            do { _ = try await store.upsert(r) }
            catch { AppLog.error("Run “\(r.name)”: live state not persisted: \(error.localizedDescription)") }
            reload()
        }
    }

    // MARK: Publish + checkpoints (Chunk 6)

    /// On-disk adapter file for a checkpoint step (nil → the run's final adapter).
    private func adapterURL(run: TrainingRun, checkpointStep: Int?) -> URL {
        if let step = checkpointStep {
            return run.outputDir.appendingPathComponent("checkpoint_\(String(format: "%06d", step))/lora.safetensors")
        }
        return run.outputDir.appendingPathComponent("lora_final.safetensors")
    }

    /// Stable per-run library name — re-publishing a different checkpoint from the SAME run replaces it.
    /// The trigger is sanitized for the FILESYSTEM ("/" or ":" in a trigger must not break the path).
    private func publishedName(run: TrainingRun) -> String {
        let raw = run.triggerWord.isEmpty ? "lora" : run.triggerWord
        let trig = String(raw.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
        return "\(trig)-\(run.params.tier)-\(run.id.uuidString.prefix(8)).safetensors"
    }

    /// Sentinel stored in `publishedCheckpointStep` when the FINAL adapter (not a numbered checkpoint)
    /// is the published one — distinguishes it from a real step and from nil ("nothing published").
    static let finalAdapterStep = -1

    /// A validation prompt exactly as the trainer rendered it: a `[trigger]` placeholder resolves
    /// in place; otherwise the applyTrigger prepend applies. Used by the model card and the
    /// compare-matrix tooltips so the displayed text matches what the model really received.
    nonisolated static func resolvedValidationPrompt(_ run: TrainingRun, index: Int) -> String {
        let prompts = run.params.validationPrompts
        guard index >= 0, index < prompts.count else { return "prompt \(index + 1)" }
        let p = prompts[index]
        let t = run.triggerWord
        if !t.isEmpty {
            let resolved = TriggerPlaceholder.resolve(in: p.prompt, triggers: [t])
            if resolved != p.prompt { return resolved }
            if p.applyTrigger { return "\(t), \(p.prompt)" }
        }
        return p.prompt
    }

    /// Build the publish-time model card + the list of validation images to snapshot-copy.
    /// Publishing the FINAL adapter uses the newest checkpoint's images as its visual record.
    nonisolated private static func makeModelCard(
        run: TrainingRun, checkpointStep: Int?, libraryFileName: String, workshopName: String?
    ) -> (card: TrainingModelCard, images: [(source: URL, fileName: String)]) {
        let cpStep = checkpointStep ?? run.runtime.checkpoints.map(\.step).max()
        var entries: [TrainingModelCard.ValidationEntry] = []
        var images: [(source: URL, fileName: String)] = []
        if let cpStep, let cp = run.runtime.checkpoints.first(where: { $0.step == cpStep }) {
            for rel in cp.validationImageNames {
                let file = (rel as NSString).lastPathComponent
                // Engine filename pattern "prompt_{i}…" — the index keys the prompt text.
                guard file.hasPrefix("prompt_"),
                      let idx = Int(file.dropFirst("prompt_".count).prefix(while: { $0.isNumber }))
                else { continue }
                entries.append(.init(fileName: file, prompt: resolvedValidationPrompt(run, index: idx)))
                images.append((source: run.outputDir.appendingPathComponent(rel), fileName: file))
            }
        }
        // Cap the stored loss series — a 4000-step run would bloat card.json for no visual gain.
        var loss = run.runtime.lossHistory
        if loss.count > 1000 {
            let stride = Double(loss.count) / 1000
            loss = (0..<1000).map { loss[min(loss.count - 1, Int(Double($0) * stride))] }
        }
        let card = TrainingModelCard(
            libraryFileName: libraryFileName,
            runID: run.id.uuidString,
            runName: run.name,
            workshopName: workshopName,
            trigger: run.triggerWord,
            tier: run.params.tier,
            conceptType: run.conceptType.label,
            publishedStep: checkpointStep,
            maxSteps: run.params.maxSteps,
            rank: run.params.rank,
            alpha: run.params.alpha,
            learningRate: run.params.learningRate,
            resolution: run.params.maxResolution,
            imageCount: run.imageCount,
            dopEnabled: run.params.dopEnabled,
            dopClass: run.params.dopEnabled ? run.params.dopClass : nil,
            mirrored: run.params.flipAugment,
            lossHistory: loss,
            validation: entries,
            validationStep: cpStep,
            trainedAt: run.runtime.startedAt,
            publishedAt: Date())
        return (card, images)
    }

    /// Publish a checkpoint (or the final adapter) into the shared LoRA library so it's usable in
    /// Generate. Copies the .safetensors in (OFF the main actor — it's hundreds of MB), sets the
    /// trigger word, and marks the run published.
    func publish(run: TrainingRun, checkpointStep: Int?) {
        let src = adapterURL(run: run, checkpointStep: checkpointStep)
        guard FileManager.default.fileExists(atPath: src.path) else {
            lastAction = .error("Adapter file not found on disk."); return
        }
        let name = publishedName(run: run)
        let trigger = run.triggerWord
        let publishedStep = checkpointStep ?? Self.finalAdapterStep
        Task { @MainActor in
            // Per-publish UNIQUE staging dir (a stable tmp path let two concurrent publishes of the
            // same run corrupt each other's copy); the FILENAME inside stays stable — importLoRA
            // names the library entry after it.
            let stagingDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("publish-\(UUID().uuidString)", isDirectory: true)
            let tmp = stagingDir.appendingPathComponent(name)
            defer { try? FileManager.default.removeItem(at: stagingDir) }   // clean staging on EVERY path
            let tier = run.tier
            do {
                // Stage the (large) copy off the main actor so the UI never freezes. The copy also
                // MERGES the ecosystem ss_*/modelspec metadata (trigger + tier) into the header, so
                // the published file keeps its identity outside this app (ComfyUI, another Mac, HF).
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
                    do {
                        try SafetensorsInspector.copyAddingMetadata(
                            from: src, to: tmp,
                            extra: SafetensorsInspector.publishMetadata(trigger: trigger, tier: tier, outputName: name))
                    } catch {
                        // Metadata must never block a publish — fall back to a plain copy.
                        try? FileManager.default.removeItem(at: tmp)
                        try FileManager.default.copyItem(at: src, to: tmp)
                    }
                }.value
                // preservingUserMeta: a REPUBLISH replaces the same run's stable file name — the
                // user's pinned default strength and typed description must survive it (the
                // replace path otherwise prunes both sidecars for foreign same-named imports).
                let item = try await loraStore.importLoRA(from: tmp, preservingUserMeta: true)
                _ = await loraStore.setTrigger(trigger, forFileName: item.fileName)
                // Identity-card linkage: readable provenance + the run id (the jump-back key).
                _ = await loraStore.annotate(fileName: item.fileName,
                                             provenance: "Published from training “\(run.name)”",
                                             sourceRunID: run.id.uuidString)
                // Snapshot the model card NOW — deleting the run later deletes its outputDir
                // (validation images included), so everything the card needs is COPIED at
                // publish time. Best-effort: a card failure must never block a publish.
                let workshopName = workshops.first { $0.id == run.workshopId }?.name
                let (card, cardImages) = Self.makeModelCard(
                    run: run, checkpointStep: checkpointStep,
                    libraryFileName: item.fileName, workshopName: workshopName)
                await Task.detached(priority: .utility) {
                    try? ModelCardStore.write(card, copyingImages: cardImages)
                }.value
                // Lost-update guard: `run` was captured at click and the staging copy above took
                // seconds — an Extend/checkpoint-delete that landed meanwhile would be reverted
                // wholesale by upserting the stale snapshot. Re-read the freshest record and
                // overlay ONLY the fields publish owns (marker + presentation status).
                // nil = the run was deleted mid-publish. The LoRA is already in the library
                // (that's the user-visible outcome); upserting the stale snapshot would only
                // resurrect a ghost record pointing at a removed outputDir.
                if var r = await store.run(run.id) {
                    r.publishedCheckpointStep = publishedStep
                    // Presentation-only status: never clobber a run that went ACTIVE meanwhile
                    // (an Extend during this publish) — persistActive owns the status then.
                    if !r.status.isActive { r.status = .published }
                    _ = try await store.upsert(r)
                }
                reload()
                lastAction = .ok("Published “\(item.fileName)” to your LoRA library — select it in Generate (trigger “\(trigger)”).")
            } catch {
                lastAction = .error("Publish failed: \(error.localizedDescription)")
            }
        }
    }

    /// Reveal a checkpoint's (or the final) adapter file in Finder so the user can copy/keep it.
    func revealAdapter(run: TrainingRun, checkpointStep: Int?) {
        let url = adapterURL(run: run, checkpointStep: checkpointStep)
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastAction = .error("Adapter file not found."); return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func deleteCheckpoint(run: TrainingRun, step: Int) {
        Task { @MainActor in
            let fm = FileManager.default
            let dir = run.outputDir.appendingPathComponent("checkpoint_\(String(format: "%06d", step))")
            // Files FIRST, record second — and each step's failure is surfaced. The old
            // fire-and-forget order could keep a record whose directory removal failed, or
            // (worse) drop the upsert's throw after the files were already gone: a phantom
            // checkpoint that dies with "Adapter file not found" on publish.
            if fm.fileExists(atPath: dir.path) {   // already-gone dir → just clean the record
                do { try fm.removeItem(at: dir) }
                catch {
                    lastAction = .error("Couldn't delete the checkpoint files: \(error.localizedDescription)")
                    return
                }
            }
            // Lost-update guard: two quick deletes each captured the SAME `run` snapshot — the
            // second upsert restored the first one's checkpoint as a phantom record ("Adapter
            // file not found" on publish). Re-read the freshest record; remove ONLY this step.
            // nil = run deleted meanwhile; its whole outputDir is gone with it — done.
            guard var r = await store.run(run.id) else { reload(); return }
            r.runtime.checkpoints.removeAll { $0.step == step }
            if r.publishedCheckpointStep == step {
                r.publishedCheckpointStep = nil
                if r.status == .published { r.status = .completed }
            }
            do {
                _ = try await store.upsert(r)
                lastAction = .ok("Checkpoint at step \(step) deleted.")
            } catch {
                lastAction = .error("Checkpoint files deleted, but the record couldn't be saved — it may linger until the next save: \(error.localizedDescription)")
            }
            reload()
        }
    }

    // MARK: Auto-caption (Qwen3.5-VLM via DescribeService)

    /// Caption every image (or only the un-captioned ones) with the local vision model. Runs right
    /// away when the trainer is idle; while a training/caption job is active (or items are already
    /// waiting) it's queued as a caption JOB that runs FIFO with the training drafts — so "caption
    /// the new photos, then start the run" chains unattended overnight, and the VLM and the trainer
    /// stay strictly sequential.
    func autoCaption(id: UUID, onlyMissing: Bool) {
        guard let w = workshops.first(where: { $0.id == id }) else { return }
        let targets = onlyMissing
            ? w.images.filter { $0.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            : w.images
        guard !targets.isEmpty else {
            lastAction = .ok(onlyMissing ? "Every image already has a caption." : "Add some images first.")
            return
        }
        guard queuedCaptionJob(for: id) == nil else {
            lastAction = .ok("A caption job for this workshop is already queued.")
            return
        }
        if activeRunID != nil || captioning || smokeRunning || forging || finishingRun || !queue.isEmpty {
            queue.append(.caption(jobID: UUID(), workshopID: id, onlyMissing: onlyMissing))
            lastAction = .ok("Caption job queued (position \(queue.count)) — it starts automatically when the current work finishes.")
            startNextInQueue()   // no-op while busy; drains immediately if the queue was only stalled
            return
        }
        runCaptioning(id: id, refIDs: targets.map(\.id))
    }

    /// Caption a single image (the per-image button in the caption editor).
    func captionOne(_ refID: UUID, in id: UUID) {
        runCaptioning(id: id, refIDs: [refID])
    }

    func cancelCaptioning() {
        captionTask?.cancel()
        captionStatus = "Cancelling…"
    }

    /// Shared captioning engine: claim the VLM single-flight latch (mirrors the Describe path), then
    /// load the VLM once and decode + describe ONE image per iteration — cancellable between images —
    /// committing EACH caption the moment the VLM finishes it (one store write per caption, so a
    /// cancel or quit mid-batch keeps everything captioned so far). The trigger word is NOT stored —
    /// the engine prepends it at train time.
    /// `queueItem` is set when the call came from the queue: an engine-busy bail re-inserts it at the
    /// head (mirrors startRun) so the job stays visibly queued instead of silently vanishing.
    private func runCaptioning(id: UUID, refIDs: [UUID], queueItem: TrainingQueueItem? = nil) {
        // FULL trainer single-flight, not just captioning/smoke: captionOne calls this directly
        // (bypassing autoCaption's queue gate), and a VLM load during an active run would share
        // the MLX pool with the trainer — and its release at the task tail would clear the latch
        // the TRAINING set, unblocking freeMemory()/generate() mid-training-step.
        guard activeRunID == nil, !captioning, !smokeRunning, !forging, !finishingRun else {
            if let queueItem { queue.insert(queueItem, at: 0) }   // defensive — keep a queued job visible
            else { lastAction = .error("The trainer is busy — captioning runs when the current job finishes.") }
            return
        }
        guard let w = workshops.first(where: { $0.id == id }) else { return }
        let targets = w.images.filter { refIDs.contains($0.id) }   // workshop order, restricted to the request
        guard !targets.isEmpty else { return }
        let urls = targets.map { w.imageURL($0) }
        let targetIDs = targets.map(\.id)
        let desc = w.conceptDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = desc.count >= 3 ? desc : nil
        // The workshop's caption instruction (or its concept-type preset) → the VLM system prompt.
        let instruction = Self.effectiveCaptionInstruction(for: w)

        captioning = true
        captioningWorkshopID = id
        captionStatus = "Preparing…"
        captionTotal = targets.count
        captionDone = 0
        captionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.captioning = false; self.captionStatus = nil
                self.captionTotal = 0; self.captionDone = 0
                self.captioningWorkshopID = nil
            }
            // The VLM (~3 GB) shares the global MLX pool with generation — claim it so the two can't
            // run at once. If the engine is generating right now, setDescribing refuses → bail cleanly.
            // The queueRunning check covers the between-items window where the latch is briefly open.
            guard self.generationQueueBusy?() != true, await self.engine.setDescribing(true) else {
                if let queueItem {
                    // Came from the queue → keep the job at the head so it stays visibly queued
                    // (mirrors startRun's busy bail — no cascade, no silent loss).
                    self.queue.insert(queueItem, at: 0)
                    self.lastAction = .error("Engine is busy (generating or describing) — the caption job stays queued.")
                } else {
                    self.lastAction = .error("Busy right now — try Auto-caption again in a moment.")
                }
                self.notifyIfFullyIdle()
                return   // nothing acquired → no release needed
            }
            // Mirror the proven describeReferences() shape: the do/catch swallows every error (no
            // rethrow), so the unconditional release below runs on EVERY path that claimed the latch
            // (success / failure / cancel). A latched describing=true would brick generation.
            do {
                // LAZY per-image decode — the old path pre-decoded the WHOLE batch (a 110-photo
                // workshop ≈ 450 MB of bitmaps) and pinned it beside the ~3 GB VLM for the entire
                // multi-hour job. DescribeService.describe takes an already-decoded [CGImage], so
                // this drives the VLM directly with the exact bracket describe() uses (download →
                // load ONCE → per-image inference → unload) while decoding a single ~4 MB
                // downsample per iteration, released before the next.
                self.captionStatus = DescribeService.isModelDownloaded
                    ? "Loading Qwen3.5-VLM…" : "Downloading Qwen3.5-VLM (~3 GB, one time)…"
                let path = try await TextEncoderModelDownloader().downloadQwen35(variant: DescribeService.variant) { p, _ in
                    if p < 1 { Task { @MainActor in self.captionStatus = "Downloading Qwen3.5-VLM… \(Int(p * 100))%" } }
                }
                try await FluxTextEncoders.shared.loadQwen35VLM(from: path.path)
                var unreadable = 0
                do {
                    for (k, url) in urls.enumerated() {
                        // Honor a Cancel between images (one image's inference itself is
                        // uninterruptible, ~10–30 s — the same granularity describe() had).
                        try Task.checkCancellation()
                        self.captionStatus = urls.count > 1 ? "Describing image \(k + 1) of \(urls.count)…"
                                                            : "Describing image…"
                        // Decode + inference OFF the main actor; a file that fails to decode is
                        // skipped (nil), exactly like the old upfront compactMap did.
                        let text: String? = try await Task.detached(priority: .userInitiated) { () async throws -> String? in
                            guard let img = WorkshopDatasetService.decodeForCaption(at: url) else { return nil }
                            // Mirrors DescribeService.describe's instruction path: the workshop
                            // context is the user prompt, the caption instruction replaces the
                            // system prompt, temperature 0 keeps batch captions deterministic.
                            return try FluxTextEncoders.shared.analyzeImageWithQwen35(
                                image: img,
                                prompt: context ?? "Caption this image.",
                                systemPrompt: instruction,
                                maxTokens: 300,
                                temperature: 0
                            ).text.trimmingCharacters(in: .whitespacesAndNewlines)
                        }.value
                        guard let text else { unreadable += 1; continue }
                        // Commit EACH caption the moment it lands (live fill; quit-safe).
                        self.captionDone += 1
                        self.commitAutoCaption(text, refID: targetIDs[k], in: id)
                    }
                    FluxTextEncoders.shared.unloadQwen35VLM()
                } catch {
                    FluxTextEncoders.shared.unloadQwen35VLM()   // never leave the VLM resident on a throw
                    throw error
                }
                if self.captionDone == 0, unreadable > 0 {
                    self.lastAction = .error("Couldn't read the selected image(s).")
                } else {
                    let n = self.captionDone
                    self.lastAction = .ok("Captioned \(n) image\(n == 1 ? "" : "s") with the vision model.")
                }
            } catch is CancellationError {
                let n = self.captionDone
                self.lastAction = .ok(n > 0 ? "Auto-caption cancelled — \(n) caption\(n == 1 ? "" : "s") already saved."
                                            : "Auto-caption cancelled.")
            } catch {
                self.lastAction = .error("Auto-caption failed: \(error.localizedDescription)")
            }
            await self.engine.setDescribing(false)
            self.chainAfterCaptioning()   // (fires one hop later, after the defer resets `captioning`)
        }
    }

    /// Persist one VLM caption immediately (live fill: the grid dot, tooltip and open caption
    /// editor update per image, and nothing is lost on a quit mid-batch).
    private func commitAutoCaption(_ text: String, refID: UUID, in id: UUID) {
        mutateWorkshop(id) { ws in
            guard let j = ws.images.firstIndex(where: { $0.id == refID }) else { return }
            ws.images[j].caption = text
            ws.images[j].captionSource = .auto
        }
    }

    /// The instruction actually sent to the VLM for a workshop: its custom caption instruction if
    /// set, else the concept-type preset (also what the editor shows as the placeholder).
    nonisolated static func effectiveCaptionInstruction(for w: Workshop) -> String {
        let custom = (w.captionInstruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? DescribeService.captionInstruction(for: w.conceptType) : custom
    }

    /// One MainActor hop after a caption job ends — so the flags reset in its `defer` are already
    /// visible — chain the next queued item and, if nothing chained, hand the GPU to an armed
    /// generation queue. This is what un-stalls a training that was enqueued DURING captioning.
    private func chainAfterCaptioning() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.startNextInQueue()
            if self.fullyIdle { self.onFullyIdle?() }
        }
    }

    // MARK: Smoke run (Chunk 2 — throwaway engine verification)

    /// Kick off a short LoRA training on a picked image folder to prove the engine + memory on
    /// this Mac. Owns the GPU single-flight bracket (mirrors the Describe path): evict the
    /// resident inference pipeline, then claim the MLX pool so generation can't run concurrently.
    func runSmoke(folder: URL) {
        guard !smokeRunning else { return }   // single-flight: ignore a re-entrant click
        smokeRunning = true
        smokeError = nil
        smoke = nil
        smokeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Flag first, then chain/idle checks (defer statements run in order) — a queue or an
            // armed generation queue must not stay stranded behind a finished smoke run.
            defer { self.smokeRunning = false; self.startNextInQueue(); self.notifyIfFullyIdle() }
            // Between-items window (see generationQueueBusy) — don't evict/claim mid-queue.
            let generationQueueMidRun = self.generationQueueBusy?() == true
            // Evict the inference pipeline FIRST — the ~8 GB base transformer needs the full
            // 32 GB budget; freeMemory's guard requires describing to still be false here.
            if !generationQueueMidRun { _ = await self.engine.freeMemory() }
            guard !generationQueueMidRun, await self.engine.setDescribing(true) else {
                self.smokeError = "Engine is busy (generating or describing) — try again in a moment."
                return   // nothing acquired → no release needed
            }
            // The do/catch below swallows every error (no rethrow), so the tail after it runs on
            // EVERY path that claimed the latch — a latched describing=true would brick generation.
            do {
                try await TrainingService.smokeRun(folder: folder,
                    onUpdate: { u in Task { @MainActor in self.smoke = u } })
            } catch {
                self.smokeError = error.localizedDescription
                self.smoke = nil   // clear stale status so the run can be retried cleanly
            }
            // AWAITED inline (exactly like startRun/runCaptioning), NOT a fire-and-forget defer:
            // the defer above chains startNextInQueue() synchronously, and a detached release
            // could lose that race — the chained training would bail against a still-latched
            // engine and cascade the whole queue.
            await self.engine.setDescribing(false)
            // The smoke run's base transformer is dead but its buffers sit in the MLX pool —
            // flush BEFORE the defer chains the next queued item / hands off to generation
            // (same rationale as the startRun tail).
            MaintenanceService.clearMLXPool()
        }
    }
}
