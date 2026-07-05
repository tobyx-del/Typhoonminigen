import Foundation
import CoreGraphics
import ImageIO
import AppKit
import MLX
import Flux2Core
import FluxTextEncoders

/// Drives a LoRA training RUN through the pinned engine's clean GUI API, OUTSIDE the
/// FluxEngine actor (exactly like `DescribeService` runs the VLM). The proven recipe:
/// `LoRATrainingHelper.prepareTrainingDataMemoryOptimized` (load VAE → encode → unload →
/// load text encoder → encode → unload) → `loadTransformerForTraining` (auto-downloads the
/// ~8 GB non-distilled base) → `TrainingSession.start` (runs the trainer synchronously).
///
/// Chunk 2 = a deliberately small, THROWAWAY "smoke run": ~20 steps, no validation, no
/// persistence — the earliest live proof that Klein 4B base actually trains on the 32 GB M4
/// without OOM. The real forge/Session flow + persistence land in later chunks.
///
/// GPU single-flight (training and image generation must never be resident together in 32 GB)
/// is owned by the CALLER (`TrainingViewModel.runSmoke`), which evicts the inference pipeline
/// with `engine.freeMemory()` then claims the global MLX pool with `engine.setDescribing(true)`
/// — the same bracket the Describe path uses. No FluxEngine changes (a dedicated `training`
/// flag is Chunk-5 hardening).
enum TrainingService {

    /// Live status pushed to the UI during a run.
    struct Update: Sendable {
        var phase: Phase
        var step: Int
        var totalSteps: Int
        var latestLoss: Float?
        var message: String
    }

    enum Phase: Sendable { case preparing, loadingModel, training, finished, failed }

    enum TrainingError: LocalizedError {
        case notEnoughImages(Int)
        var errorDescription: String? {
            switch self {
            case .notEnoughImages(let n):
                return "Need at least 4 images to train — found \(n)."
            }
        }
    }

    // MARK: - Smoke run

    /// Run a short throwaway training to verify the engine + memory budget on real hardware.
    /// The GPU must already be claimed by the caller (freeMemory + setDescribing(true)).
    static func smokeRun(
        folder: URL,
        triggerWord: String = "tphn",
        maxSteps: Int = 20,
        onUpdate: @escaping @Sendable (Update) -> Void
    ) async throws {
        onUpdate(Update(phase: .preparing, step: 0, totalSteps: maxSteps, latestLoss: nil,
                        message: "Reading images…"))

        // Clean throwaway output dir (fresh each run so .forceFresh starts at step 0).
        let outputDir = AppPaths.trainingRunsDir.appendingPathComponent("smoke", isDirectory: true)
        try? FileManager.default.removeItem(at: outputDir)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        // Leave ZERO residue: the smoke run is throwaway, so delete its working dir (cached
        // latents, checkpoints, training state) on EVERY exit — success or throw. The user's
        // source photos are never copied here; only derived latents are cached during the run,
        // and they go with it.
        defer { try? FileManager.default.removeItem(at: outputDir) }

        // All heavy, non-Sendable work stays INSIDE one detached task so MLX values
        // (latents, embeddings, transformer, session) never cross an isolation boundary.
        try await Task.detached(priority: .userInitiated) {
            let helper = LoRATrainingHelper()
            let teLoader: @Sendable () async throws -> any TrainingTextEncoder = {
                try await loadTextEncoder()
            }

            // Decode INSIDE this task, downsampled to 2× the 512 training resolution, and release
            // the bitmaps the moment latents + embeddings exist (see runTraining for the full
            // rationale) — they must not sit pinned through the ~8 GB base-transformer load.
            let loaded = try loadImages(from: folder, maxPixel: 1024)
            var images = loaded.images
            // Surface silently-dropped (undecodable) files — see runTraining for the rationale.
            if !loaded.unreadable.isEmpty {
                onUpdate(Update(phase: .preparing, step: 0, totalSteps: maxSteps, latestLoss: nil,
                                message: "\(images.count) of \(images.count + loaded.unreadable.count) images loaded (\(loaded.unreadable.count) unreadable — see Logs)"))
            }

            // PHASE 1+2 — encode latents (VAE) + embeddings (text encoder), each loaded then unloaded.
            onUpdate(Update(phase: .preparing, step: 0, totalSteps: maxSteps, latestLoss: nil,
                            message: "Encoding dataset…"))
            let (latents, embeddings) = try await helper.prepareTrainingDataMemoryOptimized(
                images: images,
                vaeLoader: { try await loadVAE() },
                textEncoderLoader: teLoader,
                triggerWord: triggerWord,
                maxResolution: 512,   // 512 (not 768) — quadratically smaller training activations to fit 32 GB
                progressCallback: { phase, cur, total in
                    onUpdate(Update(phase: .preparing, step: cur, totalSteps: max(total, 1),
                                    latestLoss: nil, message: phase))
                })
            images = []   // the latents replace the bitmaps — free them before the base load

            // PHASE 3 — load the non-distilled BASE transformer (auto-downloads ~8 GB if absent).
            onUpdate(Update(phase: .loadingModel, step: 0, totalSteps: maxSteps, latestLoss: nil,
                            message: "Loading base model…"))
            let transformer = try await helper.loadTransformerForTraining(
                modelType: .klein4B,   // helper resolves .klein4B → the base variant internally
                progressCallback: { p, msg in
                    onUpdate(Update(phase: .loadingModel, step: 0, totalSteps: maxSteps, latestLoss: nil,
                                    message: p < 1 ? "Downloading base model \(Int(p * 100))%…" : msg))
                })

            // Engine config — short run, no validation (skips the distilled-model preview download).
            var cfg = SimpleLoRAConfig(outputDir: outputDir)
            cfg.rank = 32
            cfg.alpha = 32
            cfg.learningRate = 1e-4
            cfg.maxSteps = maxSteps
            cfg.saveEveryNSteps = 10
            cfg.logEveryNSteps = 1
            cfg.timestepSampling = .balanced
            cfg.lossWeighting = .bellShaped
            cfg.triggerWord = triggerWord
            // DOP OFF for the smoke run: it reloads the ~4 GB text encoder co-resident with the
            // ~8 GB base transformer (and never unloads it) — a real training-phase memory spike we
            // don't need just to prove the pipeline trains. The real forge flow turns DOP on.
            cfg.dopEnabled = false
            // Gradient checkpointing ON — recomputes activations instead of storing them all
            // (~30-40% less peak). REQUIRED: without it the 4B training-phase peak blew past 32 GB
            // (32 GB swap) on the live M4 even with DOP off.
            cfg.gradientCheckpointing = true
            cfg.validationPrompts = []

            // PHASE 4 — train. start() blocks synchronously on this detached thread; the observer
            // (held WEAKLY by the controller) must outlive it, hence `_ = observer` after start().
            onUpdate(Update(phase: .training, step: 0, totalSteps: maxSteps, latestLoss: nil,
                            message: "Starting training…"))
            let session = TrainingSession(outputDirectory: outputDir)
            let observer = SmokeObserver(onUpdate: onUpdate, total: maxSteps)
            session.addObserver(observer)

            try await session.start(
                config: cfg,
                modelType: .klein4B,
                resumeMode: .forceFresh,
                transformer: transformer,
                cachedLatents: latents,
                cachedEmbeddings: embeddings,
                vae: nil,             // deprecated/unused — latents are already encoded
                textEncoder: nil)     // DOP is off → no lazy text-encoder closure needed
            _ = observer              // keep the strong ref alive past start()
        }.value

        onUpdate(Update(phase: .finished, step: maxSteps, totalSteps: maxSteps, latestLoss: nil,
                        message: "Smoke run complete → \(outputDir.lastPathComponent)"))
    }

    // MARK: - Folder → training images

    /// Load a folder of images into the engine's `TrainingImage`s, picking up a sibling
    /// `<name>.txt` caption if present. Requires at least 4 images.
    ///
    /// Decodes DOWNSAMPLED via ImageIO, not full-res NSImage: a 12 MP photo decoded whole is
    /// ~48 MB, and a full dataset of those used to stay pinned through the ~8 GB base-transformer
    /// load — the training path's biggest avoidable allocation. `maxPixel` should be 2× the run's
    /// training resolution: the engine's `resizeToValidDimensions` still does the exact final fit,
    /// and the 2× headroom keeps that step a quality downscale (never an upscale).
    /// `kCGImageSourceCreateThumbnailWithTransform` bakes the EXIF orientation into the pixels,
    /// exactly as the old NSImage path rendered it.
    ///
    /// Returns the loaded images PLUS the filenames that failed to decode. A truncated JPEG used
    /// to vanish here without a trace — "24 images" silently trained on 23 — so every drop is
    /// logged with a reason AND handed back so the callers' phase line can say
    /// "23 of 24 images loaded (1 unreadable — see Logs)".
    static func loadImages(from folder: URL, maxPixel: Int = 2048)
        throws -> (images: [LoRATrainingHelper.TrainingImage], unreadable: [String]) {
        let fm = FileManager.default
        let exts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp"]
        let entries = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                   options: [.skipsHiddenFiles])) ?? []
        var out: [LoRATrainingHelper.TrainingImage] = []
        var unreadable: [String] = []
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where exts.contains(url.pathExtension.lowercased()) {
            // Per-image pool: ImageIO's transient decode buffers die with the iteration,
            // not accumulated across the whole batch.
            autoreleasepool {
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel)
                ]
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    AppLog.error("Training: \(url.lastPathComponent) skipped — unreadable image header (corrupt file, or not really an image)")
                    unreadable.append(url.lastPathComponent)
                    return
                }
                guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
                    AppLog.error("Training: \(url.lastPathComponent) skipped — image data failed to decode (truncated or damaged file)")
                    unreadable.append(url.lastPathComponent)
                    return
                }
                let txt = url.deletingPathExtension().appendingPathExtension("txt")
                let caption = (try? String(contentsOf: txt, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                out.append(.init(filename: url.lastPathComponent, image: cg, caption: caption))
            }
        }
        guard out.count >= 4 else { throw TrainingError.notEnoughImages(out.count) }
        return (images: out, unreadable: unreadable)
    }

    // MARK: - Live training run (Chunk 5)

    /// Events streamed from a real training run. Pre-training progress (`phase`) comes from this
    /// service; everything from `status` on comes from the engine's `TrainingObserver` (via `RunObserver`).
    enum RunEvent: Sendable {
        case phase(Phase, String)            // preparing / loadingModel, with a message
        case status(String)                  // engine TrainingStatus rawValue (running/paused/checkpointing/…)
        case step(Int, Int, Float)           // step, totalSteps, loss
        case checkpoint(Int, URL)            // step, checkpoint directory
        case validation(Int, [URL])          // step, validation image URLs
        case paused(Int)                     // paused at step
        case resumed(Int)                    // resumed at step
        case finished(Bool, String)          // success, message
    }

    /// Drive a REAL training run through the engine's GUI API. Mirrors `smokeRun` but reads the frozen
    /// dataset + the run's locked parameters, maps them to `SimpleLoRAConfig`, and runs with validation,
    /// checkpoints and DOP. The `session` (created + observed by the caller, `@unchecked Sendable`) is what
    /// the caller uses to pause/resume/stop. The GPU must already be claimed by the caller.
    static func runTraining(
        run: TrainingRun,
        session: TrainingSession,
        onPhase: @escaping @Sendable (Phase, String) -> Void
    ) async throws {
        onPhase(.preparing, "Reading images…")
        let params = run.params
        let tier = run.tier
        let trigger = run.triggerWord
        let outputDir = run.outputDir
        let datasetDir = run.datasetDir

        try await Task.detached(priority: .userInitiated) {
            // Clear STALE `.pause`/`.stop` control files left by a previous life of the app. The
            // engine's TrainingController signals pause/stop via marker files in outputDir and only
            // removes them in notifyFinished — quit the app while paused (or right after Stop) and
            // the marker SURVIVES, so the next Resume would run the whole multi-minute
            // prepare/encode/base-load only to instantly re-pause or self-stop at the first loop
            // check. The engine's CLI calls this before every start; mirror it. Safe against a
            // legitimate Stop pressed during THIS prep: `session.stop()` also sets the controller's
            // in-memory `_stopRequested` flag, which file cleanup can't touch. (`.checkpoint` needs
            // no cleanup — the engine deletes that marker itself the moment it reads it.)
            TrainingController.cleanupControlFiles(outputDir: outputDir)

            let helper = LoRATrainingHelper()
            let kleinVariant: KleinVariant = tier == .klein9B ? .klein9B : .klein4B
            let teLoader: @Sendable () async throws -> any TrainingTextEncoder = {
                try await loadTextEncoder(variant: kleinVariant)
            }

            // Decode INSIDE this task, downsampled to 2× the training resolution (see loadImages),
            // then release the bitmaps (`images = []`) the moment latents + embeddings exist —
            // BEFORE the ~8 GB base transformer loads. The engine only needs the pixels during
            // prepare; the caption re-key below works from the lightweight filename/caption pairs.
            let loaded = try loadImages(from: datasetDir,        // frozen dataset + sibling .txt captions
                                        maxPixel: params.maxResolution * 2)
            var images = loaded.images
            // A drop here is otherwise invisible ("24 images" trains on 23): loadImages already
            // logged each unreadable file, this phase line makes the shrunken count VISIBLE in the
            // run UI (handleRunEvent mirrors it into runtime.message, so it also persists).
            if !loaded.unreadable.isEmpty {
                onPhase(.preparing, "\(images.count) of \(images.count + loaded.unreadable.count) images loaded (\(loaded.unreadable.count) unreadable — see Logs)")
            }
            let captionPairs = images.map { (filename: $0.filename, caption: $0.caption) }

            // PHASE 1+2 — encode latents (VAE) + embeddings (text encoder), each loaded then unloaded.
            onPhase(.preparing, "Encoding dataset…")
            let (latents, embeddings) = try await helper.prepareTrainingDataMemoryOptimized(
                images: images,
                vaeLoader: { try await loadVAE() },
                textEncoderLoader: teLoader,
                triggerWord: trigger,
                maxResolution: params.maxResolution,
                progressCallback: { phase, _, _ in onPhase(.preparing, phase) })
            images = []   // the latents replace the bitmaps — free them before the base load

            // ── CRITICAL caption↔image pairing fix ────────────────────────────
            // `embeddings` comes back keyed by CAPTION TEXT, but the engine's
            // training loop pairs each latent to its caption BY IMAGE FILENAME
            // (SimpleLoRATrainer.findCaption → embeddings[filename]). With distinct
            // per-image captions every lookup misses and the loop silently falls
            // back to `embeddings.keys.first`, training ALL images against one
            // arbitrary caption. Re-key by filename so each latent resolves to its
            // OWN caption. (App-side fix; no engine fork.)
            var embeddingsByFilename: [String: CachedEmbeddingEntry] = [:]
            for pair in captionPairs {
                let full = trigger.isEmpty ? pair.caption : "\(trigger), \(pair.caption)"
                if let entry = embeddings[full] { embeddingsByFilename[pair.filename] = entry }
            }

            // PHASE 3 — load the non-distilled BASE transformer (auto-downloads if absent).
            onPhase(.loadingModel, "Loading base model…")
            let transformer = try await helper.loadTransformerForTraining(
                modelType: tier.flux2Model,
                progressCallback: { p, msg in
                    onPhase(.loadingModel, p < 1 ? "Downloading base model \(Int(p * 100))%…" : msg)
                })

            // Map the locked params → engine config.
            var cfg = SimpleLoRAConfig(outputDir: outputDir)
            cfg.rank = params.rank
            cfg.alpha = params.alpha
            cfg.learningRate = params.learningRate
            cfg.weightDecay = params.weightDecay
            cfg.maxSteps = params.maxSteps
            cfg.batchSize = params.batchSize
            cfg.gradientAccumulationSteps = params.gradientAccumulationSteps
            cfg.saveEveryNSteps = params.saveEveryNSteps
            cfg.logEveryNSteps = 1
            cfg.timestepSampling = SimpleLoRAConfig.TimestepSamplingMode(rawValue: params.timestepSampling.rawValue) ?? .balanced
            cfg.lossWeighting = SimpleLoRAConfig.LossWeightingMode(rawValue: params.lossWeighting.rawValue) ?? .bellShaped
            cfg.gradientCheckpointing = true        // MANDATORY (the 76 GB OOM lesson)
            cfg.triggerWord = trigger
            cfg.dopEnabled = params.dopEnabled
            cfg.dopMultiplier = params.dopMultiplier
            cfg.dopPreservationClass = params.dopClass
            cfg.validationEveryNSteps = params.validationEveryNSteps
            cfg.validationSeed = params.validationSeed
            // Validation generates previews via the inference pipeline → needs the DISTILLED model.
            // If it isn't downloaded, SKIP validation so training still completes (the base-only setup
            // the user has). Otherwise the engine throws "transformer weights not found" mid-run.
            let hi = params.maxResolution >= 1024
            cfg.validationPrompts = validationModelPresent(tier: tier)
                ? params.validationPrompts.map { vp in
                    // [trigger] placeholder (one convention with Generate prompts): substitute
                    // the real trigger app-side and turn the engine's prepend OFF for that
                    // prompt, so the trigger can sit mid-sentence. No placeholder → the
                    // stored applyTrigger toggle keeps deciding, exactly as before.
                    let resolved = TriggerPlaceholder.resolve(
                        in: vp.prompt, triggers: trigger.isEmpty ? [] : [trigger])
                    return SimpleLoRAConfig.ValidationPromptConfig(
                        prompt: resolved, is512: !hi, is1024: hi,
                        applyTrigger: resolved != vp.prompt ? false : vp.applyTrigger,
                        // Per-prompt seed override; the run seed stays the default.
                        seed: vp.seed ?? params.validationSeed)
                  }
                : []

            // DOP needs the lazy text-encoder closure (re-loads the encoder during training); off → nil.
            let teClosure: (@Sendable (String) async throws -> MLXArray)? = params.dopEnabled
                ? helper.createLazyTextEncoderClosure(loader: teLoader) : nil

            // start() blocks synchronously on this thread; the observer (already attached by the caller,
            // held strongly by the caller) reports progress. resumeMode .autoResume → fresh when no
            // checkpoint exists, resumes from the latest on a re-launch / resume.
            try await session.start(
                config: cfg,
                modelType: tier.flux2Model,
                resumeMode: .autoResume,
                transformer: transformer,
                cachedLatents: latents,
                cachedEmbeddings: embeddingsByFilename,
                vae: nil,
                textEncoder: teClosure)
        }.value
    }

    // MARK: - Forge support (Chunk 4)

    /// Is the non-distilled BASE transformer for a tier already on disk? This is the real
    /// "you must download the base weights" gate — the big ~8 GB (4B) / ~18 GB (9B) file. The text
    /// encoder is small and `loadTransformerForTraining`/`KleinTextEncoder` auto-download it anyway.
    static func baseModelPresent(tier: ModelTier) -> Bool {
        let v: ModelRegistry.TransformerVariant = tier == .klein9B ? .klein9B_base_bf16 : .klein4B_base_bf16
        return Flux2ModelDownloader.isDownloaded(.transformer(v))
    }

    /// Whether the tier's DISTILLED inference model is on disk. Validation PREVIEWS are generated by
    /// the inference pipeline (Flux2Pipeline), which needs the distilled transformer + encoder — NOT the
    /// training base. When it's absent, training still runs fine but validation must be skipped (the engine
    /// would otherwise throw "transformer weights not found"). The base is what training itself uses.
    static func validationModelPresent(tier: ModelTier) -> Bool {
        let variants: [ModelRegistry.TransformerVariant] = tier == .klein9B
            ? [.klein9B_bf16] : [.klein4B_8bit, .klein4B_bf16]
        let transformerOK = variants.contains { Flux2ModelDownloader.isDownloaded(.transformer($0)) }
        return transformerOK && tier.isEncoderDownloaded
    }

    /// Curated training-phase peak footprint (GB) — LIVE-MEASURED: 4B = 22 GB at 512/GC-on;
    /// 9B = 33+ GB at 512/rank 32/GC-on (measured 2026-07-02 on a 32 GB M4: footprint hit 33 GB and
    /// swap exploded 2.4→12.5 GB within 60 s — the machine FROZE). NOT the engine's `estimateMemoryGB`
    /// (which under-reported 10 GB vs the real 22).
    static func estimatedPeakGB(tier: ModelTier, resolution: Int, dopEnabled: Bool) -> Int {
        let base = tier == .klein9B ? 34 : 22          // both tiers live-verified (4B measured 22, matches Help/Models "~22 GB") — do NOT lower these
        let resBump = resolution >= 1024 ? 6 : (resolution >= 768 ? 3 : 0)
        let dopBump = dopEnabled ? 4 : 0               // DOP keeps the ~4 GB text encoder co-resident during training
        return base + resBump + dopBump
    }

    /// HARD RAM gate: a training whose estimated peak exceeds physical RAM froze a real machine
    /// (the 9B-on-32-GB incident) — macOS swap cannot absorb a working set this hot. Blocks
    /// forge, Start, Resume, Extend and the queue. Big-RAM Macs (Studio 64 GB+) pass untouched.
    static func exceedsPhysicalRAM(tier: ModelTier, resolution: Int, dopEnabled: Bool) -> Bool {
        let installed = SystemRAM.installedGB
        return estimatedPeakGB(tier: tier, resolution: resolution, dopEnabled: dopEnabled) > installed
    }

    /// Delete the (large, resume-only) optimizer states from a finished run's checkpoints. The LoRA
    /// weights (`lora.safetensors`) stay — checkpoints remain reviewable + publishable — saving ~370 MB
    /// per checkpoint. With `keepLatest` the NEWEST checkpoint's state survives so "Extend training"
    /// can resume with AdamW momentum intact (without it the engine resumes with fresh momentum).
    static func trimOptimizerStates(in outputDir: URL, keepLatest: Bool = false) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil) else { return }
        func step(_ dir: URL) -> Int? { Int(dir.lastPathComponent.split(separator: "_").last ?? "") }
        let checkpoints = entries.filter { $0.lastPathComponent.hasPrefix("checkpoint_") }
        let latestStep = checkpoints.compactMap(step).max()
        for dir in checkpoints {
            if keepLatest, let s = step(dir), s == latestStep { continue }
            try? fm.removeItem(at: dir.appendingPathComponent("optimizer_state.safetensors"))
        }
    }

    /// Rolling checkpoint retention ("keep last N"): strip the HEAVY files — `lora.safetensors`,
    /// `optimizer_state.safetensors` and `training_state.json` — from every checkpoint dir older
    /// than the newest `keep`, so multi-checkpoint overnight runs don't fill the disk. Validation
    /// PNGs are NEVER touched, so the compare matrix stays complete end-to-end. Exempt from
    /// pruning: the steps in `exempt` (the published checkpoint) and the engine's best-loss step
    /// (read from the newest `training_state.json`). `training_state.json` goes WITH the weights
    /// so the engine's resume-from-latest can never land on a weightless checkpoint. Distinct from
    /// `trimOptimizerStates` (the post-run optimizer-only trim) — this runs DURING the run and
    /// removes the weights too. Returns the bytes freed. File IO — call OFF the main actor.
    @discardableResult
    static func pruneCheckpoints(in outputDir: URL, keepLast keep: Int, exempt: Set<Int>) -> Int64 {
        guard keep > 0 else { return 0 }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil) else { return 0 }
        func step(_ dir: URL) -> Int? { Int(dir.lastPathComponent.split(separator: "_").last ?? "") }
        let checkpoints = entries.filter { $0.lastPathComponent.hasPrefix("checkpoint_") }
            .compactMap { dir in step(dir).map { (step: $0, dir: dir) } }
            .sorted { $0.step > $1.step }                      // newest first
        guard checkpoints.count > keep else { return 0 }
        var protected = Set(checkpoints.prefix(keep).map(\.step)).union(exempt)
        // Best-loss exemption: it's often the checkpoint worth publishing later.
        struct StateProbe: Decodable { let bestLossStep: Int? }
        if let newest = checkpoints.first,
           let data = try? Data(contentsOf: newest.dir.appendingPathComponent("training_state.json")),
           let probe = try? JSONDecoder().decode(StateProbe.self, from: data),
           let best = probe.bestLossStep {
            protected.insert(best)
        }
        var freed: Int64 = 0
        for cp in checkpoints where !protected.contains(cp.step) {
            for name in ["lora.safetensors", "optimizer_state.safetensors", "training_state.json"] {
                let file = cp.dir.appendingPathComponent(name)
                guard let attrs = try? fm.attributesOfItem(atPath: file.path) else { continue }
                let size = (attrs[.size] as? Int64) ?? 0
                if (try? fm.removeItem(at: file)) != nil { freed += size }
            }
        }
        return freed
    }

    /// Snapshot-on-forge: copy a workshop's images (+ their BARE sibling `.txt` captions) into a run's
    /// dataset dir so later workshop edits never change an already-forged training. With `mirror` on,
    /// every image also gets a horizontally flipped `_flip.png` sibling sharing the same caption —
    /// the augmentation lives in the FROZEN snapshot only, originals untouched, and the engine sees
    /// the copies as ordinary files. Returns the count actually written (originals + flips) AND the
    /// count silently lost on the way (missing source / failed copy / failed flip) — every drop is
    /// also logged, so "12 images frozen" can never quietly mean "of my 15".
    /// File IO — call it OFF the main actor.
    @discardableResult
    static func freezeDataset(from workshop: Workshop, to datasetDir: URL,
                              mirror: Bool = false) throws -> (written: Int, skipped: Int) {
        let fm = FileManager.default
        try? fm.removeItem(at: datasetDir)
        try fm.createDirectory(at: datasetDir, withIntermediateDirectories: true)
        var n = 0
        var skipped = 0
        var copied: [(dest: URL, caption: String)] = []
        // Stems already frozen in this snapshot (lowercased — APFS default is case-insensitive).
        // The caption sidecar is `<stem>.txt`, so two dataset files sharing a stem ("photo.jpg" +
        // "photo.png") would freeze ONE caption file — the second write clobbers the first, and
        // loadImages then feeds BOTH images the surviving caption. Import now uniquifies on the
        // stem, but workshops imported BEFORE that fix can still carry colliders — rename the
        // second file inside the SNAPSHOT only (originals untouched; the engine pairs captions by
        // the frozen filename, so a rename here is transparent to training).
        var seenStems = Set<String>()
        for ref in workshop.images {
            let src = workshop.imageURL(ref)
            guard fm.fileExists(atPath: src.path) else {
                AppLog.error("Freeze: \(ref.fileName) is missing from the workshop folder — skipped")
                skipped += 1
                continue
            }
            // Mint a stem-unique snapshot name — same unique-name loop as writeMirroredCopy below.
            let base = (ref.fileName as NSString).deletingPathExtension
            let ext = (ref.fileName as NSString).pathExtension
            var destName = ref.fileName
            var i = 1
            while seenStems.contains((destName as NSString).deletingPathExtension.lowercased()) {
                destName = ext.isEmpty ? "\(base)-\(i)" : "\(base)-\(i).\(ext)"
                i += 1
            }
            if destName != ref.fileName {
                AppLog.warn("Freeze: \(ref.fileName) shares a caption stem with another dataset file — frozen as \(destName) so each keeps its own caption")
            }
            let dest = datasetDir.appendingPathComponent(destName)
            do { try fm.copyItem(at: src, to: dest) } catch {
                AppLog.error("Freeze: couldn't copy \(ref.fileName): \(error.localizedDescription)")
                skipped += 1
                continue
            }
            seenStems.insert((destName as NSString).deletingPathExtension.lowercased())
            let caption = ref.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            if !caption.isEmpty {
                // BARE caption only — the trigger word is prepended by the engine at train time.
                let txt = dest.deletingPathExtension().appendingPathExtension("txt")
                do { try caption.write(to: txt, atomically: true, encoding: .utf8) } catch {
                    // The image still trains, just caption-less — worth a trace, not a skip.
                    AppLog.error("Freeze: caption for \(ref.fileName) not written (trains caption-less): \(error.localizedDescription)")
                }
            }
            copied.append((dest, caption))
            n += 1
        }
        // Second pass AFTER every original is in place, so a generated "_flip" name can never
        // collide with (and silently drop) a real dataset file that happens to carry that suffix.
        if mirror {
            for item in copied {
                guard let flipURL = writeMirroredCopy(of: item.dest, in: datasetDir, seenStems: &seenStems) else {
                    AppLog.error("Freeze: mirrored copy of \(item.dest.lastPathComponent) failed — skipped")
                    skipped += 1
                    continue
                }
                if !item.caption.isEmpty {
                    // Same caption — both filenames resolve to the same embedding at train time.
                    let txt = flipURL.deletingPathExtension().appendingPathExtension("txt")
                    do { try item.caption.write(to: txt, atomically: true, encoding: .utf8) } catch {
                        AppLog.error("Freeze: caption for \(flipURL.lastPathComponent) not written (trains caption-less): \(error.localizedDescription)")
                    }
                }
                n += 1
            }
        }
        return (written: n, skipped: skipped)
    }

    /// Decode → flip-X → write `<stem>_flip.png` next to the frozen original. Decodes full-res via
    /// NSImage on purpose — the mirror must keep the original's full resolution in the frozen
    /// snapshot (loadImages downsamples both identically at train time), and the PNG re-encode
    /// drops any EXIF orientation ambiguity. Returns the written URL.
    private static func writeMirroredCopy(of imageURL: URL, in datasetDir: URL,
                                          seenStems: inout Set<String>) -> URL? {
        // One pool per call: NSImage/NSBitmapImageRep autorelease full-res decode + PNG-encode
        // buffers (~48 MB each on a 12 MP photo), and freezeDataset calls this across the whole
        // dataset — without the pool they'd all pile up until the forge task ends.
        autoreleasepool { () -> URL? in
            guard let ns = NSImage(contentsOf: imageURL),
                  let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            let w = cg.width, h = cg.height
            guard w > 0, h > 0,
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.translateBy(x: CGFloat(w), y: 0)
            ctx.scaleBy(x: -1, y: 1)
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let flipped = ctx.makeImage() else { return nil }
            // Unique by STEM against everything pass 1 froze, not just by exact .png filename:
            // an original pair like "a_flip.jpg" + "a.png" would pass a fileExists("a_flip.png")
            // check, then a.png's flip caption writes "a_flip.txt" — clobbering a_flip.jpg's own
            // caption (the same per-stem integrity rule the originals' rename enforces).
            let stem = imageURL.deletingPathExtension().lastPathComponent
            var flipStem = "\(stem)_flip"
            var i = 2
            while seenStems.contains(flipStem.lowercased())
                || FileManager.default.fileExists(atPath: datasetDir.appendingPathComponent("\(flipStem).png").path) {
                flipStem = "\(stem)_flip-\(i)"
                i += 1
            }
            let dest = datasetDir.appendingPathComponent("\(flipStem).png")
            let rep = NSBitmapImageRep(cgImage: flipped)
            guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
            do { try data.write(to: dest, options: .atomic) } catch { return nil }
            seenStems.insert(flipStem.lowercased())
            return dest
        }
    }

    // MARK: - Model loaders (mirror TrainLoRACommand.swift)

    /// Load the shared Flux.2 VAE (downloads if missing — it ships with Klein, so effectively present).
    private static func loadVAE() async throws -> AutoencoderKLFlux2 {
        let component = ModelRegistry.ModelComponent.vae(.standard)
        var modelPath = Flux2ModelDownloader.findModelPath(for: component)
        if modelPath == nil {
            modelPath = try await Flux2ModelDownloader().download(component) { _, _ in }
        }
        guard let base = modelPath else {
            throw TrainingError.notEnoughImages(0)   // unreachable — VAE ships with Klein
        }
        let vaeSub = base.appendingPathComponent("vae")
        let weightsPath = FileManager.default.fileExists(atPath: vaeSub.path) ? vaeSub : base
        let vae = AutoencoderKLFlux2()
        let weights = try Flux2WeightLoader.loadWeights(from: weightsPath)
        try Flux2WeightLoader.applyVAEWeights(weights, to: vae)
        eval(vae.parameters())
        return vae
    }

    /// Load the Klein text encoder (Qwen3). `load()` is `@MainActor`-isolated.
    /// Quantization follows what's ALREADY on disk: the Models tab's LoRA-Training rows install
    /// the 4-bit encoder, and the old hardcoded 8-bit here silently re-downloaded ~4 GB at Start
    /// even though the UI said "2/2 complete". 8-bit is still preferred when present.
    @MainActor
    private static func loadTextEncoder(variant: KleinVariant = .klein4B) async throws -> any TrainingTextEncoder {
        let eightBit: Qwen3Variant = variant == .klein9B ? .qwen3_8B_8bit : .qwen3_4B_8bit
        let fourBit: Qwen3Variant = variant == .klein9B ? .qwen3_8B_4bit : .qwen3_4B_4bit
        let quantization: MistralQuantization
        if TextEncoderModelDownloader.isQwen3ModelDownloaded(variant: eightBit) {
            quantization = .mlx8bit
        } else if TextEncoderModelDownloader.isQwen3ModelDownloaded(variant: fourBit) {
            quantization = .mlx4bit
        } else {
            quantization = .mlx4bit   // nothing on disk → fetch the smaller one (the Models-tab row)
        }
        let enc = KleinTextEncoder(variant: variant, quantization: quantization)
        try await enc.load()
        return enc
    }
}

// MARK: - Observer adapter

/// Bridges the engine's training-thread `TrainingObserver` callbacks to the app's `@Sendable`
/// status sink. `@unchecked Sendable` is sound: callbacks fire serially from the training loop
/// and only forward into the (already thread-safe) `onUpdate` sink.
private final class SmokeObserver: TrainingObserver, @unchecked Sendable {
    private let onUpdate: @Sendable (TrainingService.Update) -> Void
    private let total: Int
    private var lastLoss: Float?

    init(onUpdate: @escaping @Sendable (TrainingService.Update) -> Void, total: Int) {
        self.onUpdate = onUpdate
        self.total = total
    }

    func trainingStepCompleted(step: Int, totalSteps: Int, loss: Float) {
        lastLoss = loss
        onUpdate(.init(phase: .training, step: step, totalSteps: totalSteps > 0 ? totalSteps : total,
                       latestLoss: loss, message: "Training…"))
    }

    func trainingCheckpointSaved(step: Int, path: URL) {
        onUpdate(.init(phase: .training, step: step, totalSteps: total, latestLoss: lastLoss,
                       message: "Checkpoint saved at step \(step)"))
    }

    func trainingFinished(success: Bool, message: String) {
        onUpdate(.init(phase: success ? .finished : .failed, step: total, totalSteps: total,
                       latestLoss: lastLoss, message: message))
    }
}

/// Bridges the engine's `TrainingObserver` callbacks (fired serially off-main from the training loop)
/// to the app's `@Sendable` event sink for a REAL run. `@unchecked Sendable` is sound: callbacks are
/// serial and only forward into the thread-safe sink. The caller holds this strongly (the controller
/// keeps observers weakly).
final class RunObserver: TrainingObserver, @unchecked Sendable {
    private let sink: @Sendable (TrainingService.RunEvent) -> Void
    init(sink: @escaping @Sendable (TrainingService.RunEvent) -> Void) { self.sink = sink }

    func trainingStatusChanged(_ status: TrainingStatus) { sink(.status(status.rawValue)) }
    func trainingStepCompleted(step: Int, totalSteps: Int, loss: Float) { sink(.step(step, totalSteps, loss)) }
    func trainingCheckpointSaved(step: Int, path: URL) { sink(.checkpoint(step, path)) }
    func trainingValidationCompleted(step: Int, images: [URL]) { sink(.validation(step, images)) }
    func trainingFinished(success: Bool, message: String) { sink(.finished(success, message)) }
    func trainingPaused(atStep: Int) { sink(.paused(atStep)) }
    func trainingResumed(atStep: Int) { sink(.resumed(atStep)) }
}
