import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LoRAView: View {
    @Bindable var vm: LoRAViewModel
    /// Usage ledger source (gallery records) + "Show renders" jump — wired from ContentView.
    var galleryVM: GalleryViewModel? = nil
    var onShowRenders: (String) -> Void = { _ in }

    @State private var bakeItem: LoRAItem? = nil
    @State private var cardItem: LoRAItem? = nil   // "About this LoRA" model-card sheet
    @State private var showMerge = false
    @State private var showURLImport = false

    private var mergeableCount: Int { vm.items.filter(\.isCompatible).count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    SectionTitle(text: "LoRA")
                    Spacer()
                    Button { showMerge = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.merge").font(.system(size: 12))
                            Text("Merge…")
                        }
                    }
                    .buttonStyle(FxSecondaryButtonStyle(height: 32))
                    .disabled(mergeableCount < 2)
                    .opacity(mergeableCount < 2 ? 0.5 : 1)
                    .help("Combine two or more same-tier adapters into one file — average checkpoints (1/n each) or flatten a tuned stack. Always writes a NEW file.")
                    Button { showURLImport = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "link").font(.system(size: 12))
                            Text("Import from URL")
                        }
                    }
                    .buttonStyle(FxSecondaryButtonStyle(height: 32))
                    .help("Paste a Hugging Face repo or file link — compatibility is checked from the file's header BEFORE the download starts")
                    Button { vm.importLoRA() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up").font(.system(size: 12))
                            Text("Import .safetensors")
                        }
                    }
                    .buttonStyle(FxSecondaryButtonStyle(height: 32, accentText: true))
                    .help("Copy a LoRA adapter into the app — it must be trained for Klein 9B (dim 4096) or Klein 4B (dim 3072)")
                }

                Text("Only standard LoRA files load — the diffusers lora_A/lora_B layout (e.g. ai-toolkit LoRA mode). LoKr / LoHa / LyCORIS, kohya-format, and FLUX.1 / Dev adapters won't work. It must also match its Klein tier — 9B = dim 4096, 4B = dim 3072 (not interchangeable). Any trigger word is added to the prompt automatically at generation time.")
                    .font(.fx(12)).foregroundStyle(Color.fxText3)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                    .frame(maxWidth: 620, alignment: .leading)
                    .padding(.top, 8).padding(.bottom, 18)

                HStack {
                    Text("INSTALLED").font(.fx(11, weight: .semibold)).tracking(0.5).foregroundStyle(Color.fxText3)
                    Spacer()
                    Text("\(vm.items.count) \(vm.items.count == 1 ? "adapter" : "adapters")")
                        .font(.fxMono(11)).foregroundStyle(Color.fxText3)
                }
                .padding(.bottom, 12)

                if vm.items.isEmpty {
                    Text("No adapters. Import a .safetensors for Klein 9B or Klein 4B.")
                        .font(.fx(12)).foregroundStyle(Color.fxText3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 14)
                } else {
                    // ONE ledger build per body pass — `loraUsage` is a computed property that
                    // scans EVERY gallery record; subscripting it per row multiplied that full
                    // scan by the adapter count.
                    let usage = galleryVM?.loraUsage ?? [:]
                    ForEach(vm.items) { item in
                        LoRARow(item: item, vm: vm,
                                usage: usage[item.fileName],
                                onShowRenders: { onShowRenders(item.fileName) },
                                onBake: { bakeItem = item },
                                onCard: { cardItem = item })
                    }
                }

                DropZoneImport(vm: vm)
                    .padding(.top, 4)

                if let msg = vm.lastAction {
                    Text(msg.text).font(.fx(11))
                        .foregroundStyle(msg.isError ? Color.fxDanger : Color.fxText3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.fxBg)
        .task { vm.reload(); galleryVM?.reload() }   // fresh usage counts each visit
        .sheet(item: $bakeItem) { item in
            BakeSheet(vm: vm, item: item) { bakeItem = nil }
        }
        .sheet(item: $cardItem) { item in
            ModelCardSheet(vm: vm, item: item) { cardItem = nil }
        }
        .sheet(isPresented: $showMerge) {
            MergeSheet(vm: vm) { showMerge = false }
        }
        .sheet(isPresented: $showURLImport) {
            URLImportSheet(vm: vm) { showURLImport = false }
        }
    }
}

private struct LoRARow: View {
    let item: LoRAItem
    @Bindable var vm: LoRAViewModel
    var usage: GalleryViewModel.LoRAUsage? = nil
    var onShowRenders: () -> Void = {}
    var onBake: () -> Void = {}
    var onCard: () -> Void = {}
    @State private var triggerText: String = ""
    @State private var aboutText: String = ""
    @State private var scaleText: String = ""
    @State private var confirmDelete = false

    private var storedScaleText: String {
        item.defaultScale.map { String(format: "%.2f", $0) } ?? ""
    }

    /// "Added 3 Jul 2026 · Hugging Face: user/repo" — the identity-card caption under the tags.
    private var cardLine: String {
        var parts: [String] = []
        if let a = item.addedAt { parts.append("Added " + a.formatted(date: .abbreviated, time: .omitted)) }
        if let p = item.provenance { parts.append(p) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                tile
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.fileName).font(.fxMono(12.5)).foregroundStyle(Color.fxText).lineLimit(1)
                    HStack(spacing: 8) {
                        if item.isCompatible {
                            HStack(spacing: 6) { FxDot(tone: .ok, size: 7); Text("for \(item.tier?.shortName ?? "Klein")") }.fxPillOk()
                                .help("Built for \(item.tier?.shortName ?? "Klein"). It's selectable on the Generate tab only while that model is the active tier.")
                        } else {
                            HStack(spacing: 6) {
                                FxDot(tone: .amber, size: 7); Text("incompatible")
                            }
                            .font(.fxMono(11)).foregroundStyle(Color.fxAccent)
                            .padding(.vertical, 4).padding(.horizontal, 9)
                            .background(Color.fxAccentSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .help(item.note)
                        }
                        tag(item.note)
                        tag(fileSize)
                        if let d = item.defaultScale {
                            tag(String(format: "default \u{00D7}%.2f", d))
                        }
                        if let usage, usage.count > 0 {
                            Button { onShowRenders() } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "photo.stack").font(.system(size: 9))
                                    Text("\(usage.count) render\(usage.count == 1 ? "" : "s")")
                                }
                                .font(.fxMono(10.5)).foregroundStyle(Color.fxAccent)
                                .padding(.vertical, 4).padding(.horizontal, 9)
                                .background(Color.fxAccentSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help("Used in \(usage.count) gallery render\(usage.count == 1 ? "" : "s"), last on \(usage.lastUsed.formatted(date: .abbreviated, time: .omitted)). Click to see them in the Gallery.")
                        }
                    }
                    if !cardLine.isEmpty {
                        Text(cardLine).font(.fx(11)).foregroundStyle(Color.fxText3).lineLimit(1)
                            .help(cardLine)
                    }
                }
                Spacer(minLength: 8)
                if ModelCardStore.exists(forLibraryFile: item.fileName) {
                    Button { onCard() } label: { Image(systemName: "doc.text") }
                        .buttonStyle(FxIconButtonStyle())
                        .help("About this LoRA — the model card snapshotted when it was published: recipe, loss curve and validation images. Exportable as a shareable package")
                }
                if item.isCompatible {
                    Button { onBake() } label: { Image(systemName: "wand.and.stars") }
                        .buttonStyle(FxIconButtonStyle())
                        .disabled(vm.editBusy)
                        .help("Bake a strength into a copy — e.g. write a file whose 1.00 equals this adapter at 0.80, so it behaves at default strength everywhere (ComfyUI too). The original is untouched")
                }
                Button { vm.revealInFinder(item) } label: { Image(systemName: "folder") }
                    .buttonStyle(FxIconButtonStyle())
                    .help("Show this adapter's .safetensors file in Finder")
                Button { confirmDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(FxIconButtonStyle(destructive: true))
                    .help("Delete the adapter file from disk — permanent, no Trash (asks for confirmation). If it's selected on the Generate tab it will be deactivated")
                    .confirmationDialog(
                        "Delete \u{201C}\(item.fileName)\u{201D}?",
                        isPresented: $confirmDelete, titleVisibility: .visible
                    ) {
                        Button("Delete", role: .destructive) { vm.delete(item) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        // Queue-aware: deleting the file doesn't touch the queue, so pending
                        // items that reference this adapter will fail when their render starts.
                        Text("The .safetensors file is removed from disk immediately — there is no Trash to recover it from."
                             + (vm.queueUsesAdapter?(item.fileName) == true
                                ? " N.B. queued render(s) still reference this adapter — they will fail at start."
                                : ""))
                    }
            }

            if item.isCompatible {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Trigger word").fxLabel()
                    HStack(spacing: 10) {
                        TextField("this LoRA's own trigger phrase (optional)", text: $triggerText)
                            .textFieldStyle(.plain)
                            .font(.fxMono(13)).foregroundStyle(Color.fxText)
                            .onSubmit { vm.setTrigger(triggerText, for: item) }
                            .padding(.vertical, 8).padding(.horizontal, 12)
                            .fxInsetField(radius: 9)
                            .help("This LoRA's trigger phrase (from its HuggingFace page) — auto-added to the prompt whenever the LoRA is active. Press Return or Save to store it; leave empty if the LoRA needs none")
                        Button("Save") { vm.setTrigger(triggerText, for: item) }
                            .buttonStyle(FxPrimaryButtonStyle(height: 30))
                            .disabled(triggerText == item.trigger)
                            .opacity(triggerText == item.trigger ? 0.5 : 1)
                            .help("Saved per adapter — auto-added to the prompt whenever this LoRA is active")
                        Button { vm.copyTrigger(item) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(FxIconButtonStyle())
                            .disabled(item.trigger.isEmpty)
                            .opacity(item.trigger.isEmpty ? 0.4 : 1)
                            .help("Copy this LoRA's trigger word to the clipboard")
                    }
                    Text("The LoRA's trigger word (from its HuggingFace page). It's added to the prompt automatically.")
                        .font(.fx(11)).foregroundStyle(Color.fxText3)
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("Description").fxLabel()
                    HStack(spacing: 10) {
                        TextField("what this adapter does, when to use it (optional)", text: $aboutText)
                            .textFieldStyle(.plain)
                            .font(.fx(12.5)).foregroundStyle(Color.fxText)
                            .onSubmit { vm.setAbout(aboutText, for: item) }
                            .padding(.vertical, 8).padding(.horizontal, 12)
                            .fxInsetField(radius: 9)
                            .help("Your own note — \u{201C}my product shots, photoreal, pairs well with studio prompts\u{201D}. Press Return or Save to store it")
                        Button("Save") { vm.setAbout(aboutText, for: item) }
                            .buttonStyle(FxPrimaryButtonStyle(height: 30))
                            .disabled(aboutText == item.about)
                            .opacity(aboutText == item.about ? 0.5 : 1)
                            .help("Saved per adapter — shown here so a dozen variants stay distinguishable")
                    }
                    HStack(spacing: 10) {
                        Text("Default strength").fxLabel()
                        TextField("1.00", text: $scaleText)
                            .textFieldStyle(.plain)
                            .frame(width: 48)
                            .multilineTextAlignment(.trailing)
                            .font(.fxMono(12)).foregroundStyle(Color.fxText)
                            .onSubmit { vm.setDefaultScale(scaleText, for: item) }
                            .padding(.vertical, 6).padding(.horizontal, 8)
                            .fxInsetField(radius: 8)
                        Button("Save") { vm.setDefaultScale(scaleText, for: item) }
                            .buttonStyle(FxSecondaryButtonStyle(height: 28))
                            .disabled(scaleText == storedScaleText)
                            .opacity(scaleText == storedScaleText ? 0.5 : 1)
                        if item.defaultScale != nil {
                            Button("Clear") { vm.setDefaultScale("", for: item) }
                                .buttonStyle(FxGhostButtonStyle())
                                .help("Back to 1.00 on add")
                        }
                        Text("Pre-selected when you add this adapter in Generate. Recipes and remixes keep their own recorded strengths.")
                            .font(.fx(11)).foregroundStyle(Color.fxText3).lineLimit(2)
                    }
                }
            }
        }
        .padding(.vertical, 14).padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.fxPanel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.32), radius: 10, x: 0, y: 6)
        .padding(.bottom, 12)
        .onAppear { triggerText = item.trigger; aboutText = item.about; scaleText = storedScaleText }
        // A same-named adapter re-imported reuses this row's identity, so onAppear won't re-fire —
        // sync the fields when the underlying values change so they can't show stale text.
        .onChange(of: item.trigger) { _, newValue in triggerText = newValue }
        .onChange(of: item.about) { _, newValue in aboutText = newValue }
        .onChange(of: item.defaultScale) { _, _ in scaleText = storedScaleText }
    }

    private var tile: some View {
        Image(systemName: "point.3.connected.trianglepath.dotted")
            .font(.system(size: 19))
            .foregroundStyle(Color.fxAccent)
            .frame(width: 42, height: 42)
            .background(Color.fxAccentSoft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.fxAccentLine, lineWidth: 1))
    }

    private var fileSize: String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: item.url.path),
              let size = attrs[.size] as? Int64 else { return "—" }
        return ByteFormat.string(size)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.fxMono(11)).foregroundStyle(Color.fxText3).lineLimit(1)
            .padding(.vertical, 2).padding(.horizontal, 7)
            .background(Color.fxInset, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
    }
}

private struct DropZoneImport: View {
    @Bindable var vm: LoRAViewModel
    @State private var isTargeted = false

    var body: some View {
        FxDropZone(isTargeted: isTargeted) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 16)).foregroundStyle(Color.fxText3.opacity(0.8))
                (Text("Drop a ").foregroundColor(.fxText3)
                 + Text(".safetensors").foregroundColor(.fxAccent)
                 + Text(" here to add another adapter").foregroundColor(.fxText3))
                    .font(.fx(12))
            }
        }
        .onTapGesture { vm.importLoRA() }
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            fxResolveDroppedFileURL(provider) { url in
                guard let url else {
                    DispatchQueue.main.async { vm.lastAction = .error("Couldn't read the dropped item — drag a .safetensors FILE from Finder.") }
                    return
                }
                DispatchQueue.main.async { vm.importLoRA(from: url) }
            }
            return true
        }
        .help("Drop a .safetensors here — or click to choose one. Klein-architecture only: 9B = dim 4096, 4B = dim 3072; FLUX.1/Dev adapters won't load")
    }
}

// MARK: - Bake sheet

/// Write a rescaled copy: strength 1.00 of the NEW file equals the chosen strength of the old
/// one — the sweet spot becomes the new neutral, in this app and anywhere else.
private struct BakeSheet: View {
    @Bindable var vm: LoRAViewModel
    let item: LoRAItem
    let onClose: () -> Void
    @State private var strengthText: String

    init(vm: LoRAViewModel, item: LoRAItem, onClose: @escaping () -> Void) {
        self.vm = vm
        self.item = item
        self.onClose = onClose
        // Prefill with the saved sweet spot; 0.8 (the classic anti-mutation scale) otherwise.
        _strengthText = State(initialValue: String(format: "%.2f", item.defaultScale ?? 0.8))
    }

    private var strength: Float? { Float(strengthText.replacingOccurrences(of: ",", with: ".")) }
    private var isValid: Bool { strength.map { $0 >= 0.05 && $0 <= 1.5 && abs($0 - 1.0) > 0.004 } ?? false }
    private var outputName: String {
        guard let s = strength, isValid else { return "—" }
        return String(format: "%@-x%.2f.safetensors", String(item.fileName.dropLast(".safetensors".count)), s)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Bake strength").font(.fx(14, weight: .semibold)).foregroundStyle(Color.fxText)
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark") }
                    .buttonStyle(FxIconButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider().overlay(Color.fxBorder)

            VStack(alignment: .leading, spacing: 12) {
                Text(item.fileName).font(.fxMono(12)).foregroundStyle(Color.fxText2).lineLimit(1)
                Text("Writes a NEW copy whose effect at strength 1.00 equals this adapter at the strength below — so it behaves right at default strength here, in ComfyUI, or anywhere else. The metadata alpha/rank multiplier is folded in; the original file is never modified.")
                    .font(.fx(12)).foregroundStyle(Color.fxText3)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                HStack(spacing: 10) {
                    Text("Strength").fxLabel()
                    TextField("0.80", text: $strengthText)
                        .textFieldStyle(.plain)
                        .frame(width: 52)
                        .multilineTextAlignment(.trailing)
                        .font(.fxMono(13)).foregroundStyle(Color.fxText)
                        .padding(.vertical, 7).padding(.horizontal, 9)
                        .fxInsetField(radius: 8)
                    Text("0.05 – 1.5, e.g. 0.8 if it mutates at 1.0")
                        .font(.fx(11)).foregroundStyle(Color.fxText3)
                }
                HStack(spacing: 6) {
                    Text("Output:").font(.fx(11)).foregroundStyle(Color.fxText3)
                    Text(outputName).font(.fxMono(11)).foregroundStyle(Color.fxAccent).lineLimit(1)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider().overlay(Color.fxBorder)
            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                    .buttonStyle(FxSecondaryButtonStyle(height: 32))
                Button("Write baked copy") {
                    if let s = strength { vm.bake(item, strength: s) }
                    onClose()
                }
                .buttonStyle(FxPrimaryButtonStyle(height: 32))
                .disabled(!isValid || vm.editBusy)
                .opacity(!isValid || vm.editBusy ? 0.5 : 1)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(width: 480, height: 300)
        .background(Color.fxBg)
    }
}

// MARK: - Merge sheet

/// Combine 2+ same-tier adapters into one file. Strengths prefill to 1/n (the classic
/// average-two-checkpoints trick); the math is exact rank concatenation, so the output rank
/// is the sum of the sources' ranks.
private struct MergeSheet: View {
    @Bindable var vm: LoRAViewModel
    let onClose: () -> Void
    @State private var selected: [String] = []            // fileNames, in selection order
    @State private var scales: [String: String] = [:]     // fileName → strength text
    @State private var outputName: String = ""

    private var candidates: [LoRAItem] { vm.items.filter(\.isCompatible) }
    private var selectedItems: [LoRAItem] {
        selected.compactMap { name in candidates.first { $0.fileName == name } }
    }
    private var lockedTier: ModelTier? { selectedItems.first?.tier }
    private var canMerge: Bool {
        selected.count >= 2 && !vm.editBusy
            && selectedItems.allSatisfy { Float((scales[$0.fileName] ?? "").replacingOccurrences(of: ",", with: ".")) != nil }
            && !outputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Merge adapters").font(.fx(14, weight: .semibold)).foregroundStyle(Color.fxText)
                if let tier = lockedTier {
                    Text(tier.shortName).font(.fxMono(11)).foregroundStyle(Color.fxAccent)
                }
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark") }
                    .buttonStyle(FxIconButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider().overlay(Color.fxBorder)

            VStack(alignment: .leading, spacing: 10) {
                Text("Pick two or more adapters of the SAME tier. Strengths prefill to 1/n — the classic way to average neighboring checkpoints; adjust them to flatten a tuned stack instead. A NEW file is written; the sources stay untouched.")
                    .font(.fx(12)).foregroundStyle(Color.fxText3)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(candidates) { item in
                            mergeRow(item)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider().overlay(Color.fxBorder)
            HStack(spacing: 10) {
                Text("Output").fxLabel()
                TextField("merged file name", text: $outputName)
                    .textFieldStyle(.plain)
                    .font(.fxMono(12)).foregroundStyle(Color.fxText)
                    .padding(.vertical, 7).padding(.horizontal, 10)
                    .fxInsetField(radius: 8)
                Button("Cancel") { onClose() }
                    .buttonStyle(FxSecondaryButtonStyle(height: 32))
                Button("Merge") {
                    let sels = selectedItems.map { item in
                        (item: item,
                         scale: Float((scales[item.fileName] ?? "1").replacingOccurrences(of: ",", with: ".")) ?? 1.0)
                    }
                    vm.merge(sels, outputName: outputName)
                    onClose()
                }
                .buttonStyle(FxPrimaryButtonStyle(height: 32))
                .disabled(!canMerge)
                .opacity(canMerge ? 1 : 0.5)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(width: 600, height: 440)
        .background(Color.fxBg)
    }

    @ViewBuilder private func mergeRow(_ item: LoRAItem) -> some View {
        let isSelected = selected.contains(item.fileName)
        let tierBlocked = lockedTier != nil && item.tier != lockedTier && !isSelected
        HStack(spacing: 10) {
            Button { toggle(item) } label: {
                HStack(spacing: 10) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 14))
                        .foregroundStyle(isSelected ? Color.fxAccent : Color.fxText3)
                    Text(item.fileName).font(.fxMono(12)).foregroundStyle(Color.fxText).lineLimit(1)
                    Text(item.tier?.shortName ?? "—").font(.fxMono(10.5)).foregroundStyle(Color.fxText3)
                }
            }
            .buttonStyle(.plain)
            .disabled(tierBlocked)
            .help(tierBlocked ? "Different tier — 9B and 4B weights can't be combined" : "")
            Spacer()
            if isSelected {
                Text("strength").font(.fx(11)).foregroundStyle(Color.fxText3)
                TextField("", text: Binding(
                    get: { scales[item.fileName] ?? "" },
                    set: { scales[item.fileName] = $0 }
                ))
                .textFieldStyle(.plain)
                .frame(width: 44)
                .multilineTextAlignment(.trailing)
                .font(.fxMono(12)).foregroundStyle(Color.fxText)
                .padding(.vertical, 5).padding(.horizontal, 7)
                .fxInsetField(radius: 7)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(isSelected ? Color.fxInset.opacity(0.6) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(tierBlocked ? 0.4 : 1)
    }

    private func toggle(_ item: LoRAItem) {
        if let idx = selected.firstIndex(of: item.fileName) {
            selected.remove(at: idx)
        } else {
            selected.append(item.fileName)
        }
        // Auto 1/n on every selection change (like ai-toolkit's merge modal) — a fair average
        // is the default; the user tunes strengths afterwards if flattening a stack.
        let n = max(selected.count, 1)
        for name in selected { scales[name] = String(format: "%.2f", 1.0 / Float(n)) }
        if outputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let first = selected.first {
            outputName = String(first.dropLast(".safetensors".count)) + "_merged.safetensors"
        }
    }
}

// MARK: - Model card sheet ("About this LoRA")

/// The card snapshotted at publish time: training recipe, loss curve and the published
/// checkpoint's validation images — it survives even after the training run is deleted.
/// "Export package…" writes a folder (adapter + card.html + images) for sharing/archiving.
private struct ModelCardSheet: View {
    @Bindable var vm: LoRAViewModel
    let item: LoRAItem
    let onClose: () -> Void
    @State private var card: TrainingModelCard? = nil

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text").font(.system(size: 13)).foregroundStyle(Color.fxAccent)
                Text("About this LoRA").font(.fx(14, weight: .semibold)).foregroundStyle(Color.fxText)
                Text(item.fileName).font(.fxMono(11)).foregroundStyle(Color.fxText3).lineLimit(1)
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark") }
                    .buttonStyle(FxIconButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider().overlay(Color.fxBorder)

            if let card {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        headerLine(card)
                        recipeSection(card)
                        if card.lossHistory.count > 1 { lossSection(card) }
                        if !card.validation.isEmpty { validationSection(card) }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Spacer()
                Text("No model card found for this adapter.")
                    .font(.fx(12)).foregroundStyle(Color.fxText3)
                Spacer()
            }

            Divider().overlay(Color.fxBorder)
            HStack {
                Text("Snapshotted when the checkpoint was published — it outlives the training run.")
                    .font(.fx(10.5)).foregroundStyle(Color.fxText3).lineLimit(1)
                Spacer()
                Button {
                    vm.exportPackage(item)
                } label: {
                    HStack(spacing: 6) { Image(systemName: "square.and.arrow.up"); Text("Export package…") }
                }
                .buttonStyle(FxSecondaryButtonStyle(height: 30, accentText: true))
                .disabled(card == nil)
                .help("Write a folder with the .safetensors, card.html and the validation images — everything needed to use this adapter elsewhere")
                Button("Close") { onClose() }
                    .buttonStyle(FxGhostButtonStyle(height: 30))
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(width: 620, height: 640)
        .background(Color.fxBg)
        .onAppear { card = ModelCardStore.load(forLibraryFile: item.fileName) }
    }

    private func headerLine(_ card: TrainingModelCard) -> some View {
        HStack(spacing: 8) {
            Text(card.runName).font(.fx(13, weight: .semibold)).foregroundStyle(Color.fxText)
            if !card.trigger.isEmpty {
                Text(card.trigger).font(.fxMono(10)).foregroundStyle(Color.fxAccent)
                    .padding(.vertical, 2).padding(.horizontal, 7)
                    .background(Color.fxAccentSoft, in: Capsule())
            }
            Spacer()
            Text("published \(card.publishedAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.fxMono(10)).foregroundStyle(Color.fxText3)
        }
    }

    private func recipeSection(_ card: TrainingModelCard) -> some View {
        FxFlowLayout(spacing: 18, lineSpacing: 10) {
            info("Model", ModelTier(rawValue: card.tier)?.shortName ?? card.tier)
            info("Published", card.publishedStep.map { "step \($0) / \(card.maxSteps)" } ?? "final (\(card.maxSteps) steps)")
            info("Rank / Alpha", "\(card.rank) / \(Int(card.alpha))")
            info("Learning rate", String(format: "%g", card.learningRate))
            info("Resolution", "\(card.resolution)px")
            info("Dataset", "\(card.imageCount) image\(card.imageCount == 1 ? "" : "s")"
                 + (card.mirrored == true ? " (mirrored)" : ""))
            info("DOP", card.dopEnabled ? "on (\(card.dopClass ?? "—"))" : "off")
            info("Strength", item.defaultScale.map { String(format: "×%.2f", $0) } ?? "×1.00")
            if let ws = card.workshopName { info("Workshop", ws) }
        }
        .fxCard(padding: 14)
    }

    private func lossSection(_ card: TrainingModelCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Loss curve").font(.fx(12, weight: .medium)).foregroundStyle(Color.fxText2)
            LossChart(values: card.lossHistory).frame(height: 110)
                .background(Color.fxLogBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
        }
        .fxCard(padding: 14)
    }

    private func validationSection(_ card: TrainingModelCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Validation images (step \(card.validationStep.map(String.init) ?? "—"))")
                .font(.fx(12, weight: .medium)).foregroundStyle(Color.fxText2)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(card.validation, id: \.fileName) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        CardImage(url: ModelCardStore.dir(forLibraryFile: card.libraryFileName)
                            .appendingPathComponent(entry.fileName))
                        Text(entry.prompt)
                            .font(.fx(10)).foregroundStyle(Color.fxText3)
                            .lineLimit(2)
                            .help(entry.prompt)
                    }
                }
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
}

/// Square validation snapshot inside the card sheet (downsampled off-main).
private struct CardImage: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        Rectangle().fill(Color.fxInset)
            .aspectRatio(1, contentMode: .fit)
            .overlay { if let image { Image(nsImage: image).resizable().scaledToFill() } }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
            .task(id: url) { image = await WorkshopDatasetService.thumbnail(at: url, maxPixel: 360) }
    }
}

// MARK: - Import from URL sheet

/// Paste a Hugging Face repo or file link → list its .safetensors → header-only compatibility
/// check → resumable download → library registration. Incompatible files are rejected BEFORE
/// any tensor data is downloaded, with the same readable reasons as drag-drop import.
private struct URLImportSheet: View {
    @Bindable var vm: LoRAViewModel
    let onClose: () -> Void
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Import from Hugging Face").font(.fx(14, weight: .semibold)).foregroundStyle(Color.fxText)
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark") }
                    .buttonStyle(FxIconButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .help(vm.urlDownloading ? "The download keeps running — the result shows on the LoRA tab" : "Close")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider().overlay(Color.fxBorder)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    TextField("owner/repo or a huggingface.co link", text: $input)
                        .textFieldStyle(.plain)
                        .font(.fxMono(12)).foregroundStyle(Color.fxText)
                        .onSubmit {
                            // Return must obey the SAME gate as the Fetch button below — an
                            // ungated submit could start a second listing under an in-flight
                            // one (or mid-download) and clobber its status.
                            guard !vm.urlBusy, !vm.urlDownloading,
                                  !input.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                            vm.fetchRemoteList(input)
                        }
                        .padding(.vertical, 8).padding(.horizontal, 12)
                        .fxInsetField(radius: 9)
                        .help("A repo id (user/klein-loras), a repo page URL, or a direct .safetensors file link. Gated repos use your saved HF token")
                    Button("Fetch") { vm.fetchRemoteList(input) }
                        .buttonStyle(FxSecondaryButtonStyle(height: 32, accentText: true))
                        .disabled(vm.urlBusy || vm.urlDownloading || input.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if !vm.urlFiles.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(vm.urlFiles, id: \.path) { file in
                                fileRow(file)
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                }

                if let check = vm.urlCheck {
                    verdict(check)
                }

                if vm.urlDownloading {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: vm.urlProgress).tint(.fxAccent)
                        HStack {
                            Text(vm.urlStatus ?? "Downloading…").font(.fxMono(11)).foregroundStyle(Color.fxText3)
                            Spacer()
                            Button("Cancel") { vm.cancelURLImport() }
                                .buttonStyle(FxGhostButtonStyle())
                                .help("Stops the download — fetched bytes are kept, it resumes if you try again")
                        }
                    }
                } else if let status = vm.urlStatus {
                    Text(status).font(.fx(11))
                        .foregroundStyle(vm.urlStatusIsError ? Color.fxDanger : Color.fxText3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 560, height: 420)
        .background(Color.fxBg)
        .onAppear { vm.resetURLImport() }
    }

    @ViewBuilder private func fileRow(_ file: ResumableDownloader.RemoteFile) -> some View {
        let isChecked = vm.urlCheck?.path == file.path
        Button { vm.preflightRemote(file) } label: {
            HStack(spacing: 10) {
                Image(systemName: isChecked ? "doc.badge.ellipsis" : "doc")
                    .font(.system(size: 12))
                    .foregroundStyle(isChecked ? Color.fxAccent : Color.fxText3)
                Text(file.path).font(.fxMono(12)).foregroundStyle(Color.fxText).lineLimit(1)
                Spacer()
                Text(file.size > 0 ? ByteFormat.string(file.size) : "—")
                    .font(.fxMono(11)).foregroundStyle(Color.fxText3)
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(isChecked ? Color.fxInset.opacity(0.6) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(vm.urlBusy || vm.urlDownloading)
        .help("Click to check compatibility — only the file's header is fetched, not the weights")
    }

    @ViewBuilder private func verdict(_ check: LoRAViewModel.RemoteCheck) -> some View {
        HStack(spacing: 10) {
            if check.inspection.tier != nil {
                HStack(spacing: 6) { FxDot(tone: .ok, size: 7); Text("for \(check.inspection.tier?.shortName ?? "Klein")") }
                    .fxPillOk()
                Text(check.inspection.note).font(.fx(11)).foregroundStyle(Color.fxText3).lineLimit(2)
                Spacer()
                Button("Download") { vm.downloadRemote() }
                    .buttonStyle(FxPrimaryButtonStyle(height: 30))
                    .disabled(vm.urlDownloading)
            } else {
                HStack(spacing: 6) { FxDot(tone: .amber, size: 7); Text("not importable") }
                    .font(.fxMono(11)).foregroundStyle(Color.fxAccent)
                    .padding(.vertical, 4).padding(.horizontal, 9)
                    .background(Color.fxAccentSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(check.inspection.note).font(.fx(11)).foregroundStyle(Color.fxText3)
                    .fixedSize(horizontal: false, vertical: true).lineLimit(3)
                Spacer()
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(Color.fxInset.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
