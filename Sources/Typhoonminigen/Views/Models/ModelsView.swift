import SwiftUI

struct ModelsView: View {
    @Bindable var vm: ModelsViewModel
    @State private var editingToken = false
    @State private var confirmClearHF = false

    var body: some View {
        VStack(spacing: 0) {
            // Pinned banner: guard refusals / confirmations would otherwise render below the fold.
            if let msg = vm.lastAction {
                Text(msg.text).font(.fx(11))
                    .foregroundStyle(msg.isError ? Color.fxDanger : Color.fxText2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(msg.isError ? Color.fxDanger.opacity(0.12) : Color.fxInset)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        SectionTitle(text: "Models")
                        Spacer()
                        HStack(spacing: 7) {
                            FxDot(tone: vm.tokenSaved ? .ok : .idle, live: vm.tokenSaved)
                            Text(vm.tokenSaved ? "HuggingFace · token saved" : "HuggingFace · no token")
                        }
                        .font(.fxMono(11)).foregroundStyle(Color.fxText3)
                        .help("Shows whether a HuggingFace token is saved in the Keychain. Only the gated 9B weights need one — 4B and all encoders download without it.")
                    }

                    Text("Each Klein model needs a diffusion transformer and a text encoder (LLM) — download both for the tier you want. The 4-bit encoder is lighter on RAM and disk; the engine uses whichever encoder it finds on disk. Gated 9B weights need a free HuggingFace token (kept in your Keychain, never leaves this Mac).")
                        .font(.fx(12)).foregroundStyle(Color.fxText3)
                        .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                        .frame(maxWidth: 640, alignment: .leading)
                        .padding(.top, 8).padding(.bottom, 18)

                    tokenCard

                    TierComparisonCard()
                        .padding(.top, 14)

                    HStack {
                        Text(totalSummary).font(.fxMono(11)).foregroundStyle(Color.fxText3)
                        Spacer()
                        importButton
                    }
                    .padding(.top, 18).padding(.bottom, 4)

                    // ── Image Generation ──────────────────────────────────────────
                    CollapsibleSection(
                        icon: "photo.badge.plus",
                        title: "Image Generation",
                        subtitle: "Flux 2 models for text-to-image. Each model needs a diffusion transformer and a text encoder (LLM)."
                    ) {
                        ForEach(vm.imageGenGroups) { group in
                            TierGroupCard(group: group, vm: vm)
                        }
                    }
                    .padding(.top, 16)

                    // ── LoRA Training ─────────────────────────────────────────────
                    CollapsibleSection(
                        icon: "brain",
                        title: "LoRA Training",
                        subtitle: "Base (non-distilled) weights a LoRA trains on — a base model and its text encoder.",
                        startExpanded: false
                    ) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11)).foregroundStyle(Color.fxAccent)
                            Text("Training needs a 32 GB Mac (Klein 4B; 9B needs 48 GB+) and can take hours. These rows download the base weights the Training tab trains on. Checkpoint previews also need the tier's Image Generation model from the section above.")
                                .font(.fx(11)).foregroundStyle(Color.fxText2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 9).padding(.horizontal, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.fxAccentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.fxAccentLine, lineWidth: 1))

                        ForEach(vm.loraGroups) { group in
                            TierGroupCard(group: group, vm: vm)
                        }
                    }
                    .padding(.top, 18)

                    // ── Shared components (VAE + Describe VLM) ─────────────────────
                    if !vm.auxComponents.isEmpty {
                        HStack {
                            Text("SHARED COMPONENTS").font(.fx(11, weight: .semibold)).tracking(0.5).foregroundStyle(Color.fxText3)
                            Spacer()
                            Text(componentsSummary).font(.fxMono(11)).foregroundStyle(Color.fxText3)
                        }
                        .padding(.top, 22).padding(.bottom, 4)
                        Text("Not tied to one tier — the shared VAE (used by BOTH Klein tiers) and the vision model behind Describe and Auto-caption (4-bit recommended; 8-bit = sharper captions, more RAM). They re-download automatically when needed; the vision model can also be downloaded ahead of time below.")
                            .font(.fx(11.5)).foregroundStyle(Color.fxText3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 640, alignment: .leading)
                            .padding(.bottom, 12)
                        ForEach(vm.auxComponents) { comp in
                            AuxComponentRow(comp: comp, vm: vm)
                        }
                    }

                    storageCard
                        .padding(.top, 18)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.fxBg)
        .task { vm.reload() }
    }

    // MARK: Summaries

    private var totalSummary: String {
        // Dedupe by id: the shared encoders (qwen3-4b-4bit / qwen3-8b-4bit) are listed in an
        // Image-Generation group AND a LoRA-Training group — same id, same directory on disk,
        // so summing the raw flatMap double-counted their count and bytes.
        var seen = Set<String>()
        let comps = (vm.imageGenGroups.flatMap(\.allComponents) + vm.loraGroups.flatMap(\.allComponents))
            .filter { seen.insert($0.id).inserted }
        let onDisk = comps.filter(\.isDownloaded)
        // Aux components: count and bytes must agree — only DOWNLOADED ones belong in the
        // "on disk" figure (a cancelled VLM's residue used to be silently folded into bytes
        // while the count ignored it); the residue is reported in the partial figure instead.
        let auxOnDisk = vm.auxComponents.filter(\.isDownloaded)
        let count = onDisk.count + auxOnDisk.count
        let bytes = onDisk.reduce(Int64(0)) { $0 + $1.downloadedBytes }
            + auxOnDisk.reduce(Int64(0)) { $0 + $1.bytes }
        var text = "\(count) component\(count == 1 ? "" : "s") on disk · \(ByteFormat.string(bytes))"
        // Cancelled-download residue is real disk usage too — surface it in the total instead
        // of letting GBs of `.part` files hide behind a "0 bytes" row. partialBytes is a dict
        // keyed by component id, so the shared encoders can't double-count here either.
        let partial = vm.partialBytes.values.reduce(Int64(0), +)
            + vm.auxComponents.filter { !$0.isDownloaded }.reduce(Int64(0)) { $0 + $1.bytes }
        if partial > 0 { text += " · \(ByteFormat.string(partial)) partial" }
        return text
    }

    private var componentsSummary: String {
        let onDisk = vm.auxComponents.filter(\.isDownloaded)
        let bytes = onDisk.reduce(Int64(0)) { $0 + $1.bytes }
        return "\(onDisk.count) on disk · \(ByteFormat.string(bytes))"
    }

    // MARK: Import

    private var importButton: some View {
        Button(vm.importing ? "Importing…" : "Import existing weights…") {
            vm.pickAndScanImportFolder()
        }
        .buttonStyle(FxGhostButtonStyle(height: 26, accentText: true))
        .disabled(vm.importing || vm.downloadingID != nil)
        .help("Use MLX-format weights you already have on disk — pick the folder that contains them. ComfyUI .safetensors checkpoints are not supported.")
        .confirmationDialog(
            "Import found components?",
            isPresented: Binding(
                get: { vm.pendingImport != nil },
                set: { if !$0 { vm.pendingImport = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Copy (uses disk, safe)") { vm.performImport(mode: .copy) }
            Button("Link (saves disk — original must stay in place)") { vm.performImport(mode: .link) }
            Button("Cancel", role: .cancel) { vm.cancelImport() }
        } message: {
            Text(importDialogMessage)
        }
    }

    private var importDialogMessage: String {
        let items = vm.pendingImport ?? []
        let lines = items.map { item in
            let size = ByteFormat.string(item.sizeBytes)
            return item.alreadyInstalled
                ? "\(item.component.displayName) — \(size) — already installed, will be skipped"
                : "\(item.component.displayName) — \(size)"
        }
        return lines.joined(separator: "\n")
            + "\n\nCopy duplicates the files into the app's models folder (instant clone on the same disk). Link points at the originals instead — if they move or their drive is unmounted, the model stops loading."
    }

    // MARK: Token card

    private var tokenCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                (Text("HuggingFace token ").foregroundColor(.fxText2)
                 + Text("(gated 9B weights only)").foregroundColor(.fxText3))
                    .font(.fx(12, weight: .medium))
                Spacer()
                if vm.tokenSaved {
                    HStack(spacing: 6) { FxDot(tone: .ok, size: 7); Text("saved") }.fxPillOk()
                }
            }
            HStack(spacing: 10) {
                if vm.tokenSaved && !editingToken {
                    Text(String(repeating: "•", count: 28))
                        .font(.fxMono(13)).tracking(2).foregroundStyle(Color.fxText2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Edit") { editingToken = true }
                        .buttonStyle(FxGhostButtonStyle(height: 28, accentText: true))
                        .help("Replace or clear the saved token")
                } else {
                    SecureField("hf_…", text: $vm.hfToken)
                        .textFieldStyle(.plain)
                        .font(.fxMono(12)).foregroundStyle(Color.fxText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help("Paste a HuggingFace \u{201C}Read\u{201D} token (starts with hf_) — required only for the gated 9B weights. Saved to the macOS Keychain when you press Save.")
                    Button("Save") {
                        vm.persistToken()
                        editingToken = false
                    }
                    .buttonStyle(FxSecondaryButtonStyle(height: 28, accentText: true))
                    .help("Store the token in the macOS Keychain — it never leaves this Mac. Saving an empty field removes the stored token.")
                }
            }
            .padding(.vertical, 10).padding(.horizontal, 12)
            .fxInsetField(radius: 10)
            HStack(spacing: 16) {
                Link("Get a token ↗", destination: URL(string: "https://huggingface.co/settings/tokens")!)
                    .help("Opens huggingface.co — create a free account, then a \u{201C}Read\u{201D} token")
                Link("Accept the Klein 9B license ↗", destination: URL(string: "https://huggingface.co/black-forest-labs/FLUX.2-klein-9B")!)
                    .help("Opens the model page — accept the license there or the gated download is refused")
                Spacer()
            }
            .font(.fx(11)).tint(Color.fxAccent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxCard()
    }

    // MARK: Storage card

    private var storageCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("HuggingFace cache · this app's entries").font(.fx(12.5, weight: .semibold)).foregroundStyle(Color.fxText)
                Text("Some model weights are cached in the shared ~/.cache/huggingface — this counts (and Clear deletes) only the entries this app's models can create. Other tools' caches are never touched.")
                    .font(.fx(11)).foregroundStyle(Color.fxText3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(ByteFormat.string(vm.hfCacheBytes)).font(.fxMono(12)).foregroundStyle(Color.fxText2)
            Button("Clear") { confirmClearHF = true }
                .buttonStyle(FxSecondaryButtonStyle(height: 28, accentText: true))
                .disabled(vm.hfCacheBytes == 0)
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.fxPanel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
        .confirmationDialog("Clear this app's HuggingFace cache entries?", isPresented: $confirmClearHF, titleVisibility: .visible) {
            Button("Clear (\(ByteFormat.string(vm.hfCacheBytes)))", role: .destructive) { vm.clearHFCache() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Frees \(ByteFormat.string(vm.hfCacheBytes)) of re-downloadable model files. Only this app's entries in the shared cache are deleted — whatever other HuggingFace tools stored there stays.")
        }
    }
}

// MARK: - Collapsible section

private struct CollapsibleSection<Content: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    var startExpanded: Bool = true
    @ViewBuilder var content: () -> Content

    @State private var expanded: Bool

    init(icon: String, title: String, subtitle: String, startExpanded: Bool = true,
         @ViewBuilder content: @escaping () -> Content) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.startExpanded = startExpanded
        self.content = content
        _expanded = State(initialValue: startExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(Color.fxText3)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Color.fxAccent)
                    Text(title).font(.fx(14, weight: .bold)).foregroundStyle(Color.fxText)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !subtitle.isEmpty {
                Text(subtitle).font(.fx(11.5)).foregroundStyle(Color.fxText3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(.leading, 32).padding(.top, 4)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 12) { content() }
                    .padding(.top, 14)
            }
        }
    }
}

// MARK: - Tier group card (collapsible)

private struct TierGroupCard: View {
    let group: ModelGroupInfo
    @Bindable var vm: ModelsViewModel
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(Color.fxText3)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(group.title).font(.fx(13.5, weight: .semibold)).foregroundStyle(Color.fxText)
                            if group.nonCommercial {
                                Text("Non-commercial use")
                                    .font(.fxMono(9.5)).foregroundStyle(Color.fxAccent)
                                    .fxChip(accent: true, padV: 2, padH: 7, radius: 6)
                            }
                        }
                        if !group.subtitle.isEmpty {
                            Text(group.subtitle).font(.fx(11)).foregroundStyle(Color.fxText3)
                        }
                    }
                    Spacer()
                    Text("\(group.downloaded)/\(group.total)").font(.fxMono(11)).foregroundStyle(Color.fxText3)
                    Text(group.ramBadge)
                        .font(.fxMono(10.5)).foregroundStyle(Color.fxText2)
                        .fxChip(padV: 3, padH: 8, radius: 7)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 9) {
                    subHeader(icon: "sparkles", text: "Diffusion Transformer")
                    ForEach(group.transformers) { ComponentRow(comp: $0, vm: vm) }
                    subHeader(icon: "character.bubble", text: "Text Encoder (LLM)  ·  \(group.encoderHeader)")
                        .padding(.top, 4)
                    ForEach(group.encoders) { ComponentRow(comp: $0, vm: vm) }
                }
                .padding(.top, 13)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.fxPanel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
    }

    private func subHeader(icon: String, text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Color.fxText3)
            Text(text).font(.fx(11, weight: .semibold)).tracking(0.3).foregroundStyle(Color.fxText3)
        }
    }
}

// MARK: - Component row

private struct ComponentRow: View {
    let comp: ComponentInfo
    @Bindable var vm: ModelsViewModel
    @State private var confirmDelete = false
    @State private var confirmDeletePartial = false

    private var isDownloading: Bool { vm.downloadingID == comp.id }

    /// Delete-confirmation body — with an extra warning line when the composed render queue
    /// still references this component's tier (its queued items would fail or re-download GBs).
    private var deleteMessage: String {
        var text = comp.isGated
            ? "Deletion is immediate and permanent — getting it back means re-downloading ~\(comp.sizeGB) GB with your HF token."
            : "Deletion is immediate and permanent — getting it back means re-downloading ~\(comp.sizeGB) GB."
        if let warning = vm.deleteQueueWarning(for: comp) {
            text += "\n\n\(warning)"
        }
        return text
    }

    var body: some View {
        HStack(spacing: 12) {
            FxDot(tone: comp.isDownloaded ? .ok : .idle, size: 7)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(comp.title).font(.fx(12.5, weight: .medium)).foregroundStyle(Color.fxText)
                    Text("(\(comp.rawTag))").font(.fxMono(10)).foregroundStyle(Color.fxText3)
                    if comp.isGated {
                        Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Color.fxAccent)
                            .help("Gated — needs a HuggingFace token and an accepted license")
                    }
                    Link(destination: URL(string: comp.repoURL)!) {
                        Image(systemName: "arrow.up.right.square").font(.system(size: 10))
                    }
                    .tint(Color.fxText3)
                    .help("Open the model page on HuggingFace")
                }
                if isDownloading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Meter(value: vm.downloadProgress).frame(width: 170)
                            .animation(.easeInOut(duration: 0.3), value: vm.downloadProgress)
                    }
                    Text(vm.downloadMessage).font(.fxMono(10)).foregroundStyle(Color.fxText3).lineLimit(1)
                } else if vm.isQueued(comp.id) {
                    Text("Queued — starts after the current download").font(.fxMono(10)).foregroundStyle(Color.fxAccent)
                } else if let partial = vm.partialBytes[comp.id], partial > 0 {
                    // Cancelled/interrupted download residue: kept on disk for resume, so name
                    // it — it used to read as a plain "not downloaded" row holding hidden GBs.
                    Text("~\(comp.sizeGB) GB · \(ByteFormat.string(partial)) partial on disk")
                        .font(.fxMono(10.5)).foregroundStyle(Color.fxText3)
                        .help("A cancelled download left \(ByteFormat.string(partial)) of resumable data — Download continues from there, or delete it with the trash button.")
                } else {
                    Text("~\(comp.sizeGB) GB").font(.fxMono(10.5)).foregroundStyle(Color.fxText3)
                }
            }
            Spacer(minLength: 8)
            controls
        }
        .padding(.vertical, 9).padding(.horizontal, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.fxInset, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
    }

    @ViewBuilder private var controls: some View {
        if isDownloading {
            HStack(spacing: 8) {
                Text("\(Int(vm.downloadProgress * 100))%").font(.fxMono(11)).foregroundStyle(Color.fxText2)
                Button("Cancel") { vm.cancelDownload() }
                    .buttonStyle(FxGhostButtonStyle(height: 26, accentText: true))
                    .help("Stop the download — already-fetched files are reused next time")
            }
        } else if comp.isDownloaded {
            HStack(spacing: 8) {
                HStack(spacing: 5) { FxDot(tone: .ok, size: 6); Text("on disk") }.fxPillOk()
                Button { confirmDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(FxIconButtonStyle(size: 28, destructive: true))
                    .disabled(vm.importing)
                    .help("Delete this weight from disk")
                    .confirmationDialog(
                        "Delete \(comp.title)?",
                        isPresented: $confirmDelete, titleVisibility: .visible
                    ) {
                        Button("Delete (~\(comp.sizeGB) GB)", role: .destructive) { vm.delete(comp) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(deleteMessage)
                    }
            }
        } else if vm.isQueued(comp.id) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "clock").font(.system(size: 10))
                    Text("Queued")
                }
                .font(.fxMono(11)).foregroundStyle(Color.fxText3)
                .padding(.vertical, 4).padding(.horizontal, 9)
                .background(Color.fxInset, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.fxBorder, lineWidth: 1))
                Button("Remove") { vm.removeFromQueue(comp.id) }
                    .buttonStyle(FxGhostButtonStyle(height: 26))
                    .help("Remove this from the download queue")
            }
        } else {
            HStack(spacing: 8) {
                // Cancelled-download residue gets its own small Delete — the regular Delete
                // renders only for downloaded components, so these GBs were unreclaimable.
                if let partial = vm.partialBytes[comp.id], partial > 0 {
                    Button { confirmDeletePartial = true } label: { Image(systemName: "trash") }
                        .buttonStyle(FxIconButtonStyle(size: 28, destructive: true))
                        .disabled(vm.importing)
                        .help("Delete the partial download (\(ByteFormat.string(partial))) — the next download starts from the beginning")
                        .confirmationDialog(
                            "Delete the partial download of \(comp.title)?",
                            isPresented: $confirmDeletePartial, titleVisibility: .visible
                        ) {
                            Button("Delete (\(ByteFormat.string(partial)))", role: .destructive) { vm.deletePartial(comp) }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Frees \(ByteFormat.string(partial)) of resumable download data. The next download of this component starts from zero instead of continuing.")
                        }
                }
                Button { vm.download(comp) } label: {
                    HStack(spacing: 6) { Image(systemName: "arrow.down.circle"); Text("Download") }
                }
                .buttonStyle(FxPrimaryButtonStyle(height: 28))
                .disabled(vm.importing)
                .help(comp.isGated
                      ? "Downloads ~\(comp.sizeGB) GB — needs the token above and the accepted license. Queues if another download is running."
                      : "Downloads ~\(comp.sizeGB) GB — no account needed. Queues if another download is running.")
            }
        }
    }
}

// MARK: - Shared component row (VAE + VLM)

private struct AuxComponentRow: View {
    let comp: AuxComponent
    @Bindable var vm: ModelsViewModel
    @State private var confirmDelete = false
    @State private var confirmDeletePartial = false

    private var isDownloading: Bool { vm.downloadingID == comp.id }

    /// Cancelled/interrupted VLM download residue: bytes on disk but the engine's completeness
    /// check says "not downloaded" — mirror of the tier rows' partialBytes state. Only meaningful
    /// for downloadable rows (the VAE reads as downloaded whenever its dir exists).
    private var partialBytes: Int64 { !comp.isDownloaded && comp.bytes > 0 ? comp.bytes : 0 }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 16))
                .foregroundStyle(comp.isDownloaded ? Color.fxText2 : Color.fxText3)
                .frame(width: 36, height: 36)
                .background(Color.fxInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 9) {
                    Text(comp.title).font(.fx(12.5, weight: .semibold)).foregroundStyle(Color.fxText)
                    if comp.recommended {
                        Text("Recommended").font(.fxMono(9)).tracking(0.3)
                            .foregroundStyle(Color.fxAccent)
                            .padding(.vertical, 2).padding(.horizontal, 7)
                            .background(Color.fxAccentSoft, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.fxAccentLine, lineWidth: 1))
                    }
                    if !isDownloading {
                        // Name the residue: a cancelled VLM download used to read as a plain
                        // "~3 GB" row while holding invisible, unreclaimable GBs on disk.
                        Text(comp.isDownloaded ? ByteFormat.string(comp.bytes)
                             : partialBytes > 0 ? "~\(comp.sizeGB) GB · \(ByteFormat.string(partialBytes)) partial on disk"
                             : "~\(comp.sizeGB) GB")
                            .font(.fxMono(11)).foregroundStyle(Color.fxText3)
                            .help(partialBytes > 0
                                  ? "A cancelled download left \(ByteFormat.string(partialBytes)) of resumable data — Download continues from there, or delete it with the trash button."
                                  : "")
                    }
                }
                if isDownloading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Meter(value: vm.downloadProgress).frame(width: 170)
                            .animation(.easeInOut(duration: 0.3), value: vm.downloadProgress)
                    }
                    Text(vm.downloadMessage).font(.fxMono(10)).foregroundStyle(Color.fxText3).lineLimit(1)
                } else if vm.isQueued(comp.id) {
                    Text("Queued — starts after the current download finishes.")
                        .font(.fxMono(10)).foregroundStyle(Color.fxAccent)
                } else {
                    Text(comp.note)
                        .font(.fx(11)).foregroundStyle(Color.fxText3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            controls
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.fxPanel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
        .padding(.bottom, 10)
    }

    @ViewBuilder private var controls: some View {
        if isDownloading {
            HStack(spacing: 8) {
                Text("\(Int(vm.downloadProgress * 100))%").font(.fxMono(11)).foregroundStyle(Color.fxText2)
                Button("Cancel") { vm.cancelDownload() }
                    .buttonStyle(FxGhostButtonStyle(height: 26, accentText: true))
                    .help("Stop the download — already-fetched files are reused next time")
            }
        } else if comp.isDownloaded {
            HStack(spacing: 8) {
                if comp.isActive {
                    HStack(spacing: 5) { FxDot(tone: .ok, size: 6); Text("active") }.fxPillOk()
                        .help("This is the variant Describe & Auto-caption use right now")
                } else if comp.downloadable {
                    Button("Use") { vm.setActiveVLM(comp) }
                        .buttonStyle(FxGhostButtonStyle(height: 26, accentText: true))
                        .help("Use this variant for Describe & Auto-caption instead")
                } else {
                    HStack(spacing: 5) { FxDot(tone: .ok, size: 6); Text("on disk") }.fxPillOk()
                }
                Button { confirmDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(FxIconButtonStyle(size: 28, destructive: true))
                    .disabled(vm.importing)
                    .help("Delete from disk — it re-downloads automatically when next needed")
                    .confirmationDialog("Delete \(comp.title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Delete", role: .destructive) { vm.deleteAux(comp) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Deletion is immediate. It re-downloads automatically the next time Describe or Auto-caption needs it.")
                    }
            }
        } else if vm.isQueued(comp.id) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "clock").font(.system(size: 10))
                    Text("Queued")
                }
                .font(.fxMono(11)).foregroundStyle(Color.fxText3)
                .padding(.vertical, 4).padding(.horizontal, 9)
                .background(Color.fxInset, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.fxBorder, lineWidth: 1))
                Button("Remove") { vm.removeFromQueue(comp.id) }
                    .buttonStyle(FxGhostButtonStyle(height: 26))
                    .help("Remove this from the download queue")
            }
        } else if comp.downloadable {
            HStack(spacing: 8) {
                // Same "Delete partial" affordance as the tier rows (ComponentRow): cancelled
                // aux residue was otherwise undeletable — the regular trash renders only for
                // downloaded components.
                if partialBytes > 0 {
                    Button { confirmDeletePartial = true } label: { Image(systemName: "trash") }
                        .buttonStyle(FxIconButtonStyle(size: 28, destructive: true))
                        .disabled(vm.importing)
                        .help("Delete the partial download (\(ByteFormat.string(partialBytes))) — the next download starts from the beginning")
                        .confirmationDialog(
                            "Delete the partial download of \(comp.title)?",
                            isPresented: $confirmDeletePartial, titleVisibility: .visible
                        ) {
                            Button("Delete (\(ByteFormat.string(partialBytes)))", role: .destructive) { vm.deleteAuxPartial(comp) }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Frees \(ByteFormat.string(partialBytes)) of resumable download data. The next download of this component starts from zero instead of continuing.")
                        }
                }
                Button { vm.downloadAux(comp) } label: {
                    HStack(spacing: 6) { Image(systemName: "arrow.down.circle"); Text("Download") }
                }
                .buttonStyle(FxPrimaryButtonStyle(height: 28))
                .disabled(vm.importing)
                .help("Downloads ~\(comp.sizeGB) GB — no account needed. Queues if another download is running.")
            }
        }
    }
}
