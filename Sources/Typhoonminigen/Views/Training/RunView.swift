import SwiftUI
import AppKit

/// Lightweight Identifiable wrapper so a run row can present `RunView` via `.sheet(item:)`.
struct RunRef: Identifiable { let id: UUID }

/// The live training run screen (Chunk 5), shown as a sheet for one run. A Draft shows "Start
/// training"; a running one shows live telemetry (step/ETA, loss curve, checkpoint markers) +
/// Pause/Checkpoint/Stop; a finished one shows the summary + its checkpoints. The run keeps training
/// in the view model even when this sheet is dismissed.
struct RunView: View {
    @Bindable var vm: TrainingViewModel
    let runID: UUID
    let onClose: () -> Void

    @State private var pendingDelete: Int?   // checkpoint step awaiting a delete confirmation
    @State private var matrix: ValidationMatrix?   // disk-scanned compare grid (terminal runs)
    @State private var diskStats: CheckpointDiskStats?   // adapter sizes + weight presence (terminal runs)

    /// Prefer the live in-memory run while it (or its just-finished snapshot) matches; else the persisted one.
    private var run: TrainingRun? {
        if vm.activeRun?.id == runID { return vm.activeRun }
        return vm.runs.first { $0.id == runID }
    }
    private var isActive: Bool { vm.activeRunID == runID }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.fxBorder)
            if let run {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        outcomeNote(run)
                        if run.status.isActive || isActive { progressSection(run) }
                        if !run.runtime.lossHistory.isEmpty { lossSection(run) }
                        checkpointSection(run)
                        infoSection(run)
                    }
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Spacer(); Text("Training not found").font(.fx(13)).foregroundStyle(Color.fxText3); Spacer()
            }
            Divider().overlay(Color.fxBorder)
            controls
        }
        .frame(width: 640, height: 660)
        .background(Color.fxBg)
        // Rescan the compare matrix + the checkpoint disk stats when the run lands in a terminal
        // state or checkpoints change (a delete bumps the count → this re-keys).
        .task(id: scanKey) {
            guard let run, !run.status.isActive else { matrix = nil; diskStats = nil; return }
            let snapshot = run
            let scanned = await Task.detached(priority: .utility) {
                (matrix: ValidationMatrix.scan(run: snapshot), stats: CheckpointDiskStats.scan(run: snapshot))
            }.value
            matrix = scanned.matrix
            diskStats = scanned.stats
        }
    }

    private var scanKey: String {
        // status+count alone missed two stale windows: (1) a retention prune landing AFTER the
        // run went terminal deletes weight files without changing the count — reclaimedBytes is
        // the trace it leaves on the record; (2) a delete whose record-save failed keeps the
        // step LIST as the thing that changes on the next successful save, not its size — so
        // key on the steps themselves.
        let steps = run?.runtime.checkpoints.map { String($0.step) }.joined(separator: ".") ?? ""
        return "\(runID)-\(run?.status.rawValue ?? "")-\(steps)-\(run?.runtime.reclaimedBytes ?? 0)"
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            FxDot(tone: tone, live: run?.status.isActive ?? false, size: 8)
            Text(run?.name ?? "Training").font(.fx(14, weight: .semibold)).foregroundStyle(Color.fxText)
            if let t = run?.triggerWord, !t.isEmpty {
                Text(t).font(.fxMono(10)).foregroundStyle(Color.fxAccent)
                    .padding(.vertical, 2).padding(.horizontal, 7)
                    .background(Color.fxAccentSoft, in: Capsule())
            }
            Text(run?.status.label ?? "").font(.fxMono(11)).foregroundStyle(Color.fxText3)
            Spacer()
            if let run, !run.status.isActive, vm.canDuplicate(run) {
                Button { vm.duplicateAsDraft(run) } label: { Image(systemName: "plus.square.on.square") }
                    .buttonStyle(FxIconButtonStyle())
                    .help("Duplicate as a new draft — every parameter copied for A/B tweaks, dataset re-snapshotted from the workshop")
            }
            Button { onClose() } label: { Image(systemName: "xmark") }
                .buttonStyle(FxIconButtonStyle())
                .keyboardShortcut(.cancelAction)
                .help("Close — training keeps running in the background")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: Outcome note

    /// The run's stored `runtime.message` for a NOT-currently-running failed/stopped/interrupted
    /// run — the failure reason and the store's "Interrupted — open it to resume." were persisted
    /// but rendered nowhere, so a Failed run showed no WHY anywhere in the app.
    @ViewBuilder private func outcomeNote(_ run: TrainingRun) -> some View {
        let msg = run.runtime.message.trimmingCharacters(in: .whitespacesAndNewlines)
        // Queued runs are excluded: a parked FAILED run carries "Queued — starts when the
        // engine frees up." as its message, and rendering that through the failure styling
        // showed it in alarm-red with a warning icon — the queued chip already says it all.
        if !isActive, !msg.isEmpty, vm.queuePosition(of: run.id) == nil,
           run.status == .failed || run.status == .cancelled || run.status == .paused {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: run.status == .failed ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(run.status == .failed ? Color.fxDanger : Color.fxText3)
                Text(msg)
                    .font(.fx(11.5))
                    .foregroundStyle(run.status == .failed ? Color.fxDanger : Color.fxText2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)   // failure reasons get pasted into bug reports
                Spacer()
            }
            .fxCard(padding: 12)
        }
    }

    // MARK: Progress

    private func progressSection(_ run: TrainingRun) -> some View {
        let rt = run.runtime
        let total = max(1, rt.totalSteps)
        return VStack(alignment: .leading, spacing: 10) {
            if let phase = vm.runPhaseLine, isActive {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(phase).font(.fxMono(11)).foregroundStyle(Color.fxText2)
                }
            }
            // Elapsed + ETA tick every second while active.
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let elapsed = rt.startedAt.map { ctx.date.timeIntervalSince($0) } ?? 0
                let frac = Double(rt.currentStep) / Double(total)
                // ETA from THIS session's throughput: startedAt is session-local but currentStep
                // is GLOBAL — after Resume/Extend from step N, elapsed×(1-frac)/frac inflated the
                // per-step time by up to total/N× (resume at 280/300 read ~20× too long). Divide
                // elapsed only by the steps stepped since this session began; ≥3 steps before
                // showing anything (mirrors the old 1%-warm-up — the first steps carry load noise).
                let sessionSteps = isActive ? rt.currentStep - vm.activeSessionStartStep : 0
                let eta: TimeInterval? = (sessionSteps >= 3 && run.status.isActive)
                    ? elapsed / Double(sessionSteps) * Double(total - rt.currentStep) : nil
                HStack {
                    Text("Step \(rt.currentStep) / \(total)").font(.fxMono(13)).foregroundStyle(Color.fxText)
                    Text("· \(Int(frac * 100))%").font(.fxMono(12)).foregroundStyle(Color.fxAccent)
                    Spacer()
                    Text("elapsed \(Self.fmt(elapsed))"
                         + (eta.map { " · ~\(Self.fmt($0)) left" } ?? ""))
                        .font(.fxMono(11)).foregroundStyle(Color.fxText3)
                }
            }
            checkpointMeter(run)
        }
        .fxCard(padding: 14)
    }

    /// Progress meter with green checkpoint markers along it.
    private func checkpointMeter(_ run: TrainingRun) -> some View {
        let total = max(1, run.runtime.totalSteps)
        let frac = min(1, Double(run.runtime.currentStep) / Double(total))
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.fxInset)
                Capsule().fill(LinearGradient(colors: [.fxAccentDeep, .fxAccent], startPoint: .leading, endPoint: .trailing))
                    .frame(width: frac * geo.size.width)
                ForEach(run.runtime.checkpoints) { cp in
                    Circle().fill(Color.fxOk).frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(Color.fxBg, lineWidth: 1))
                        .offset(x: min(geo.size.width - 7, Double(cp.step) / Double(total) * geo.size.width - 3.5))
                }
            }
        }
        .frame(height: 8)
    }

    // MARK: Loss

    private func lossSection(_ run: TrainingRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Loss curve").font(.fx(12, weight: .medium)).foregroundStyle(Color.fxText2)
                Spacer()
                if let last = run.runtime.lossHistory.last {
                    Text(String(format: "loss %.4f", last)).font(.fxMono(11)).foregroundStyle(Color.fxText3)
                }
            }
            LossChart(values: run.runtime.lossHistory).frame(height: 120)
                .background(Color.fxLogBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
            HStack(spacing: 14) {
                legend(Color.fxText3.opacity(0.7), "raw")
                legend(Color.fxAccent, "smoothed")
            }
        }
        .fxCard(padding: 14)
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1).fill(c).frame(width: 14, height: 2.5)
            Text(t).font(.fxMono(10)).foregroundStyle(Color.fxText3)
        }
    }

    // MARK: Checkpoints

    @ViewBuilder private func checkpointSection(_ run: TrainingRun) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Checkpoints").font(.fx(12, weight: .medium)).foregroundStyle(Color.fxText2)
                Spacer()
                Text("\(run.runtime.checkpoints.count) saved").font(.fxMono(11)).foregroundStyle(Color.fxText3)
            }
            if run.runtime.checkpoints.isEmpty {
                Text(run.status.isActive ? "Checkpoints will appear here as they're saved."
                                         : "No checkpoints were saved.")
                    .font(.fx(11)).foregroundStyle(Color.fxText3)
            } else if run.status.isActive {
                // Live: compact chips only (publishing happens once the run finishes).
                FxFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(run.runtime.checkpoints) { cp in
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 9)).foregroundStyle(Color.fxOk)
                            Text("step \(cp.step)").font(.fxMono(10.5)).foregroundStyle(Color.fxText2)
                        }
                        .padding(.vertical, 4).padding(.horizontal, 8)
                        .background(Color.fxInset, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.fxBorder, lineWidth: 1))
                    }
                }
            } else {
                // Terminal: review + publish. The final checkpoint isn't always the best.
                if run.publishedCheckpointStep == nil {
                    Text("Pick the version that looks best and publish it as a LoRA you can use in Generate — the final one isn't always best (it can overfit).")
                        .font(.fx(11)).foregroundStyle(Color.fxText3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let matrix {
                    // `?? false`: until the disk scan lands, assume NO weights — a false
                    // "publishable" offers a button whose click dies on publish's fileExists
                    // guard; a false "preview only" just corrects itself when the scan lands.
                    CheckpointCompareGrid(run: run, matrix: matrix,
                                          hasWeights: { diskStats?.hasWeights($0) ?? false },
                                          onPublish: { step in vm.publish(run: run, checkpointStep: step) })
                        .padding(.bottom, 4)
                }
                ForEach(run.runtime.checkpoints) { cp in checkpointRow(run, cp) }
                finalAdapterRow(run)
            }
        }
        .fxCard(padding: 14)
        .confirmationDialog("Delete checkpoint at step \(pendingDelete ?? 0)?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let s = pendingDelete { vm.deleteCheckpoint(run: run, step: s) }; pendingDelete = nil }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { Text("Its files are removed permanently. The published LoRA (if any) stays in your library.") }
    }

    private func checkpointRow(_ run: TrainingRun, _ cp: TrainingCheckpoint) -> some View {
        let published = run.publishedCheckpointStep == cp.step
        // Rolling retention stripped this checkpoint's weight files → preview-only: its
        // validation images remain in the compare grid, but it can't be published.
        // Both facts come from the diskStats SNAPSHOT — the row used to stat the filesystem on
        // every body evaluation. nil until the scan lands → assume NO weights: a wrongly
        // offered Publish dies confusingly on the fileExists guard, while a wrongly shown
        // "preview only" corrects itself milliseconds later when the scan lands.
        let pruned = !(diskStats?.hasWeights(cp.step) ?? false)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: pruned ? "circle.dashed" : "checkmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(pruned ? Color.fxText3 : Color.fxOk)
                Text("Step \(cp.step)").font(.fxMono(12)).foregroundStyle(Color.fxText)
                Text(Self.sizeLabel(diskStats?.adapterSizes[cp.step])).font(.fxMono(10)).foregroundStyle(Color.fxText3)
                if published {
                    HStack(spacing: 4) { FxDot(tone: .ok, size: 6); Text("published") }.fxPillOk()
                }
                if pruned {
                    Text("preview only")
                        .font(.fxMono(10)).foregroundStyle(Color.fxText3)
                        .padding(.vertical, 2).padding(.horizontal, 7)
                        .background(Color.fxInset, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.fxBorder, lineWidth: 1))
                        .help("Retention removed this checkpoint's weight files to save disk — its validation images stay for comparing, but it can't be published or extended from.")
                }
                Spacer()
                if !pruned {
                    Button { vm.publish(run: run, checkpointStep: cp.step) } label: {
                        Text(published ? "Republish" : "Publish")
                    }
                    .buttonStyle(FxSecondaryButtonStyle(height: 26, accentText: true))
                    Button { vm.revealAdapter(run: run, checkpointStep: cp.step) } label: { Image(systemName: "folder") }
                        .buttonStyle(FxIconButtonStyle(size: 26))
                        .help("Show this checkpoint's .safetensors in Finder")
                }
                Button { pendingDelete = cp.step } label: { Image(systemName: "trash") }
                    .buttonStyle(FxIconButtonStyle(size: 26, destructive: true))
                    .help("Delete this checkpoint")
            }
            // Validation previews for this checkpoint — only when the compare matrix above
            // isn't showing them already (it's the better home for the same images).
            if matrix == nil, !cp.validationImageNames.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(cp.validationImageNames, id: \.self) { rel in
                            PreviewThumb(url: run.outputDir.appendingPathComponent(rel))
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 11)
        .background(Color.fxInset, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(published ? Color.fxAccentLine : Color.fxBorder, lineWidth: published ? 1.4 : 1))
    }

    private func finalAdapterRow(_ run: TrainingRun) -> some View {
        let published = run.publishedCheckpointStep == TrainingViewModel.finalAdapterStep
        return HStack(spacing: 10) {
            Image(systemName: "flag.checkered").font(.system(size: 11)).foregroundStyle(Color.fxText3)
            Text("Final adapter").font(.fxMono(12)).foregroundStyle(Color.fxText2)
            Text(Self.sizeLabel(diskStats?.finalAdapterSize)).font(.fxMono(10)).foregroundStyle(Color.fxText3)
            if published {
                HStack(spacing: 4) { FxDot(tone: .ok, size: 6); Text("published") }.fxPillOk()
            }
            Spacer()
            Button { vm.publish(run: run, checkpointStep: nil) } label: { Text(published ? "Republish" : "Publish") }
                .buttonStyle(FxSecondaryButtonStyle(height: 26, accentText: true))
            Button { vm.revealAdapter(run: run, checkpointStep: nil) } label: { Image(systemName: "folder") }
                .buttonStyle(FxIconButtonStyle(size: 26))
                .help("Show the final .safetensors in Finder")
        }
        .padding(.vertical, 8).padding(.horizontal, 11)
        .background(Color.fxInset.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(published ? Color.fxAccentLine : Color.clear, lineWidth: 1.4))
    }

    private static func sizeLabel(_ bytes: Int64?) -> String {
        bytes.map(ByteFormat.string) ?? "—"
    }

    // MARK: Info

    private func infoSection(_ run: TrainingRun) -> some View {
        FxFlowLayout(spacing: 18, lineSpacing: 10) {
            info("Model", run.tier.shortName)
            info("Steps", "\(run.params.maxSteps)")
            info("Resolution", "\(run.params.maxResolution)px")
            info("Rank / Alpha", "\(run.params.rank) / \(Int(run.params.alpha))")
            // imageCount is what freezeDataset WROTE — originals + flips already summed — so the
            // old "(mirror ×2)" suffix read as "N originals ×2 = 2N", double-counting the flips.
            info("Images", "\(run.imageCount)" + (run.params.flipAugment == true ? " (incl. mirrored)" : ""))
            info("DOP", run.params.dopEnabled ? "on (\(run.params.dopClass))" : "off")
            if let keep = run.params.keepLastCheckpoints {
                let freed = run.runtime.reclaimedBytes ?? 0
                info("Retention", "last \(keep)" + (freed > 0 ? " · \(ByteFormat.string(freed)) freed" : ""))
            }
        }
        .fxCard(padding: 14)
    }

    private func info(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.fx(10)).foregroundStyle(Color.fxText3)
            Text(value).font(.fxMono(11.5)).foregroundStyle(Color.fxText2)
        }
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        HStack(spacing: 10) {
            if let run {
                if isActive {
                    if run.status == .paused {
                        Button { vm.resumeRun() } label: { ctl("play.fill", "Resume") }
                            .buttonStyle(FxSecondaryButtonStyle(height: 32, accentText: true))
                    } else {
                        Button { vm.pauseRun() } label: { ctl("pause.fill", "Pause") }
                            .buttonStyle(FxSecondaryButtonStyle(height: 32))
                            .disabled(vm.stopRequested)
                        Button { vm.checkpointRun() } label: { ctl("square.and.arrow.down", "Checkpoint") }
                            .buttonStyle(FxSecondaryButtonStyle(height: 32))
                            .disabled(vm.stopRequested)
                    }
                    Spacer()
                    if vm.stopRequested {
                        // The graceful stop finishes the in-flight step + checkpoint + validation
                        // (~a minute) — show that, or the Stop button reads as dead.
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Stopping — saving a checkpoint…")
                                .font(.fx(11.5)).foregroundStyle(Color.fxText3)
                        }
                    } else {
                        Button { vm.stopRun() } label: { ctl("stop.fill", "Stop") }
                            .buttonStyle(FxSecondaryButtonStyle(height: 32))
                            .help("Stop gracefully — saves a checkpoint first; its checkpoints stay usable.")
                    }
                } else if vm.exceedsRAM(run) {
                    // Hard RAM block: this exact footgun froze a 32 GB Mac (9B incident) — no Start,
                    // no Resume, no queue; say WHY instead of showing a dead button.
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.octagon.fill").font(.system(size: 12)).foregroundStyle(Color.fxDanger)
                        Text("Needs ~\(TrainingService.estimatedPeakGB(tier: run.tier, resolution: run.params.maxResolution, dopEnabled: run.params.dopEnabled)) GB — this Mac has \(SystemRAM.installedGB) GB. Starting it would freeze the machine; run it on a bigger-RAM Mac.")
                            .font(.fx(11)).foregroundStyle(Color.fxText2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                } else if vm.canStart(run) {
                    let label = run.status == .draft ? "Start training" : "Resume training"
                    Button { vm.startRun(run) } label: { ctl("play.fill", label) }
                        .buttonStyle(FxPrimaryButtonStyle(height: 32))
                        .help(TrainingService.baseModelPresent(tier: run.tier)
                              ? "Runs on this Mac — \(run.params.maxSteps) steps, ~1–3 h. Image generation pauses while it runs."
                              : "The \(run.tier.shortName) base model (~\(run.tier == .klein9B ? 18 : 8) GB) downloads first, then training starts.")
                    Spacer()
                    if !TrainingService.baseModelPresent(tier: run.tier) {
                        Text("Base model downloads first (~\(run.tier == .klein9B ? 18 : 8) GB).")
                            .font(.fx(11)).foregroundStyle(Color.fxText3)
                    }
                } else if let pos = vm.queuePosition(of: run.id) {
                    // Already queued — show its place and let the user pull it back out.
                    Text("Queued · position \(pos)").font(.fxMono(11)).foregroundStyle(Color.fxAccent)
                    Spacer()
                    Button { vm.dequeue(run.id) } label: { ctl("xmark", "Remove from queue") }
                        .buttonStyle(FxSecondaryButtonStyle(height: 32))
                } else if vm.isQueueable(run) {
                    // The trainer is busy — offer to chain this one after it instead of refusing.
                    // The blocker isn't always a training: caption jobs are queue citizens too.
                    Text(trainerBusyReason).font(.fx(11)).foregroundStyle(Color.fxText3)
                    Spacer()
                    Button { vm.enqueue(run) } label: { ctl("rectangle.stack.badge.plus", "Add to queue") }
                        .buttonStyle(FxSecondaryButtonStyle(height: 32, accentText: true))
                        .help("Starts automatically when the current work finishes.")
                } else if vm.canExtend(run) {
                    // Finished run → continue from the last checkpoint with a raised step target.
                    Menu {
                        ForEach([250, 500, 1000], id: \.self) { n in
                            Button("+\(n) steps") { vm.extendRun(run, addSteps: n) }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "goforward.plus").font(.system(size: 11))
                            Text("Extend training").font(.fx(12.5, weight: .medium))
                            Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(Color.fxText3)
                        }
                        .foregroundStyle(Color.fxAccent)
                        .padding(.vertical, 7).padding(.horizontal, 12)
                        .background(Color.fxInset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.fxBorder, lineWidth: 1))
                    }
                    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
                    .fixedSize()
                    .help("Continue this training from its last checkpoint (step \(vm.latestCheckpointStep(run) ?? 0)) with more steps — the fix for a result that looks undertrained.")
                    if !vm.extendKeepsMomentum(run) {
                        Text("Optimizer state was removed — resumes with fresh momentum.")
                            .font(.fx(10.5)).foregroundStyle(Color.fxText3)
                    }
                    Spacer()
                } else if vm.isTrainingActive {
                    Spacer()
                    Text("Another training is already running.").font(.fx(11)).foregroundStyle(Color.fxText3)
                } else {
                    Spacer()   // terminal / published — review above, just Close here
                }
            }
            Button("Close") { onClose() }
                .buttonStyle(FxGhostButtonStyle(height: 32))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func ctl(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 6) { Image(systemName: icon); Text(text) }
    }

    /// WHY canStart refuses right now — canStart also gates on captioning/smoke/forge, so
    /// "A training is already running." would be plain wrong during a 45-min caption batch.
    private var trainerBusyReason: String {
        if vm.isTrainingActive { return "A training is already running." }
        if vm.captioning { return "An auto-caption job is running." }
        if vm.smokeRunning { return "A smoke test is running." }
        return "The trainer is busy."
    }

    private var tone: FxTone {
        switch run?.status {
        case .training, .preparing, .loadingModel: return .amber
        case .completed, .published:               return .ok
        case .failed, .cancelled:                  return .danger
        default:                                   return .idle
        }
    }

    /// "1h 23m" / "5m 12s" / "45s".
    static func fmt(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        if s >= 60 { return "\(s / 60)m \(s % 60)s" }
        return "\(s)s"
    }
}

/// Disk facts for the checkpoint review (adapter sizes + which checkpoints still have their
/// weights), scanned ONCE off-main when the sheet loads or the checkpoints change. The rows
/// used to `attributesOfItem`/`fileExists` per row on EVERY body evaluation — a main-thread
/// syscall storm, re-fired every second by the progress section's TimelineView.
struct CheckpointDiskStats: Sendable {
    var adapterSizes: [Int: Int64] = [:]     // checkpoint step → lora.safetensors bytes
    var finalAdapterSize: Int64? = nil       // lora_final.safetensors bytes (nil → not on disk)
    private var stepsWithWeights: Set<Int> = []

    /// Mirrors `TrainingViewModel.checkpointHasWeights` from the snapshot instead of the disk.
    func hasWeights(_ step: Int) -> Bool { stepsWithWeights.contains(step) }

    /// File IO — call OFF the main actor.
    static func scan(run: TrainingRun) -> CheckpointDiskStats {
        let fm = FileManager.default
        var stats = CheckpointDiskStats()
        for cp in run.runtime.checkpoints {
            let url = run.outputDir.appendingPathComponent(
                "checkpoint_\(String(format: "%06d", cp.step))/lora.safetensors")
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64 {
                stats.adapterSizes[cp.step] = size
                stats.stepsWithWeights.insert(cp.step)   // size readable ⇒ the weight file exists
            }
        }
        let final = run.outputDir.appendingPathComponent("lora_final.safetensors")
        if let size = (try? fm.attributesOfItem(atPath: final.path))?[.size] as? Int64 {
            stats.finalAdapterSize = size
        }
        return stats
    }
}

/// Small square validation-preview thumbnail (downsampled, off-main) for the checkpoint review.
private struct PreviewThumb: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        Rectangle().fill(Color.fxInset)
            .frame(width: 60, height: 60)
            .overlay { if let image { Image(nsImage: image).resizable().scaledToFill() } }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
            .task(id: url) { image = await WorkshopDatasetService.thumbnail(at: url, maxPixel: 140) }
    }
}

/// Raw (faint) + moving-average-smoothed (amber) loss, drawn on ONE shared y-scale so they align.
/// Internal (not private) — the LoRA library's model-card sheet renders the same chart from the
/// loss series snapshotted at publish time.
struct LossChart: View {
    let values: [Float]
    var smoothWindow: Int = 20

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let lo = values.min().map(Double.init) ?? 0
            let hi = values.max().map(Double.init) ?? 1
            let span = (hi - lo) == 0 ? 1 : (hi - lo)
            func point(_ i: Int, _ v: Double) -> CGPoint {
                let x = CGFloat(i) / CGFloat(values.count - 1) * size.width
                let y = size.height - 6 - CGFloat((v - lo) / span) * (size.height - 12)
                return CGPoint(x: x, y: y)
            }
            // Raw
            var raw = Path()
            raw.move(to: point(0, Double(values[0])))
            for i in 1..<values.count { raw.addLine(to: point(i, Double(values[i]))) }
            ctx.stroke(raw, with: .color(.fxText3.opacity(0.55)), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
            // Smoothed (trailing moving average)
            var sm = Path()
            var started = false
            for i in values.indices {
                let lo2 = max(0, i - smoothWindow + 1)
                let window = values[lo2...i]
                let avg = Double(window.reduce(0, +)) / Double(window.count)
                let p = point(i, avg)
                if started { sm.addLine(to: p) } else { sm.move(to: p); started = true }
            }
            ctx.stroke(sm, with: .color(.fxAccent), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
        .drawingGroup(opaque: false)
    }
}
