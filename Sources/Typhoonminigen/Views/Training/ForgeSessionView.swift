import SwiftUI
import Foundation

/// Forge a training (Chunk 4): configure the parameters that get FROZEN into an immutable training
/// run, with base-model + RAM advisories and validation gates, then snapshot the workshop's dataset.
/// Shown as a sheet over the workshop editor. Starting/running the forged Draft is the next chunk.
struct ForgeSessionView: View {
    @Bindable var vm: TrainingViewModel
    let workshop: Workshop
    let onClose: () -> Void

    @State private var params: TrainingParams
    @State private var name: String
    /// Upper bound of the steps slider — widened for a prefill beyond 4000 (an EXTENDED run being
    /// duplicated), so the label and the thumb agree and the first drag doesn't silently snap down.
    @State private var stepsSliderMax: Double = 4000
    @State private var showAdvanced = false
    @State private var confirmForge = false
    // Saved validation prompt sets (loaded on appear; the Sets menu edits them).
    @State private var promptSets: [ValidationPromptSet] = []
    @State private var showSaveSet = false
    @State private var saveSetName = ""

    /// `prefillParams`/`prefillName` seed the form from an EXISTING run ("Duplicate as new
    /// draft") instead of the defaults — every locked parameter carries over for A/B tweaks.
    init(vm: TrainingViewModel, workshop: Workshop,
         prefillParams: TrainingParams? = nil, prefillName: String = "",
         onClose: @escaping () -> Void) {
        self.vm = vm
        self.workshop = workshop
        self.onClose = onClose
        if let prefillParams {
            _params = State(initialValue: prefillParams)
            _name = State(initialValue: prefillName)
            // Extend can push maxSteps past the default slider ceiling (rounded up to the grid).
            _stepsSliderMax = State(initialValue: Double(max(4000, ((prefillParams.maxSteps + 99) / 100) * 100)))
            return
        }
        var seed = TrainingParams.defaults(tier: ModelTier.klein4B.rawValue,
                                           conceptType: workshop.conceptType,
                                           triggerWord: workshop.triggerWord)
        if seed.validationPrompts.isEmpty {
            seed.validationPrompts = [ValidationPrompt(prompt: Self.defaultPrompt(workshop.conceptType, withTrigger: true),
                                                       applyTrigger: true)]
            if seed.dopEnabled {
                seed.validationPrompts.append(ValidationPrompt(prompt: Self.defaultPrompt(workshop.conceptType, withTrigger: false),
                                                               applyTrigger: false))
            }
        }
        _params = State(initialValue: seed)
        _name = State(initialValue: "")
    }

    private var tier: ModelTier { ModelTier(rawValue: params.tier) ?? .klein4B }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.fxBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    inheritedCallout
                    nameField
                    modelSection
                    stepsSection
                    resolutionSection
                    augmentSection
                    checkpointsSection
                    dopSection
                    validationSection
                    advancedSection
                    gatesSection
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(Color.fxBorder)
            footer
        }
        .frame(width: 720, height: 820)
        .background(Color.fxBg)
        .onAppear { promptSets = ValidationPromptSetStore.load() }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "hammer").font(.system(size: 14)).foregroundStyle(Color.fxAccent)
            Text("New training").font(.fx(14, weight: .semibold)).foregroundStyle(Color.fxText)
            Text(workshop.name.isEmpty ? "Untitled" : workshop.name).font(.fxMono(11)).foregroundStyle(Color.fxText3)
            Spacer()
            Button { onClose() } label: { Image(systemName: "xmark") }
                .buttonStyle(FxIconButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let first = blockers.first {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Color.fxAccent)
                    Text(first).font(.fx(11)).foregroundStyle(Color.fxText3).lineLimit(1)
                }
            } else {
                Text("Parameters lock once you create the training — they can't be changed afterward.")
                    .font(.fx(11)).foregroundStyle(Color.fxText3)
            }
            Spacer()
            Button("Cancel") { onClose() }
                .buttonStyle(FxSecondaryButtonStyle(height: 32))
            Button {
                confirmForge = true
            } label: {
                HStack(spacing: 6) { Image(systemName: "hammer"); Text("Training") }
            }
            .buttonStyle(FxPrimaryButtonStyle(height: 32))
            .disabled(!blockers.isEmpty || vm.forging)
            .opacity(blockers.isEmpty ? 1 : 0.5)
            .confirmationDialog("Create this training?", isPresented: $confirmForge, titleVisibility: .visible) {
                Button("Create") { doForge() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The dataset and all parameters are frozen into this training. Editing the workshop later won't affect it.")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: Sections

    private var inheritedCallout: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill").font(.system(size: 12)).foregroundStyle(Color.fxText3)
            VStack(alignment: .leading, spacing: 3) {
                Text("Inherited from this workshop").font(.fx(12, weight: .semibold)).foregroundStyle(Color.fxText2)
                Text("\(workshop.images.count) images, trigger « \(workshop.triggerWord.isEmpty ? "—" : workshop.triggerWord) ». These are frozen the moment you create the training — editing the workshop later won't change this training.")
                    .font(.fx(11)).foregroundStyle(Color.fxText3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .fxCard(padding: 12)
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionLabel("Training name")
            TextField("Training \(vm.runs(for: workshop).count + 1)", text: $name)
                .textFieldStyle(.plain).font(.fx(13)).foregroundStyle(Color.fxText)
                .padding(.vertical, 8).padding(.horizontal, 12).fxInsetField()
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionLabel("Target model")
            HStack(spacing: 8) {
                ForEach(ModelTier.allCases) { t in
                    chip(t.shortName, selected: tier == t) { params.tier = t.rawValue }
                }
                Spacer()
            }
            Text(tier == .klein9B
                 ? "Higher quality, heavier — needs gradient checkpointing (always on) and is tight on 32 GB."
                 : "Compact and fast — the recommended starting point, ~8 GB base model.")
                .font(.fx(11)).foregroundStyle(Color.fxText3)
        }
    }

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                sectionLabel("Training steps")
                Spacer()
                Text("\(params.maxSteps)").font(.fxMono(12)).foregroundStyle(Color.fxAccent)
            }
            Slider(value: Binding(get: { Double(params.maxSteps) },
                                  set: { params.maxSteps = Int(($0 / 100).rounded()) * 100 }),
                   in: 200...stepsSliderMax, step: 100)
                .tint(Color.fxAccent)
            // Live dataset insight: passes per image = steps × batch ÷ images. Bands sourced from the
            // engine author's difficulty table (new subject ≈ 1000–2000 steps) + real training outcomes.
            Text(passesAdvice.text)
                .font(.fx(11)).foregroundStyle(passesAdvice.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Dataset size the trainer actually sees — doubled when mirror augmentation is on.
    private var effectiveImageCount: Int {
        max(1, workshop.images.count * (params.flipAugment == true ? 2 : 1))
    }

    /// Steps ÷ dataset size, the number every steps decision should be made in.
    private var passesPerImage: Double {
        Double(params.maxSteps * params.batchSize * params.gradientAccumulationSteps)
            / Double(effectiveImageCount)
    }

    private var passesAdvice: (text: String, color: Color) {
        let n = effectiveImageCount
        let p = passesPerImage
        let base = params.flipAugment == true
            ? "Each of your \(workshop.images.count) images (+ mirrored copies = \(n)) is seen ~\(Int(p.rounded()))× at \(params.maxSteps) steps."
            : "Each of your \(n) images is seen ~\(Int(p.rounded()))× at \(params.maxSteps) steps."
        switch p {
        case ..<15:
            return (base + " Likely undertrained for a subject the base model doesn't already know — those need ~25–60 passes (≈\(((25 * n + 99) / 100) * 100)–\(((60 * n + 99) / 100) * 100) steps here). Easy subjects can get away with less.",
                    Color.fxAccent)
        case ..<25:
            return (base + " On the low side — enough for an easy subject, thin for a hard one.", Color.fxText3)
        case ...60:
            return (base + " Healthy range for a subject LoRA.", Color.fxText3)
        default:
            return (base + " High — watch the late checkpoints for overfitting (sharp in dataset-like scenes, waxy everywhere else).",
                    Color.fxAccent)
        }
    }

    private var resolutionSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionLabel("Training resolution")
            HStack(spacing: 8) {
                ForEach([512, 768, 1024], id: \.self) { r in
                    chip("\(r)px", selected: params.maxResolution == r) { params.maxResolution = r }
                }
                Spacer()
            }
            Text("512 is the safe minimum (verified to fit). Higher = more detail but more memory — 1024 is heavy on 32 GB.")
                .font(.fx(11)).foregroundStyle(Color.fxText3)
        }
    }

    /// Off-by-default dataset doubling via horizontal mirroring — written into the FROZEN
    /// snapshot only, so the workshop's originals are never touched.
    private var augmentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { params.flipAugment == true },
                                 set: { params.flipAugment = $0 ? true : nil })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mirror images (doubles the dataset)")
                        .font(.fx(12.5, weight: .medium)).foregroundStyle(Color.fxText)
                    Text("Adds a horizontally flipped copy of every image to the frozen dataset, same caption — \(workshop.images.count) photos train as \(workshop.images.count * 2) views. Cheap extra variety for small subject sets.")
                        .font(.fx(11)).foregroundStyle(Color.fxText3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch).tint(Color.fxAccent)
            if params.flipAugment == true {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(Color.fxAccent)
                    Text("Never for faces, text, logos or anything left/right-asymmetric — a mirrored logo teaches the model the WRONG logo. Skip it if your subject carries lettering.")
                        .font(.fx(11)).foregroundStyle(Color.fxText2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .fxCard(padding: 14)
    }

    /// How many checkpoints these settings actually produce. NO `max(1, …)` floor: a save
    /// interval above the step target really saves ZERO (the old "≈ 1 saved" was a lie that
    /// also silently killed Extend and the compare matrix — both need a checkpoint).
    private var estimatedCheckpoints: Int { params.maxSteps / max(1, params.saveEveryNSteps) }

    private var checkpointsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                sectionLabel("Checkpoints")
                Spacer()
                Text(estimatedCheckpoints == 0 ? "0 saved" : "≈ \(estimatedCheckpoints) saved")
                    .font(.fxMono(11))
                    .foregroundStyle(estimatedCheckpoints == 0 ? Color.fxDanger : Color.fxText3)
            }
            FxStepper(label: "Save every (steps)", value: $params.saveEveryNSteps, range: 50...1000, step: 50)
            if estimatedCheckpoints == 0 {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(Color.fxAccent)
                    Text("No checkpoints at these settings — “Save every” (\(params.saveEveryNSteps)) is above the step target (\(params.maxSteps)). Only the final adapter is written: nothing to compare, and “Extend training” needs a checkpoint to resume from. Lower the save interval.")
                        .font(.fx(11)).foregroundStyle(Color.fxText2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Regular saves so you can pick the best version at the end — the final one isn't always best.")
                .font(.fx(11)).foregroundStyle(Color.fxText3)
            HStack(spacing: 8) {
                sectionLabel("Keep weights of")
                chip("All", selected: params.keepLastCheckpoints == nil) { params.keepLastCheckpoints = nil }
                ForEach([2, 4, 8], id: \.self) { n in
                    chip("last \(n)", selected: params.keepLastCheckpoints == n) { params.keepLastCheckpoints = n }
                }
                Spacer()
            }
            .padding(.top, 4)
            Text(params.keepLastCheckpoints == nil
                 ? "Every checkpoint keeps its weight files (~hundreds of MB each on long runs)."
                 : "As new checkpoints land, older ones lose their heavy weight/optimizer files but keep EVERY validation image — the compare grid stays complete. The published and best-loss checkpoints are never pruned; pruned ones show as preview-only.")
                .font(.fx(11)).foregroundStyle(Color.fxText3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dopSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $params.dopEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Differential Output Preservation (DOP)").font(.fx(12.5, weight: .medium)).foregroundStyle(Color.fxText)
                    Text("Keeps the model's idea of the whole class (e.g. “a person”) while it learns your specific subject. Recommended for people and pets, not needed for objects or styles.")
                        .font(.fx(11)).foregroundStyle(Color.fxText3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch).tint(Color.fxAccent)
            if params.dopEnabled {
                HStack(spacing: 10) {
                    Text("Class word").fxLabel()
                    TextField("e.g. person, dog, car", text: $params.dopClass)
                        .textFieldStyle(.plain).font(.fxMono(12)).foregroundStyle(Color.fxText)
                        .padding(.vertical, 7).padding(.horizontal, 11).fxInsetField()
                        .frame(maxWidth: 260)
                    Spacer()
                }
                Text("With DOP on, you need at least two validation prompts below — one WITH the trigger and one WITHOUT.")
                    .font(.fx(11)).foregroundStyle(Color.fxAccent.opacity(0.9))
            }
        }
        .fxCard(padding: 14)
    }

    private var validationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Validation prompts")
                Spacer()
                setsMenu
                Button {
                    params.validationPrompts.append(ValidationPrompt(prompt: "", applyTrigger: true))
                } label: { HStack(spacing: 5) { Image(systemName: "plus"); Text("Add prompt") } }
                .buttonStyle(FxGhostButtonStyle(height: 26, accentText: true))
            }
            Text("Test images are generated from these at each checkpoint so you can watch progress. Write [trigger] inside a prompt to place the trigger word mid-sentence — the automatic prepend is skipped for that prompt.")
                .font(.fx(11)).foregroundStyle(Color.fxText3)
                .fixedSize(horizontal: false, vertical: true)
            ForEach($params.validationPrompts) { $vp in
                HStack(spacing: 8) {
                    TextField("Describe the scene…", text: $vp.prompt)
                        .textFieldStyle(.plain).font(.fx(12)).foregroundStyle(Color.fxText)
                        .padding(.vertical, 7).padding(.horizontal, 11).fxInsetField()
                    // Optional per-prompt seed override — the placeholder shows the run seed
                    // that applies when the field is empty.
                    TextField("\(params.validationSeed)", text: seedBinding($vp))
                        .textFieldStyle(.plain)
                        .frame(width: 58)
                        .multilineTextAlignment(.trailing)
                        .font(.fxMono(11)).foregroundStyle(vp.seed == nil ? Color.fxText3 : Color.fxText)
                        .padding(.vertical, 7).padding(.horizontal, 8).fxInsetField(radius: 8)
                        .help("Seed override for THIS prompt — empty uses the run seed \(params.validationSeed). Lock one prompt to a known-good seed while others vary.")
                    if embedsTrigger(vp) {
                        // The prompt places the trigger itself via [trigger] — the prepend
                        // toggle is moot for it, so show the state instead of a dead control.
                        HStack(spacing: 5) {
                            Image(systemName: "text.insert").font(.system(size: 9))
                            Text("[trigger] inline")
                        }
                        .font(.fxMono(10)).foregroundStyle(Color.fxAccent)
                        .padding(.vertical, 5).padding(.horizontal, 8)
                        .background(Color.fxAccentSoft, in: Capsule())
                        .help("“\(workshop.triggerWord)” replaces [trigger] right where you typed it — the automatic prepend is off for this prompt.")
                    } else {
                        Button { $vp.applyTrigger.wrappedValue = !vp.applyTrigger } label: {
                            HStack(spacing: 5) {
                                Image(systemName: vp.applyTrigger ? "checkmark.circle.fill" : "circle")
                                Text("trigger")
                            }
                        }
                        .buttonStyle(FxGhostButtonStyle(height: 30, accentText: vp.applyTrigger))
                        .help(vp.applyTrigger ? "The trigger word is prepended to this prompt" : "This prompt is generated WITHOUT the trigger (needed for DOP)")
                    }
                    Button { params.validationPrompts.removeAll { $0.id == vp.id } } label: { Image(systemName: "xmark") }
                        .buttonStyle(FxIconButtonStyle(size: 28, destructive: true))
                        .disabled(params.validationPrompts.count <= 1)
                }
            }
        }
        .alert("Save prompt set", isPresented: $showSaveSet) {
            TextField("Set name (e.g. Product standards)", text: $saveSetName)
            Button("Save") { saveCurrentSet() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the current prompt list — trigger flags and seed overrides included — for one-click reuse in any future training. A same-named set is replaced.")
        }
    }

    /// Load / save / delete reusable validation prompt sets.
    private var setsMenu: some View {
        Menu {
            Section("Load a set") {
                Button(ValidationPromptSetStore.starterName) {
                    loadSet(ValidationPromptSetStore.starterPrompts)
                }
                ForEach(promptSets) { set in
                    Button("\(set.name) (\(set.prompts.count))") { loadSet(set.prompts) }
                }
            }
            Button("Save current as set…") {
                saveSetName = ""
                showSaveSet = true
            }
            // All-blank prompts would make Save a silent no-op (nothing to store, and the forge
            // sheet has no feedback line) — don't offer it.
            .disabled(params.validationPrompts.allSatisfy {
                $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
            if !promptSets.isEmpty {
                Menu("Delete a set") {
                    ForEach(promptSets) { set in
                        Button(set.name, role: .destructive) {
                            promptSets = ValidationPromptSetStore.remove(set.id)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "list.star").font(.system(size: 10))
                Text("Sets").font(.fx(11.5, weight: .medium))
            }
            .foregroundStyle(Color.fxText2)
            .padding(.vertical, 5).padding(.horizontal, 10)
            .background(Color.fxInset, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.fxBorder, lineWidth: 1))
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
        .fixedSize()
        .help("Reusable validation prompt lists — save your standards once, load them into every future training")
    }

    /// Replace the current list with a set's prompts (fresh ids so SwiftUI rows never collide).
    private func loadSet(_ prompts: [ValidationPrompt]) {
        guard !prompts.isEmpty else { return }
        params.validationPrompts = prompts.map {
            ValidationPrompt(prompt: $0.prompt, applyTrigger: $0.applyTrigger, seed: $0.seed)
        }
    }

    private func saveCurrentSet() {
        var name = saveSetName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompts = params.validationPrompts.filter {
            !$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !prompts.isEmpty else { return }   // menu entry is disabled then — belt-and-braces
        if name.isEmpty {
            // The alert's Save button always dismisses (SwiftUI can't disable it per-field) —
            // fall back to a dated default instead of silently discarding the set.
            name = "Prompt set " + Date().formatted(date: .abbreviated, time: .shortened)
        }
        promptSets = ValidationPromptSetStore.add(name: name, prompts: prompts)
    }

    /// String binding over the optional per-prompt seed (empty text → nil → run seed).
    /// A failed parse KEEPS the last valid value — writing nil on any non-numeric keystroke
    /// visibly wiped everything typed (the getter renders nil as ""), instead of just
    /// rejecting the one bad character.
    private func seedBinding(_ vp: Binding<ValidationPrompt>) -> Binding<String> {
        Binding(get: { vp.wrappedValue.seed.map(String.init) ?? "" },
                set: {
                    let t = $0.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { vp.wrappedValue.seed = nil }
                    else if let v = UInt64(t) { vp.wrappedValue.seed = v }
                })
    }

    /// Whether a prompt places the trigger itself via a resolvable [trigger] token — the engine
    /// prepend is turned off for such prompts at train time (TrainingService mirrors this test).
    private func embedsTrigger(_ vp: ValidationPrompt) -> Bool {
        let t = workshop.triggerWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        return TriggerPlaceholder.resolve(in: vp.prompt, triggers: [t]) != vp.prompt
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { showAdvanced.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: showAdvanced ? "chevron.down" : "chevron.right").font(.system(size: 10))
                    Text("Advanced (optimizer, rank, learning rate)").font(.fx(12, weight: .medium))
                }
                .foregroundStyle(Color.fxText2)
            }
            .buttonStyle(.plain)

            if showAdvanced {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            sectionLabel("LoRA rank")
                            HStack(spacing: 6) {
                                ForEach([8, 16, 32, 64], id: \.self) { r in
                                    chip("\(r)", selected: params.rank == r) { params.rank = r }
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            sectionLabel("LoRA alpha")
                            HStack(spacing: 6) {
                                ForEach([8, 16, 32, 64], id: \.self) { a in
                                    chip("\(a)", selected: Int(params.alpha) == a) { params.alpha = Float(a) }
                                }
                            }
                        }
                        Spacer()
                    }
                    Text("Rank = learning capacity, alpha = effect strength. Equal by default (32). Raise rank for complex subjects.")
                        .font(.fx(11)).foregroundStyle(Color.fxText3)

                    VStack(alignment: .leading, spacing: 6) {
                        sectionLabel("Learning rate")
                        HStack(spacing: 6) {
                            lrChip("5e-5", 5e-5); lrChip("1e-4", 1e-4); lrChip("2e-4", 2e-4)
                            Spacer()
                        }
                    }
                    HStack(spacing: 16) {
                        infoPair("Optimizer", "AdamW")
                        infoPair("Weight decay", "1e-4")
                        infoPair("Gradient checkpointing", "on")
                        Spacer()
                    }
                }
                .padding(.top, 2)
            }
        }
        .fxCard(padding: 14)
    }

    private var gatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Readiness")
            gateRow(ok: baseReady,
                    okText: "Base model for \(tier.shortName) is on disk.",
                    warnText: "\(tier.shortName) base (~\(tier == .klein9B ? 18 : 8) GB) isn't downloaded — it downloads when training starts, or get it in Models first.")
            gateRow(ok: ramOK, tone: ramOK ? .ok : (ramTight ? .amber : .danger),
                    okText: "Fits memory — ~\(peakGB) GB peak, you have \(installedGB) GB.",
                    warnText: ramTight
                        ? "Tight on memory — ~\(peakGB) GB peak vs \(installedGB) GB. It may swap; lower the resolution if it crawls."
                        : "Does NOT fit — ~\(peakGB) GB peak vs \(installedGB) GB. Starting this would freeze the whole Mac. Use Klein 4B / a lower resolution, or run it on a bigger-RAM Mac.")
            if !params.validationPrompts.isEmpty {
                gateRow(ok: TrainingService.validationModelPresent(tier: tier),
                        okText: "Validation previews will be generated at each checkpoint.",
                        warnText: "Validation previews need the \(tier.shortName) inference model (download it in Models). Training still runs — it just skips previews until then.")
            }
        }
        .fxCard(padding: 14)
    }

    // MARK: Small builders

    private func sectionLabel(_ t: String) -> some View {
        Text(t).font(.fx(12, weight: .medium)).foregroundStyle(Color.fxText2)
    }

    private func chip(_ label: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.fxMono(11.5)).foregroundStyle(selected ? Color.fxOnAccent : Color.fxText2)
                .padding(.vertical, 6).padding(.horizontal, 12)
                .background(selected ? Color.fxAccent : Color.fxInset, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Color.clear : Color.fxBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func lrChip(_ label: String, _ value: Float) -> some View {
        chip(label, selected: abs(params.learningRate - value) < value * 0.01) { params.learningRate = value }
    }

    private func infoPair(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.fx(10)).foregroundStyle(Color.fxText3)
            Text(value).font(.fxMono(11)).foregroundStyle(Color.fxText2)
        }
    }

    private func gateRow(ok: Bool, tone: FxTone? = nil, okText: String, warnText: String) -> some View {
        let t = tone ?? (ok ? .ok : .amber)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(t == .ok ? Color.fxOk : (t == .danger ? Color.fxDanger : Color.fxAccent))
            Text(ok ? okText : warnText)
                .font(.fx(11)).foregroundStyle(Color.fxText2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    // MARK: Derived state

    private var baseReady: Bool { TrainingService.baseModelPresent(tier: tier) }
    private var installedGB: Int { SystemRAM.installedGB }
    private var peakGB: Int { TrainingService.estimatedPeakGB(tier: tier, resolution: params.maxResolution, dopEnabled: params.dopEnabled) }
    // ok = fits with headroom · tight = borderline (may swap) · beyond = HARD BLOCK (froze a real
    // 32 GB M4 — the 9B incident: footprint 33 GB, swap +10 GB in 60 s, machine unresponsive).
    private var ramOK: Bool { peakGB + 2 <= installedGB }
    private var ramTight: Bool { !ramOK && peakGB <= installedGB }

    private var blockers: [String] {
        var b: [String] = []
        // HARD RAM block — a peak beyond physical RAM froze a real machine; never allow creating it.
        if peakGB > installedGB {
            b.append("Needs ~\(peakGB) GB but this Mac has \(installedGB) GB — training would freeze it")
        }
        let prompts = params.validationPrompts
        if params.dopEnabled {
            if params.dopClass.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                b.append("DOP needs a class word (e.g. “person”)")
            }
            if prompts.count < 2 {
                b.append("DOP needs at least two validation prompts")
            } else {
                // A prompt counts as "with trigger" via the prepend toggle OR an inline [trigger].
                let with = prompts.contains { $0.applyTrigger || embedsTrigger($0) }
                let without = prompts.contains { !$0.applyTrigger && !embedsTrigger($0) }
                if !(with && without) {
                    b.append("DOP needs one validation prompt WITH the trigger and one WITHOUT")
                }
            }
        } else if prompts.isEmpty {
            b.append("Add at least one validation prompt")
        }
        if prompts.contains(where: { $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            b.append("A validation prompt is empty")
        }
        return b
    }

    // MARK: Actions

    private func doForge() {
        var p = params
        p.validationEveryNSteps = p.saveEveryNSteps   // keep validation cadence aligned with checkpoints
        vm.forge(workshopID: workshop.id, name: name, params: p)
        onClose()
    }

    private static func defaultPrompt(_ ct: ConceptType, withTrigger: Bool) -> String {
        switch ct {
        case .person: return withTrigger ? "a portrait photo, studio lighting" : "a portrait photo of a person"
        case .pet:    return withTrigger ? "sitting on a sofa, soft light" : "a photo of an animal"
        case .object: return withTrigger ? "a product photo on a plain background" : "a product photo on a plain background"
        case .style:  return withTrigger ? "a landscape with mountains and a lake" : "a landscape with mountains and a lake"
        }
    }
}
