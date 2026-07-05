import SwiftUI
import AppKit

/// LoRA Training tab. Chunk 1 = the foundation screen: lists Workshops (reusable
/// training concepts) and the runs forged from them. Image import, captioning, the
/// params form, the live run and checkpoint review land in later chunks.
struct TrainingView: View {
    @Bindable var vm: TrainingViewModel

    /// Workshop awaiting a delete confirmation (mirrors RunView's checkpoint-delete precedent) —
    /// deleting cascades to EVERY run forged from it, so it must never be a single misclick.
    @State private var pendingWorkshopDelete: Workshop?

    var body: some View {
        Group {
            if let id = vm.selectedWorkshopID, vm.selectedWorkshop != nil {
                WorkshopEditorView(vm: vm, workshopID: id)
            } else {
                listView
            }
        }
        .task { vm.reload() }
    }

    private var listView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // ── Header + primary action ──
                HStack(spacing: 12) {
                    SectionTitle(text: "LoRA Training")
                    Spacer()
                    Button { vm.newWorkshop() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                            Text("New Workshop")
                        }
                    }
                    .buttonStyle(FxSecondaryButtonStyle(height: 32, accentText: true))
                }

                // ── Explanation ──
                Text("Train your own LoRA adapter on a set of your images. A Workshop holds a concept — your photos, a trigger word and a description; from it you forge trainings that produce an adapter you can use in Generate.")
                    .font(.fx(12)).foregroundStyle(Color.fxText3)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(.top, 8).padding(.bottom, 18)

                // ── Queue (auto-chained trainings) ──
                queueBanner

                // ── Trainings (their home — flat list across all workshops) ──
                allTrainingsSection

                // ── Workshops ──
                if vm.workshops.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 12) {
                        ForEach(vm.workshops) { workshop in
                            workshopCard(workshop)
                        }
                    }
                }

                // ── Outcome line ──
                if let msg = vm.lastAction {
                    Text(msg.text)
                        .font(.fx(11))
                        .foregroundStyle(msg.isError ? Color.fxDanger : Color.fxText3)
                        .padding(.top, 12)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.fxBg)
        .sheet(item: Binding(get: { vm.presentedRunID.map { RunRef(id: $0) } },
                             set: { vm.presentedRunID = $0?.id })) { ref in
            RunView(vm: vm, runID: ref.id, onClose: { vm.presentedRunID = nil })
        }
        // "Duplicate as new draft" → the forge sheet pre-filled with the source run's parameters.
        .sheet(item: $vm.forgePrefill) { pf in
            ForgeSessionView(vm: vm, workshop: pf.workshop,
                             prefillParams: pf.params, prefillName: pf.suggestedName,
                             onClose: { vm.forgePrefill = nil })
        }
        // Workshop delete confirmation (RunView's checkpoint-delete precedent): spell out the
        // cascade — the images AND every training forged from this concept go with it.
        .confirmationDialog("Delete “\(pendingWorkshopDelete?.name ?? "")”?",
                            isPresented: Binding(get: { pendingWorkshopDelete != nil },
                                                 set: { if !$0 { pendingWorkshopDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete workshop and trainings", role: .destructive) {
                if let w = pendingWorkshopDelete { vm.deleteWorkshop(w) }
                pendingWorkshopDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingWorkshopDelete = nil }
        } message: {
            if let w = pendingWorkshopDelete {
                let rs = vm.runs(for: w)
                let cps = rs.reduce(0) { $0 + $1.runtime.checkpoints.count }
                Text("Its \(w.images.count) image\(w.images.count == 1 ? "" : "s"), \(rs.count) training\(rs.count == 1 ? "" : "s") and \(cps) checkpoint\(cps == 1 ? "" : "s") are removed permanently. Published LoRAs stay in your library.")
            }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No workshops yet")
                .font(.fx(13, weight: .semibold)).foregroundStyle(Color.fxText2)
            Text("Create a workshop to start training a LoRA.")
                .font(.fx(12)).foregroundStyle(Color.fxText3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxCard(padding: 24)
    }

    // MARK: Queue

    @ViewBuilder private var queueBanner: some View {
        // Renders the FULL queue — trainings AND caption jobs — with full-queue positions, so the
        // numbers here always match the "queued #N" chips and the sidebar badge. Also shows the
        // RUNNING caption job (it left the queue when it started); without that row a 30–60 min
        // VLM batch made the Training root look completely idle.
        if !vm.queue.isEmpty || vm.captioning {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.stack").font(.system(size: 12)).foregroundStyle(Color.fxAccent)
                    Text("Up next").font(.fx(13, weight: .semibold)).foregroundStyle(Color.fxText2)
                    if !vm.queue.isEmpty {
                        Text("\(vm.queue.count) queued").font(.fxMono(10)).foregroundStyle(Color.fxText3)
                    }
                    Spacer()
                    if !vm.queue.isEmpty {
                        Button { vm.clearQueue() } label: { Text("Clear queue") }
                            .buttonStyle(FxGhostButtonStyle(height: 26))
                            .help("Remove every queued item — trainings and caption jobs (the running one keeps going)")
                    }
                }
                if vm.captioning { runningCaptionRow }
                if !vm.queue.isEmpty {
                    Text("These start automatically, one after another, when the current work finishes.")
                        .font(.fx(11)).foregroundStyle(Color.fxText3)
                    VStack(spacing: 6) {
                        ForEach(Array(vm.queue.enumerated()), id: \.element.id) { idx, item in
                            queueRow(position: idx + 1, item: item)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fxCard()
            .padding(.bottom, 14)
        }
    }

    /// One queue row — a training draft or a caption job — numbered by its FULL-queue position.
    @ViewBuilder private func queueRow(position: Int, item: TrainingQueueItem) -> some View {
        HStack(spacing: 10) {
            Text("\(position)").font(.fxMono(11)).foregroundStyle(Color.fxAccent).frame(width: 16)
            switch item {
            case .run(let id):
                if let run = vm.runs.first(where: { $0.id == id }) {
                    Button { vm.presentRun(run.id) } label: {
                        HStack(spacing: 8) {
                            Text(run.name).font(.fxMono(12)).foregroundStyle(Color.fxText).lineLimit(1)
                            Text("· \(run.tier.shortName) · \(run.params.maxSteps) steps")
                                .font(.fxMono(10)).foregroundStyle(Color.fxText3).lineLimit(1)
                            Spacer(minLength: 8)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("Deleted training").font(.fxMono(12)).foregroundStyle(Color.fxText3)
                    Spacer(minLength: 8)
                }
            case .caption(_, let workshopID, let onlyMissing):
                let name = vm.workshops.first { $0.id == workshopID }?.name ?? "deleted workshop"
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(Color.fxAccent)
                    Text("Caption job · \(name)").font(.fxMono(12)).foregroundStyle(Color.fxText).lineLimit(1)
                    Text(onlyMissing ? "· missing captions only" : "· all images")
                        .font(.fxMono(10)).foregroundStyle(Color.fxText3).lineLimit(1)
                    Spacer(minLength: 8)
                }
            }
            Button { vm.dequeue(item.id) } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                .buttonStyle(.plain).foregroundStyle(Color.fxText3)
                .help("Remove this item from the queue")
        }
        .padding(.vertical, 7).padding(.horizontal, 11)
        .background(Color.fxInset, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
    }

    /// Live strip for the RUNNING caption job — the only root-level sign a VLM batch is churning.
    private var runningCaptionRow: some View {
        let name = vm.captioningWorkshopID.flatMap { id in vm.workshops.first { $0.id == id }?.name } ?? "workshop"
        return HStack(spacing: 10) {
            FxDot(tone: .amber, live: true, size: 7)
            Text("Auto-captioning “\(name)”\(vm.captionTotal > 0 ? " — \(vm.captionDone)/\(vm.captionTotal)" : "")")
                .font(.fxMono(11)).foregroundStyle(Color.fxText2).lineLimit(1)
            Spacer()
            Button("Cancel") { vm.cancelCaptioning() }
                .buttonStyle(FxGhostButtonStyle(height: 26))
                .help("Stop after the current image — captions already made are kept")
        }
        .padding(.vertical, 7).padding(.horizontal, 11)
        .background(Color.fxInset, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
    }

    // MARK: Workshop card

    private func workshopCard(_ workshop: Workshop) -> some View {
        let runs = vm.runs(for: workshop)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button { vm.openWorkshop(workshop) } label: {
                    Text(workshop.name.isEmpty ? "Untitled" : workshop.name)
                        .font(.fx(14, weight: .semibold)).foregroundStyle(Color.fxText)
                }
                .buttonStyle(.plain)
                Text(workshop.conceptType.label.uppercased())
                    .font(.fxMono(10)).tracking(0.5).foregroundStyle(Color.fxAccent)
                Spacer()
                Button { vm.openWorkshop(workshop) } label: {
                    HStack(spacing: 5) { Text("Open"); Image(systemName: "chevron.right").font(.system(size: 10)) }
                }
                .buttonStyle(FxGhostButtonStyle(height: 26, accentText: true))
                .help("Open this workshop to edit images, captions and the trigger word")
                // Confirmation-gated (the VM refuses a busy delete too — this is the visible
                // half): the cascade removes every forged run's files, and doing that under a
                // LIVE training would yank the engine's output dir mid-write.
                Button(role: .destructive) { pendingWorkshopDelete = workshop } label: {
                    Image(systemName: "trash").font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.fxText3)
                .disabled(vm.workshopIsBusy(workshop))
                .opacity(vm.workshopIsBusy(workshop) ? 0.4 : 1)
                .help(vm.workshopIsBusy(workshop)
                      ? "Stop the training (or cancel the caption job) first"
                      : "Delete this workshop and its trainings")
            }

            HStack(spacing: 14) {
                metaItem(icon: "photo.stack", text: "\(workshop.images.count) image\(workshop.images.count == 1 ? "" : "s")")
                metaItem(icon: "tag", text: workshop.triggerWord.isEmpty ? "no trigger" : workshop.triggerWord)
                metaItem(icon: "rectangle.stack", text: "\(runs.count) training\(runs.count == 1 ? "" : "s")")
            }
            // Trainings themselves live in the top-level "Trainings" section (their home) — the card
            // stays about the concept/dataset so there's exactly one place to find and resume a run.
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxCard()   // fxCard owns the inset (default 14) — no extra .padding()
    }

    // MARK: Trainings (top-level home)

    /// Every forged training across all workshops, always visible so you never have to dig into a
    /// workshop to find or resume one. The active run is pinned first, then newest-first.
    @ViewBuilder private var allTrainingsSection: some View {
        let all = vm.runs.sorted { a, b in
            let aActive = a.id == vm.activeRunID, bActive = b.id == vm.activeRunID
            if aActive != bActive { return aActive }        // the running one on top
            return a.createdAt > b.createdAt                 // then newest first
        }
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "graduationcap").font(.system(size: 12)).foregroundStyle(Color.fxAccent)
                    Text("Trainings").font(.fx(13, weight: .semibold)).foregroundStyle(Color.fxText2)
                    Text("\(all.count)").font(.fxMono(10)).foregroundStyle(Color.fxText3)
                    Spacer()
                }
                Text("Every training you've created. Click one to open its live monitor — start it, watch progress, or review and publish checkpoints.")
                    .font(.fx(11)).foregroundStyle(Color.fxText3)
                VStack(spacing: 8) {
                    ForEach(all) { run in trainingRow(run) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fxCard()
            .padding(.bottom, 14)
        }
    }

    private func trainingRow(_ run: TrainingRun) -> some View {
        let workshopName = vm.workshops.first { $0.id == run.workshopId }?.name ?? "—"
        let isActive = run.id == vm.activeRunID
        return HStack(spacing: 10) {
            // Whole left region opens the live monitor.
            Button { vm.presentRun(run.id) } label: {
                HStack(spacing: 10) {
                    FxDot(tone: tone(for: run.status), live: run.status.isActive, size: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(run.name).font(.fxMono(12)).foregroundStyle(Color.fxText).lineLimit(1)
                            Text(run.status.label).font(.fxMono(10)).foregroundStyle(Color.fxText3)
                            if let pos = vm.queuePosition(of: run.id) { queuedChip(pos) }
                            if run.status.isActive || run.status == .completed {
                                Text("\(run.runtime.currentStep)/\(run.runtime.totalSteps)")
                                    .font(.fxMono(10)).foregroundStyle(Color.fxText3)
                            }
                        }
                        Text("\(workshopName) · \(run.tier.shortName) · \(run.params.maxSteps) steps · \(run.params.maxResolution)px")
                            .font(.fxMono(9.5)).foregroundStyle(Color.fxText3).lineLimit(1)
                        // Terminal outcome — runtime.message carries the failure reason / stop
                        // summary / "Interrupted — open it to resume.", persisted but previously
                        // rendered nowhere: a Failed run showed no WHY anywhere.
                        // Queued runs excluded — their park message ("Queued — starts when the
                        // engine frees up.") would render as red failure text; the chip covers it.
                        if !isActive, vm.queuePosition(of: run.id) == nil,
                           run.status == .failed || run.status == .cancelled || run.status == .paused,
                           !run.runtime.message.isEmpty {
                            Text(run.runtime.message)
                                .font(.fx(10))
                                .foregroundStyle(run.status == .failed ? Color.fxDanger : Color.fxText3)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            runOpenButton(run)
            Button(role: .destructive) { vm.deleteRun(run) } label: {
                Image(systemName: "trash").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(Color.fxText3)
            .disabled(isActive)
            .opacity(isActive ? 0.4 : 1)
            .help(isActive ? "Stop the training first" : "Delete this training")
        }
        .padding(.vertical, 8).padding(.horizontal, 12)
        .background(Color.fxInset, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(isActive ? Color.fxAccentLine : Color.fxBorder, lineWidth: isActive ? 1.3 : 1))
        .contextMenu {
            Button {
                vm.duplicateAsDraft(run)
            } label: {
                Label("Duplicate as new draft", systemImage: "plus.square.on.square")
            }
            .disabled(!vm.canDuplicate(run))
        }
    }

    /// Small "queued #N" pill shown on a run that's waiting in the auto-chain queue.
    private func queuedChip(_ pos: Int) -> some View {
        Text("queued #\(pos)")
            .font(.fxMono(9.5)).foregroundStyle(Color.fxAccent)
            .padding(.vertical, 2).padding(.horizontal, 6)
            .background(Color.fxAccentSoft, in: Capsule())
    }

    /// A clear affordance in place of the old bare chevron: "▶ Start" for a Draft, "Open ›" otherwise.
    /// Both open the live monitor — the actual (gated) Start button lives there.
    @ViewBuilder private func runOpenButton(_ run: TrainingRun) -> some View {
        if run.status == .draft {
            Button { vm.presentRun(run.id) } label: {
                HStack(spacing: 5) { Image(systemName: "play.fill").font(.system(size: 9)); Text("Start") }
            }
            .buttonStyle(FxSecondaryButtonStyle(height: 26, accentText: true))
            .help("Open to start this training")
        } else {
            Button { vm.presentRun(run.id) } label: {
                HStack(spacing: 5) { Text("Open"); Image(systemName: "chevron.right").font(.system(size: 9)) }
            }
            .buttonStyle(FxGhostButtonStyle(height: 26, accentText: true))
            .help(run.status.isActive ? "Open the live monitor" : "Open this training")
        }
    }

    private func metaItem(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Color.fxText3)
            Text(text).font(.fxMono(11)).foregroundStyle(Color.fxText2).lineLimit(1)
        }
    }

    private func tone(for status: TrainingRunStatus) -> FxTone {
        switch status {
        case .training, .preparing, .loadingModel: return .amber
        case .completed, .published:               return .ok
        case .failed, .cancelled:                  return .danger
        default:                                   return .idle
        }
    }
}
