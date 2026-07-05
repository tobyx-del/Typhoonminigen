import Foundation
import Observation

/// Owns which built-in Library preset cards + whole studios the user has "deleted".
///
/// The 200 recipes and 19 studios live in code (`PromptPresetLibrary`), so a delete is really a
/// reversible HIDE: we persist a set of hidden ids and filter them out at query time. "Restore all"
/// just clears the sets — nothing is ever destroyed. Mirrors `CustomPresetStore`'s hidden-chip half
/// exactly (two `Set<String>` in UserDefaults, cleared by Remove-all-data).
@MainActor
@Observable
final class LibraryVisibilityStore {
    static let shared = LibraryVisibilityStore()

    private(set) var hiddenRecipeIDs: Set<String> = []
    private(set) var hiddenStudioIDs: Set<String> = []

    private static let recipeKey = "hiddenLibraryRecipeIDs"
    private static let studioKey = "hiddenLibraryStudioIDs"

    init() {
        hiddenRecipeIDs = Set(UserDefaults.standard.array(forKey: Self.recipeKey) as? [String] ?? [])
        hiddenStudioIDs = Set(UserDefaults.standard.array(forKey: Self.studioKey) as? [String] ?? [])
    }

    /// How many separate things are hidden — drives the "Restore all (N)" affordance. A whole-studio
    /// hide counts once (not once per member card).
    var totalHiddenCount: Int { hiddenRecipeIDs.count + hiddenStudioIDs.count }

    func hideRecipe(_ id: String) { hiddenRecipeIDs.insert(id); persistRecipes() }
    func hideStudio(_ id: String) { hiddenStudioIDs.insert(id); persistStudios() }

    /// "Delete all" — the user chose a FULLY empty Library, so hide every built-in card AND every
    /// studio section. Only "Restore all" brings them back.
    func hideEverything() {
        hiddenRecipeIDs = Set(PromptPresetLibrary.recipes.map(\.id))
        hiddenStudioIDs = Set(PromptPresetLibrary.studios.map(\.id))
        persistRecipes(); persistStudios()
    }

    /// Bring back everything — the guaranteed recovery, always reachable from the header.
    func restoreAll() {
        hiddenRecipeIDs = []; hiddenStudioIDs = []
        persistRecipes(); persistStudios()
    }

    /// Drop in-memory state for Remove-all-data. Does NOT re-persist (the wipe already cleared both
    /// UserDefaults keys); a write here would resurrect them — same rationale as `CustomPresetStore.reset`.
    func reset() { hiddenRecipeIDs = []; hiddenStudioIDs = [] }

    private func persistRecipes() { UserDefaults.standard.set(Array(hiddenRecipeIDs), forKey: Self.recipeKey) }
    private func persistStudios() { UserDefaults.standard.set(Array(hiddenStudioIDs), forKey: Self.studioKey) }
}

/// Single lookup surface the Library reads through — built-in cards/studios minus the user's hidden
/// set (Task 1), plus the user's own custom cards (Task 2). Mirrors `PresetCatalog` for chips so both
/// features ride one accessor.
@MainActor
enum LibraryCatalog {
    /// Studios shown in the selector: built-ins the user hasn't deleted, PLUS any studio that holds
    /// at least one of the user's own cards (so a custom card is never stranded in a hidden section),
    /// PLUS the user's own sections.
    static func studios() -> [LibraryStudio] {
        let hidden = LibraryVisibilityStore.shared.hiddenStudioIDs
        let studiosWithCustom = Set(CustomRecipeStore.shared.items.map(\.studio))
        let builtins = PromptPresetLibrary.studios.filter { !hidden.contains($0.id) || studiosWithCustom.contains($0.id) }
        return builtins + CustomStudioStore.shared.asStudios
    }

    /// Cards in a studio: visible built-ins + the user's own cards filed under it. A hidden studio
    /// (deleted as a whole, but kept on screen because it still holds custom cards) shows ONLY those
    /// custom cards — its built-ins stay deleted.
    static func recipes(in studioID: String) -> [SceneRecipe] {
        let vis = LibraryVisibilityStore.shared
        let builtin = vis.hiddenStudioIDs.contains(studioID)
            ? []
            : PromptPresetLibrary.recipes.filter { $0.studio == studioID && !vis.hiddenRecipeIDs.contains($0.id) }
        return builtin + CustomRecipeStore.shared.recipes(in: studioID)
    }
}
