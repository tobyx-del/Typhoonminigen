import SwiftUI

/// Inline icon helper for the Library: one point size + an equal square footprint + monochrome,
/// so SF Symbols with different intrinsic metrics (triangle vs star vs play vs gamecontroller)
/// read at the same visual weight instead of looking "bigger/smaller than the others".
private extension Image {
    func fxIcon(_ size: CGFloat = 11) -> some View {
        self.font(.system(size: size, weight: .regular))
            .symbolRenderingMode(.monochrome)
            .frame(width: size + 4, height: size + 4)
    }
}

/// The Library — task-first browsing over the same chip engine. Studios → one-tap scene-recipes,
/// plus the honesty panel. One tap seeds the recipe's example subject into the prompt, applies its
/// chips, and jumps to Generate.
///
/// Editing: an Edit toggle turns on per-card and per-section delete. Built-in cards/studios are
/// HIDDEN (reversible via Restore all — `LibraryVisibilityStore`); the user's own cards are DELETED
/// permanently (`CustomRecipeStore`). "+ New card" opens the card editor.
struct LibraryView: View {
    @Bindable var vm: GenerateViewModel
    let goToGenerate: () -> Void
    var openQueue: () -> Void = {}

    @AppStorage("librarySelectedStudio") private var studioID = "cinema"
    @State private var showHonesty = false
    @State private var queueNote = ""   // transient "Added X — N in queue" feedback

    // Observing the stores so the grid re-renders when a card/studio is hidden, restored, or added.
    @State private var vis = LibraryVisibilityStore.shared
    @State private var customs = CustomRecipeStore.shared
    @State private var customStudios = CustomStudioStore.shared

    @State private var editMode = false
    @State private var confirmDeleteStudio: LibraryStudio?
    @State private var confirmDeleteCustomStudio: LibraryStudio?
    @State private var confirmHideRecipe: SceneRecipe?
    @State private var confirmDeleteCustom: SceneRecipe?
    @State private var confirmDeleteAll = false
    @State private var editorDraft: SceneRecipe?   // non-nil → the card editor sheet is up

    // ── Visibility-aware data ─────────────────────────────────────────────────────
    private var visibleStudios: [LibraryStudio] { LibraryCatalog.studios() }
    /// The studio actually shown: the saved selection if still visible, else the first visible one
    /// (nil only when the user deleted everything). Computed — never writes state during body.
    private var effectiveStudioID: String? {
        if visibleStudios.contains(where: { $0.id == studioID }) { return studioID }
        return visibleStudios.first?.id
    }
    private var recipes: [SceneRecipe] {
        guard let sid = effectiveStudioID else { return [] }
        return LibraryCatalog.recipes(in: sid)
    }
    private var currentStudio: LibraryStudio? {
        effectiveStudioID.flatMap { id in visibleStudios.first { $0.id == id } }
    }

    // chip id → label, over built-ins + the generated Library chips.
    private static let chipLabel: [String: String] =
        Dictionary(PromptPresets.all.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                studioRow
                queueBar
                if let err = vm.errorMessage, !err.isEmpty {
                    Text(err)
                        .font(.fx(11.5)).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !queueNote.isEmpty {
                    Text(queueNote)
                        .font(.fx(11.5)).foregroundStyle(Color.fxAccent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if showHonesty {
                    honestyPanel
                } else {
                    sceneGrid
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(
            "Hide “\(confirmHideRecipe?.title ?? "")”?",
            isPresented: Binding(get: { confirmHideRecipe != nil }, set: { if !$0 { confirmHideRecipe = nil } }),
            titleVisibility: .visible
        ) {
            Button("Hide card", role: .destructive) {
                if let r = confirmHideRecipe { vis.hideRecipe(r.id) }
                confirmHideRecipe = nil
            }
            Button("Cancel", role: .cancel) { confirmHideRecipe = nil }
        } message: { Text("It's removed from the Library but not deleted — use Restore all to bring it back.") }
        .confirmationDialog(
            "Delete “\(confirmDeleteCustom?.title ?? "")”?",
            isPresented: Binding(get: { confirmDeleteCustom != nil }, set: { if !$0 { confirmDeleteCustom = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete card", role: .destructive) {
                if let r = confirmDeleteCustom { customs.remove(r.id) }
                confirmDeleteCustom = nil
            }
            Button("Cancel", role: .cancel) { confirmDeleteCustom = nil }
        } message: { Text("This is your own card — deleting it is permanent.") }
        .confirmationDialog(
            "Delete this whole section?",
            isPresented: Binding(get: { confirmDeleteStudio != nil }, set: { if !$0 { confirmDeleteStudio = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete section", role: .destructive) {
                if let s = confirmDeleteStudio {
                    vis.hideStudio(s.id)
                    if studioID == s.id { studioID = LibraryCatalog.studios().first?.id ?? studioID }
                }
                confirmDeleteStudio = nil
            }
            Button("Cancel", role: .cancel) { confirmDeleteStudio = nil }
        } message: { Text("The whole “\(confirmDeleteStudio?.title ?? "")” section is hidden — use Restore all to bring it back.") }
        .confirmationDialog(
            "Delete your section “\(confirmDeleteCustomStudio?.title ?? "")”?",
            isPresented: Binding(get: { confirmDeleteCustomStudio != nil }, set: { if !$0 { confirmDeleteCustomStudio = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete section & its cards", role: .destructive) {
                if let s = confirmDeleteCustomStudio { deleteCustomSection(s) }
                confirmDeleteCustomStudio = nil
            }
            Button("Cancel", role: .cancel) { confirmDeleteCustomStudio = nil }
        } message: {
            let n = confirmDeleteCustomStudio.map { customs.recipes(in: $0.id).count } ?? 0
            Text("This is your own section. Deleting it permanently removes it and its \(n) card\(n == 1 ? "" : "s").")
        }
        .confirmationDialog(
            "Delete the entire Library?",
            isPresented: $confirmDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete everything", role: .destructive) { vis.hideEverything() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Every built-in card and section is hidden. Your own cards stay. Restore all brings the library back.") }
        .sheet(item: $editorDraft) { draft in
            CardEditorView(draft: draft) { saved in
                if customs.items.contains(where: { $0.id == saved.id }) { customs.update(saved) }
                else { customs.add(saved) }
                studioID = saved.studio
                editorDraft = nil
            } onCancel: { editorDraft = nil }
        }
    }

    // ── Header ────────────────────────────────────────────────────────────────
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Library").font(.fx(20, weight: .bold)).foregroundStyle(Color.fxText)
                Text("Pick what you want to make — one tap loads a ready scene into Generate. Edit the subject, then press Generate.")
                    .font(.fx(12)).foregroundStyle(Color.fxText3)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    Button { editorDraft = blankDraft() } label: {
                        HStack(spacing: 5) { Image(systemName: "plus").fxIcon(10); Text("New card") }
                    }
                    .buttonStyle(FxGhostButtonStyle(height: 28))
                    .help("Create your own preset card — a full scene you can reuse and queue like the built-ins.")

                    editToggle
                        .help("Turn on delete controls for cards and sections.")
                }
                if vis.totalHiddenCount > 0 {
                    Button { vis.restoreAll() } label: {
                        Text("Restore all (\(vis.totalHiddenCount) hidden)")
                            .font(.fx(10)).foregroundStyle(Color.fxText3)
                    }
                    .buttonStyle(.plain)
                    .help("Bring back every card and section you hid.")
                }
                if editMode {
                    Button(role: .destructive) { confirmDeleteAll = true } label: {
                        Text("Delete all").font(.fx(10.5, weight: .semibold)).foregroundStyle(Color.fxDanger)
                    }
                    .buttonStyle(.plain)
                    .help("Hide the entire built-in library at once (reversible with Restore all).")
                }
            }
        }
    }

    private var editToggleLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: editMode ? "checkmark" : "trash").fxIcon(10)
            Text(editMode ? "Done" : "Edit")
        }
    }
    @ViewBuilder private var editToggle: some View {
        if editMode {
            Button { editMode.toggle() } label: { editToggleLabel }
                .buttonStyle(FxPrimaryButtonStyle(height: 28, fullWidth: false))
        } else {
            Button { editMode.toggle() } label: { editToggleLabel }
                .buttonStyle(FxGhostButtonStyle(height: 28))
        }
    }

    // ── Studio selector + honesty toggle ────────────────────────────────────────
    private var studioRow: some View {
        FxFlowLayout(spacing: 7, lineSpacing: 7) {
            ForEach(visibleStudios) { studio in
                studioChip(studio)
            }
            honestyChip
        }
    }

    // ── Queue bar — appears once you've added scenes; run or open without leaving ────────
    @ViewBuilder private var queueBar: some View {
        if !vm.queue.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet.rectangle").fxIcon().foregroundStyle(Color.fxAccent)
                Text(vm.queueRunning ? "Running — \(vm.queue.count) left" : "\(vm.queue.count) in queue")
                    .font(.fx(12, weight: .semibold)).foregroundStyle(Color.fxText)
                Spacer()
                if !vm.queueRunning {
                    Button { vm.runAll() } label: {
                        HStack(spacing: 6) { Image(systemName: "play.fill").fxIcon(10); Text("Run all") }
                    }
                    .buttonStyle(FxPrimaryButtonStyle(height: 28, fullWidth: false))
                    .help("Generate every queued task, one after another.")
                }
                Button { openQueue() } label: { Text("Open").font(.fx(11.5)) }
                    .buttonStyle(FxGhostButtonStyle(height: 28))
                    .help("Open the Queue tab to reorder, edit or remove tasks.")
            }
            .padding(.vertical, 9).padding(.horizontal, 12)
            .background(Color.fxInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.fxAccent.opacity(0.4), lineWidth: 1))
        }
    }

    private func studioChip(_ studio: LibraryStudio) -> some View {
        let active = !showHonesty && studio.id == effectiveStudioID
        return Button {
            showHonesty = false
            studioID = studio.id
            queueNote = ""
        } label: {
            HStack(spacing: 6) {
                Image(systemName: studio.icon).fxIcon()
                Text(studio.title).font(.fx(12, weight: active ? .semibold : .regular))
                if studio.badge == .yellow { FxDot(tone: .amber, size: 7) }
            }
            .foregroundStyle(active ? Color.fxText : Color.fxText2)
            .fxChip(accent: active, padV: 5, padH: 10)
        }
        .buttonStyle(.plain)
        .help(studio.priority == .top ? "Top-quality area for this model." : studio.title)
        .contextMenu {
            if CustomStudioStore.isCustom(studio.id) {
                Button(role: .destructive) { confirmDeleteCustomStudio = studio } label: {
                    Label("Delete this section", systemImage: "trash")
                }
            } else {
                Button(role: .destructive) { confirmDeleteStudio = studio } label: {
                    Label("Delete this section", systemImage: "trash")
                }
            }
        }
    }

    /// Delete a user-created section AND its cards (built-in sections are only hidden).
    private func deleteCustomSection(_ s: LibraryStudio) {
        for card in customs.recipes(in: s.id) { customs.remove(card.id) }
        customStudios.remove(s.id)
        if studioID == s.id { studioID = LibraryCatalog.studios().first?.id ?? studioID }
    }

    private var honestyChip: some View {
        Button { showHonesty.toggle(); queueNote = "" } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").fxIcon()
                Text("What this can't do").font(.fx(12, weight: showHonesty ? .semibold : .regular))
            }
            .foregroundStyle(showHonesty ? Color.fxDanger : Color.fxText3)
            .padding(.vertical, 5).padding(.horizontal, 10)
            .background(showHonesty ? Color.fxDangerSoft : Color.fxHover,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("An honest list of what FLUX can't deliver (text, icons, real 3D, charts…) — and what to do instead.")
    }

    // ── Scene grid ──────────────────────────────────────────────────────────────
    @ViewBuilder private var sceneGrid: some View {
        if visibleStudios.isEmpty {
            emptyLibrary
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if let s = currentStudio, s.badge == .yellow {
                    Label("These are believable images, not exportable assets — see the note on each card.",
                          systemImage: "info.circle")
                        .font(.fx(11)).foregroundStyle(.orange)
                }
                if recipes.isEmpty {
                    emptySection
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12, alignment: .top)],
                              alignment: .leading, spacing: 12) {
                        ForEach(recipes) { recipe in
                            sceneCard(recipe)
                        }
                    }
                }
            }
            .contextMenu {
                Button { editorDraft = blankDraft() } label: { Label("New card here", systemImage: "plus") }
            }
        }
    }

    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("The Library is empty", systemImage: "tray")
                .font(.fx(14, weight: .semibold)).foregroundStyle(Color.fxText)
            Text("You deleted every section. Bring them back, or start your own.")
                .font(.fx(12)).foregroundStyle(Color.fxText3)
            HStack(spacing: 8) {
                Button { vis.restoreAll() } label: { Text("Restore all") }
                    .buttonStyle(FxPrimaryButtonStyle(height: 30, fullWidth: false))
                Button { editorDraft = blankDraft() } label: { Text("New card") }
                    .buttonStyle(FxGhostButtonStyle(height: 30))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxCard(padding: 16)
    }

    private var emptySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nothing here yet — every card in this section is hidden, or you haven't added your own.")
                .font(.fx(12)).foregroundStyle(Color.fxText3)
            Button { editorDraft = blankDraft() } label: {
                HStack(spacing: 5) { Image(systemName: "plus").fxIcon(10); Text("New card") }
            }.buttonStyle(FxGhostButtonStyle(height: 28))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxCard(padding: 14)
    }

    /// Bundled preview thumbnail for a scene (built-in → Bundle.module/ScenePreviews/<id>.jpg;
    /// custom → the writable AppPaths.customRecipePreviews/<id>.jpg). nil → a placeholder.
    private static func previewURL(for id: String) -> URL? {
        if CustomRecipeStore.isCustom(id) {
            let u = AppPaths.customRecipePreview(for: id)
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
        guard let base = Bundle.module.resourceURL else { return nil }
        let u = base.appendingPathComponent("ScenePreviews/\(id).jpg")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Decoded covers shared by built-in AND custom cards. An NSCache (vs the old grow-only
    /// dictionary) evicts under memory pressure; cost = decoded-bitmap byte estimate. 24 MB holds
    /// every 320px cover in the library comfortably while still bounding the worst case.
    private static let previewCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    /// Cached decode for one card cover. The key carries `stamp` (CustomRecipeStore.previewStamp)
    /// so a custom cover rewritten mid-session keys a FRESH entry and the stale one just ages out
    /// of the NSCache — built-in previews are immutable and always pass 0. The JPEG decode itself
    /// (the expensive part) runs OFF the MainActor; the cache lookup and the tiny exists-stat stay
    /// on it (View statics are MainActor via the SwiftUI View protocol).
    private static func previewImage(for id: String, stamp: Int) async -> NSImage? {
        let key = "\(id)#\(stamp)" as NSString
        if let hit = previewCache.object(forKey: key) { return hit }
        guard let url = previewURL(for: id) else { return nil }
        guard let img = await Task.detached(priority: .userInitiated, operation: { NSImage(contentsOf: url) }).value
        else { return nil }
        let px = img.representations.first.map { $0.pixelsWide * $0.pixelsHigh }
            ?? Int(img.size.width * img.size.height)
        previewCache.setObject(img, forKey: key, cost: px * 4)
        return img
    }

    /// One card cover, loaded per cell like a Gallery cell (@State image + `.task(id:)` with the
    /// decode off-main) — switching studios used to decode 10–20 JPEGs synchronously inside ONE
    /// body pass, and custom covers re-statted + re-decoded on EVERY body re-eval (per queue tick).
    /// On a cache miss the plain placeholder shows for the frame or two a 320px jpg takes — no
    /// spinner needed at that size.
    private struct ScenePreview: View {
        let id: String
        /// CustomRecipeStore.previewStamp at build time (0 for built-ins) — a rewritten cover
        /// changes the task id, so the load re-fires and keys a fresh cache entry.
        let stamp: Int
        @State private var image: NSImage?

        var body: some View {
            // Fill the square and crop the overflow — EXACTLY like the Gallery grid — so previews
            // read clean with no black letterbox bars. The image is an overlay on a square
            // Color.clear, so a non-square thumb never participates in layout and can't push past
            // the grid slot.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Color.fxText3.opacity(0.10).overlay {
                            Image(systemName: "photo").fxIcon(22).foregroundStyle(Color.fxText3.opacity(0.5))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .task(id: "\(id)#\(stamp)") {
                    image = await LibraryView.previewImage(for: id, stamp: stamp)
                }
        }
    }

    private func sceneCard(_ recipe: SceneRecipe) -> some View {
        let isCustom = CustomRecipeStore.isCustom(recipe.id)
        return Button {
            vm.loadScene(recipe)
            goToGenerate()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Reading previewStamp here (only for custom cards) subscribes the body to cover
                // rewrites, so an edited cover refreshes without touching the built-ins' cache keys.
                ScenePreview(id: recipe.id, stamp: isCustom ? customs.previewStamp : 0)
                HStack(alignment: .top, spacing: 6) {
                    FxDot(tone: recipe.badge == .yellow ? .amber : .ok, size: 6)
                        .padding(.top, 3)
                    Text(recipe.title).font(.fx(13, weight: .semibold)).foregroundStyle(Color.fxText)
                        .lineLimit(2, reservesSpace: true)
                    Spacer(minLength: 0)
                }
                Text("“\(recipe.subjectExample)”")
                    .font(.fx(11.5)).foregroundStyle(Color.fxText2)
                    .italic().lineLimit(2, reservesSpace: true)
                Text(chipSummary(recipe.chipIDs))
                    .font(.fx(10)).foregroundStyle(Color.fxText3).lineLimit(1, reservesSpace: true)
                Text(recipe.note)
                    .font(.fx(10.5)).foregroundStyle(recipe.badge == .yellow ? .orange : Color.fxText3)
                    .lineLimit(3, reservesSpace: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fxCard(padding: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {
            if isCustom {
                Text("YOURS")
                    .font(.fx(8, weight: .bold)).tracking(0.6)
                    .foregroundStyle(Color.fxAccent)
                    .padding(.vertical, 2).padding(.horizontal, 5)
                    .background(Color.black.opacity(0.5), in: Capsule())
                    .padding(8)
            }
        }
        .help("\(recipe.note)\n\nTap to load this scene into Generate (edit the subject, then Generate or Add to queue).")
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 7) {
                if editMode {
                    if isCustom {
                        overlayIcon("pencil", Color.fxText) { editorDraft = recipe }
                            .help("Edit this card.")
                        overlayIcon("trash.fill", Color.fxDanger) { confirmDeleteCustom = recipe }
                            .help("Delete this card permanently.")
                    } else {
                        overlayIcon("trash.fill", Color.fxDanger) { confirmHideRecipe = recipe }
                            .help("Hide this card (restorable).")
                    }
                } else {
                    if recipe.featured {
                        Image(systemName: "star.fill").fxIcon(10).foregroundStyle(Color.fxAccent)
                    }
                    Button {
                        let n = vm.enqueueScene(recipe)
                        queueNote = "Added “\(recipe.title)” — \(n) in queue"
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.fxAccent)
                            .background(Circle().fill(.black.opacity(0.45)).padding(2))
                    }
                    .buttonStyle(.plain)
                    .help("Add this scene to the queue without leaving — line up several, then Run all.")
                }
            }
            .padding(10)
        }
        .contextMenu {
            if isCustom {
                Button { editorDraft = recipe } label: { Label("Edit card", systemImage: "pencil") }
                Button(role: .destructive) { confirmDeleteCustom = recipe } label: { Label("Delete card", systemImage: "trash") }
            } else {
                Button {
                    let n = vm.enqueueScene(recipe)
                    queueNote = "Added “\(recipe.title)” — \(n) in queue"
                } label: { Label("Add to queue", systemImage: "plus") }
                Button(role: .destructive) { confirmHideRecipe = recipe } label: { Label("Hide card", systemImage: "trash") }
            }
        }
    }

    private func overlayIcon(_ system: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.black.opacity(0.5)))
        }
        .buttonStyle(.plain)
    }

    private func chipSummary(_ ids: [String]) -> String {
        ids.compactMap { Self.chipLabel[$0] }.joined(separator: " · ")
    }

    /// A fresh blank card seeded into the currently-viewed studio.
    private func blankDraft() -> SceneRecipe {
        SceneRecipe(id: CustomRecipeStore.newID(),
                    studio: effectiveStudioID ?? PromptPresetLibrary.studios.first?.id ?? "cinema",
                    title: "", subjectExample: "", chipIDs: [], note: "", badge: .green, featured: false)
    }

    // ── Honesty panel ───────────────────────────────────────────────────────────
    private var honestyPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What this app can't do — and what to use instead")
                .font(.fx(14, weight: .bold)).foregroundStyle(Color.fxText)
            Text("FLUX makes images, not assets. Here's where it falls short, honestly — so you don't waste a render.")
                .font(.fx(11.5)).foregroundStyle(Color.fxText3)
            ForEach(PromptPresetLibrary.redPanel) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.octagon.fill").fxIcon().foregroundStyle(Color.fxDanger)
                        Text(row.trap).font(.fx(12.5, weight: .semibold)).foregroundStyle(Color.fxText)
                    }
                    if !row.who.isEmpty {
                        Text(row.who).font(.fx(10.5)).foregroundStyle(Color.fxText3)
                    }
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "arrow.turn.down.right").fxIcon().foregroundStyle(Color.fxOk)
                        Text(row.reframe).font(.fx(11.5)).foregroundStyle(Color.fxText2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fxCard(padding: 12)
            }
        }
    }
}
