import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The workshop atelier — Chunk 3. Edit a reusable training concept: identity (name, trigger,
/// concept type, description), the image dataset (import / drag-drop / per-image captions / batch
/// auto-caption via the local Qwen3.5-VLM), and a live readiness gate that flips to "Ready to
/// launch a session" once every requirement is met. Forging a session (params) is the next chunk.
struct WorkshopEditorView: View {
    @Bindable var vm: TrainingViewModel
    let workshopID: UUID

    // Identity drafts — edited live, persisted 400 ms after the last keystroke (and on close).
    @State private var name = ""
    @State private var trigger = ""
    @State private var conceptType: ConceptType = .object
    @State private var conceptDescription = ""
    @State private var captionInstruction = ""    // empty → the concept-type preset is used
    @State private var seeded = false

    @State private var captionIndex = 0
    @State private var showCaption = false
    @State private var dropTargeted = false
    @State private var forgeWorkshop: Workshop?   // non-nil → the forge sheet is up

    // Caption tooling drafts (feature: bulk find & replace / append / prepend + instruction editor).
    @State private var showInstruction = false
    @State private var showCaptionTools = false
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var ignoreCase = true
    @State private var amendText = ""

    private enum Gate {
        static let minImages = 10
        static let recommended = 15...25
        static let minDescription = 10
    }

    private var workshop: Workshop? { vm.workshops.first { $0.id == workshopID } }

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerBar
                titleRow
                readinessBanner
                identityCard
                galleryCard
                trainingsSection
                if let msg = vm.lastAction {
                    Text(msg.text).font(.fx(11))
                        .foregroundStyle(msg.isError ? Color.fxDanger : Color.fxText3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.fxBg)
        .onAppear(perform: seedIfNeeded)
        .onDisappear(perform: commitIdentity)   // final save if the user left within the debounce window
        .sheet(isPresented: $showCaption) {
            CaptionEditorView(vm: vm, workshopID: workshopID, index: $captionIndex,
                              onClose: { showCaption = false })
        }
        .sheet(item: $forgeWorkshop) { w in
            ForgeSessionView(vm: vm, workshop: w, onClose: { forgeWorkshop = nil })
        }
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
    }

    // MARK: Header / title

    private var headerBar: some View {
        HStack(spacing: 12) {
            Button { commitIdentity(); vm.closeEditor() } label: {
                HStack(spacing: 6) { Image(systemName: "chevron.left"); Text("Workshops") }
            }
            .buttonStyle(FxGhostButtonStyle(height: 30, accentText: true))
            Spacer()
            Button { openForge() } label: {
                HStack(spacing: 6) { Image(systemName: "hammer"); Text("New training") }
            }
            .buttonStyle(FxPrimaryButtonStyle(height: 30))
            .disabled(!isReady)
            .opacity(isReady ? 1 : 0.5)
            .help(isReady ? "Forge a training from this workshop"
                          : "Complete the workshop first — see the checklist above")
        }
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            SectionTitle(text: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled workshop" : name)
            Text(conceptType.label.uppercased())
                .font(.fxMono(10)).tracking(0.5).foregroundStyle(Color.fxAccent)
            Spacer()
        }
    }

    // MARK: Readiness gate

    private var readinessBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(isReady ? Color.fxOk : Color.fxAccent)
            VStack(alignment: .leading, spacing: isReady ? 2 : 6) {
                Text(isReady ? "Ready to start a training" : "Workshop incomplete")
                    .font(.fx(13, weight: .semibold))
                    .foregroundStyle(isReady ? Color.fxOk : Color.fxText)
                if isReady {
                    Text("This workshop meets every requirement to train a LoRA.")
                        .font(.fx(11)).foregroundStyle(Color.fxText3)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(blockers, id: \.self) { b in
                            HStack(spacing: 7) {
                                Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(Color.fxText3)
                                Text(b).font(.fx(11)).foregroundStyle(Color.fxText2)
                            }
                        }
                    }
                }
            }
            Spacer()
        }
        .fxCard()
    }

    // MARK: Identity

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Concept").font(.fx(13, weight: .semibold)).foregroundStyle(Color.fxText2)

            field(label: "Workshop name") {
                TextField("Workshop name", text: $name)
                    .textFieldStyle(.plain).font(.fx(13)).foregroundStyle(Color.fxText)
                    .padding(.vertical, 8).padding(.horizontal, 12).fxInsetField()
                    .onChange(of: name) { _, _ in scheduleSave() }
            }

            field(label: "Trigger word") {
                TextField("ex: sks, ohwx, zwx…", text: $trigger)
                    .textFieldStyle(.plain).font(.fxMono(13)).foregroundStyle(Color.fxText)
                    .padding(.vertical, 8).padding(.horizontal, 12).fxInsetField()
                    .onChange(of: trigger) { _, _ in scheduleSave() }
                triggerHint
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Concept type").fxLabel()
                FxFlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(ConceptType.allCases) { ct in typeChip(ct) }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Concept description").fxLabel()
                    Spacer()
                    Text("\(descLen)/\(Gate.minDescription)+")
                        .font(.fxMono(10))
                        .foregroundStyle(descLen >= Gate.minDescription ? Color.fxOk : Color.fxText3)
                }
                descriptionEditor
                Text(descLen < Gate.minDescription
                     ? "\(Gate.minDescription - descLen) more character(s) needed."
                     : "Describe the subject, style and context — it guides captioning and the recommended settings.")
                    .font(.fx(11)).foregroundStyle(Color.fxText3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxCard(padding: 16)
    }

    private var triggerHint: some View {
        let t = trimmedTrigger
        let (text, color): (String, Color) =
            t.isEmpty ? ("Required — a single word, no spaces, that activates your LoRA.", Color.fxText3)
            : triggerHasSpace ? ("The trigger word must not contain spaces.", Color.fxDanger)
            : ("“\(t)” will activate your LoRA. It's added to every caption automatically at train time.", Color.fxText3)
        return Text(text).font(.fx(11)).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func typeChip(_ ct: ConceptType) -> some View {
        let selected = conceptType == ct
        return Button {
            if conceptType != ct { conceptType = ct; scheduleSave() }
        } label: {
            Text(ct.label)
                .font(.fxMono(11)).foregroundStyle(selected ? Color.fxOnAccent : Color.fxText2)
                .padding(.vertical, 6).padding(.horizontal, 12)
                .background(selected ? Color.fxAccent : Color.fxInset, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Color.clear : Color.fxBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var descriptionEditor: some View {
        ZStack(alignment: .topLeading) {
            if conceptDescription.isEmpty {
                Text("Describe what you're training (subject, style, context)…")
                    .font(.fx(12)).foregroundStyle(Color.fxText3.opacity(0.8))
                    .padding(.horizontal, 10).padding(.vertical, 8).allowsHitTesting(false)
            }
            TextEditor(text: $conceptDescription)
                .font(.fx(12)).foregroundStyle(Color.fxText)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .onChange(of: conceptDescription) { _, _ in scheduleSave() }
        }
        .frame(height: 78)
        .fxInsetField()
    }

    // MARK: Gallery

    private var galleryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Images").font(.fx(13, weight: .semibold)).foregroundStyle(Color.fxText2)
                countStatusPill
                Spacer()
                importMenu
            }

            // The live strip shows for THIS workshop's caption job; a job running in another
            // workshop leaves the buttons visible so a job here can still be queued behind it.
            if vm.captioning && vm.captioningWorkshopID == workshopID { captioningRow }
            else { captionActionsRow }
            queuedCaptionRow
            captionLintRow
            captionInstructionSection

            if let w = workshop, !w.images.isEmpty {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(Array(w.images.enumerated()), id: \.element.id) { idx, ref in
                        WorkshopThumbView(
                            ref: ref,
                            url: w.imageURL(ref),
                            isReference: w.coverImageFileName == ref.fileName,
                            onOpen: { captionIndex = idx; showCaption = true },
                            onDelete: { vm.removeImage(ref, from: workshopID) }
                        )
                    }
                }
                Text("Drop more images anywhere here, or use Import. A sibling .txt caption file next to an image is picked up automatically.")
                    .font(.fx(11)).foregroundStyle(Color.fxText3)
            } else {
                dropZone
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.fxPanel, in: RoundedRectangle(cornerRadius: FxRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: FxRadius.card, style: .continuous)
            .strokeBorder(dropTargeted ? Color.fxAccent : Color.fxBorder, lineWidth: dropTargeted ? 1.5 : 1))
        .shadow(color: .black.opacity(0.32), radius: 10, x: 0, y: 6)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in handleDrop(providers) }
    }

    private var countStatusPill: some View {
        let n = imageCount
        let (text, tone): (String, FxTone) =
            n < Gate.minImages ? ("\(n)/\(Gate.minImages) min", .amber)
            : n < Gate.recommended.lowerBound ? ("\(n) · \(Gate.recommended.lowerBound)–\(Gate.recommended.upperBound) recommended", .amber)
            : ("\(n) images", .ok)
        return HStack(spacing: 6) {
            FxDot(tone: tone, size: 6)
            Text(text).font(.fxMono(10)).foregroundStyle(Color.fxText3)
        }
    }

    @ViewBuilder private var importMenu: some View {
        Button { importFiles() } label: {
            HStack(spacing: 6) { Image(systemName: "photo.badge.plus"); Text("Import images") }
        }
        .buttonStyle(FxSecondaryButtonStyle(height: 30, accentText: true))
        .disabled(vm.importing)

        Button { importFolder() } label: {
            HStack(spacing: 6) { Image(systemName: "folder.badge.plus"); Text("Import a folder") }
        }
        .buttonStyle(FxSecondaryButtonStyle(height: 30))
        .disabled(vm.importing)
    }

    @ViewBuilder private var captionActionsRow: some View {
        if let w = workshop, !w.images.isEmpty {
            let jobQueued = vm.queuedCaptionJob(for: workshopID) != nil
            HStack(spacing: 10) {
                Button { vm.autoCaption(id: workshopID, onlyMissing: false) } label: {
                    HStack(spacing: 6) { Image(systemName: "sparkles"); Text("Auto-caption all") }
                }
                .buttonStyle(FxSecondaryButtonStyle(height: 30, accentText: true))
                .disabled(vm.importing || jobQueued)
                .help(jobQueued ? "A caption job for this workshop is already queued"
                                : "Caption every image with the vision model — runs now, or queues behind the current training")

                if missingCaptions > 0 {
                    Button { vm.autoCaption(id: workshopID, onlyMissing: true) } label: {
                        Text("Generate \(missingCaptions) missing")
                    }
                    .buttonStyle(FxGhostButtonStyle(height: 30))
                    .disabled(vm.importing || jobQueued)
                    .help(jobQueued ? "A caption job for this workshop is already queued"
                                    : "Caption only the images without one — runs now, or queues behind the current training")
                }

                Button { showCaptionTools = true } label: {
                    HStack(spacing: 6) { Image(systemName: "text.magnifyingglass"); Text("Caption tools") }
                }
                .buttonStyle(FxGhostButtonStyle(height: 30))
                .disabled(vm.importing)
                .help("Find & replace or append/prepend across every caption")
                .popover(isPresented: $showCaptionTools, arrowEdge: .bottom) { captionToolsPopover }

                Spacer()
                Text(missingCaptions == 0 ? "All captioned" : "\(w.images.count - missingCaptions)/\(w.images.count) captioned")
                    .font(.fxMono(10)).foregroundStyle(Color.fxText3)
            }
        }
    }

    /// Chip for a caption job waiting in the training queue (added while the trainer was busy).
    @ViewBuilder private var queuedCaptionRow: some View {
        if let job = vm.queuedCaptionJob(for: workshopID),
           case .caption(_, _, let onlyMissing) = job {
            HStack(spacing: 10) {
                FxDot(tone: .amber, size: 6)
                Text("Caption job queued\(vm.queuePosition(of: job.id).map { " (#\($0))" } ?? "") — \(onlyMissing ? "missing captions only" : "all images"). It starts automatically when the current work finishes.")
                    .font(.fx(11)).foregroundStyle(Color.fxText2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Remove") { vm.dequeueCaptionJob(for: workshopID) }
                    .buttonStyle(FxGhostButtonStyle(height: 26))
                    .help("Remove the caption job from the queue")
            }
            .padding(.vertical, 8).padding(.horizontal, 11)
            .background(Color.fxInset, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
        }
    }

    // MARK: Caption tools (bulk find & replace / append / prepend)

    private var captionToolsPopover: some View {
        let images = workshop?.images ?? []
        let total = images.count
        let matches = images.filter {
            TrainingViewModel.captionMatches($0.caption, find: findText, caseInsensitive: ignoreCase)
        }.count
        let replaceHasTrigger = TrainingViewModel.captionContainsTrigger(replaceText, trigger: trimmedTrigger)
        let amendHasTrigger = TrainingViewModel.captionContainsTrigger(amendText, trigger: trimmedTrigger)
        let amendEmpty = amendText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 12) {
            Text("Caption tools").font(.fx(13, weight: .semibold)).foregroundStyle(Color.fxText)

            VStack(alignment: .leading, spacing: 7) {
                Text("Find & replace").fxLabel()
                TextField("Find (ex: bicycle, blue mug…)", text: $findText)
                    .textFieldStyle(.plain).font(.fx(12)).foregroundStyle(Color.fxText)
                    .padding(.vertical, 7).padding(.horizontal, 10).fxInsetField()
                TextField("Replace with (empty = remove)", text: $replaceText)
                    .textFieldStyle(.plain).font(.fx(12)).foregroundStyle(Color.fxText)
                    .padding(.vertical, 7).padding(.horizontal, 10).fxInsetField()
                Toggle("Ignore case", isOn: $ignoreCase)
                    .font(.fx(11)).foregroundStyle(Color.fxText2).toggleStyle(.checkbox)
                HStack {
                    // Live preview BEFORE applying: how many captions the find phrase touches.
                    Text(findText.isEmpty ? "Type a phrase to preview its reach."
                                          : "Affects \(matches) of \(total) caption\(total == 1 ? "" : "s").")
                        .font(.fx(11))
                        .foregroundStyle(findText.isEmpty || matches == 0 ? Color.fxText3 : Color.fxAccent)
                    Spacer()
                    Button("Replace") {
                        vm.bulkReplaceCaptions(id: workshopID, find: findText,
                                               replace: replaceText, caseInsensitive: ignoreCase)
                    }
                    .buttonStyle(FxSecondaryButtonStyle(height: 26, accentText: true))
                    .disabled(findText.isEmpty || matches == 0 || replaceHasTrigger)
                }
            }

            Divider().overlay(Color.fxBorder)

            VStack(alignment: .leading, spacing: 7) {
                Text("Add to every caption").fxLabel()
                TextField("Phrase (ex: a photo, studio lighting…)", text: $amendText)
                    .textFieldStyle(.plain).font(.fx(12)).foregroundStyle(Color.fxText)
                    .padding(.vertical, 7).padding(.horizontal, 10).fxInsetField()
                HStack(spacing: 8) {
                    Button("Prepend") { vm.bulkAmendCaptions(id: workshopID, phrase: amendText, prepend: true) }
                        .buttonStyle(FxSecondaryButtonStyle(height: 26))
                        .disabled(amendEmpty || amendHasTrigger)
                    Button("Append") { vm.bulkAmendCaptions(id: workshopID, phrase: amendText, prepend: false) }
                        .buttonStyle(FxSecondaryButtonStyle(height: 26))
                        .disabled(amendEmpty || amendHasTrigger)
                    Spacer()
                    Text("\(total) caption\(total == 1 ? "" : "s")")
                        .font(.fxMono(10)).foregroundStyle(Color.fxText3)
                }
            }

            if replaceHasTrigger || amendHasTrigger {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(Color.fxAccent)
                    Text("Don't put the trigger “\(trimmedTrigger)” into captions — it's added automatically at train time.")
                        .font(.fx(10.5)).foregroundStyle(Color.fxText2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: Caption instruction (VLM system prompt, per-workshop with concept presets)

    /// Collapsed editor for WHAT the vision model is asked to do when captioning. Empty → the
    /// concept-type preset (shown as the placeholder), which names the subject only by its class
    /// word so the LoRA — not the caption — owns the identity.
    @ViewBuilder private var captionInstructionSection: some View {
        if let w = workshop, !w.images.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showInstruction.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(showInstruction ? 90 : 0))
                            .foregroundStyle(Color.fxText3)
                        Text("Caption instruction").font(.fx(12, weight: .medium)).foregroundStyle(Color.fxText2)
                        if !captionInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("custom").font(.fxMono(9.5)).foregroundStyle(Color.fxAccent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("What the vision model is asked to do when auto-captioning")

                if showInstruction {
                    ZStack(alignment: .topLeading) {
                        if captionInstruction.isEmpty {
                            // Placeholder = the live concept-type preset (what an empty field means).
                            Text(DescribeService.captionInstruction(for: conceptType))
                                .font(.fx(11)).foregroundStyle(Color.fxText3.opacity(0.8))
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $captionInstruction)
                            .font(.fx(11)).foregroundStyle(Color.fxText)
                            .scrollContentBackground(.hidden)
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .onChange(of: captionInstruction) { _, _ in scheduleSave() }
                    }
                    .frame(height: 110)
                    .fxInsetField()
                    HStack {
                        Text("Sent to the vision model with every auto-caption. Empty = the \(conceptType.label) preset. Never include the trigger word — it's added at train time.")
                            .font(.fx(11)).foregroundStyle(Color.fxText3)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if !captionInstruction.isEmpty {
                            Button("Reset to default") { captionInstruction = ""; scheduleSave() }
                                .buttonStyle(FxGhostButtonStyle(height: 26))
                                .help("Go back to the \(conceptType.label) preset")
                        }
                    }
                }
            }
        }
    }

    /// Lint: the trigger word inside a caption doubles it at train time (the engine prepends it to
    /// every caption). Shows only when it actually bites, with a one-click fix.
    @ViewBuilder private var captionLintRow: some View {
        let n = captionsWithTrigger
        if n > 0, !vm.captioning {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Color.fxAccent)
                Text("\(n) caption\(n == 1 ? "" : "s") contain\(n == 1 ? "s" : "") the trigger “\(trimmedTrigger)”. It's added automatically at train time — inside the caption it gets doubled, which weakens what it learns.")
                    .font(.fx(11)).foregroundStyle(Color.fxText2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Remove from captions") { vm.stripTriggerFromCaptions(id: workshopID, trigger: trimmedTrigger) }
                    .buttonStyle(FxGhostButtonStyle(height: 26, accentText: true))
            }
            .padding(.vertical, 8).padding(.horizontal, 11)
            .background(Color.fxAccentSoft.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    /// Slim live strip while THIS workshop's caption job runs: streamed status, captions committed
    /// so far (they land under the thumbnails one by one), and cancel.
    private var captioningRow: some View {
        HStack(spacing: 10) {
            FxDot(tone: .amber, live: true, size: 7)
            Text(vm.captionStatus ?? "Captioning with the vision model…")
                .font(.fxMono(11)).foregroundStyle(Color.fxText2).lineLimit(1)
            Spacer()
            if vm.captionTotal > 1 {
                Text("\(vm.captionDone)/\(vm.captionTotal)")
                    .font(.fxMono(10)).foregroundStyle(Color.fxText3)
                    .help("Captions saved so far — each one is stored the moment it's ready")
            }
            Button("Cancel") { vm.cancelCaptioning() }
                .buttonStyle(FxGhostButtonStyle(height: 28))
                .help("Stop after the current image — captions already made are kept")
        }
        .padding(.vertical, 2)
    }

    private var dropZone: some View {
        FxDropZone(isTargeted: dropTargeted) {
            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 20)).foregroundStyle(Color.fxText3.opacity(0.85))
                Text("Drop your images here").font(.fx(13, weight: .medium)).foregroundStyle(Color.fxText2)
                Text("JPEG · PNG · HEIC · WEBP — a sibling .txt caption is picked up automatically")
                    .font(.fx(11)).foregroundStyle(Color.fxText3)
                HStack(spacing: 10) {
                    Button { importFiles() } label: { Text("Import images") }
                        .buttonStyle(FxSecondaryButtonStyle(height: 30, accentText: true))
                    Button { importFolder() } label: { Text("Import a folder") }
                        .buttonStyle(FxSecondaryButtonStyle(height: 30))
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
    }

    // MARK: Trainings forged from this workshop

    @ViewBuilder private var trainingsSection: some View {
        let runs = workshop.map { vm.runs(for: $0) } ?? []
        if !runs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Trainings").font(.fx(13, weight: .semibold)).foregroundStyle(Color.fxText2)
                ForEach(runs) { run in
                    HStack(spacing: 10) {
                        // Whole left region opens the live monitor.
                        Button { vm.presentRun(run.id) } label: {
                            HStack(spacing: 10) {
                                FxDot(tone: tone(run.status), live: run.status.isActive, size: 7)
                                Text(run.name).font(.fxMono(12)).foregroundStyle(Color.fxText).lineLimit(1)
                                Text(run.status.label).font(.fxMono(10)).foregroundStyle(Color.fxText3)
                                if let pos = vm.queuePosition(of: run.id) { queuedChip(pos) }
                                Text("· \(run.tier.shortName) · \(run.params.maxSteps) steps · \(run.params.maxResolution)px")
                                    .font(.fxMono(10)).foregroundStyle(Color.fxText3).lineLimit(1)
                                if run.id == vm.activeRunID {
                                    Text("\(vm.activeRun?.runtime.currentStep ?? 0)/\(run.params.maxSteps)")
                                        .font(.fxMono(10)).foregroundStyle(Color.fxAccent)
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
                        .disabled(run.id == vm.activeRunID)
                        .opacity(run.id == vm.activeRunID ? 0.4 : 1)
                        .help(run.id == vm.activeRunID ? "Stop the training before deleting it" : "Delete this training and its files")
                    }
                    .padding(.vertical, 8).padding(.horizontal, 12)
                    .background(Color.fxInset, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
                    .contextMenu {
                        Button {
                            vm.duplicateAsDraft(run)
                        } label: {
                            Label("Duplicate as new draft", systemImage: "plus.square.on.square")
                        }
                        .disabled(!vm.canDuplicate(run))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fxCard(padding: 16)
        }
    }

    private func tone(_ status: TrainingRunStatus) -> FxTone {
        switch status {
        case .training, .preparing, .loadingModel: return .amber
        case .completed, .published:               return .ok
        case .failed, .cancelled:                  return .danger
        default:                                   return .idle
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

    // MARK: Small builder

    private func field<Content: View>(label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).fxLabel()
            content()
        }
    }

    // MARK: Derived state

    private var trimmedTrigger: String { trigger.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var triggerHasSpace: Bool { trimmedTrigger.contains(where: \.isWhitespace) }
    private var descLen: Int { conceptDescription.trimmingCharacters(in: .whitespacesAndNewlines).count }
    private var imageCount: Int { workshop?.images.count ?? 0 }
    private var missingCaptions: Int {
        workshop?.images.filter { $0.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count ?? 0
    }
    /// How many captions contain the trigger word (they must not — the engine prepends it).
    private var captionsWithTrigger: Int {
        guard let w = workshop, !trimmedTrigger.isEmpty, !triggerHasSpace else { return 0 }
        return w.images.filter { TrainingViewModel.captionContainsTrigger($0.caption, trigger: trimmedTrigger) }.count
    }

    private var blockers: [String] {
        var b: [String] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { b.append("Give the workshop a name") }
        if trimmedTrigger.isEmpty { b.append("Add a trigger word") }
        else if triggerHasSpace { b.append("Trigger word must be a single word (no spaces)") }
        if descLen < Gate.minDescription { b.append("\(Gate.minDescription - descLen) more character(s) in the description") }
        if imageCount < Gate.minImages { b.append("\(Gate.minImages - imageCount) more image(s) (minimum \(Gate.minImages))") }
        return b
    }
    private var isReady: Bool { blockers.isEmpty }

    // MARK: Actions

    private func seedIfNeeded() {
        guard !seeded, let w = workshop else { return }
        name = w.name
        trigger = w.triggerWord
        conceptType = w.conceptType
        conceptDescription = w.conceptDescription
        captionInstruction = w.captionInstruction ?? ""
        seeded = true
    }

    private func scheduleSave() {
        vm.scheduleIdentitySave(id: workshopID, name: name, trigger: trigger,
                                description: conceptDescription, conceptType: conceptType,
                                captionInstruction: captionInstruction)
    }

    private func commitIdentity() {
        guard seeded else { return }   // never write empty drafts before the initial seed ran
        vm.commitIdentity(id: workshopID, name: name, trigger: trigger,
                          description: conceptDescription, conceptType: conceptType,
                          captionInstruction: captionInstruction)
    }

    private func openForge() {
        commitIdentity()              // persist any pending identity edits before the snapshot
        forgeWorkshop = workshop      // present the forge sheet for the live workshop
    }

    private func importFiles() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = true
        p.allowedContentTypes = [.image]
        p.message = "Choose images to add to this workshop"
        if p.runModal() == .OK { vm.importImages(into: workshopID, urls: p.urls) }
    }

    private func importFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.allowsMultipleSelection = false
        p.message = "Choose a folder of images (sibling .txt captions are picked up)"
        if p.runModal() == .OK, let u = p.url { vm.importImages(into: workshopID, urls: [u]) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        Task {
            var urls: [URL] = []
            for p in providers { if let u = await loadURL(from: p) { urls.append(u) } }
            if !urls.isEmpty { vm.importImages(into: workshopID, urls: urls) }
        }
        return true
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            fxResolveDroppedFileURL(provider) { url in cont.resume(returning: url) }
        }
    }
}
