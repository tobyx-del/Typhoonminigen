import SwiftUI
import Observation
import CoreGraphics
import Flux2Core

/// Drives one text-to-image generation: inputs, live progress + ETA, result.
@MainActor
@Observable
final class GenerateViewModel {
    // MARK: Inputs
    // The draft form (size / toggles / batch) persists across launches — losing dialed-in
    // settings to an accidental quit costs real work. The PROMPT deliberately does NOT
    // persist (privacy, 2026-06-11): it's user content, and settings were the only place it
    // lived outside the gallery. Seed is also not persisted: a stale fixed seed silently
    // stamps every new series (user-reported confusion).
    var prompt: String = ""
    /// Selected model tier. Persisted across launches; first launch defaults by RAM
    /// (see init). Switching clears the LoRA selection — a dim-4096 adapter fused into the
    /// 4B transformer (or vice versa) is silent weight corruption: the engine only LOGS a
    /// mismatch warning and merges anyway.
    var tier: ModelTier = .klein9B {
        didSet {
            guard tier != oldValue else { return }
            UserDefaults.standard.set(tier.rawValue, forKey: Self.tierKey)
            steps = tier.defaultSteps   // reset to the new tier's distilled default
            // Quality rungs differ per tier (4B: 4, 9B: 2) — keep the rung if both tiers have
            // it (e.g. Best), otherwise fall back to the new tier's default.
            if !tier.qualityPresets.contains(quality) { quality = tier.defaultQuality }
            loraSlots.removeAll()   // wrong-tier adapters must not survive a tier switch
            reloadLoRAs()
            Task { @MainActor in await syncModelState() }  // pill: is THIS tier resident?
            AppLog.info("Model tier switched to \(tier.shortName)")
        }
    }
    // Size persists only while it's the USER'S size: adding a reference auto-snaps the
    // dims (preReferenceSize holds the original), and persisting that snap would restore
    // a reference-derived size on relaunch with no reference in sight to explain it.
    var width: Int = 1024 {
        didSet {
            guard preReferenceSize == nil else { return }
            UserDefaults.standard.set(width, forKey: Self.draftWidthKey)
        }
    }
    var height: Int = 1024 {
        didSet {
            guard preReferenceSize == nil else { return }
            UserDefaults.standard.set(height, forKey: Self.draftHeightKey)
        }
    }
    var seedText: String = ""          // empty = random

    /// Denoising steps. Klein is distilled (4 = its trained sweet spot), but the engine
    /// accepts ANY step count as a pure runtime parameter — NO model reload, no engine clamp
    /// (verified live: Klein 9B renders fine at 10/20/50 steps, just slower). Stored +
    /// persisted; resets to the tier default on a tier switch; clamped 1…maxSteps.
    var steps: Int = 4 {
        didSet {
            let clamped = min(Self.maxSteps, max(1, steps))
            if clamped != steps { steps = clamped; return }   // re-enters with the clamped value
            guard steps != oldValue else { return }
            UserDefaults.standard.set(steps, forKey: Self.stepsKey)
        }
    }
    static let maxSteps = 50

    /// Guidance stays tier-fixed (1.0 for Klein) and has NO slider on purpose: the distilled
    /// Klein tiers are CFG-free — `usesGuidanceEmbeds` is false in the engine, so it ignores
    /// the value entirely. A guidance control here would be a fake knob (only Dev uses it).
    var guidance: Float { tier.defaultGuidance }

    /// Render-quality rung (quantization preset). Persisted; reset to the tier default when the
    /// tier changes (rungs differ per tier). Drives buildRequest's quant + the download gate.
    var quality: QualityPreset = .medium {
        didSet {
            guard quality != oldValue else { return }
            UserDefaults.standard.set(quality.rawValue, forKey: Self.qualityKey)
            Task { @MainActor in await syncModelState() }   // pill/CTA reflects the new quant
        }
    }

    // MARK: State
    var isBusy = false
    var statusMessage = ""
    var progress: Double = 0           // 0...1
    var etaSeconds: Double? = nil
    var currentStep: Int = 0           // last completed denoise step (for the rail)
    /// Total steps of the CURRENTLY RENDERING item — NOT the live `steps` slider. Drives the
    /// "step X of N" progress + the preview blur, so dragging the slider mid-render no longer
    /// shifts the running render's displayed total or its preview blur.
    var renderSteps: Int = 4
    var resultImage: CGImage? = nil
    var errorMessage: String? = nil
    var lastSavedURL: URL? = nil
    var savedImageCount = 0            // bumped once per gallery save — a MONOTONIC signal the
                                       // Gallery observes; lastSavedURL toggles nil→URL→nil within
                                       // one queue run so it never reaches SwiftUI as a change (#live-refresh)
    var isModelLoaded = false          // SELECTED tier resident in RAM (drives the status pill)
    var residentTier: ModelTier? = nil // whichever tier the engine actually holds (unload button)
    // Stored (not computed) so the idle canvas doesn't re-stat the disk on every telemetry
    // tick — refreshed by syncModelState (tab switch, tier change, downloads, gen end).
    var modelMissing = false           // selected tier's transformer not on disk → canvas CTA
    var encoderMissing = false         // selected tier's Qwen3 encoder not on disk → CTA variant
    // Klein 9B's two Qwen3-8B encoder variants on disk — cached inputs for the model card's
    // honest "Standard vs Best render identically" note. Stored for the same reason as the
    // flags above: encodersOnDisk parses model.safetensors.index.json and stats every shard,
    // and the Generate body re-evaluates on every telemetry tick / step tick / keystroke —
    // under a saturated disk (a model downloading) those sync probes stalled typing.
    var nineBEncoder8BitOnDisk = false
    var nineBEncoder4BitOnDisk = false
    var lastGenSeconds: Double? = nil  // wall-clock of the last completed generation
    // Render telemetry: what the "frozen" pre-step-1 window is actually doing, the denoise pace,
    // and the app's real peak footprint — recorded per render, shown live and in the gallery.
    var renderPhase: String? = nil       // "Loading model…" / "Encoding & preparing…" until step 1
    var lastStepSeconds: Double? = nil   // smoothed seconds per denoise step (this/last render)
    private var lastTickAt: Date? = nil
    private var peakFootprintGB: Double = 0
    var lastSeed: UInt64? = nil        // seed of the last completed generation (for the canvas overlay)

    // LoRA selection (only adapters compatible with the current tier are offered).
    // UNLIMITED list (Fluxforge-style Add/Remove) — the engine fuses adapters sequentially and
    // their deltas SUM with NO count cap; inference RAM stays flat (they fold into the base and
    // their matrices are freed). Each entry has its own strength. Stable UUID id so the dynamic
    // list survives add/remove without ForEach identity churn.
    struct LoRASlot: Identifiable {
        let id = UUID()
        var item: LoRAItem? = nil
        var scale: Float = 1.0
    }
    var availableLoRAs: [LoRAItem] = []
    /// Every compatible adapter on disk, unfiltered by tier — drives the "switch to the
    /// other tier to use these" hint when the current tier has no matching adapters.
    private var allLoRAsOnDisk: [LoRAItem] = []
    /// Adapters on disk built for the OTHER tier (empty unless the active tier has none of its own).
    var loRAsForOtherTier: [LoRAItem] { allLoRAsOnDisk.filter { $0.tier != nil && $0.tier != tier } }
    /// The fuse list — starts empty, grows via Add LoRA (no fixed slot count).
    var loraSlots: [LoRASlot] = []
    /// The slots that actually carry a selection (drives the UI notes and the request).
    var activeLoRASlots: [LoRASlot] { loraSlots.filter { $0.item != nil } }
    /// The placeholder token this slot's trigger answers to ("[trigger]", "[trigger:2]", …) —
    /// numbered by position among the TRIGGERED slots in list order, matching the request's
    /// substitution. Nil when the slot has no selection or no trigger word.
    func triggerPlaceholderToken(for slotID: UUID) -> String? {
        let triggered = activeLoRASlots.filter { $0.item?.trigger.isEmpty == false }
        guard let idx = triggered.firstIndex(where: { $0.id == slotID }) else { return nil }
        return TriggerPlaceholder.token(idx + 1)
    }
    /// True when the live prompt already carries this slot's token (flips the row note from
    /// "appended automatically" to "replaces [trigger]").
    func promptUsesTriggerPlaceholder(for slotID: UUID) -> Bool {
        guard let token = triggerPlaceholderToken(for: slotID) else { return false }
        if prompt.range(of: token, options: .caseInsensitive) != nil { return true }
        // "[trigger:1]" is the explicit spelling of the first token — honor it too.
        return token == TriggerPlaceholder.token(1)
            && prompt.range(of: "[trigger:1]", options: .caseInsensitive) != nil
    }
    var upsamplePrompt = false {
        didSet { UserDefaults.standard.set(upsamplePrompt, forKey: Self.upsampleKey) }
    }

    /// Add an adapter to the fuse list (deduped by file — fusing the same file twice just
    /// doubles its effect and would mislead the footer).
    func addLoRA(_ item: LoRAItem) {
        guard !loraSlots.contains(where: { $0.item?.id == item.id }) else { return }
        // MANUAL adds start at the adapter's saved sweet-spot strength (recipe/remix restores go
        // through applyLoRAUses and keep their recorded scale untouched).
        loraSlots.append(LoRASlot(item: item, scale: item.defaultScale ?? 1.0))
    }

    /// Persist the slot's CURRENT strength as this adapter's default (the value future manual
    /// adds pre-select) — the "0.8 fixes the mutations" lesson, made permanent per adapter.
    func saveDefaultScale(_ slotID: UUID) {
        guard let slot = loraSlots.first(where: { $0.id == slotID }), let item = slot.item else { return }
        let scale = slot.scale
        Task { @MainActor in
            _ = await loraStore.setDefaultScale(scale, forFileName: item.fileName)
            reloadLoRAs()   // re-point slots/pickers at the fresh items so defaultScale is visible
            statusMessage = "“\(item.fileName)” now defaults to strength \(String(format: "%.2f", scale))."
        }
    }

    // MARK: LoRA strength sweep

    /// The rung set every sweep renders — brackets the mutation zone (clean 0.75–0.9 vs 1.0+).
    static let sweepScales: [Float] = [0.6, 0.7, 0.8, 0.9, 1.0, 1.1]

    /// Queue one render per strength rung for ONE adapter — same prompt, SAME seed, same
    /// size/steps/other adapters — so strength is the only variable across the series. Starts
    /// right away when the queue is idle; the labels carry the strength for the gallery review.
    func sweepStrength(_ slotID: UUID) {
        guard canGenerate, ensureModelReady() else { return }
        guard let idx = loraSlots.firstIndex(where: { $0.id == slotID }), let item = loraSlots[idx].item else { return }
        idleUnloadTask?.cancel()
        errorMessage = nil
        // One shared seed: a pinned form seed is respected; otherwise draw one and reuse it.
        let seed = seedValue ?? UInt64.random(in: 0 ... UInt64.max)
        let refImages = references.map(\.image)
        let original = loraSlots[idx].scale
        // Built into a local series (not straight into `queue`) so an idle queue can take it
        // as ONE contiguous block at the head — see below.
        var series: [QueueItem] = []
        for scale in Self.sweepScales {
            loraSlots[idx].scale = scale
            let req = buildRequest(seed: seed)
            series.append(QueueItem(request: req, referenceImages: refImages,
                                    label: "sweep \(String(format: "%.2f", scale)) · \(item.fileName)"))
        }
        loraSlots[idx].scale = original
        if queueRunning {
            queue.append(contentsOf: series)
            queueTotal += series.count
            statusMessage = "Strength sweep queued — \(series.count) renders, one seed, \(item.fileName) at 0.6→1.1."
        } else {
            // Idle queue with drafted tasks: the sweep is what the user asked for NOW — insert
            // it as a contiguous block at the HEAD so it renders first and the drafts follow
            // (same head-insert honesty as generate(); startQueue drains the whole queue).
            let drafted = queue.count
            queue.insert(contentsOf: series, at: 0)
            // startQueue overwrites statusMessage as items run — the "what to do next" guidance
            // lives in the sweep button's tooltip instead, where it can actually be read.
            statusMessage = "Strength sweep — \(series.count) renders, one seed, \(item.fileName) at 0.6→1.1."
                + (drafted > 0 ? " \(drafted) drafted task(s) will follow." : "")
            startQueue()
        }
    }

    /// Remove one adapter row by its stable id.
    func removeLoRA(_ id: LoRASlot.ID) {
        loraSlots.removeAll { $0.id == id }
    }

    /// Remove every adapter from the fuse list.
    func clearAllLoRAs() {
        loraSlots.removeAll()
    }

    // Prompt presets — camera / shot / lighting / style chips appended to the prompt at generation.
    var selectedPresetIDs: Set<String> = []

    // I2I — reference images (empty = T2I mode). The engine accepts at most 3.
    struct ReferenceSlot: Identifiable {
        let id = UUID()
        let image: CGImage
        let url: URL?   // nil when fed from the canvas result before it was saved
    }
    var references: [ReferenceSlot] = []
    // 4 = the model's spec max (Flux2Config.maxReferenceImages). We feed them via the engine's
    // generate(mode:) path, which (unlike the generateImageToImage wrapper) has no 3-image guard.
    // RAM barely scales with ref count (3 refs ≈ 17.7 GB on 32 GB); TIME does (~+3.5 min/ref).
    static let maxReferences = 4
    var isDescribing = false {   // Qwen3.5-VLM is reading the references right now
        // Re-arm hook: a trainingDidBecomeIdle ping landing while a Describe/Ask/Compare holds
        // the MLX pool keeps the queue ARMED (see restartArmedQueueIfReady) — retry the deferred
        // start the moment ANY path releases the flag. A didSet (not per-call-site calls) so
        // every current and future describe path re-checks; the onDescribeIdle closure only
        // pings the TRAINER (TyphoonminigenApp wiring) and never re-reads our armed flag.
        didSet { if oldValue, !isDescribing { restartArmedQueueIfReady() } }
    }
    var vlmAnswer: String? = nil                              // "Ask AI about this image" answer
    var vlmComparison: DescribeService.ComparisonResult? = nil   // "Compare to reference" scores
    var isUpscaling = false    // Real-ESRGAN is enlarging the last result

    // Generation queue — "Generate" enqueues `batchCount` items (series of seeds) and renders
    // now; "Add to queue" composes tasks without running. Items run strictly one at a time (the
    // engine actor serializes anyway). request/label are var so a pending task can be edited (#2).
    /// What a queued task actually does. Generation tasks carry their full request snapshot;
    /// an upscale task is self-contained (source file + factor) and runs through the SAME
    /// sequential runner — so renders and upscales line up in one Run All.
    enum QueueTaskKind: Equatable {
        case generation
        case upscale(source: URL, factor: Int)
    }

    struct QueueItem: Identifiable {
        let id = UUID()
        var request: GenerationRequest   // placeholder (never rendered) for upscale tasks
        let referenceImages: [CGImage]
        var label: String        // short prompt excerpt for the queue list
        var kind: QueueTaskKind = .generation
    }
    var queue: [QueueItem] = []
    var queueRunning = false
    var queueDone = 0            // finished items in the current run
    var queueTotal = 0           // total enqueued in the current run
    var batchCount = 1 {         // how many seeds "Generate" enqueues at once
        didSet { UserDefaults.standard.set(batchCount, forKey: Self.batchKey) }
    }
    var currentItemID: QueueItem.ID? = nil
    var lastSavedGenID: UUID? = nil          // gallery id of the on-canvas render (#11 "delete it")
    var lastResultWasCancelled = false       // the kept frame came from a stopped run
    /// Set by runUpscaleTask when Stop lands while its item is still WAITING on the single
    /// Real-ESRGAN gate (never started): the run loop then leaves the item in the queue —
    /// Stop's "N task(s) kept" message used to lie there, the waiting task was consumed.
    private var stopKeepsCurrentItem = false

    /// Seed strategy when duplicating a queued task (#1 scheduler).
    enum SeedMode: Sendable { case newRandom, same, sequential }

    // Live render preview — the engine VAE-decodes the latents after every step and the
    // canvas shows the image taking shape. Costs ~one VAE decode per step (a few seconds
    // per image at 1024²), so it's a toggle.
    var livePreview = false {
        didSet { UserDefaults.standard.set(livePreview, forKey: Self.livePreviewKey) }
    }
    var previewImage: CGImage? = nil
    var previewStep: Int = 0
    var previewEveryStep = false {   // when livePreview is on: show EVERY step like Draw Things (noisy early frames) vs one clean frame at ~75%
        didSet { UserDefaults.standard.set(previewEveryStep, forKey: Self.previewEveryStepKey) }
    }

    // MARK: Internals
    private let engine: FluxEngine
    private let store: GenerationStore
    private let loraStore: LoRAStore
    private let sessionStats: SessionStats
    private var genTask: Task<Void, Never>? = nil
    private var describeTask: Task<Void, Never>? = nil
    private var genStart: Date? = nil
    private var cancelledGen = false
    // Bumped at the start of every queue item. Late MainActor hops (a preview checkpoint
    // landing after cancel) and the sleeping idle-unload task check it so a stale callback
    // can't re-pin an old preview or unload right under a fresh run.
    private var generationEpoch = 0
    private var preReferenceSize: (width: Int, height: Int)? = nil  // dims to restore on Remove
    private var idleUnloadTask: Task<Void, Never>? = nil   // frees ~9–19 GB when the user walks away
    // Single-slot reload (same pattern as LoRAViewModel.reload): reloadLoRAs fires on appear,
    // every tier switch and saveDefaultScale — without cancel-before-replace, overlapping
    // discover() snapshots could apply out of order (an older list landing over a newer one).
    private var reloadLoRAsTask: Task<Void, Never>? = nil
    // Bumped per syncModelState call: its disk probe runs detached, so two overlapping syncs
    // (a download-finished ping racing the tab's .task) could resolve out of order — only the
    // freshest snapshot may land, or a stale "missing" reading would stick until the next event.
    private var modelProbeEpoch = 0
    private static let idleUnloadMinutes = 15

    init(engine: FluxEngine, store: GenerationStore, loraStore: LoRAStore, sessionStats: SessionStats) {
        self.engine = engine
        self.store = store
        self.loraStore = loraStore
        self.sessionStats = sessionStats
        // Restore the preset selection from the last launch, dropping ids that no longer exist
        // (e.g. a deleted custom chip) AND ids hidden via the context menu — a hidden built-in
        // used to come back ALREADY selected, silently re-entering the prompt.
        let saved = UserDefaults.standard.array(forKey: Self.presetSelectionKey) as? [String] ?? []
        selectedPresetIDs = Set(saved.filter { PresetCatalog.category(for: $0) != nil })
            .subtracting(CustomPresetStore.shared.hiddenIDs)
        // Tier: stored preference wins; on first launch auto-detect by RAM. 9B peaks at
        // ~19–20 GB phys_footprint (measured on the 32 GB M4) + ~4–5 GB macOS, so 24 GB
        // machines land at the edge — only ≥32 GB defaults to 9B (user decision 2026-06-10).
        if let raw = UserDefaults.standard.string(forKey: Self.tierKey),
           let storedTier = ModelTier(rawValue: raw) {
            tier = storedTier
        } else if ramGB < 32 {
            tier = .klein4B
        }
        // Seed a neutral sample prompt whenever the box would otherwise be empty on launch —
        // so first use AND a fresh start after "Remove all data" aren't an intimidating blank
        // field. The prompt is session-only (never persisted — privacy), so this re-seeds on
        // each launch until the user types their own; it never overwrites typed text mid-session.
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt = "A serene mountain lake at sunrise, soft mist over the water, pine forest, warm golden light"
        }
        // Restore the draft form (prompt intentionally absent — see its declaration).
        // The didSet observers fire on these assignments and write the same values back —
        // harmless. Width/height are validated so a corrupted default can't smuggle in an
        // unsafe generation size.
        UserDefaults.standard.removeObject(forKey: "draftPrompt")  // scrub drafts saved by pre-0.45 builds
        let w = UserDefaults.standard.integer(forKey: Self.draftWidthKey)
        let h = UserDefaults.standard.integer(forKey: Self.draftHeightKey)
        // Snap restored drafts to /32 — a pre-fix build may have persisted a tearing width (720).
        if (ReferenceSize.minSide...ReferenceSize.maxSide).contains(w) { width = ReferenceSize.snap(w) }
        if (ReferenceSize.minSide...ReferenceSize.maxSide).contains(h) { height = ReferenceSize.snap(h) }
        // Live preview now defaults to Off. Apply that new default ONCE to existing installs
        // too (the user asked for Off by default); afterwards their own choice persists normally.
        if UserDefaults.standard.bool(forKey: Self.previewDefaultOffKey) {
            if UserDefaults.standard.object(forKey: Self.livePreviewKey) != nil {
                livePreview = UserDefaults.standard.bool(forKey: Self.livePreviewKey)
            }
            previewEveryStep = UserDefaults.standard.bool(forKey: Self.previewEveryStepKey)
        } else {
            // didSet does NOT fire for assignments inside init, so persist explicitly —
            // otherwise the stale stored value reloads on the next launch and the new
            // Off-default is lost after one run.
            UserDefaults.standard.set(true, forKey: Self.previewDefaultOffKey)
            UserDefaults.standard.set(false, forKey: Self.livePreviewKey)
            UserDefaults.standard.set(false, forKey: Self.previewEveryStepKey)
            livePreview = false
            previewEveryStep = false
        }
        upsamplePrompt = UserDefaults.standard.bool(forKey: Self.upsampleKey)
        let batch = UserDefaults.standard.integer(forKey: Self.batchKey)
        if (1...8).contains(batch) { batchCount = batch }
        // Steps ALWAYS start at 4 on launch (Klein's distilled sweet spot) — explicit and hard, not
        // via tier.defaultSteps, so it can't drift if an engine default changes. A previous session's
        // value is never restored (a stale 50 would quietly cost 12-min renders). Loading a Library
        // card still applies THAT card's pinned steps; only a fresh/blank start is 4.
        steps = 4
        // Restore the quality rung — only if it's valid for the resolved tier.
        if let qraw = UserDefaults.standard.string(forKey: Self.qualityKey),
           let q = QualityPreset(rawValue: qraw), tier.qualityPresets.contains(q) {
            quality = q
        } else {
            quality = tier.defaultQuality
        }
    }

    private static let presetSelectionKey = "selectedPresetIDs"
    private static let tierKey = "selectedModelTier"
    private static let previewEveryStepKey = "previewEveryStep"
    private static let draftWidthKey = "draftWidth"
    private static let draftHeightKey = "draftHeight"
    private static let livePreviewKey = "livePreview"
    private static let previewDefaultOffKey = "previewDefaultOffApplied"   // one-time migration to Off-by-default
    private static let upsampleKey = "upsamplePrompt"
    private static let batchKey = "batchCount"
    private static let stepsKey = "stepsCount"
    private static let qualityKey = "qualityPreset"

    /// Physical RAM in GB (drives the tier default and the 9B-on-small-Mac warning).
    var ramGB: Int { SystemRAM.installedGB }

    /// Output area past which Klein quality degrades (mutations) — its sweet spot is
    /// ~1.05 MP regardless of tier; the engine has no working size guard of its own.
    /// 1_100_000 so 1152×1024 (1.18 MP) already warns, 1024×1024 doesn't.
    var sizeIsLarge: Bool { width * height > 1_100_000 }

    /// Max generation AREA (px) this Mac can VAE-decode without the GPU aborting. <16 GB
    /// (i.e. 8 GB) crashes above ~0.8 MP — 896²=0.80 MP works, 1024²=1.05 MP aborts (GPU
    /// command-buffer OOM → mlx check_error throw → abort). 16/32 GB take the full range.
    /// Shared with the engine's hard floor so the two clamps can't silently diverge.
    var maxGenArea: Int { ReferenceSize.maxArea(forInstalledGB: ramGB) }

    /// Clamp a size to `maxGenArea`, preserving aspect + /32 (stride-safe) granularity. No-op if it fits.
    func clampedSizeForRAM(_ w: Int, _ h: Int) -> (width: Int, height: Int) {
        guard w > 0, h > 0, w * h > maxGenArea else { return (w, h) }
        let s = (Double(maxGenArea) / Double(w * h)).squareRoot()
        // snapDown floors (not rounds) so the result is ALWAYS ≤ maxGenArea, AND /32 so the capped
        // width's RGB row stride stays 32-aligned (else it tears). 1024² on 8 GB → 896² (803k ≤ 820k).
        return (ReferenceSize.snapDown(Int(Double(w) * s)),
                ReferenceSize.snapDown(Int(Double(h) * s)))
    }

    // NOTE: no isBusy gate — while the queue runs the same button ADDS to the queue
    // (the leftover isBusy check from the pre-queue era silently swallowed every
    // "Add to queue" click — user-reported twice).
    var canGenerate: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !isDescribing   // VLM holds ~3 GB + GPU — finish describing before generating
        && !seedIsInvalid  // S-6: disable button instead of showing an error after tap
    }

    /// Seed text with separators stripped — pasted seeds often carry locale commas/spaces
    /// (the gallery used to display them that way).
    private var cleanedSeedText: String {
        seedText.filter { $0.isNumber }
    }

    var seedValue: UInt64? {
        let t = cleanedSeedText
        return t.isEmpty ? nil : UInt64(t)
    }

    /// True if the seed field has text that isn't a valid number.
    var seedIsInvalid: Bool {
        let raw = seedText.trimmingCharacters(in: .whitespaces)
        return !raw.isEmpty && UInt64(cleanedSeedText) == nil
    }

    /// Human-friendly time of the last generation, e.g. "47 s" or "2 min 27 s".
    var lastGenText: String? {
        guard let s = lastGenSeconds else { return nil }
        if s < 60 { return String(format: "%.0f s", s) }
        return "\(Int(s) / 60) min \(Int(s) % 60) s"
    }

    // MARK: Actions

    /// Generate-screen primary: enqueue `batchCount` items (one per seed) and start the run if
    /// the queue is idle. With a fixed seed the series uses seed, seed+1, … (reproducible).
    func generate() {
        guard canGenerate, ensureModelReady() else { return }
        idleUnloadTask?.cancel()
        errorMessage = nil
        if queueRunning {
            enqueueFromForm()
            statusMessage = "Added to queue — \(max(0, queue.count - 1)) waiting"
            AppLog.info("Added \(max(1, batchCount)) item(s) to queue (\(max(0, queue.count - 1)) waiting)")
            return
        }
        // Idle queue holding DRAFTED tasks: Generate means "render THIS now", so the fresh
        // batch head-inserts at index 0 and the drafts follow — startQueue drains the whole
        // queue, and silently rendering every draft BEFORE the user's explicit ask was the
        // same trap enqueueUpscales documents. Here the drafts still run, but after the ask
        // and with an honest note.
        let drafted = queue.count
        enqueueFromForm()   // appends at the tail — relocate the fresh batch to the head below
        if drafted > 0 {
            let fresh = Array(queue[drafted...])
            queue.removeSubrange(drafted...)
            queue.insert(contentsOf: fresh, at: 0)
            statusMessage = "Rendering now — \(drafted) drafted task(s) will follow."
            AppLog.info("Generate head-inserted ahead of \(drafted) drafted task(s)")
        }
        startQueue()
    }

    /// "Add to queue": compose a task (or batch) from the current form WITHOUT starting the run
    /// — build a list of different prompts, then "Run all" on the Queue tab. (#1)
    func addTaskToQueue() {
        guard canGenerate else { return }
        idleUnloadTask?.cancel()
        errorMessage = nil
        enqueueFromForm()
        let n = queue.count
        statusMessage = "Added to queue — \(n) task\(n == 1 ? "" : "s") waiting"
        AppLog.info("Added \(max(1, batchCount)) task(s) to the queue (now \(n))")
    }

    /// Library quick-add (#queue-presets): append ONE task built from a scene recipe — its subject +
    /// chips, combined with the CURRENT technical settings (tier, size, LoRA). Doesn't touch the form
    /// or the canvas and works while a render runs, so you can line up several scenes and walk away.
    /// Each add gets its OWN random seed (a varied batch must not share one — pin a specific seed
    /// later via the Queue editor). Returns the new queue length.
    @discardableResult
    func enqueueScene(_ recipe: SceneRecipe) -> Int {
        errorMessage = nil   // a stale render error would otherwise hide the "Added — N in queue" confirmation in the Library
        idleUnloadTask?.cancel()
        // The scene's chips apply via buildRequest's ignoringHidden suffix — no need to permanently
        // un-hide them globally (a queue-add must not mutate the user's hidden-chip set).
        // Each Library add gets its OWN random seed: queuing a batch of DIFFERENT scenes must not
        // stamp them all with the form's pinned seed (a fixed seed is for reproducing ONE
        // composition, not a varied batch). Pin a specific seed by editing the task in the Queue.
        // A recipe with a pinned seed reproduces its bundled preview; otherwise a fresh random one.
        let seed = recipe.seed ?? UInt64.random(in: 0 ... UInt64.max)
        // A recipe pinned to the OTHER tier can't take the form's LoRAs (a cross-tier fuse is
        // silent weight corruption) — exclude them from the BUILD itself, not just the request:
        // buildRequest bakes each adapter's trigger word into the prompt, so clearing req.loras
        // after the fact left dangling trigger words steering the render.
        let crossTier = recipe.tier.map { $0 != tier } ?? false
        var req = buildRequest(seed: seed,
                               promptOverride: recipe.subjectExample,
                               presetIDsOverride: Set(recipe.chipIDs),
                               includeLoRAs: !crossTier)
        // Bake the recipe's pinned settings so a QUEUED scene renders like its preview too (the
        // loadScene path does this via the form; the queue path bakes them straight into the request).
        if let t = recipe.tier, t != req.tier {
            req.tier = t
            req.loras = []   // belt-and-braces — includeLoRAs:false above already excluded them (and their triggers)
            // Clamp to the TARGET tier's rungs like the sibling branch below: a 4B card pinned to
            // Low, tier-flipped to 9B in the editor, would otherwise hit quantConfig's default
            // fallback (qint8 — a rung 9B never offers) and silently degrade every render.
            let q = recipe.quality.flatMap { t.qualityPresets.contains($0) ? $0 : nil } ?? t.defaultQuality
            req.quality = q.rawValue
            req.quant = t.quantConfig(for: q)
        } else if let q = recipe.quality, req.tier.qualityPresets.contains(q) {
            req.quality = q.rawValue
            req.quant = req.tier.quantConfig(for: q)
        }
        if let s = recipe.steps { req.steps = min(Self.maxSteps, max(1, s)) }
        if let w = recipe.aspectW, let h = recipe.aspectH {
            let sz = Self.aspectSize(w, h)
            let c = clampedSizeForRAM(sz.width, sz.height)
            req.width = c.width
            req.height = c.height
        }
        // A scene is text-to-image — don't inherit the form's leftover references (that silently
        // turned it into an I2I run). buildRequest already empties refPaths for an override.
        queue.append(QueueItem(request: req, referenceImages: [], label: queueLabel(req)))
        if queueRunning { queueTotal += 1 }
        AppLog.info("Scene added to queue: \(recipe.id) (now \(queue.count))")
        return queue.count
    }

    /// #2 Inline-edit a PENDING queued task (prompt / size / seed). Size is clamped to Klein's
    /// 512–1536 range and snapped to /32 (stride-safe); a nil seed renders random. The task that
    /// is currently rendering can't be edited.
    func updateTask(_ id: UUID, prompt: String, width: Int, height: Int, seed: UInt64?, steps: Int, quality: QualityPreset) {
        guard id != currentItemID, let idx = queue.firstIndex(where: { $0.id == id }),
              queue[idx].kind == .generation else { return }   // upscale tasks have nothing to edit
        queue[idx].request.prompt = prompt
        queue[idx].request.steps = min(Self.maxSteps, max(1, steps))
        // Quality change also re-derives the quant the pipeline loads with.
        queue[idx].request.quality = quality.rawValue
        queue[idx].request.quant = queue[idx].request.tier.quantConfig(for: quality)
        // Snap to /32 AND clamp to the RAM-safe area, so an edited task can't store a recipe whose
        // recorded size disagrees with the pixels actually rendered (the engine re-clamps its copy).
        let c = clampedSizeForRAM(ReferenceSize.snap(width), ReferenceSize.snap(height))
        queue[idx].request.width = c.width
        queue[idx].request.height = c.height
        queue[idx].request.seed = seed
        queue[idx].label = queueLabel(queue[idx].request)
        // Surface a silent size adjustment (out-of-range / RAM cap / /32 snap) instead of just
        // saving a different size than the user typed.
        if c.width != width || c.height != height {
            statusMessage = "Task \(idx + 1) updated — size adjusted to \(c.width)×\(c.height)."
        } else {
            statusMessage = "Task \(idx + 1) updated"
        }
    }

    /// Cross-queue handoff: "Run all" pressed while the trainer holds the GPU ARMS the queue
    /// instead of failing against the busy engine; TrainingViewModel pings `trainingDidBecomeIdle()`
    /// when its runs/queue/captioning are all done and the armed queue starts by itself.
    var queueArmedAfterTraining = false
    var isTrainingBusy: (() -> Bool)? = nil   // wired in TyphoonminigenApp
    /// Reverse handoff (wired in TyphoonminigenApp): fired after Describe/Ask/Compare release the
    /// engine latch, so a queued training/caption job that bailed against it can start now.
    var onDescribeIdle: (() -> Void)? = nil
    /// Reverse handoff #2 (wired in TyphoonminigenApp): fired when the generation queue ends —
    /// finished, failed, or stopped — and the engine is free. A queued training/caption job that
    /// bailed against a running render sits re-inserted at the trainer's queue head; without this
    /// ping nothing ever re-drains it and it stalls despite the "starts automatically" promise.
    var onGenerationIdle: (() -> Void)? = nil

    /// Queue-tab "Run all": start the composed queue. (#1)
    /// 9B Int4 is stored as community MLX shards, not the BF16 registry variant.
    private static func transformerInstalled(for request: GenerationRequest) -> Bool {
        if request.tier == .klein9B {
            return request.quant.transformer == .int4 && Klein9BMLXInt4Model.isAvailable
        }
        return Flux2ModelDownloader.isDownloaded(.transformer(request.transformerVariant))
    }

    func runAll() {
        guard !isDescribing else {
            errorMessage = "Finish describing the reference first — it's using the GPU."
            return
        }
        guard !queueRunning, !queue.isEmpty else { return }
        // Gate on what the QUEUE will actually render, not the form's tier/quality chip
        // (ensureModelReady reads self.tier): a runnable all-4B queue used to refuse to start
        // because the form sat on an undownloaded 9B — and the armed-after-training auto-start
        // funnels through here with whatever the form happens to show. First missing item wins
        // the error. Upscale-only queues skip entirely (Real-ESRGAN needs no transformer);
        // model presence per (tier, variant) is probed once — isDownloaded walks a multi-GB
        // directory, and a long single-tier queue must not repeat that walk per item.
        var probed = Set<String>()
        for (idx, item) in queue.enumerated() {
            guard case .generation = item.kind else { continue }
            let tier = item.request.tier
            let key = "\(tier.rawValue)|\(item.request.transformerVariant)"
            guard probed.insert(key).inserted else { continue }
            if !Self.transformerInstalled(for: item.request) {
                let rung = item.request.quality.flatMap(QualityPreset.init(rawValue:)).map { " \($0.label)" } ?? ""
                errorMessage = "Task \(idx + 1) needs \(tier.shortName)\(rung) — it isn't downloaded yet. Open the Models tab to download it, then Run all again."
                statusMessage = ""
                return
            }
            if !tier.isEncoderDownloaded {
                errorMessage = "Task \(idx + 1) needs the \(tier.shortName) text encoder — download its Text Encoder row in the Models tab."
                statusMessage = ""
                return
            }
        }
        idleUnloadTask?.cancel()
        errorMessage = nil
        startQueue()   // arms instead of starting while the trainer holds the GPU (gate lives there)
    }

    // MARK: Queued upscales

    /// Queue one ×N upscale per source image (gallery batch action). Self-contained tasks —
    /// they run in queue order, each with its own error isolation, and start right away when
    /// the queue is idle (fire-and-forget: select the keepers, queue ×4, walk away).
    func enqueueUpscales(_ sources: [URL], factor: Int) {
        guard !sources.isEmpty else { return }
        for src in sources {
            // The request field is a never-rendered placeholder (kind drives execution).
            let placeholder = GenerationRequest(prompt: "", tier: tier, quant: tier.quantConfig(for: quality),
                                                steps: 1, guidance: 1.0, seed: 0)
            queue.append(QueueItem(request: placeholder, referenceImages: [],
                                   label: "×\(factor) · \(src.lastPathComponent)",
                                   kind: .upscale(source: src, factor: factor)))
        }
        if queueRunning {
            queueTotal += sources.count
            statusMessage = "Queued \(sources.count) upscale\(sources.count == 1 ? "" : "s") ×\(factor)."
        } else if queue.allSatisfy({ if case .upscale = $0.kind { return true } else { return false } }) {
            statusMessage = "Upscaling \(sources.count) image\(sources.count == 1 ? "" : "s") ×\(factor)…"
            startQueue()
        } else {
            // The idle queue holds DRAFTED generation tasks — auto-starting the upscales would
            // silently fire those renders too. Leave the composed queue to an explicit Run all.
            statusMessage = "Queued \(sources.count) upscale\(sources.count == 1 ? "" : "s") ×\(factor) — the queue has drafted tasks; press Run all when ready."
        }
    }

    /// Run one queued upscale. The source can vanish between enqueue and run (Finder delete,
    /// gallery delete) — skip with a readable note instead of failing the whole queue.
    private func runUpscaleTask(source: URL, factor: Int) async -> Bool {
        guard FileManager.default.fileExists(atPath: source.path) else {
            errorMessage = "Upscale skipped — \(source.lastPathComponent) is gone (moved or deleted)."
            return false
        }
        errorMessage = nil
        // Per-item live state: without this the mixed queue kept the PREVIOUS render's
        // "100% · step N/N" on the header/rail through every upscale item.
        progress = 0
        etaSeconds = nil
        currentStep = 0
        // A queued upscale is real work exactly like a render item: the footer's Stop button
        // gates on isBusy and the rail's state word reads it too — without this an upscale-only
        // queue showed "idle" with no way to stop, and runOne only flips the flag for GENERATION
        // items (the upscale dispatch happens before it). The queue-end block resets it, same as
        // for renders. isUpscaling swings alongside so the rail can say "upscaling" (not the
        // "warming up" lie of step 0) and the canvas ×2/×4 buttons pause for the duration.
        isBusy = true
        isUpscaling = true
        renderPhase = "Upscaling ×\(factor)…"
        statusMessage = "Upscaling ×\(factor) — \(source.lastPathComponent)…"
        defer {
            renderPhase = nil
            isUpscaling = false
        }
        while true {
            // A DIRECT upscale (canvas ×2/×4, gallery detail) may hold the single Real-ESRGAN
            // gate — WAIT for it instead of burning the whole queued batch on instant "busy".
            while UpscaleService.isBusy {
                statusMessage = "Waiting for the current upscale to finish…"
                try? await Task.sleep(for: .milliseconds(500))
                if cancelledGen || Task.isCancelled {
                    // Stop while still WAITING (nothing ran): leave the item queued — the run
                    // loop honors this flag, keeping Stop's "N task(s) kept" promise instead of
                    // silently consuming a task that never started.
                    stopKeepsCurrentItem = true
                    return false
                }
            }
            do {
                let out = try await UpscaleService.upscale(source, scale: factor,
                    onStatus: { msg in Task { @MainActor in self.statusMessage = msg } })
                statusMessage = "Upscaled ×\(factor): \(out.lastPathComponent)"
                AppLog.info("Queue upscale ×\(factor): \(out.lastPathComponent)")
                return true
            } catch UpscaleService.UpscaleError.busy {
                continue   // lost the check-then-acquire race — back to the wait loop
            } catch {
                errorMessage = "Upscale failed for \(source.lastPathComponent): \(error.localizedDescription)"
                AppLog.error("Queue upscale: \(error.localizedDescription)")
                return false
            }
        }
    }

    func disarmAfterTraining() {
        queueArmedAfterTraining = false
        statusMessage = ""
    }

    /// Called by the training side the moment it's fully idle — fire the armed queue (re-runs
    /// every runAll gate, so a queue that emptied or a busy engine is handled, not assumed).
    func trainingDidBecomeIdle() {
        restartArmedQueueIfReady()
    }

    /// Fire the armed queue only when nothing blocks it anymore (training idle AND no VLM
    /// describe on the shared MLX pool) — and KEEP the arm otherwise. trainingDidBecomeIdle
    /// used to disarm unconditionally before calling runAll, so a Describe running at that
    /// instant hit runAll's isDescribing guard and the auto-start died forever. The retry
    /// fires from isDescribing's didSet the moment the describe releases the flag.
    private func restartArmedQueueIfReady() {
        guard queueArmedAfterTraining, !isDescribing, isTrainingBusy?() != true else { return }
        queueArmedAfterTraining = false
        runAll()
    }

    /// The selected model + encoder must be on disk before a run — otherwise the engine fetches
    /// gigabytes silently mid-generation. (Queued mixed-tier items are re-checked per item.)
    private func ensureModelReady() -> Bool {
        if !(tier == .klein9B ? Klein9BMLXInt4Model.isAvailable : Flux2ModelDownloader.isDownloaded(.transformer(tier.transformerVariant(for: quality)))) {
            errorMessage = "\(tier.shortName) \(quality.label) isn't downloaded yet. Open the Models tab to download it, then come back."
            statusMessage = ""
            return false
        }
        if !tier.isEncoderDownloaded {
            // No "Get encoder" button exists anymore — the encoder has its own download row
            // in the rebuilt grouped Models tab, so point at that.
            errorMessage = "The \(tier.shortName) text encoder isn't downloaded — open the Models tab and download its Text Encoder row."
            statusMessage = ""
            return false
        }
        return true
    }

    /// Append `batchCount` tasks built from the CURRENT form (does not start the run).
    private func enqueueFromForm() {
        let baseSeed = seedValue
        let refImages = references.map(\.image)   // snapshot — items keep their own references
        for i in 0 ..< max(1, batchCount) {
            let seed = baseSeed.map { $0 &+ UInt64(i) } ?? UInt64.random(in: 0 ... UInt64.max)
            let req = buildRequest(seed: seed)
            queue.append(QueueItem(request: req, referenceImages: refImages, label: queueLabel(req)))
        }
        if queueRunning { queueTotal += max(1, batchCount) }   // keep "Image N of M" honest for mid-run adds
    }

    /// Assemble the effective request from the CURRENT form state (prompt + LoRA trigger +
    /// preset phrases + size + references' paths).
    /// `promptOverride`/`presetIDsOverride` let the Library queue a SCENE (its own subject + chips)
    /// without disturbing the form; nil = use the live form (the normal Generate / Add-to-queue path).
    /// `includeLoRAs: false` builds WITHOUT the form's adapters — prompt triggers included: a
    /// cross-tier scene can't fuse them, and stripping req.loras afterwards would leave their
    /// trigger words baked into the prompt (dangling steering with no adapter behind it).
    private func buildRequest(seed: UInt64, promptOverride: String? = nil, presetIDsOverride: Set<String>? = nil,
                              includeLoRAs: Bool = true) -> GenerationRequest {
        // Belt-and-braces: never let a wrong-tier adapter into a request. The tier didSet
        // clears the selections, but if any window ever lets one slip through, the engine
        // would FUSE it with only a log warning (dim 3072 vs 4096 = corrupted weights).
        // Also dedupe by file — fusing the same adapter twice doubles its effect.
        var seenFiles = Set<String>()
        let activeLoRAs: [(item: LoRAItem, scale: Float)] = !includeLoRAs ? [] : loraSlots.compactMap { slot in
            guard let item = slot.item, item.tier == tier,
                  seenFiles.insert(item.url.path).inserted else { return nil }   // same key as the engine's dedupe
            return (item, slot.scale)
        }
        // Auto-append each selected LoRA's trigger word so it's never forgotten.
        // A literal [trigger] / [trigger:N] places the word mid-sentence instead — resolved
        // FIRST, so a substituted trigger satisfies the word-boundary check below (no double
        // add) and the request/recipe carry the prompt the model actually saw.
        var effectivePrompt = TriggerPlaceholder.resolve(
            in: promptOverride ?? prompt,
            triggers: activeLoRAs.compactMap { $0.item.trigger.isEmpty ? nil : $0.item.trigger })
        for (item, _) in activeLoRAs where !item.trigger.isEmpty {
            // Word-boundary match, not substring: a trigger "art" must still be added to a
            // prompt that only contains "smart" (the UI promised the trigger would be added).
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: item.trigger) + "\\b"
            if effectivePrompt.range(of: pattern, options: [.regularExpression, .caseInsensitive]) == nil {
                effectivePrompt += (effectivePrompt.isEmpty ? "" : ", ") + item.trigger
            }
        }
        // A Library scene (override args set) is its OWN composition — it must not inherit the
        // form's leftover references or write back to the form/status.
        let isOverride = promptOverride != nil || presetIDsOverride != nil
        // Append selected preset phrases (camera/technical last so the subject stays front-loaded).
        // A scene queued from the Library passes its OWN chip ids here instead of the form's,
        // ignoringHidden so a chip the user hid still applies WITHOUT globally un-hiding it.
        let suffix = presetIDsOverride.map { PresetCatalog.suffix(for: $0, ignoringHidden: true) } ?? presetSuffix
        if !suffix.isEmpty {
            effectivePrompt += (effectivePrompt.isEmpty ? "" : ", ") + suffix
        }
        // A scene is text-to-image — never bake the form's reference PATHS into it (that turned a
        // T2I scene into a silent I2I run). Only the live form contributes references.
        let refPaths = isOverride ? [] : references.compactMap { $0.url?.path }
        // 8 GB safety: clamp to a size the GPU can actually decode (≥1 MP aborts on 8 GB).
        // Done HERE so the request AND the saved recipe carry the real size, and the form
        // updates to show what actually ran.
        let capped = clampedSizeForRAM(width, height)
        // Only the live-form Generate path may write back to the form/status. A Library scene
        // stays side-effect-free — it bakes the capped size into the request only.
        if !isOverride, capped.width != width || capped.height != height {
            statusMessage = "Size capped to \(capped.width)×\(capped.height) — \(ramGB) GB runs out of GPU memory above ~0.8 MP."
            width = capped.width
            height = capped.height
        }
        return GenerationRequest(
            prompt: effectivePrompt,
            tier: tier,
            quant: tier.quantConfig(for: quality),
            width: capped.width,
            height: capped.height,
            steps: steps,
            guidance: guidance,
            seed: seed,
            loras: activeLoRAs.map { LoRAUse(path: $0.item.url.path, name: $0.item.fileName, scale: $0.scale) },
            // With references the engine's upsampling would load a 24 GB Mistral VLM
            // (swap-freeze on 32 GB) — force it off in I2I. FluxEngine enforces this too.
            // Decided from THIS REQUEST's references: a scene (isOverride) is T2I by
            // construction, so only the toggle matters — the FORM's leftover references
            // must not silently switch a queued scene's upsampling off.
            upsamplePrompt: upsamplePrompt && (isOverride || references.isEmpty),
            quality: quality.rawValue,   // record the rung so the gallery/queue show it (was lost)
            referenceImagePaths: refPaths.isEmpty ? nil : refPaths
        )
    }

    private func queueLabel(_ req: GenerationRequest) -> String {
        let words = req.prompt.split(separator: " ").prefix(5).joined(separator: " ")
        return words.isEmpty ? "(empty prompt)" : words
    }

    /// Remove a PENDING task (the running one can only be stopped).
    func removeQueued(_ id: QueueItem.ID) {
        let before = queue.count
        queue.removeAll { $0.id == id && $0.id != currentItemID }
        if queue.count < before, queueRunning { queueTotal -= 1 }   // keep "Image N of M" honest
    }

    /// Duplicate a task `count` times with the chosen seed strategy (#1). Copies land right
    /// after the source, so "same prompt × many seeds" reads in order. Generation tasks only —
    /// duplicating an upscale of the same file would just overwrite its own output.
    func duplicateTask(_ id: QueueItem.ID, count: Int, seedMode: SeedMode) {
        guard let idx = queue.firstIndex(where: { $0.id == id }), queue[idx].kind == .generation else { return }
        let src = queue[idx]
        // A source with no pinned seed renders a fresh random seed; "same"/"sequential" copies
        // would otherwise all get 0 (matching neither the source nor the intent). Resolve one
        // concrete seed, and pin the source too (unless it's mid-render) so the copies relate to it.
        let baseSeed = src.request.seed ?? UInt64.random(in: 0 ... UInt64.max)
        if src.request.seed == nil, seedMode != .newRandom, src.id != currentItemID {
            queue[idx].request.seed = baseSeed
        }
        var copies: [QueueItem] = []
        for i in 0 ..< max(1, count) {
            var req = src.request
            switch seedMode {
            case .same:       req.seed = baseSeed
            case .sequential: req.seed = baseSeed &+ UInt64(i + 1)
            case .newRandom:  req.seed = UInt64.random(in: 0 ... UInt64.max)
            }
            copies.append(QueueItem(request: req, referenceImages: src.referenceImages, label: src.label))
        }
        queue.insert(contentsOf: copies, at: idx + 1)
        if queueRunning { queueTotal += copies.count }
    }

    /// Move a PENDING task up/down. The running task (always at the front) can't move.
    func moveTask(_ id: QueueItem.ID, up: Bool) {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        let target = up ? idx - 1 : idx + 1
        guard queue.indices.contains(target),
              queue[idx].id != currentItemID, queue[target].id != currentItemID else { return }
        queue.swapAt(idx, target)
    }

    /// Jump a pending task to the front of the queue. It lands just AFTER the currently-running
    /// item (which never moves), or at index 0 when nothing is running.
    func moveTaskToTop(_ id: QueueItem.ID) {
        guard let idx = queue.firstIndex(where: { $0.id == id }), queue[idx].id != currentItemID else { return }
        let dest = queue.firstIndex(where: { $0.id == currentItemID }).map { $0 + 1 } ?? 0
        guard idx != dest else { return }
        let item = queue.remove(at: idx)
        queue.insert(item, at: min(dest, queue.count))
    }

    /// Empty the queue of PENDING tasks (a running task keeps going — use Stop for that).
    func clearQueue() {
        queue.removeAll { $0.id != currentItemID }
        if queueRunning { queueTotal = queueDone + queue.count }
    }

    /// Whether any queued (pending or running) generation item references this LoRA file / tier —
    /// the Models/LoRA tabs warn before deleting something the queue is about to need.
    /// Matched by file name (requests store absolute paths; recipe-restored uses may carry the
    /// name only) — upscale items hold a never-rendered placeholder request and never count.
    func queuedItemsReference(loraFileName: String) -> Bool {
        queue.contains { item in
            guard case .generation = item.kind else { return false }
            return item.request.loras.contains {
                ($0.path as NSString).lastPathComponent == loraFileName || $0.name == loraFileName
            }
        }
    }

    func queuedItemsReference(tier: ModelTier) -> Bool {
        queue.contains { item in
            guard case .generation = item.kind else { return false }
            return item.request.tier == tier
        }
    }

    private func startQueue() {
        guard !queueRunning, !queue.isEmpty else { return }
        // Cross-queue handoff gate — EVERY starter funnels through here (Generate button, Run all,
        // strength sweep): while the trainer holds the GPU, ARM instead of draining the queue
        // against the engine's busy latch (each item would fail instantly and be consumed).
        if isTrainingBusy?() == true {
            queueArmedAfterTraining = true
            statusMessage = "Waiting for the training to finish — the queue starts automatically."
            return
        }
        queueRunning = true
        cancelledGen = false
        queueDone = 0
        queueTotal = queue.count
        genTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var succeeded = 0, attempted = 0
            var runNotes: [String] = []   // per-item skip/failure reasons — runOne clears errorMessage each item, so capture it here
            while let item = self.queue.first, !Task.isCancelled, !self.cancelledGen {
                self.currentItemID = item.id
                self.stopKeepsCurrentItem = false
                let madeImage = await self.runOne(item)
                if madeImage { succeeded += 1 }
                else if self.stopKeepsCurrentItem {
                    // Stop arrived while a queued upscale was still WAITING on the Real-ESRGAN
                    // gate — nothing ran, so the item STAYS queued (Stop's "tasks kept" promise)
                    // and doesn't count as attempted/failed.
                    break
                }
                else if let note = self.errorMessage { runNotes.append(note) }
                attempted += 1
                // Remove the item we just ran BY ID (safe under reorder/duplicate), not by position.
                self.queue.removeAll { $0.id == self.currentItemID }
                self.queueDone += 1
                if self.cancelledGen { break }   // Stop: leave remaining tasks queued for "Run all"
            }
            let stopped = self.cancelledGen
            let wasSeries = self.queueTotal > 1
            self.currentItemID = nil
            self.cancelledGen = false
            self.queueRunning = false
            self.isBusy = false
            self.renderPhase = nil   // no lingering "Loading…" after a failed/cancelled item
            self.queueDone = 0
            self.queueTotal = 0
            self.scheduleIdleUnload()
            // Engine is free now — let the trainer re-drain a queued run/caption job that bailed
            // against this render (mirror of onDescribeIdle; idle-unload re-checks the latch, so a
            // chained training isn't raced by the unload timer).
            self.onGenerationIdle?()

            let failed = attempted - succeeded
            if stopped {
                self.statusMessage = self.queue.isEmpty
                    ? "Stopped."
                    : "Stopped — \(self.queue.count) task(s) kept. Run all to resume."
                AppLog.info("Run stopped: \(succeeded) made, \(self.queue.count) kept")
            } else if wasSeries {
                QueueNotifier.notifyFinished(count: succeeded)
                AppLog.info("Queue finished: \(succeeded) image(s)" + (failed > 0 ? " (\(failed) failed)" : ""))
                // Don't let the last item's success message hide that earlier items were skipped/failed.
                if failed > 0 {
                    self.errorMessage = nil
                    self.statusMessage = "Queue finished: \(succeeded) made, \(failed) skipped/failed."
                        + (runNotes.first.map { " First issue: \($0)" } ?? "")
                }
            } else if succeeded == 1,
                      let secs = self.lastGenSeconds, secs > 60,
                      !NSApplication.shared.isActive {
                // Single renders past a minute (multi-ref I2I runs 6–10 min) — ping the user if
                // they switched away; silent when they're watching the canvas.
                QueueNotifier.notifyFinished(count: 1)
            }
        }
    }

    /// Run ONE queue item through the engine, updating all the live observables.
    /// Returns true only if this item produced an image that was actually saved to the gallery,
    /// so the queue counts/announces REAL finished images (not failed/cancelled attempts).
    @discardableResult
    private func runOne(_ item: QueueItem) async -> Bool {
        // Upscale tasks don't touch the engine at all — dispatch before the model guard.
        if case .upscale(let source, let factor) = item.kind {
            return await runUpscaleTask(source: source, factor: factor)
        }
        // Per-item download guard: a queued mixed-tier task whose model isn't on disk would make
        // the engine fetch gigabytes silently. Skip it instead of triggering a hidden download.
        guard Self.transformerInstalled(for: item.request),
              item.request.tier.isEncoderDownloaded else {
            errorMessage = "\(item.request.tier.shortName) isn't downloaded — open the Models tab. (Task skipped.)"
            return false
        }
        generationEpoch += 1
        let epoch = generationEpoch
        resultImage = nil
        vlmAnswer = nil          // a new render → the previous result's AI insights are stale
        vlmComparison = nil
        // Clear the previous render's saved-file URL up front: until THIS item saves, the
        // canvas save/drag/upscale must not act on the prior image (buttons disable on nil).
        // The gallery id + cancelled flag clear WITH it: if this item's save fails they'd
        // otherwise keep pointing at the PREVIOUS record, and the footer's "Delete this kept
        // image" (gated on lastResultWasCancelled) would delete the wrong gallery entry.
        lastSavedURL = nil
        lastSavedGenID = nil
        lastResultWasCancelled = false
        previewImage = nil
        previewStep = 0
        progress = 0
        etaSeconds = nil
        currentStep = 0
        renderSteps = item.request.steps   // this render's fixed total (the slider may change mid-run)
        lastGenSeconds = nil
        errorMessage = nil   // a prior queue item's error must not hide this item's outcome
        isBusy = true
        cancelledGen = false
        statusMessage = queueTotal > 1 ? "Image \(queueDone + 1) of \(queueTotal)…" : "Preparing…"
        // Telemetry: the pre-step-1 window gets an honest label (load/encode — only the split at
        // the first step tick is exact), the pace/peak trackers reset per render. The resident
        // check asks the ENGINE about THIS item's tier+quant — the form-tier isModelLoaded flag
        // goes stale after trainings and lies for mixed-tier / quant-switch queue items.
        renderPhase = "Preparing…"
        lastStepSeconds = nil
        lastTickAt = nil
        peakFootprintGB = TelemetryService.footprintGB()
        genStart = Date()
        Task { @MainActor in
            let resident = await engine.isResident(tier: item.request.tier, quant: item.request.quant)
            guard self.generationEpoch == epoch, self.isBusy, self.renderPhase == "Preparing…" else { return }
            self.renderPhase = resident ? "Encoding & preparing…" : "Loading model weights…"
        }
        AppLog.info("Generation started: \(item.request.tier.displayName), \(item.request.width)×\(item.request.height)"
                    + (item.referenceImages.isEmpty ? "" : " · \(item.referenceImages.count) ref"))
        let token = HFToken.current(for: item.request.tier)
        let wantPreview = livePreview
        let wantEveryStep = previewEveryStep
        // Pin a concrete seed BEFORE generating. A nil (random) seed makes the engine roll its
        // OWN seed we can't read back — recording the literal 0 then lies on the canvas overlay,
        // the gallery record, the PNG filename and the embedded recipe (irreproducible). Resolve
        // it here and feed the SAME value to the engine and to store.save so they all agree.
        // (enqueueFromForm/enqueueScene already resolve concrete seeds; this covers any remaining
        // nil-seed item — e.g. duplicate "same seed" on a nil-seed source.)
        let seed = item.request.seed ?? UInt64.random(in: 0 ... UInt64.max)
        var request = item.request
        request.seed = seed
        do {
            let output = try await engine.generate(
                request,
                hfToken: token,
                referenceImages: item.referenceImages,
                onDownload: { _, message in
                    Task { @MainActor in
                        // Same epoch/isBusy guard as onStep/onCheckpoint — a late download hop
                        // must not stamp a stale "Downloading…" line over the NEXT item's (or
                        // the idle footer's) status after this one finished or was cancelled.
                        guard self.generationEpoch == epoch, self.isBusy else { return }
                        self.statusMessage = message
                        // Loading/downloading progress IS the current phase — kill the frozen look.
                        self.renderPhase = message
                    }
                },
                onStep: { current, total in
                    Task { @MainActor in
                        // Same epoch/isBusy guard as onCheckpoint — a late progress hop must not
                        // write onto the NEXT item's rail after this one finished or was cancelled.
                        guard self.generationEpoch == epoch, self.isBusy else { return }
                        self.updateProgress(current: current, total: total)
                    }
                },
                previewEachStep: wantPreview,
                previewEveryStep: wantEveryStep,
                onCheckpoint: { step, img in
                    Task { @MainActor in
                        // A checkpoint hop can land after cancel/finish — don't re-pin a
                        // stale ~4-9 MB preview over the cleared state.
                        guard self.generationEpoch == epoch, self.isBusy else { return }
                        self.previewImage = img
                        self.previewStep = step
                    }
                }
            )
            let image = output.image
            // The engine can't abort mid-flight, so a cancelled run still finishes its
            // frame — the compute is spent either way. KEEP the image (it used to be
            // silently discarded: user lost a finished render and saw nothing in the
            // gallery, with no log line either).
            resultImage = image
            previewImage = nil
            progress = 1
            etaSeconds = 0
            lastSeed = seed
            lastGenSeconds = genStart.map { Date().timeIntervalSince($0) }
            statusMessage = cancelledGen ? "Cancelled — the finished image was kept (see Gallery)" : "Done"
            AppLog.info((cancelledGen ? "Cancelled after finish: " : "Done: ")
                        + "\(item.request.tier.displayName) · seed \(seed) · \(item.request.width)×\(item.request.height)"
                        + (item.request.loras.isEmpty ? ""
                           : " · LoRA " + item.request.loras.map(\.name).joined(separator: " + ")))
            peakFootprintGB = max(peakFootprintGB, TelemetryService.footprintGB())
            renderPhase = nil
            // Persist to the gallery FIRST, refresh the model pill after: syncModelState awaits
            // an engine hop + a detached disk probe (seconds under a saturated disk), and running
            // it before the save opened a window where the canvas already showed the image but
            // lastSavedURL was still nil — drag vended an empty file and canvas "save" stamped a
            // false "the gallery copy is gone" note. The sync is a pure disk-presence/residency
            // refresh; nothing in store.save reads its flags, so the order swap is free.
            // S-1: surface save failures instead of swallowing them with try?
            var saved = false
            do {
                let gen = try await store.save(image: image, request: request, seed: seed, duration: lastGenSeconds, enhancedPrompt: output.usedPrompt,
                                               secondsPerStep: lastStepSeconds, peakRAMGB: peakFootprintGB > 0 ? peakFootprintGB : nil)
                lastSavedURL = gen.imageURL
                lastSavedGenID = gen.id
                savedImageCount += 1   // live gallery refresh: monotonic, so .onChange always fires per queued image
                lastResultWasCancelled = cancelledGen   // a frame kept after Stop offers a one-tap delete
                saved = true
            } catch {
                // lastSavedURL/GenID/WasCancelled were already cleared at item start (and nothing
                // set them since) — re-clear as belt-and-braces so the canvas save/drag/upscale
                // and the footer's "Delete this kept image" can never act on a PREVIOUS item's
                // record while the user tries to rescue this one.
                lastSavedGenID = nil
                lastResultWasCancelled = false
                errorMessage = "Image created but couldn't be saved: \(error.localizedDescription)"
            }
            await syncModelState()  // tier-aware: the pill answers "is MY tier resident?"
            sessionStats.generationCount += 1
            return saved   // image created AND saved → a real finished image
        } catch is CancellationError {
            statusMessage = "Cancelled"
            previewImage = nil
            progress = 0   // a partial progress value must not read as "done · 100%" on the rail
            renderPhase = nil   // a stale "Loading model weights…" must not survive into the next item
            await syncModelState()  // C-4
            return false
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Error"
            previewImage = nil
            progress = 0   // ditto — a failed render is not 100% done
            renderPhase = nil
            await syncModelState()  // C-4: 19 GB not locked without unload button
            AppLog.error("Generation error: \(error.localizedDescription)")
            return false
        }
    }

    /// Auto-unload: a generation just finished — if the user walks away, release the ~9–19 GB
    /// the resident model holds. Any new generation cancels the timer; manual unload too.
    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        guard isModelLoaded || residentTier != nil else { return }
        let epoch = generationEpoch
        idleUnloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleUnloadMinutes * 60))
            // !isDescribing is load-bearing (re-checked after the actor hop below): a VLM
            // describe holds the global MLX pool but isn't a generation, so isBusy is false.
            guard !Task.isCancelled, let self, !self.isBusy, !self.isDescribing,
                  epoch == self.generationEpoch else { return }
            // Ask the ENGINE, not isModelLoaded: after a tier switch the pill goes false
            // while the other tier's weights are still resident — those must still be freed.
            guard await self.engine.isLoaded else { return }
            // Re-check the epoch after the actor hop too: a generation that started in the
            // gap shouldn't have its status overwritten (the engine's busy guard already
            // protects the weights themselves).
            if await self.engine.freeMemory(), epoch == self.generationEpoch, !self.isBusy, !self.isDescribing {
                self.isModelLoaded = false
                self.residentTier = nil
                self.statusMessage = "Model auto-unloaded after \(Self.idleUnloadMinutes) min idle"
                AppLog.info("Model auto-unloaded after \(Self.idleUnloadMinutes) min idle")
            }
        }
    }

    /// Stop the run after the current frame (the engine has no mid-step abort — with 4 Klein
    /// steps that's within ~1 step). The finished frame is KEPT; remaining tasks stay queued so
    /// "Run all" resumes them. (#11 — Stop no longer drops the user's composed list.)
    func cancel() {
        guard queueRunning else { return }
        cancelledGen = true
        // #11 The image already rendering can't be interrupted (the engine's GPU step is a
        // blocking call) — say so honestly instead of promising a stop that never lands.
        let pending = max(0, queue.count - 1)
        statusMessage = pending > 0
            ? "The current image can't be interrupted — it'll finish, then stop. \(pending) task(s) kept for Run all."
            : "The current image can't be interrupted — it'll finish, then stop."
        AppLog.info("Run stop requested — current image runs to completion; \(pending) kept")
    }

    /// Discard the image now on the canvas (used to throw away a frame kept after Stop, #11).
    func deleteLastResult() {
        guard let id = lastSavedGenID else { return }
        let thumbName = lastSavedURL?.lastPathComponent   // capture before clearing — to drop its thumbnail too
        resultImage = nil
        lastSavedURL = nil          // also triggers the gallery reload in ContentView
        lastSavedGenID = nil
        lastResultWasCancelled = false
        previewImage = nil
        statusMessage = "Deleted that image."
        Task {
            await store.delete(id)
            // Match the gallery delete paths — don't orphan the thumbnail cache file.
            if let thumbName {
                try? FileManager.default.removeItem(at: AppPaths.thumbnails.appendingPathComponent(thumbName))
            }
        }
        AppLog.info("Deleted the on-canvas result from the gallery")
    }

    /// C-1: sync isModelLoaded from the engine (call on appear so System-tab frees are
    /// reflected). Tier-aware: with two tiers, "loaded" means the CURRENTLY SELECTED tier
    /// is the resident one — after a switch the other tier's weights may still be in RAM,
    /// and the pill must not claim them as ours.
    func syncModelState() async {
        // Snapshot the selection up front — a tier/quality change mid-probe re-enters here
        // with the fresh values (both didSets call syncModelState), so probing the snapshot
        // is safe and the Sendable capture for the detached task is explicit.
        let tier = self.tier
        let quality = self.quality
        modelProbeEpoch += 1
        let epoch = modelProbeEpoch
        residentTier = await engine.loadedTier
        isModelLoaded = (residentTier == tier)
        // Disk probing OFF the main actor: isDownloaded enumerates a multi-GB model directory
        // and encodersOnDisk parses the safetensors index + stats every shard — done inline
        // (the old shape), that sync I/O ran on the main thread and, under a saturated disk,
        // stalled the very UI these flags exist to keep responsive.
        let probe = await Task.detached(priority: .userInitiated) {
            (transformerMissing: tier == .klein9B ? !Klein9BMLXInt4Model.isAvailable : !Flux2ModelDownloader.isDownloaded(.transformer(tier.transformerVariant(for: quality))),
             encoderMissing: !tier.isEncoderDownloaded,
             nineB: ModelTier.klein9B.encodersOnDisk)
        }.value
        guard epoch == modelProbeEpoch else { return }   // a newer sync superseded this snapshot
        modelMissing = probe.transformerMissing
        encoderMissing = probe.encoderMissing
        nineBEncoder8BitOnDisk = probe.nineB.eightBit
        nineBEncoder4BitOnDisk = probe.nineB.fourBit
    }

    /// Load LoRAs compatible with the current tier (call on appear / tier change).
    func reloadLoRAs() {
        // Cancel a prior reload so an older discover() snapshot can't land after a newer one
        // (fires on appear, every tier switch and saveDefaultScale — a rapid 4B↔9B flip used to
        // race two unstructured Tasks and could apply the stale tier's list last). Same
        // single-slot pattern as LoRAViewModel.reload. [weak self] = no retain cycle.
        reloadLoRAsTask?.cancel()
        reloadLoRAsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let all = await self.loraStore.discover()
            guard !Task.isCancelled else { return }   // a newer reload owns the slot now
            self.allLoRAsOnDisk = all
            self.availableLoRAs = all.filter { $0.tier == self.tier }
            // Re-point each row's selection to the fresh item (picks up trigger edits), then
            // drop any row whose file is gone / no longer tier-compatible.
            for i in self.loraSlots.indices {
                if let sel = self.loraSlots[i].item {
                    self.loraSlots[i].item = self.availableLoRAs.first { $0.id == sel.id }
                }
            }
            self.loraSlots.removeAll { $0.item == nil }
        }
    }

    var isI2IMode: Bool { !references.isEmpty }

    // MARK: Aspect-ratio chips

    /// One-tap output formats — the 7 Fluxforge presets. Every chip lands near Klein's ~1 MP
    /// sweet spot in the ratio's canonical orientation (landscape first, then portrait) — the
    /// swap button flips it. aspectSize() keeps each /32-aligned (the 9:16 tear fix).
    static let aspectChips: [(label: String, w: Int, h: Int)] = [
        ("1:1", 1, 1), ("4:3", 4, 3), ("3:2", 3, 2), ("16:9", 16, 9),
        ("3:4", 3, 4), ("2:3", 2, 3), ("9:16", 9, 16)
    ]

    /// Friendly Fluxforge-style name for a chip's ratio (shown in its tooltip).
    static func aspectName(_ rw: Int, _ rh: Int) -> String {
        switch (rw, rh) {
        case (1, 1):   return "Square"
        case (4, 3):   return "Landscape 4:3"
        case (3, 2):   return "Landscape 3:2"
        case (16, 9):  return "Wide 16:9"
        case (3, 4):   return "Portrait 3:4"
        case (2, 3):   return "Portrait 2:3"
        case (9, 16):  return "Vertical 9:16"
        default:       return "\(rw):\(rh)"
        }
    }

    /// The chip's concrete pixel size: a /32-aligned size near Klein's ~1 MP sweet spot whose
    /// ratio is as close as possible to rw:rh. /32 (NOT /16) because the engine's VAE→CGImage
    /// row stride is width×3 and CoreGraphics aligns it to 32 bytes — a /16-but-not-/32 width
    /// (the old 9:16 = 720×1280) makes each scanline read off-by-16 → a clean horizontal tear.
    /// Searches /32 pairs in 512–1536 with area 0.85–1.10 MP, minimizing ratio error (larger
    /// area breaks ties). Yields 1:1=1024², 4:3=1152×864, 3:2=1248×832, 16:9=1312×736 (the
    /// portrait chips mirror those) — all /32, all <1.1 MP; 1:1/4:3/3:2 stay EXACT, 16:9/9:16
    /// drift ≤0.27%.
    static func aspectSize(_ rw: Int, _ rh: Int) -> (width: Int, height: Int) {
        guard rw > 0, rh > 0 else { return (1024, 1024) }
        let target = Double(rw) / Double(rh)
        let grain = ReferenceSize.grain
        let lo = ReferenceSize.minSide, hi = ReferenceSize.maxSide
        let minArea = 850_000, maxArea = 1_100_000
        var best: (width: Int, height: Int)?
        var bestErr = Double.infinity
        var bestArea = 0
        var w = lo
        while w <= hi {
            var h = lo
            while h <= hi {
                let area = w * h
                if area >= minArea, area <= maxArea {
                    let err = abs(Double(w) / Double(h) - target)
                    if err < bestErr - 1e-9 || (abs(err - bestErr) < 1e-9 && area > bestArea) {
                        bestErr = err; bestArea = area; best = (w, h)
                    }
                }
                h += grain
            }
            w += grain
        }
        // Fallback for extreme ratios with no /32 pair in the sweet-spot area band.
        return best ?? (ReferenceSize.snapped(width: rw * 64, height: rh * 64) ?? (1024, 1024))
    }

    func applyAspect(_ rw: Int, _ rh: Int) {
        let size = Self.aspectSize(rw, rh)
        width = size.width
        height = size.height
    }

    /// Active when the form's current aspect RATIO matches the chip (within a small tolerance),
    /// not an exact pixel match: on <16 GB the RAM cap rewrites the form size after a render
    /// (preserving aspect), and an exact-size test would then wrongly de-highlight the chip.
    /// The ratio still distinguishes orientation (16:9 ≠ 9:16) and every chip (1:1/4:5/3:2).
    func aspectIsActive(_ rw: Int, _ rh: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let target = Double(rw) / Double(rh)
        let current = Double(width) / Double(height)
        // 0.03, not 0.02: the <16 GB RAM cap can drift 3:2 (1248×832) to 1088×736 — a 0.0217 ratio
        // shift that 0.02 wrongly de-highlighted. The smallest gap between chip ratios is ~0.20, so
        // 0.03 still can't cross-highlight a neighbouring aspect.
        return abs(current - target) < 0.03
    }

    func swapOrientation() {
        let w = width
        width = height
        height = w
    }

    // MARK: Remix — restore a stored recipe into the form

    /// Clear the on-canvas result + its action targets so a freshly-loaded recipe doesn't leave
    /// the PREVIOUS render live underneath — save/upscale/drag/to-I2I/pin-seed would act on it.
    private func clearResultState() {
        resultImage = nil
        previewImage = nil
        previewStep = 0
        lastSavedURL = nil
        lastSavedGenID = nil
        lastResultWasCancelled = false
        progress = 0
        etaSeconds = nil
        lastGenSeconds = nil
    }

    /// Apply a recipe's size, validated/clamped to Klein's range (snap if out of range or not
    /// /32). Returns a note when it had to adjust. Both recipe paths go through this so Remix
    /// can't push an unvalidated (or tearing /16-not-/32) size into the engine the way a
    /// hand-edited record could.
    private func applyRecipeSize(_ w: Int, _ h: Int) -> String? {
        let range = ReferenceSize.minSide ... ReferenceSize.maxSide
        if range.contains(w), range.contains(h), w % 32 == 0, h % 32 == 0 {
            width = w; height = h
            return nil
        }
        if let s = ReferenceSize.snapped(width: w, height: h) {
            width = s.width; height = s.height
            return "size \(w)×\(h) adjusted to \(s.width)×\(s.height) for Klein"
        }
        return "stored size \(w)×\(h) is invalid — kept \(width)×\(height)"
    }

    /// Gallery "Remix": load a record's full recipe (prompt with everything baked in, seed,
    /// size, tier, LoRA set, references) back into the form. Presets are CLEARED — their
    /// phrases are already inside the stored prompt and would double up. Missing files
    /// (deleted LoRA / moved reference) are skipped with an honest note.
    func applyRecipe(_ gen: Generation) async {
        errorMessage = nil   // a stale error would hide every confirmation/notice below (footer shows one)
        // Same gate as the tier chips: a mid-run tier flip desyncs the model pill, and
        // half-applying a recipe under a running queue only breeds confusion.
        guard !isBusy, !queueRunning else {
            statusMessage = "A render is running — finish or cancel it, then Remix."
            return
        }
        clearResultState()   // the recipe describes a NEW pending render — drop the old result
        var notes: [String] = []
        if let t = ModelTier(rawValue: gen.modelTier) {
            tier = t   // didSet no-ops when unchanged; otherwise persists + reloads LoRA list
        } else {
            notes.append("unknown model \u{201C}\(gen.modelTier)\u{201D} — kept \(tier.shortName)")
        }
        prompt = gen.prompt
        seedText = String(gen.seed)
        // Steps + quality are part of the recipe too — without them a same-seed Remix renders a
        // DIFFERENT image (the step count and the rung's transformer/encoder quant both change
        // the output). Applied AFTER `tier` above (its didSet resets both to the tier defaults),
        // clamped/validated exactly like loadScene's pinned settings.
        steps = min(Self.maxSteps, max(1, gen.steps))
        if let q = gen.quality.flatMap(QualityPreset.init(rawValue:)), tier.qualityPresets.contains(q) {
            quality = q
        } else {
            quality = tier.defaultQuality   // old record (nil) or a rung this tier doesn't offer
        }
        clearPresets()
        clearReferences()
        let refPaths = gen.referenceImagePaths ?? gen.referenceImagePath.map { [$0] } ?? []
        var missingRefs = 0
        for path in refPaths {
            if FileManager.default.fileExists(atPath: path) {
                // snapToFirst:false — refs are appended asynchronously (off-main decode), so the
                // first one's auto-snap would land AFTER applyRecipeSize and overwrite the recipe's
                // stored size. The recipe's size must win.
                addReference(from: URL(fileURLWithPath: path), snapToFirst: false)
            } else {
                missingRefs += 1
            }
        }
        if missingRefs > 0 {
            notes.append("\(missingRefs) reference\(missingRefs > 1 ? "s" : "") no longer on disk")
        }
        // Size AFTER references — the first reference auto-snaps dims, the recipe's size wins.
        // Validated like the PNG-drop path (a hand-edited record could carry a bad size).
        if let note = applyRecipeSize(gen.width, gen.height) { notes.append(note) }
        // The async ref appends haven't run yet (references is still empty here), so gate on
        // refPaths (known synchronously): after a remix, removing the references restores the
        // RECIPE's size — not a reference-snapped one (snapToFirst:false above prevents the snap).
        if !refPaths.isEmpty { preReferenceSize = (width, height) }
        let uses = gen.loras
            ?? gen.loraName.map { [LoRAUse(path: "", name: $0, scale: gen.loraScale ?? 1.0)] }
            ?? []
        notes.append(contentsOf: await applyLoRAUses(uses))
        errorMessage = nil
        statusMessage = "Recipe loaded — review and press Generate"
            + (notes.isEmpty ? "" : ". Note: \(notes.joined(separator: "; "))")
        AppLog.info("Remix: recipe restored (seed \(gen.seed))")
    }

    /// Canvas drop: read the recipe embedded in a PNG (ours, or any A1111-schema file) and
    /// apply it through the same path as Remix. No recipe → explain instead of guessing.
    func applyDroppedRecipe(from url: URL) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            errorMessage = nil   // a stale error would hide the notices/confirmation below (footer shows one)
            guard !isBusy, !queueRunning else {
                statusMessage = "A render is running — finish or cancel it, then drop the PNG again."
                return
            }
            guard let text = PNGMetadata.parameters(fromPNGAt: url) else {
                statusMessage = "No recipe inside \u{201C}\(url.lastPathComponent)\u{201D} — images made here carry one. To use it as a reference instead, drop it on the References box."
                return
            }
            let recipe = PNGMetadata.recipe(from: text)
            clearResultState()   // the dropped recipe describes a NEW pending render
            var notes: [String] = []
            if let model = recipe.modelName {
                if model.localizedCaseInsensitiveContains("klein 4b") {
                    tier = .klein4B
                } else if model.localizedCaseInsensitiveContains("klein 9b") {
                    tier = .klein9B
                } else {
                    notes.append("made with \u{201C}\(model)\u{201D} — rendering on \(tier.shortName)")
                }
            }
            if !recipe.prompt.isEmpty { prompt = recipe.prompt }
            seedText = recipe.seed.map(String.init) ?? ""
            // Steps/quality AFTER tier (its didSet resets both). recipe.steps was parsed but
            // never applied — a same-seed drop-restore silently rendered at the form's steps.
            if let s = recipe.steps { steps = min(Self.maxSteps, max(1, s)) }
            if let q = recipe.quality.flatMap(QualityPreset.init(rawValue:)), tier.qualityPresets.contains(q) {
                quality = q
            } else {
                // Old/foreign PNGs carry no "Quality:" key (and a tampered one may not fit the
                // tier) — restore with the tier default, like a fresh form, never crash.
                quality = tier.defaultQuality
            }
            clearPresets()
            clearReferences()
            if let w = recipe.width, let h = recipe.height {
                if let note = applyRecipeSize(w, h) { notes.append(note) }
            }
            if recipe.hadNegativePrompt {
                notes.append("negative prompt skipped (Klein doesn't use one)")
            }
            let uses = recipe.loras.map { LoRAUse(path: "", name: $0.name, scale: $0.scale) }
            notes.append(contentsOf: await applyLoRAUses(uses))
            errorMessage = nil
            statusMessage = "Recipe restored from \(url.lastPathComponent)"
                + (notes.isEmpty ? "" : ". Note: \(notes.joined(separator: "; "))")
            AppLog.info("Recipe restored from PNG: \(url.lastPathComponent)")
        }
    }

    /// Point the LoRA slots at library items matching the given uses (by file name, against
    /// the CURRENT tier's list). Returns notes for adapters that aren't available anymore.
    private func applyLoRAUses(_ uses: [LoRAUse]) async -> [String] {
        loraSlots.removeAll()
        guard !uses.isEmpty else { return [] }
        let all = await loraStore.discover()
        availableLoRAs = all.filter { $0.tier == tier }
        var notes: [String] = []
        var seen = Set<String>()
        for use in uses {
            // Dedupe by name: the engine fuses each adapter once, so adding the same file
            // twice would only mislead the footer (no double effect).
            guard seen.insert(use.name).inserted else { continue }
            if let item = availableLoRAs.first(where: { $0.fileName == use.name }) {
                // Clamp to the slider's range — a tampered/foreign recipe could carry any scale.
                loraSlots.append(LoRASlot(item: item, scale: min(max(use.scale, 0), 1.5)))
            } else {
                notes.append("LoRA \u{201C}\(use.name)\u{201D} isn't in the library — skipped")
            }
        }
        return notes
    }

    // MARK: Prompt presets

    /// Selected preset phrases assembled in BFL append order (style → shot → lighting → camera).
    /// Goes through PresetCatalog so the user's own chips participate too.
    var presetSuffix: String { PresetCatalog.suffix(for: selectedPresetIDs) }
    var hasPresets: Bool { !selectedPresetIDs.isEmpty }

    func togglePreset(_ id: String) {
        if selectedPresetIDs.contains(id) {
            selectedPresetIDs.remove(id)
            persistPresetSelection()
            return
        }
        selectPreset(id)
    }

    /// Idempotent select — used by toggle and by the LOOK bundles (a toggle would deselect
    /// chips a bundle shares with the current selection). Single-select categories replace
    /// their sibling; physically contradictory multi chips (hard sun ↔ overcast…) replace
    /// each other via the conflict map.
    func selectPreset(_ id: String) {
        if let category = PresetCatalog.category(for: id), !category.allowsMultiple {
            let siblings = Set(PresetCatalog.presets(for: category).map(\.id))
            selectedPresetIDs.subtract(siblings)
        }
        if let conflicting = PromptPresets.conflicts[id] {
            selectedPresetIDs.subtract(conflicting)
        }
        selectedPresetIDs.insert(id)
        persistPresetSelection()
    }

    /// A LOOK bundle is "active" when every one of its chips is selected.
    func bundleIsActive(_ bundle: PresetBundle) -> Bool {
        Set(bundle.chipIDs).isSubset(of: selectedPresetIDs)
    }

    /// Apply a LOOK: clear current selection, then set the bundle's chips (re-tap clears).
    /// Chips the user hid via right-click are unhidden first — hidden ids are filtered out
    /// of the prompt assembly, so leaving them hidden would silently break the look.
    func applyBundle(_ bundle: PresetBundle) {
        if bundleIsActive(bundle) {
            clearPresets()
            return
        }
        CustomPresetStore.shared.unhide(bundle.chipIDs)
        selectedPresetIDs.removeAll()
        for id in bundle.chipIDs { selectPreset(id) }
    }

    func clearPresets() {
        selectedPresetIDs.removeAll()
        persistPresetSelection()
    }

    /// One-tap from the Library: seed the recipe's example subject into the prompt and apply its
    /// chips. Styling lives entirely in the chips (centrally updatable) — no baked prompt string,
    /// so a chip phrase edit can never make a scene drift. The honest `note` becomes the status
    /// line (the per-scene capability honesty). Returns false if a render is running.
    @discardableResult
    func loadScene(_ recipe: SceneRecipe) -> Bool {
        errorMessage = nil
        // A scene is text-to-image: drop any leftover I2I references (and their size snap) so that
        // tapping a scene then pressing Generate can't silently run an I2I off a stale reference.
        // (enqueueScene already forces refs empty for the QUEUE path — this is the matching fix for
        // the tap-card → Generate path, mirroring Remix / PNG-drop which also clear on load.)
        clearReferences()
        // While a render runs, the canvas belongs to it — load the scene into the FORM only (so the
        // user can tweak it and Add to queue) without wiping the in-flight preview. The running render
        // already snapshotted its inputs, so changing the form can't disturb it. (#queue-presets: the
        // old hard block here was exactly the "can't queue the next preset during a render" report.)
        let running = isBusy || queueRunning
        if !running { clearResultState() }   // idle: a scene describes a NEW pending render — drop the old result
        prompt = recipe.subjectExample
        selectedPresetIDs.removeAll()
        CustomPresetStore.shared.unhide(recipe.chipIDs)   // hidden ids drop out of the prompt assembly
        for id in recipe.chipIDs { selectPreset(id) }     // selectPreset persists + honors single-select/conflicts
        // Pinned settings reproduce the recipe's bundled preview: load → Generate → the same image.
        // Order matters — the `tier` setter's didSet resets steps/quality to the tier default, so
        // apply tier FIRST, then override steps/quality/size/seed. Switch tier only if it's on disk;
        // otherwise keep the current one and say which tier the preview was made on.
        var settingsNote = ""
        if let t = recipe.tier, t != tier {
            let q = recipe.quality ?? t.defaultQuality
            if (t == .klein9B ? Klein9BMLXInt4Model.isAvailable : Flux2ModelDownloader.isDownloaded(.transformer(t.transformerVariant(for: q)))) {
                tier = t
            } else {
                settingsNote = " This preview was made on \(t.shortName) — switch to it (and download it) for the exact result."
            }
        }
        if let q = recipe.quality, tier.qualityPresets.contains(q) { quality = q }
        if let s = recipe.steps { steps = s }
        if let w = recipe.aspectW, let h = recipe.aspectH { applyAspect(w, h) }
        // Mirror Remix/PNG-drop: a seedless recipe CLEARS the field — a leftover pinned seed
        // would silently stamp the same composition onto every render of the new scene.
        seedText = recipe.seed.map(String.init) ?? ""
        statusMessage = (running
            ? "Scene loaded into the form — press Add to queue. " + recipe.note
            : "Scene loaded — edit the subject, then Generate. " + recipe.note) + settingsNote
        AppLog.info("Scene loaded\(running ? " (during a render)" : ""): \(recipe.id)")
        return true
    }

    /// Snapshot the current Generate form into a draft custom card ("Save as card"). The user fills
    /// in the title + section in the editor; everything else — subject, chips, and the pinned
    /// tier/steps/quality/aspect/seed — is captured so loading the card reproduces what's on screen.
    func draftCardFromCurrentState() -> SceneRecipe {
        let orderedChips = PromptPresetCategory.appendOrder.flatMap { cat in
            PresetCatalog.presets(for: cat).map(\.id).filter { selectedPresetIDs.contains($0) }
        }
        // Pin the aspect only if the current size matches a clean named ratio; else leave it free.
        // Iterate the REAL chip list, not a hand-copied one: a stale copy here (had 4:5, missed
        // 4:3) silently dropped the aspect pin for every 4:3 form — the saved card then rendered
        // at whatever size the form happened to hold on load. 4:5 is appended explicitly: it's
        // not a UI chip, but dozens of built-in recipes pin it — saving a card from a loaded
        // 4:5 scene must keep the pin (3:4 is 0.75 vs 0.80, outside the 0.03 match tolerance).
        var aw: Int?, ah: Int?
        for (w, h) in Self.aspectChips.map({ ($0.w, $0.h) }) + [(4, 5)] where aspectIsActive(w, h) {
            aw = w; ah = h; break
        }
        let id = CustomRecipeStore.newID()
        // If a render is on the canvas, use it as the card's preview straight away (the natural
        // "save what I just made" flow) — the editor can still change or clear it.
        if let cg = resultImage { CustomRecipeStore.writePreview(cg, for: id) }
        return SceneRecipe(
            id: id,
            studio: PromptPresetLibrary.studios.first?.id ?? "cinema",
            title: "", subjectExample: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            chipIDs: orderedChips, note: "", badge: .green, featured: false,
            tier: tier, steps: steps, quality: quality,
            aspectW: aw, aspectH: ah, seed: UInt64(seedText.trimmingCharacters(in: .whitespaces)))
    }

    /// Deselect one chip AND persist — the hide/delete context menus used to mutate
    /// `selectedPresetIDs` directly, losing the removal on quit (it came back selected).
    func deselectPreset(_ id: String) {
        selectedPresetIDs.remove(id)
        persistPresetSelection()
    }

    /// Selection survives relaunches (tiny, lives in UserDefaults).
    private func persistPresetSelection() {
        UserDefaults.standard.set(Array(selectedPresetIDs), forKey: Self.presetSelectionKey)
    }

    /// Live word count of prompt + appended preset phrases. Klein's encoder caps at 512
    /// tokens and ~40–70 words is the sweet spot — the counter goes green inside that band.
    var promptWordCount: Int {
        (prompt + " " + presetSuffix)
            .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" })
            .count
    }
    var promptIsLong: Bool { promptWordCount > 70 }

    /// Whether the selected tier+quality transformer is present on disk (drives the status pill).
    /// Reads the CACHED probe (kept fresh by syncModelState) — the pill re-evaluates on every
    /// telemetry tick and prompt keystroke, so a live isDownloaded() directory walk here was
    /// exactly the sync main-thread I/O the stored flags exist to avoid.
    var isModelDownloaded: Bool { !modelMissing }

    /// One component the selected tier+quality needs to run.
    struct MissingAsset: Identifiable { let label: String; let gb: Int; var id: String { label } }

    /// The components for the selected tier+quality that are NOT on disk yet, with sizes — drives the
    /// per-item breakdown on the canvas "models required" CTA (what to download + how much).
    /// Presence comes from the CACHED flags (syncModelState) — this renders inside the body, and
    /// re-probing the disk per frame is what the flags fixed; the variant/size lookups are pure.
    var missingAssets: [MissingAsset] {
        var out: [MissingAsset] = []
        if modelMissing {
            let tv = tier.transformerVariant(for: quality)
            out.append(MissingAsset(label: "\(tier.shortName) transformer · \(quality.label)", gb: tier == .klein9B ? 5 : tv.estimatedSizeGB))
        }
        if encoderMissing {
            out.append(MissingAsset(label: "\(tier.shortName) text encoder", gb: tier.encoderVariant(for: quality).estimatedSizeGB))
        }
        return out
    }

    var missingAssetsTotalGB: Int { missingAssets.reduce(0) { $0 + $1.gb } }

    /// Non-nil when the selected quality needs a download before it can run (e.g. 4B "Best"
    /// pulls the 8 GB bf16 transformer). Mirrors Fluxforge's "Requires N GB download".
    /// Cached flags only (see missingAssets) — this line sits in the model card's body.
    var qualityDownloadHint: String? {
        var gb = 0
        if modelMissing { gb += tier == .klein9B ? 5 : tier.transformerVariant(for: quality).estimatedSizeGB }
        if encoderMissing { gb += tier.encoderVariant(for: quality).estimatedSizeGB }
        guard gb > 0 else { return nil }
        return "Requires ~\(gb) GB download for \(quality.label) — open the Models tab."
    }

    /// Export a copy of the current result to a user-chosen location (canvas "save").
    /// Prefers copying the gallery file — byte-identical AND keeps the embedded recipe;
    /// re-encoding from the CGImage (the fallback) would strip the tEXt chunk.
    func saveResultAs() {
        guard let img = resultImage else { return }
        let panel = NSSavePanel()
        panel.title = "Save image"
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "typhoonminigen_\(lastSeed.map(String.init) ?? "image").png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let fm = FileManager.default
            if let src = lastSavedURL, fm.fileExists(atPath: src.path) {
                // Saving INTO the gallery folder over the original would copy the file onto
                // itself — permanently destroying the only copy. APFS is case-insensitive, so
                // compare case-insensitively (foo.png == FOO.png are the same file).
                guard url.standardizedFileURL.path.caseInsensitiveCompare(src.standardizedFileURL.path) != .orderedSame else {
                    errorMessage = nil   // don't let a stale error hide this notice
                    statusMessage = "That IS the gallery original — pick a different folder or name."
                    return
                }
                // Copy to a temp sibling, then atomically swap in — a failed copy can no
                // longer lose the file the user chose to overwrite.
                let tmp = url.deletingLastPathComponent().appendingPathComponent(".tmsave-\(UUID().uuidString).png")
                do {
                    try fm.copyItem(at: src, to: tmp)
                    if fm.fileExists(atPath: url.path) {   // the panel already confirmed replacing
                        _ = try fm.replaceItemAt(url, withItemAt: tmp)
                    } else {
                        try fm.moveItem(at: tmp, to: url)
                    }
                } catch {
                    try? fm.removeItem(at: tmp)
                    throw error
                }
                errorMessage = nil
                statusMessage = "Saved to \(url.lastPathComponent)"
            } else {
                // No gallery original on disk → re-encode the in-memory pixels. The recipe
                // metadata lives ONLY in the gallery PNG, so this copy has none — say so.
                let rep = NSBitmapImageRep(cgImage: img)
                guard let data = rep.representation(using: .png, properties: [:]) else {
                    errorMessage = "Couldn't encode the image as PNG."
                    return
                }
                try data.write(to: url, options: .atomic)
                errorMessage = nil
                statusMessage = "Saved to \(url.lastPathComponent) (no recipe metadata — the gallery copy is gone)"
            }
            AppLog.info("Image saved: \(url.lastPathComponent)")
        } catch {
            errorMessage = "Couldn't save: \(error.localizedDescription)"
            AppLog.error("Image save failed: \(error.localizedDescription)")
        }
    }

    /// Real-ESRGAN ×2/×4 on the saved result; reveals the new file in Finder when done.
    func upscaleResult(scale: Int) {
        guard let src = lastSavedURL, !isUpscaling else { return }
        guard FileManager.default.fileExists(atPath: src.path) else {
            // The result was deleted from the gallery after generating.
            lastSavedURL = nil
            errorMessage = "That image was deleted from the gallery — generate a new one first."
            return
        }
        isUpscaling = true
        errorMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let out = try await UpscaleService.upscale(src, scale: scale,
                    onStatus: { msg in Task { @MainActor in self.statusMessage = msg } })
                // No auto-reveal in Finder: the focus-steal made users open the PNG by
                // accident (the «Preview opens by itself» report). Gallery has a Finder button.
                self.statusMessage = "Upscaled ×\(scale) — saved next to the original (\(out.lastPathComponent))"
                AppLog.info("Upscaled ×\(scale): \(out.lastPathComponent)")
            } catch {
                self.errorMessage = "Upscale failed: \(error.localizedDescription)"
                AppLog.error("Upscale: \(error.localizedDescription)")
            }
            self.isUpscaling = false
        }
    }

    /// Pin the last result's seed into the Seed field (canvas "pin seed") so follow-up
    /// renders iterate on the same composition instead of rolling a new one.
    func pinLastSeed() {
        guard let seed = lastSeed else { return }
        seedText = String(seed)
        errorMessage = nil   // a stale error would hide this confirmation (footer shows one or the other)
        statusMessage = "Seed \(seed) pinned — clear the Seed field to go random again"
    }

    /// Feed the just-generated image back in as another I2I reference (canvas "to I2I").
    func useResultAsReference() {
        guard let img = resultImage else { return }
        guard references.count < Self.maxReferences else {
            errorMessage = nil
            statusMessage = "\(Self.maxReferences) references max"
            return
        }
        appendReference(img, url: lastSavedURL)
    }

    /// Opens an NSOpenPanel to pick reference images for I2I (up to the remaining free slots).
    func selectReferenceImages() {
        let panel = NSOpenPanel()
        panel.title = "Choose reference images"
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .bmp, .gif]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        // Only the FIRST selected image may set the generation size — the per-file decodes run
        // concurrently, so leaving snapToFirst on all of them snapped to whichever decoded first,
        // not the one the user picked first.
        for (i, url) in panel.urls.enumerated() { addReference(from: url, snapToFirst: i == 0) }
    }

    /// Pick any PNG made here and restore its recipe — prompt, seed, size, model, LoRA — into
    /// the form. Routes through applyDroppedRecipe so it shares the busy guard, the size
    /// validation, and the honest "no recipe inside" message.
    func importRecipeFromPNG() {
        let panel = NSOpenPanel()
        panel.title = "Import recipe from a PNG"
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        applyDroppedRecipe(from: url)
    }

    /// Load one reference from disk into a free slot. Decoded DOWNSAMPLED to ≤1448 px on the
    /// long side (~2 MP ≈ 8 MB RGBA): the engine shrinks references to ≤1024² area anyway, so
    /// keeping more pixels in memory (queue items retain these images) buys nothing.
    func addReference(from url: URL, snapToFirst: Bool = true) {
        guard references.count < Self.maxReferences else {
            errorMessage = nil
            statusMessage = "\(Self.maxReferences) references max"
            return
        }
        // Decide the size-snap NOW (synchronously, in call order) rather than after the async decode,
        // where concurrent multi-file decodes finish out of order. `snapToFirst` marks the chosen
        // file; we snap only if it's also the first reference (an empty list at call time).
        let shouldSnap = snapToFirst && references.isEmpty
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Decode/downsample OFF the main thread — a large source photo would otherwise
            // hitch the UI while it's read and shrunk.
            let cg = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(src, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1448
                ] as CFDictionary)
            }.value
            guard let cg else {
                // Undecodable / unsupported file — say so instead of a dead, silent drop.
                self.errorMessage = "Couldn't read \u{201C}\(url.lastPathComponent)\u{201D} — unsupported or damaged image."
                return
            }
            // Re-check capacity: several files decode concurrently; the appends land here serialized.
            guard self.references.count < Self.maxReferences else { return }
            self.appendReference(cg, url: url, snapToFirst: shouldSnap)
        }
    }

    /// Load a reference from raw image DATA — a drag from Photos / a browser carries data, not a
    /// file URL. Same downsample (≤1448 px) and capacity rules as addReference(from:). `url` is the
    /// on-disk path when the bytes came from a Finder/Desktop file (decoded from DATA for
    /// reliability, but the URL is kept so buildRequest records it in the recipe); nil for
    /// Photos/browser drags that have no file.
    func addReference(fromImageData data: Data, url: URL? = nil, snapToFirst: Bool = true) {
        guard references.count < Self.maxReferences else {
            errorMessage = nil
            statusMessage = "\(Self.maxReferences) references max"
            return
        }
        let shouldSnap = snapToFirst && references.isEmpty   // decide before the async decode (see addReference(from:))
        Task { @MainActor [weak self] in
            guard let self else { return }
            let cg = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(src, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1448
                ] as CFDictionary)
            }.value
            guard let cg else {
                self.errorMessage = "Couldn't read the dropped image — unsupported or damaged."
                return
            }
            guard self.references.count < Self.maxReferences else { return }
            self.appendReference(cg, url: url, snapToFirst: shouldSnap)
        }
    }

    private func appendReference(_ img: CGImage, url: URL?, snapToFirst: Bool = true) {
        // The snap decision is made SYNCHRONOUSLY at call time (see addReference) so it survives
        // concurrent off-main decode: with several files the first-PICKED may not be the first to
        // decode, and a `references.isEmpty` test here would then snap to the wrong file (or none).
        if snapToFirst { snapSize(toReference: img) }
        references.append(ReferenceSlot(image: img, url: url))
    }

    /// Match the generation size to the FIRST reference's aspect, CLAMPED to 512–1536 and
    /// rounded to /16. A raw 12 MP photo must never set a 12 MP generation — output latents
    /// scale quadratically and the engine has no working size guard (its hard stop is dead code).
    private func snapSize(toReference img: CGImage) {
        guard let snapped = ReferenceSize.snapped(width: img.width, height: img.height) else { return }
        if preReferenceSize == nil { preReferenceSize = (width, height) }
        width = snapped.width
        height = snapped.height
    }

    /// Qwen3.5-VLM 4B looks at every reference and APPENDS its description to the prompt
    /// editor — visible and editable, so the user stays in control of what gets generated.
    func describeReferences() {
        // Also gate on queueRunning: runAll() sets queueRunning synchronously while the engine's
        // busy/describing flags only flip after an async hop, so without this a user could press
        // Run-all then immediately Describe, launching the VLM concurrently with a denoise/VAE-decode
        // on the shared global MLX/Metal pool (buffer corruption / SIGABRT).
        guard !references.isEmpty, !isBusy, !queueRunning, !isDescribing else { return }
        isDescribing = true
        idleUnloadTask?.cancel()   // the VLM holds the global MLX pool — don't let the 15-min idle timer clear it mid-describe
        errorMessage = nil
        let imgs = references.map(\.image)
        let userContext = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        AppLog.info("VLM describe started: \(imgs.count) reference(s)")
        describeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Tell the engine a describe is in flight so freeMemory()/Clear-cache (any tab)
            // refuse to tear down the global MLX pool under the running VLM inference. If the
            // engine is mid-unload or generating RIGHT NOW (a freeMemory()/Clear-cache from any
            // tab sets no VM flag this button could see), it refuses — bail instead of loading the
            // VLM into a pool being torn down (the unload→Describe race).
            guard await self.engine.setDescribing(true) else {
                self.isDescribing = false
                self.statusMessage = "Busy right now — try Describe again in a moment."
                self.scheduleIdleUnload()
                return
            }
            do {
                let texts = try await DescribeService.describe(
                    images: imgs,
                    context: userContext.isEmpty ? nil : userContext,
                    onStatus: { msg in Task { @MainActor in self.statusMessage = msg } }
                )
                // Cancel can land during the LAST image's inference, after which describe
                // returns normally — honor it instead of reporting success.
                try Task.checkCancellation()
                let block = texts.enumerated()
                    .map { texts.count > 1 ? "Reference \($0.offset + 1): \($0.element)" : $0.element }
                    .joined(separator: "\n")
                self.prompt += (self.prompt.isEmpty ? "" : "\n") + block
                self.statusMessage = "Description added to the prompt — edit it freely"
                AppLog.info("VLM described \(imgs.count) reference(s)")
            } catch is CancellationError {
                self.statusMessage = "Describe cancelled"
                AppLog.info("VLM describe cancelled by user")
            } catch {
                self.errorMessage = "Describe failed: \(error.localizedDescription)"
                self.statusMessage = ""
                AppLog.error("VLM describe: \(error.localizedDescription)")
            }
            await self.engine.setDescribing(false)
            self.isDescribing = false
            self.scheduleIdleUnload()   // re-arm the idle timer now that the VLM has released the pool
            self.onDescribeIdle?()      // a queued training/caption job may have bailed against the latch
        }
    }

    /// Stop the VLM describe (it used to be impossible to abort — a stuck describe latched
    /// `isDescribing` and disabled Generate until relaunch). Takes effect at the next image
    /// boundary; the model download aborts immediately.
    func cancelDescribe() {
        describeTask?.cancel()
        statusMessage = "Cancelling describe…"
    }

    /// Ask the local Qwen3.5-VLM a free-form question about the latest result (or the first reference
    /// if nothing's rendered yet). Reuses the Describe machinery + the engine's MLX-pool gate, and
    /// shares `isDescribing` so Describe/Ask/Compare are mutually exclusive on the global pool.
    func askAboutImage(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let image = resultImage ?? references.first?.image,
              !isBusy, !queueRunning, !isDescribing else { return }
        isDescribing = true
        idleUnloadTask?.cancel()
        errorMessage = nil
        vlmAnswer = nil
        AppLog.info("VLM ask started")
        describeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.engine.setDescribing(true) else {
                self.isDescribing = false
                self.statusMessage = "Busy right now — try again in a moment."
                self.scheduleIdleUnload()
                return
            }
            do {
                let answer = try await DescribeService.ask(
                    about: image, question: q,
                    onStatus: { msg in Task { @MainActor in self.statusMessage = msg } }
                )
                try Task.checkCancellation()
                self.vlmAnswer = answer
                self.statusMessage = "Answer ready"
                AppLog.info("VLM ask done")
            } catch is CancellationError {
                self.statusMessage = "Cancelled"
            } catch {
                self.errorMessage = "Ask failed: \(error.localizedDescription)"
                self.statusMessage = ""
                AppLog.error("VLM ask: \(error.localizedDescription)")
            }
            await self.engine.setDescribing(false)
            self.isDescribing = false
            self.scheduleIdleUnload()
            self.onDescribeIdle?()
        }
    }

    /// Score the latest result against the first reference with the local VLM (scene + style, 0–10).
    /// Needs both a result and a reference; same gate/exclusivity as askAboutImage.
    func compareToReference() {
        guard let generated = resultImage, let reference = references.first?.image,
              !isBusy, !queueRunning, !isDescribing else { return }
        isDescribing = true
        idleUnloadTask?.cancel()
        errorMessage = nil
        vlmComparison = nil
        AppLog.info("VLM compare started")
        describeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.engine.setDescribing(true) else {
                self.isDescribing = false
                self.statusMessage = "Busy right now — try again in a moment."
                self.scheduleIdleUnload()
                return
            }
            do {
                let cmp = try await DescribeService.compare(
                    reference: reference, generated: generated,
                    onStatus: { msg in Task { @MainActor in self.statusMessage = msg } }
                )
                try Task.checkCancellation()
                self.vlmComparison = cmp
                self.statusMessage = "Comparison ready"
                AppLog.info("VLM compare done")
            } catch is CancellationError {
                self.statusMessage = "Cancelled"
            } catch {
                self.errorMessage = "Compare failed: \(error.localizedDescription)"
                self.statusMessage = ""
                AppLog.error("VLM compare: \(error.localizedDescription)")
            }
            await self.engine.setDescribing(false)
            self.isDescribing = false
            self.scheduleIdleUnload()
            self.onDescribeIdle?()
        }
    }

    func removeReference(_ id: ReferenceSlot.ID) {
        references.removeAll { $0.id == id }
        if references.isEmpty { restorePreReferenceSize() }
    }

    func clearReferences() {
        references.removeAll()
        restorePreReferenceSize()
    }

    private func restorePreReferenceSize() {
        if let prior = preReferenceSize {
            preReferenceSize = nil   // first — so the restored size persists as the draft size
            width = prior.width
            height = prior.height
        }
    }

    func clearPreview() {
        resultImage = nil
        progress = 0
        etaSeconds = nil
        lastGenSeconds = nil
        statusMessage = ""
    }

    /// Unload the resident model and clear MLX caches to reclaim RAM (feature: free memory).
    func freeMemory() {
        idleUnloadTask?.cancel()
        Task { @MainActor in
            self.errorMessage = nil
            self.statusMessage = "Unloading model…"
            let freed = await self.engine.freeMemory()
            if freed {
                self.isModelLoaded = false
                self.residentTier = nil
                self.statusMessage = "Memory freed"
            } else {
                self.statusMessage = self.isDescribing
                    ? "Describing a reference — unload deferred until it finishes."
                    : "Generation in progress — unload deferred."
            }
        }
    }

    // NB: no "Step N/M" status here — the visible status line is for EVENTS (queued /
    // saved / unloaded…); live step progress already renders in the rail, canvas and header.
    private func updateProgress(current: Int, total: Int) {
        guard total > 0 else { return }
        // Denoise is running — retire the stale "Preparing…"/"Image X of Y…" line (the
        // rail, canvas and header carry the live progress from here). NOT when the user
        // just cancelled: "Cancelling…" must stay visible until the frame finishes.
        if current == 1, !cancelledGen { statusMessage = "" }
        renderPhase = nil   // first tick = the load/encode window is over
        currentStep = current
        renderSteps = total   // authoritative total from the engine for THIS render
        progress = Double(current) / Double(total)
        if let start = genStart, current > 0 {
            let perStep = Date().timeIntervalSince(start) / Double(current)
            etaSeconds = perStep * Double(total - current)
        }
        // Telemetry: smoothed tick-to-tick pace (only BETWEEN ticks — the first includes the
        // whole load+encode window and would lie) + running peak of the real app footprint.
        let now = Date()
        if let last = lastTickAt, current > 1 {
            let dt = now.timeIntervalSince(last)
            lastStepSeconds = lastStepSeconds.map { $0 * 0.6 + dt * 0.4 } ?? dt
        }
        lastTickAt = now
        peakFootprintGB = max(peakFootprintGB, TelemetryService.footprintGB())
    }
}

// MARK: - [trigger] placeholder

/// One trigger-placement convention shared by Generate prompts and training validation
/// prompts: a literal `[trigger]` (or `[trigger:1]`) in the text is replaced by the FIRST
/// trigger word, `[trigger:2]` by the second, and so on — numbered in Add-LoRA slot order,
/// counting only adapters that have a trigger. Tokens with no matching trigger are left
/// exactly as typed (the saved recipe must show what the model really received), and when
/// no token is present the caller's existing auto-append/prepend behavior stays the fallback.
/// Not an actor-isolated type on purpose — the trainer calls `resolve` from detached tasks.
enum TriggerPlaceholder {
    /// The token that addresses the `n`-th trigger word (1-based): `[trigger]`, `[trigger:2]`, …
    static func token(_ n: Int) -> String { n <= 1 ? "[trigger]" : "[trigger:\(n)]" }

    /// True when `text` contains any `[trigger]` / `[trigger:N]` token (case-insensitive).
    static func containsToken(_ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Replace every token that has a matching entry in `triggers` (1-based; `[trigger]` = #1).
    /// Pure string substitution — never adds, drops or reorders anything else.
    static func resolve(in prompt: String, triggers: [String]) -> String {
        guard !triggers.isEmpty, containsToken(prompt),
              let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return prompt }
        let ns = prompt as NSString
        let result = NSMutableString(string: prompt)
        // Back-to-front so earlier match ranges stay valid while we splice.
        for match in regex.matches(in: prompt, range: NSRange(location: 0, length: ns.length)).reversed() {
            var n = 1
            if match.range(at: 1).location != NSNotFound,
               let parsed = Int(ns.substring(with: match.range(at: 1))) { n = parsed }
            guard (1 ... triggers.count).contains(n) else { continue }   // unmatched → left as typed
            result.replaceCharacters(in: match.range, with: triggers[n - 1])
        }
        return result as String
    }

    private static let pattern = #"\[trigger(?::(\d+))?\]"#
}
