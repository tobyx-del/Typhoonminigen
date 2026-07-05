import SwiftUI
import AppKit

struct GalleryView: View {
    @Bindable var vm: GalleryViewModel
    /// Remix: ContentView loads the record's recipe into the Generate form and switches tabs.
    var onRemix: (Generation) -> Void = { _ in }
    /// Batch upscale: ContentView enqueues the URLs on the shared queue and shows the Queue tab.
    var onQueueUpscales: ([URL], Int) -> Void = { _, _ in }
    @State private var confirmDeleteAll = false
    @State private var confirmDeleteSelected = false

    /// Thumbnail min width drives the adaptive column count — smaller = more per row.
    /// ~140 px ≈ the old 4-up on a typical window; ~90 px fills a 27″/4K row with ~8–10.
    @AppStorage("galleryThumbMinWidth") private var thumbMinWidth: Double = 140
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: thumbMinWidth, maximum: 280), spacing: 14)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                SectionTitle(text: "Gallery")
                Text("\(vm.generations.count) images")
                    .font(.fxMono(11)).foregroundStyle(Color.fxText2)
                    .fxChip(padV: 4, padH: 10)
                if !vm.generations.isEmpty && !vm.selectionMode {
                    HStack(spacing: 7) {
                        Image(systemName: "square.grid.3x3").font(.system(size: 11)).foregroundStyle(Color.fxText3)
                        Slider(value: $thumbMinWidth, in: 90...240, step: 10)
                            .frame(width: 110).tint(.fxAccent)
                    }
                    .help("Thumbnail size — drag left for more images per row (denser grid), right for larger thumbnails.")
                }
                Spacer()
                if vm.selectionMode {
                    Text("\(vm.selectedIDs.count) selected")
                        .font(.fxMono(11)).foregroundStyle(Color.fxAccent)
                    Button("Select all") { vm.selectAll() }
                        .buttonStyle(FxGhostButtonStyle(height: 30, accentText: false))
                    Button { vm.exportSelected() } label: {
                        HStack(spacing: 6) { Image(systemName: "square.and.arrow.up").font(.system(size: 12)); Text("Export") }
                    }
                    .buttonStyle(FxGhostButtonStyle(height: 30, accentText: false))
                    .disabled(vm.selectedIDs.isEmpty).opacity(vm.selectedIDs.isEmpty ? 0.45 : 1)
                    .help("Copy the selected images to a folder you choose.")
                    Menu {
                        Button("Upscale ×2") { queueSelectedUpscales(factor: 2) }
                        Button("Upscale ×4") { queueSelectedUpscales(factor: 4) }
                    } label: {
                        HStack(spacing: 6) { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11)); Text("Upscale") }
                            .font(.fx(12)).foregroundStyle(Color.fxText2)
                            .padding(.vertical, 6).padding(.horizontal, 10)
                    }
                    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
                    .fixedSize()
                    .disabled(vm.selectedIDs.isEmpty).opacity(vm.selectedIDs.isEmpty ? 0.45 : 1)
                    .help("Queue a Real-ESRGAN upscale for every selected image — they run one after another on the Queue tab (each saves a _xN copy next to the original).")
                    Button { confirmDeleteSelected = true } label: {
                        HStack(spacing: 6) { Image(systemName: "trash").font(.system(size: 12)); Text("Delete") }
                    }
                    .buttonStyle(FxSecondaryButtonStyle(height: 30, accentText: true))
                    .disabled(vm.selectedIDs.isEmpty || UpscaleService.isBusy).opacity(vm.selectedIDs.isEmpty ? 0.45 : 1)
                    .help("Delete the selected images — permanent, no Trash.")
                    .confirmationDialog(
                        "Delete \(vm.selectedIDs.count) image\(vm.selectedIDs.count == 1 ? "" : "s")?",
                        isPresented: $confirmDeleteSelected, titleVisibility: .visible
                    ) {
                        Button("Delete", role: .destructive) { vm.deleteSelected() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Removed from disk immediately and permanently (no Trash), together with their ×2/×4 upscales.")
                    }
                    Button("Done") { vm.exitSelectionMode() }
                        .buttonStyle(FxGhostButtonStyle(height: 30, accentText: true))
                } else {
                    Button { vm.enterSelectionMode() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle").font(.system(size: 12))
                            Text("Select")
                        }
                    }
                    .buttonStyle(FxGhostButtonStyle(height: 30, accentText: false))
                    .disabled(vm.generations.isEmpty).opacity(vm.generations.isEmpty ? 0.45 : 1)
                    .help("Pick several images to export or delete together. Tip: you can also Shift-click or ⌘-click a photo directly.")
                    Button("Open folder") { vm.revealFolder() }
                        .buttonStyle(FxGhostButtonStyle(height: 30, accentText: false))
                        .help("Open the output folder in Finder: \(AppPaths.images.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                    Button { confirmDeleteAll = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash").font(.system(size: 12))
                            Text("Delete all")
                        }
                    }
                    .buttonStyle(FxSecondaryButtonStyle(height: 30, accentText: true))
                    .disabled(vm.generations.isEmpty || UpscaleService.isBusy)
                    .opacity(vm.generations.isEmpty ? 0.45 : 1)
                    .help("Delete every image in the gallery — permanent, no Trash (asks for confirmation first)")
                    .confirmationDialog(
                        "Delete all \(vm.generations.count) images?",
                        isPresented: $confirmDeleteAll, titleVisibility: .visible
                    ) {
                        Button("Delete all", role: .destructive) { vm.deleteAll() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Files are removed from disk immediately and permanently — they do not go to the Trash. Upscaled ×2/×4 copies are swept too.")
                    }
                }
            }
            .padding(.bottom, vm.selectionMode ? 8 : 16)

            // In-mode instruction — the multi-select interaction was undiscoverable on its own.
            if vm.selectionMode {
                Text("Click images to select them. Shift-click to select a range.")
                    .font(.fx(11)).foregroundStyle(Color.fxText3)
                    .padding(.bottom, 12)
            }

            // Action-time refusal from the VM (e.g. delete blocked while an upscale is writing
            // into the gallery) — the buttons' .disabled(UpscaleService.isBusy) is cosmetic and
            // can go stale mid-batch, so the VM's gate needs a visible voice here.
            if let err = vm.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 10))
                    Text(err)
                }
                .font(.fx(11)).foregroundStyle(Color.fxDanger)
                .padding(.bottom, 12)
            }

            // ONE visible evaluation per body pass — it's a full filter scan of the store.
            // The filter bar's "N of M" readout shares it too (it used to run a second full pass).
            let shown = vm.visible

            if !vm.generations.isEmpty { filterBar(shownCount: shown.count).padding(.bottom, 12) }

            if vm.generations.isEmpty {
                emptyState
            } else if shown.isEmpty {
                noMatches
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(shown) { gen in
                            // Selection state is passed in PRECOMPUTED: a cell reading
                            // vm.selectedIDs itself made every visible cell observation-invalidate
                            // on each click (one toggle re-rendered the whole grid).
                            GalleryCell(gen: gen, vm: vm,
                                        selectionMode: vm.selectionMode,
                                        isSelected: vm.selectionMode && vm.selectedIDs.contains(gen.id),
                                        onRemix: onRemix)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.fxBg)
        .task { vm.reload() }
        .sheet(item: $vm.selected) { gen in
            GenerationDetailView(gen: gen, vm: vm, onRemix: onRemix)
        }
    }

    /// Hand the selected images to the shared queue as upscale tasks (grid order preserved).
    private func queueSelectedUpscales(factor: Int) {
        let urls = vm.visible.filter { vm.selectedIDs.contains($0.id) }.map(\.imageURL)
        guard !urls.isEmpty else { return }
        vm.exitSelectionMode()
        onQueueUpscales(urls, factor)
    }

    // MARK: Search & filters

    /// `shownCount` = vm.visible.count from the body's single evaluation — do NOT re-read
    /// vm.visible here (that was a second full filter scan per body pass).
    private func filterBar(shownCount: Int) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Color.fxText3)
                TextField("Search prompt, LoRA or seed…", text: $vm.searchText)
                    .textFieldStyle(.plain).font(.fx(12)).foregroundStyle(Color.fxText)
                if !vm.searchText.isEmpty {
                    Button { vm.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Color.fxText3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 10).fxInsetField()
            .frame(maxWidth: 280)

            if vm.tiersPresent.count > 1 {
                filterMenu(label: "Model",
                           value: vm.filterTier.flatMap { ModelTier(rawValue: $0)?.shortName ?? $0 },
                           options: vm.tiersPresent.map { ($0, ModelTier(rawValue: $0)?.shortName ?? $0) },
                           selection: $vm.filterTier)
            }
            if !vm.lorasPresent.isEmpty {
                filterMenu(label: "LoRA",
                           value: vm.filterLoRA,
                           options: vm.lorasPresent.map { ($0, $0) },
                           selection: $vm.filterLoRA)
            }
            if vm.qualitiesPresent.count > 1 {
                filterMenu(label: "Quality",
                           value: vm.filterQuality.flatMap { QualityPreset(rawValue: $0)?.label ?? $0 },
                           options: vm.qualitiesPresent.map { ($0, QualityPreset(rawValue: $0)?.label ?? $0) },
                           selection: $vm.filterQuality)
            }
            if vm.hasActiveFilters {
                Text("\(shownCount) of \(vm.generations.count)")
                    .font(.fxMono(10.5)).foregroundStyle(Color.fxAccent)
                Button("Clear") { vm.clearFilters() }
                    .buttonStyle(FxGhostButtonStyle(height: 26, accentText: true))
            }
            Spacer()
        }
    }

    /// One filter chip-menu: "Label · value ⌄" with an "All" reset entry.
    private func filterMenu(label: String, value: String?,
                            options: [(raw: String, display: String)],
                            selection: Binding<String?>) -> some View {
        Menu {
            Button("All") { selection.wrappedValue = nil }
            Divider()
            ForEach(options, id: \.raw) { opt in
                Button(opt.display) { selection.wrappedValue = opt.raw }
            }
        } label: {
            HStack(spacing: 5) {
                Text(label).font(.fx(11)).foregroundStyle(Color.fxText3)
                Text(value ?? "All").font(.fxMono(11)).foregroundStyle(value == nil ? Color.fxText2 : Color.fxAccent)
                    .lineLimit(1).frame(maxWidth: 160)
                Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(Color.fxText3)
            }
            .padding(.vertical, 5).padding(.horizontal, 9)
            .background(Color.fxInset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
        .fixedSize()
    }

    private var noMatches: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32)).foregroundStyle(Color.fxText3.opacity(0.7))
            Text("No matches").font(.fx(14, weight: .semibold)).foregroundStyle(Color.fxText2)
            Text("Nothing fits the current search/filters — \(vm.generations.count) image\(vm.generations.count == 1 ? "" : "s") total.")
                .font(.fx(12)).foregroundStyle(Color.fxText3)
            Button("Clear filters") { vm.clearFilters() }
                .buttonStyle(FxSecondaryButtonStyle(height: 30, accentText: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40)).foregroundStyle(Color.fxText3.opacity(0.7))
            Text("Nothing yet").font(.fx(14, weight: .semibold)).foregroundStyle(Color.fxText2)
            Text("Generate your first image on the Generate tab.")
                .font(.fx(12)).foregroundStyle(Color.fxText3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// File-drag provider — hands other apps the PNG itself (recipe chunk included).
private func dragProvider(for gen: Generation) -> NSItemProvider {
    guard FileManager.default.fileExists(atPath: gen.imageURL.path),
          let provider = NSItemProvider(contentsOf: gen.imageURL) else { return NSItemProvider() }
    provider.suggestedName = gen.imageFileName
    return provider
}

private struct GalleryCell: View {
    let gen: Generation
    @Bindable var vm: GalleryViewModel
    /// Selection state arrives PRECOMPUTED from the grid loop — the cell's body must not read
    /// vm.selectedIDs / vm.selectionMode (observation would invalidate ALL visible cells per
    /// click). vm is still used for actions (toggle/delete/thumbnail), which don't observe.
    let selectionMode: Bool
    let isSelected: Bool
    var onRemix: (Generation) -> Void
    @State private var thumb: NSImage?
    @State private var loadFailed = false
    @State private var hover = false
    @State private var confirmDelete = false

    var body: some View {
        Button {
            let mods = NSEvent.modifierFlags
            if vm.selectionMode {
                vm.toggleSelection(gen, shift: mods.contains(.shift))
            } else if mods.contains(.shift) || mods.contains(.command) {
                // Modifier-click outside selection mode jumps straight into multi-select,
                // so the user doesn't have to find "Select" first.
                vm.beginSelection(with: gen)
            } else {
                vm.selected = gen
            }
        } label: {
            // A fixed SQUARE cell with the image as a clipped overlay — the image never
            // participates in layout, so wide/tall thumbs can't push past the grid slot
            // (they used to overlap neighboring cells once non-square sizes appeared).
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let thumb {
                        Image(nsImage: thumb).resizable().scaledToFill()
                    } else if loadFailed {
                        // PNG missing or undecodable — a clear broken state, not an eternal spinner.
                        Color.fxInset.overlay(
                            VStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle")
                                Text("missing").font(.fxMono(9))
                            }
                            .foregroundStyle(Color.fxText2)
                        )
                    } else {
                        Color.fxInset.overlay(ProgressView().controlSize(.small))
                    }
                }
                .overlay(alignment: .bottom) {
                    if hover {
                        HStack(spacing: 6) {
                            FxDot(tone: .ok, size: 7)
                            Text("seed \(shortSeed(gen.seed)) · \(gen.width)×\(gen.height) · \(metaTail(gen))")
                                .font(.fxMono(9.5)).foregroundStyle(Color.fxText2).lineLimit(1)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.fxBorder, lineWidth: 1))
                .overlay {
                    if selectionMode {
                        ZStack(alignment: .topTrailing) {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(isSelected ? Color.fxAccent.opacity(0.14) : Color.black.opacity(0.05))
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(isSelected ? Color.fxAccent : Color.clear, lineWidth: 2.5)
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 18))
                                .foregroundStyle(isSelected ? Color.fxAccent : Color.white.opacity(0.85))
                                .background(Circle().fill(Color.black.opacity(0.4)))
                                .padding(7)
                        }
                    }
                }
                .shadow(color: .black.opacity(0.32), radius: 10, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(gen.prompt)
        .onDrag { dragProvider(for: gen) }
        .task(id: gen.id) {
            if let t = await vm.thumbnail(for: gen) { thumb = t; loadFailed = false }
            else { thumb = nil; loadFailed = true }
        }
        .contextMenu {
            Button("Remix in Generate") { onRemix(gen) }
            Button("Reveal in Finder") { vm.revealInFinder(gen) }
            // Block delete while an upscale runs: its finished _x2/_x4 output would otherwise
            // resurrect a "deleted" image as an un-indexed orphan after the delete sweep. isBusy
            // (not isRunning) also covers the one-time upscaler download phase.
            Button("Delete", role: .destructive) { confirmDelete = true }
                .disabled(UpscaleService.isBusy)
        }
        .confirmationDialog(
            "Delete this image?",
            isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { vm.delete(gen) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removed from disk immediately and permanently (no Trash), together with its ×2/×4 upscales.")
        }
    }

    private func shortSeed(_ seed: UInt64) -> String {
        let s = String(seed)
        guard s.count > 10 else { return s }
        return "\(s.prefix(4))…\(s.suffix(5))"
    }

    /// Tail of the hover meta — generation DURATION ("how long") when we have it, else "X ago".
    private func metaTail(_ gen: Generation) -> String {
        if let d = gen.durationSeconds { return durationText(d) }
        return "\(relTime(gen.createdAt)) ago"
    }

    private func durationText(_ s: Double) -> String {
        if s < 60 { return "\(Int(s.rounded()))s" }
        return "\(Int(s) / 60)m \(Int(s) % 60)s"
    }

    /// Compact time-ago, e.g. "12s" / "4m" / "3h" / "5d".
    private func relTime(_ date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "\(max(0, secs))s" }
        if secs < 3600 { return "\(secs / 60)m" }
        if secs < 86400 { return "\(secs / 3600)h" }
        return "\(secs / 86400)d"
    }
}

private struct GenerationDetailView: View {
    let gen: Generation
    @Bindable var vm: GalleryViewModel
    var onRemix: (Generation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isUpscaling = false
    @State private var upscaleMessage: String? = nil
    @State private var confirmDelete = false
    // Decoded ONCE per sheet — `vm.image(for:)` in body re-read the full-resolution PNG on
    // every body re-evaluation (each status message / hover change).
    @State private var fullImage: NSImage? = nil
    // Decode came back nil (PNG missing/undecodable) — a definitive broken state mirroring the
    // grid cell's, instead of the placeholder spinner spinning forever over a nil that will
    // never resolve.
    @State private var fullImageMissing = false
    // Flip-compare: index into referenceImagePaths currently shown instead of the result.
    @State private var flippedRef: Int? = nil
    @State private var flippedRefImage: NSImage? = nil

    private var createdLine: String {
        let when = gen.createdAt.formatted(date: .abbreviated, time: .shortened)
        var line = "Created \(when)"
        if let d = gen.durationSeconds {
            let dur = d < 60 ? "\(Int(d.rounded()))s" : "\(Int(d) / 60)m \(Int(d) % 60)s"
            line += " · generated in \(dur)"
        }
        if let sps = gen.secondsPerStep { line += String(format: " · %.1f s/step", sps) }
        if let peak = gen.peakRAMGB { line += String(format: " · peak %.1f GB", peak) }
        return line
    }

    /// "Klein 4B · Best · seed … · 1024×1024 · 15 steps · g1.0" — Quality shown when recorded
    /// (older records have none). Built as a plain String so the optional Quality can be omitted.
    private func detailLine(_ gen: Generation) -> String {
        var parts = [ModelTier(rawValue: gen.modelTier)?.shortName ?? gen.modelTier]
        if let q = gen.quality, let label = QualityPreset(rawValue: q)?.label { parts.append(label) }
        parts.append("seed \(gen.seed)")
        parts.append("\(gen.width)×\(gen.height)")
        parts.append("\(gen.steps) steps")
        parts.append("g\(String(format: "%.1f", gen.guidance))")
        if let iter = iterationLabel(gen) { parts.append(iter) }
        return parts.joined(separator: " · ")
    }

    /// "iteration 2/5" when this exact prompt has several renders (variations by seed), else nil.
    /// Position is by creation order (oldest = 1) among same-prompt records in the gallery.
    private func iterationLabel(_ gen: Generation) -> String? {
        let siblings = vm.generations.filter { $0.prompt == gen.prompt }
        guard siblings.count > 1 else { return nil }
        let ordered = siblings.sorted { $0.createdAt < $1.createdAt }
        guard let idx = ordered.firstIndex(where: { $0.id == gen.id }) else { return nil }
        return "iteration \(idx + 1)/\(ordered.count)"
    }

    /// FluxForge-style large chevron overlaid on the image edge — pages prev/next.
    /// Hidden at the ends (and while an upscale runs). The bottom ‹ › + arrow keys still work too.
    @ViewBuilder private func sideNavArrow(isNext: Bool) -> some View {
        if (isNext ? vm.canSelectNext : vm.canSelectPrevious) && !isUpscaling {
            Button { isNext ? vm.selectNext() : vm.selectPrevious() } label: {
                Image(systemName: isNext ? "chevron.right" : "chevron.left")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.45), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(10)
            .help(isNext ? "Next image (→)" : "Previous image (←)")
        }
    }

    // Long prompts (e.g. pasted VLM descriptions) used to grow past the sheet and
    // paint over the metadata and buttons — cap them in a scrollable box instead.
    // Short prompts keep the plain compact layout.
    @ViewBuilder private var promptBlock: some View {
        if gen.prompt.count > 360 {
            ScrollView {
                Text(gen.prompt).font(.fx(13)).foregroundStyle(Color.fxText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 150)
            .fxInsetField(radius: 8)
        } else {
            Text(gen.prompt).font(.fx(13)).foregroundStyle(Color.fxText).textSelection(.enabled)
        }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(gen.prompt, forType: .string)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "doc.on.doc").font(.system(size: 10))
                Text("Copy prompt").font(.fx(11))
            }
        }
        .buttonStyle(FxGhostButtonStyle(height: 22))
        .help("Copy the full prompt to the clipboard")
        if let enhanced = gen.enhancedPrompt, !enhanced.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(Color.fxAccent)
                    Text("Enhanced prompt — what the model actually saw")
                        .font(.fx(10.5, weight: .semibold)).foregroundStyle(Color.fxAccent)
                }
                Text(enhanced).font(.fx(12)).foregroundStyle(Color.fxText2)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.fxAccentSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            // Height-capped: an unconstrained portrait image (912×1152 from the aspect
            // chips) used to blow the sheet past the screen and push the buttons out of
            // sight (user screenshots, v0.43).
            // While a flip is pending (reference still decoding) fall through to the placeholder —
            // showing the RESULT under a highlighted "showing reference" chip lies for a beat.
            if let img = (flippedRef != nil ? flippedRefImage : fullImage) {
                Image(nsImage: img).resizable().scaledToFit()
                    .frame(maxHeight: 470)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .leading) { sideNavArrow(isNext: false) }
                    .overlay(alignment: .trailing) { sideNavArrow(isNext: true) }
                    .overlay(alignment: .bottomLeading) { refFlipStrip }
                    // Drag exports what's DISPLAYED — the reference file while flipped.
                    .onDrag {
                        if let i = flippedRef, let paths = gen.referenceImagePaths, paths.indices.contains(i),
                           let p = NSItemProvider(contentsOf: URL(fileURLWithPath: paths[i])) {
                            p.suggestedName = (paths[i] as NSString).lastPathComponent
                            return p
                        }
                        return dragProvider(for: gen)
                    }
                    .help(flippedRef == nil
                          ? "Drag the image out — into Finder, a chat, an editor… The PNG carries the full recipe; drop it back on the canvas later to restore it"
                          : "Showing the reference — click its thumbnail again for the result. Dragging exports the reference file.")
            } else if fullImageMissing && flippedRef == nil {
                // File missing on disk — mirrors the grid cell's broken state (a Finder-deleted
                // PNG opened from a stale record). Repair Library on the System tab prunes these.
                Color.fxInset
                    .frame(height: 470)
                    .overlay(
                        VStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle").font(.system(size: 24))
                            Text("Image file missing").font(.fx(12, weight: .semibold))
                            Text("The PNG was moved or deleted outside the app — System → Repair Library cleans up such records.")
                                .font(.fx(10.5)).multilineTextAlignment(.center).frame(maxWidth: 340)
                        }
                        .foregroundStyle(Color.fxText2)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .leading) { sideNavArrow(isNext: false) }
                    .overlay(alignment: .trailing) { sideNavArrow(isNext: true) }
            } else {
                Color.fxInset
                    .frame(height: 470)
                    .overlay(ProgressView().controlSize(.small))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 5) {
                promptBlock
                // String(seed): Text's number interpolation adds locale commas, which the Seed
                // field couldn't parse back. Selectable so the seed can be copied for a re-run.
                // Prettify the stored rawValue ("klein4B" → "Klein 4B"); unknown legacy strings display as-is.
                Text(detailLine(gen))
                    .font(.fxMono(11)).foregroundStyle(Color.fxText3)
                    .textSelection(.enabled)
                Text(createdLine).font(.fxMono(10.5)).foregroundStyle(Color.fxText3)
                if !gen.loraSummary.isEmpty {
                    Text("LoRA: \(gen.loraSummary.joined(separator: "  +  "))")
                        .font(.fxMono(10.5)).foregroundStyle(Color.fxText3)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !gen.referenceNames.isEmpty {
                    Text("Reference\(gen.referenceNames.count > 1 ? "s" : ""): \(gen.referenceNames.joined(separator: ", "))")
                        .font(.fxMono(10.5)).foregroundStyle(Color.fxAccent)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                // ‹ position › — the sheet is item-bound, so stepping the selection flips
                // it in place (arrow keys work too).
                Button { vm.selectPrevious() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(FxSecondaryButtonStyle(height: 30))
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(!vm.canSelectPrevious || isUpscaling)
                    .help("Previous image (←)")
                if let pos = vm.positionText(of: gen) {
                    Text(pos).font(.fxMono(10.5)).foregroundStyle(Color.fxText3)
                }
                Button { vm.selectNext() } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(FxSecondaryButtonStyle(height: 30))
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(!vm.canSelectNext || isUpscaling)
                    .help("Next image (→)")
                Button("Remix") { dismiss(); onRemix(gen) }
                    .buttonStyle(FxSecondaryButtonStyle(height: 30, accentText: true))
                    .disabled(isUpscaling)
                    .help("Load this image's full recipe — prompt, seed, size, model, LoRA, references — back into the Generate form, replacing the current settings")
                // Short labels — the buttons must fit the sheet without truncating into
                // "Upscale…/Upscalin…"; the live "Upscaling ×N…" status shows below instead.
                Button("Finder") { vm.revealInFinder(gen) }
                    .buttonStyle(FxSecondaryButtonStyle(height: 30))
                    .help("Reveal this PNG in Finder")
                Button("×2") { upscale(scale: 2) }
                    .buttonStyle(FxSecondaryButtonStyle(height: 30))
                    .disabled(isUpscaling)
                    .help("Upscale ×2 with Real-ESRGAN — saves a separate <name>_x2.png next to the original (kept). First use downloads the upscaler (~50 MB, one time)")
                Button("×4") { upscale(scale: 4) }
                    .buttonStyle(FxSecondaryButtonStyle(height: 30))
                    .disabled(isUpscaling)
                    .help("Upscale ×4 with Real-ESRGAN — saves a separate <name>_x4.png next to the original (kept). First use downloads the upscaler (~50 MB, one time)")
                Button { confirmDelete = true } label: {
                    HStack(spacing: 6) { Image(systemName: "trash"); Text("Delete") }
                }
                .buttonStyle(FxSecondaryButtonStyle(height: 30, accentText: true))
                // Don't delete while THIS image's upscale (or the one-time upscaler download) is in
                // flight — the _x2/_x4 output would land after the sweep and orphan on disk.
                .disabled(isUpscaling || UpscaleService.isBusy)
                .help("Delete this image from disk — permanent, no Trash; its ×2/×4 upscales go too (asks for confirmation)")
                .confirmationDialog(
                    "Delete this image?",
                    isPresented: $confirmDelete, titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) { vm.delete(gen); dismiss() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Removed from disk immediately and permanently (no Trash), together with its ×2/×4 upscales.")
                }
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(FxPrimaryButtonStyle(height: 30))
                    .keyboardShortcut(.cancelAction)
                    .help("Close (Esc)")
            }
            if let msg = upscaleMessage {
                Text(msg).font(.fx(11)).foregroundStyle(Color.fxText3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        // Fixed width: the action row (now 9 controls with Remix) truncated into
        // "Re…/D…/Cl…" at the old 560-min — 680 fits every label with room to spare,
        // and a fixed width keeps the sheet shape identical for every aspect ratio.
        .frame(width: 680)
        .frame(minHeight: 540)
        .background(Color.fxBg)
        // Synchronous per-record reset (same transaction as the ‹ › step) — the async .task
        // variant painted the PREVIOUS record's reference/result for a frame under the NEW
        // record's metadata. onChange doesn't fire on first presentation; initial state is nil anyway.
        .onChange(of: gen.id) {
            upscaleMessage = nil
            fullImage = nil
            fullImageMissing = false   // the neighbour may exist even if this one didn't
            flippedRef = nil
            flippedRefImage = nil
        }
        .task(id: gen.id) {
            let img = await vm.image(for: gen)
            // ‹ › may have moved on while this decoded — a stale result must not paint the
            // WRONG image under the new record's metadata.
            guard !Task.isCancelled else { return }
            fullImage = img
            fullImageMissing = (img == nil)   // nil never resolves — show broken, not an eternal spinner
        }
        .task(id: flippedRef) {
            flippedRefImage = nil   // an A→B flip must not show A's image under B's highlight
            guard let i = flippedRef, let paths = gen.referenceImagePaths, paths.indices.contains(i) else { return }
            let url = URL(fileURLWithPath: paths[i])
            let img = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: url) }.value
            guard !Task.isCancelled else { return }
            flippedRefImage = img
            if img == nil { upscaleMessage = "Reference not found — the file was moved or deleted." ; flippedRef = nil }
        }
    }

    /// Flip-compare strip on the detail image: one thumb per recorded I2I reference — click to
    /// show the reference IN PLACE of the result, click again to return. Paths are informational
    /// and may be stale; a missing file reports instead of flipping.
    @ViewBuilder private var refFlipStrip: some View {
        if let paths = gen.referenceImagePaths, !paths.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(paths.enumerated()), id: \.offset) { i, path in
                    Button {
                        flippedRef = (flippedRef == i) ? nil : i
                    } label: {
                        RefThumb(url: URL(fileURLWithPath: path))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(flippedRef == i ? Color.fxAccent : Color.white.opacity(0.35),
                                              lineWidth: flippedRef == i ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .help("Flip between this reference and the result in place — judge whether the fine identity survived.")
                }
                if flippedRef != nil {
                    Text("showing reference")
                        .font(.fxMono(9.5)).foregroundStyle(Color.fxText)
                        .fxChip(padV: 3, padH: 8)
                }
            }
            .padding(8)
        }
    }

    /// Small reference thumbnail loaded off-main (paths can point outside the app's folders).
    private struct RefThumb: View {
        let url: URL
        @State private var image: NSImage?
        var body: some View {
            Rectangle().fill(Color.fxInset)
                .frame(width: 36, height: 36)
                .overlay {
                    if let image { Image(nsImage: image).resizable().scaledToFill() }
                    else { Image(systemName: "photo").font(.system(size: 10)).foregroundStyle(Color.fxText3) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .task(id: url) { image = await WorkshopDatasetService.thumbnail(at: url, maxPixel: 96) }
        }
    }

    private func upscale(scale: Int) {
        isUpscaling = true
        upscaleMessage = nil
        Task { @MainActor in
            do {
                let out = try await UpscaleService.upscale(gen.imageURL, scale: scale,
                    onStatus: { msg in Task { @MainActor in upscaleMessage = msg } })
                // No auto-reveal in Finder — see GenerateViewModel.upscale (focus-steal).
                upscaleMessage = "Saved: \(out.lastPathComponent)"
                AppLog.info("Upscaled ×\(scale) (gallery): \(out.lastPathComponent)")
            } catch {
                upscaleMessage = "Upscale failed: \(error.localizedDescription)"
                AppLog.error("Upscale: \(error.localizedDescription)")
            }
            isUpscaling = false
        }
    }
}
