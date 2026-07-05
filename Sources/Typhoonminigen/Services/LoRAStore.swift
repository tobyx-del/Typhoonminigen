import Foundation

/// Owns the LoRA folder: discover, import (copy in), delete, and per-LoRA trigger words
/// (stored in a small `.triggers.json` so the user never has to remember them).
actor LoRAStore {
    private var triggersURL: URL { AppPaths.loras.appendingPathComponent(".triggers.json") }
    private var defaultScalesURL: URL { AppPaths.loras.appendingPathComponent(".default-scales.json") }
    private var cardsURL: URL { AppPaths.loras.appendingPathComponent(".cards.json") }

    /// Decode a sidecar dict; if the file EXISTS but won't decode, move it aside to a
    /// timestamped quarantine BEFORE returning [:]. Every mutation here is load → mutate →
    /// save, so a silent [:] from one corrupt read meant the very next edit atomically
    /// OVERWROTE the user's only copy of all triggers/scales/cards with a near-empty dict.
    /// Quarantines keep the newest 3 per sidecar (bounded disk, enough evidence to recover
    /// by hand); names stay dot-prefixed so discover()/Finder never see them.
    private func loadSidecar<V: Decodable>(_ type: [String: V].Type, at url: URL) -> [String: V] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }   // no file yet — normal
        if let dict = try? JSONDecoder().decode([String: V].self, from: data) { return dict }
        let fm = FileManager.default
        let name = url.lastPathComponent                       // e.g. ".triggers.json"
        let quarantine = url.deletingLastPathComponent()
            .appendingPathComponent("\(name).corrupt.\(Int(Date().timeIntervalSince1970))")
        try? fm.moveItem(at: url, to: quarantine)
        // Prune: epoch stamp is fixed-width until 2286, so a lexicographic sort is newest-first.
        if let stale = try? fm.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter({ $0.lastPathComponent.hasPrefix("\(name).corrupt.") })
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
            .dropFirst(3) {
            for f in stale { try? fm.removeItem(at: f) }
        }
        AppLog.error("\(name) unreadable — moved aside as \(quarantine.lastPathComponent); starting empty (recover the old values from the quarantined copy)")
        return [:]
    }

    private func loadTriggers() -> [String: String] {
        loadSidecar([String: String].self, at: triggersURL)
    }

    @discardableResult
    private func saveTriggers(_ dict: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(dict) else { return false }
        do { try data.write(to: triggersURL, options: .atomic); return true }
        catch { return false }
    }

    // Per-adapter sweet-spot strength (mirrors the triggers sidecar).
    private func loadDefaultScales() -> [String: Float] {
        loadSidecar([String: Float].self, at: defaultScalesURL)
    }

    @discardableResult
    private func saveDefaultScales(_ dict: [String: Float]) -> Bool {
        guard let data = try? JSONEncoder().encode(dict) else { return false }
        do { try data.write(to: defaultScalesURL, options: .atomic); return true }
        catch { return false }
    }

    /// Save (or clear, if nil) the strength Generate pre-selects when this adapter is added.
    @discardableResult
    func setDefaultScale(_ scale: Float?, forFileName name: String) -> Bool {
        var dict = loadDefaultScales()
        if let s = scale { dict[name] = min(max(s, 0), 1.5) } else { dict.removeValue(forKey: name) }
        return saveDefaultScales(dict)
    }

    // Per-adapter identity cards (description / added date / provenance) — third sidecar.
    private func loadCards() -> [String: LoRACardInfo] {
        loadSidecar([String: LoRACardInfo].self, at: cardsURL)
    }

    @discardableResult
    private func saveCards(_ dict: [String: LoRACardInfo]) -> Bool {
        guard let data = try? JSONEncoder().encode(dict) else { return false }
        do { try data.write(to: cardsURL, options: .atomic); return true }
        catch { return false }
    }

    /// Set (or clear, if empty) the free-text description for a LoRA file.
    @discardableResult
    func setAbout(_ text: String, forFileName name: String) -> Bool {
        var dict = loadCards()
        var card = dict[name] ?? LoRACardInfo()
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        card.about = t.isEmpty ? nil : String(t.prefix(500))
        if card.isEmpty { dict.removeValue(forKey: name) } else { dict[name] = card }
        return saveCards(dict)
    }

    /// Merge non-nil fields into the adapter's card, stamping `addedAt` on first write.
    /// Used by import / URL import / bake / merge to record provenance without clobbering
    /// whatever the user already typed into the description.
    @discardableResult
    func annotate(fileName: String, about: String? = nil,
                  provenance: String? = nil, sourceRunID: String? = nil) -> Bool {
        var dict = loadCards()
        var card = dict[fileName] ?? LoRACardInfo()
        if card.addedAt == nil { card.addedAt = Date() }
        if let about, !about.isEmpty, (card.about?.isEmpty ?? true) { card.about = String(about.prefix(500)) }
        if let provenance, !provenance.isEmpty { card.provenance = String(provenance.prefix(300)) }
        if let sourceRunID, !sourceRunID.isEmpty { card.sourceRunID = sourceRunID }
        dict[fileName] = card
        return saveCards(dict)
    }

    func discover() -> [LoRAItem] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: AppPaths.loras, includingPropertiesForKeys: nil) else {
            return []
        }
        let files = urls.filter {
            $0.pathExtension.lowercased() == "safetensors" && !$0.lastPathComponent.hasPrefix(".")
        }
        // Self-heal the sidecars: drop entries whose .safetensors was deleted outside
        // the app (in-app delete already prunes; Finder deletes used to leave keys forever).
        var stored = loadTriggers()
        let names = Set(files.map(\.lastPathComponent))
        let stale = stored.keys.filter { !names.contains($0) }
        if !stale.isEmpty {
            for key in stale { stored.removeValue(forKey: key) }
            saveTriggers(stored)
        }
        var scales = loadDefaultScales()
        let staleScales = scales.keys.filter { !names.contains($0) }
        if !staleScales.isEmpty {
            for key in staleScales { scales.removeValue(forKey: key) }
            saveDefaultScales(scales)
        }
        var cards = loadCards()
        let staleCards = cards.keys.filter { !names.contains($0) }
        if !staleCards.isEmpty {
            for key in staleCards { cards.removeValue(forKey: key) }
            saveCards(cards)
        }
        // Model-card FOLDERS are keyed by filename too — a Finder-deleted adapter leaves its
        // `.cards/<name>/` behind forever, and a later same-named import would inherit the wrong
        // card (recipe, loss curve, validation images). Sweep orphans alongside the sidecars.
        if let cardDirs = try? fm.contentsOfDirectory(at: AppPaths.loraCards, includingPropertiesForKeys: nil) {
            for dir in cardDirs
            where dir.lastPathComponent.lowercased().hasSuffix(".safetensors") && !names.contains(dir.lastPathComponent) {
                try? fm.removeItem(at: dir)
            }
        }
        return files
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map { item(for: $0, stored: stored, scales: scales, cards: cards) }
    }

    /// Case-insensitive lookup of an already-imported file (APFS is case-insensitive by
    /// default). Returns the URL with the ON-DISK casing so we never rename it on re-import.
    private func existingFile(named name: String) -> URL? {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: AppPaths.loras, includingPropertiesForKeys: nil) else { return nil }
        return urls.first { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// `provenance` (optional) is recorded on the adapter's identity card — e.g.
    /// "Hugging Face: user/repo" from the URL importer. The publish path passes nothing
    /// and keeps its filename-derived provenance (see `item(for:)`).
    /// `preservingUserMeta`: a replace normally prunes the old adapter's default strength and
    /// identity card (a DIFFERENT file must not inherit them) — the publish path passes `true`
    /// because a republish replaces the SAME run's adapter and the user's pinned strength and
    /// typed description must survive it.
    func importLoRA(from src: URL, provenance: String? = nil, preservingUserMeta: Bool = false) throws -> LoRAItem {
        let fm = FileManager.default
        try fm.createDirectory(at: AppPaths.loras, withIntermediateDirectories: true)
        // Reuse the existing on-disk filename (and its exact casing) when re-importing a
        // same-named file, so case-sensitive recipe / PNG-recipe name matches don't orphan
        // (re-importing "style.safetensors" over "Style.safetensors" must NOT rename it).
        let existing = existingFile(named: src.lastPathComponent)
        let dest = existing ?? AppPaths.loras.appendingPathComponent(src.lastPathComponent)

        // Self-import: the user picked a file ALREADY inside the LoRAs folder (open panel or
        // drag). The old remove-then-copy deleted the source, then copyItem threw 'no such
        // file' — the adapter was gone forever (no Trash). Just return it untouched.
        // Case-insensitive: APFS is case-insensitive and `dest` carries the on-disk casing, so a
        // differently-cased re-import of the same file (Style vs style) is still a self-import —
        // a case-sensitive compare would treat it as a replace and wipe the trigger word below.
        if src.standardizedFileURL.path.caseInsensitiveCompare(dest.standardizedFileURL.path) == .orderedSame {
            return item(for: dest, stored: loadTriggers())
        }

        let replacing = existing != nil

        // Copy to a temp name first, then atomically swap it in. A failed copy (ejected drive,
        // permission error) can no longer destroy the adapter that was already at `dest`.
        let tmp = AppPaths.loras.appendingPathComponent(".import-\(UUID().uuidString).tmp")
        do {
            try fm.copyItem(at: src, to: tmp)
            if replacing {
                _ = try fm.replaceItemAt(dest, withItemAt: tmp)
                // Prune the old trigger ONLY after the new file is actually in place — pruning it
                // before the copy/replace would strip the trigger off the still-intact existing
                // adapter if the copy threw. The pinned default strength belongs to the OLD file
                // too — a replacement must not inherit it. Same for the identity card: a different
                // adapter under the same name must not inherit a stale description/provenance.
                var dict = loadTriggers()
                if dict.removeValue(forKey: dest.lastPathComponent) != nil { saveTriggers(dict) }
                if !preservingUserMeta {
                    var scales = loadDefaultScales()
                    if scales.removeValue(forKey: dest.lastPathComponent) != nil { saveDefaultScales(scales) }
                    var cards = loadCards()
                    if cards.removeValue(forKey: dest.lastPathComponent) != nil { saveCards(cards) }
                }
                // A different adapter under the same name must not inherit the old MODEL CARD
                // either (the publish path re-writes a fresh one right after its replace).
                ModelCardStore.delete(forLibraryFile: dest.lastPathComponent)
            } else {
                try fm.moveItem(at: tmp, to: dest)
                // A brand-new file can still shadow an adapter deleted OUTSIDE the app (Finder):
                // its model-card folder survives the sidecar self-heal, and the new adapter must
                // not inherit the old run's recipe/validation images.
                ModelCardStore.delete(forLibraryFile: dest.lastPathComponent)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        annotate(fileName: dest.lastPathComponent, provenance: provenance)   // stamps addedAt
        return item(for: dest, stored: loadTriggers())
    }

    /// Throws if the on-disk file can't be removed, so the UI can report a real failure
    /// instead of an unconditional "Deleted". The trigger is pruned ONLY after the file is
    /// actually gone (otherwise a still-present adapter would lose its trigger word).
    func delete(_ item: LoRAItem) throws {
        try FileManager.default.removeItem(at: item.url)
        var dict = loadTriggers()
        if dict.removeValue(forKey: item.fileName) != nil { saveTriggers(dict) }
        var scales = loadDefaultScales()
        if scales.removeValue(forKey: item.fileName) != nil { saveDefaultScales(scales) }
        var cards = loadCards()
        if cards.removeValue(forKey: item.fileName) != nil { saveCards(cards) }
        ModelCardStore.delete(forLibraryFile: item.fileName)   // the model-card folder goes with it
    }

    /// Set (or clear, if empty) the trigger word for a LoRA file. Returns whether the sidecar
    /// was actually written, so the UI doesn't claim "Trigger saved" on a swallowed write error.
    @discardableResult
    func setTrigger(_ trigger: String, forFileName name: String) -> Bool {
        var dict = loadTriggers()
        let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { dict.removeValue(forKey: name) } else { dict[name] = t }
        return saveTriggers(dict)
    }

    private func item(for url: URL, stored: [String: String],
                      scales: [String: Float]? = nil, cards: [String: LoRACardInfo]? = nil) -> LoRAItem {
        let insp = SafetensorsInspector.inspect(at: url)
        let name = url.lastPathComponent
        // Priority: user-set trigger > auto-detected from metadata > none.
        let trigger = stored[name] ?? insp.trigger ?? ""
        let card = (cards ?? loadCards())[name]
        // addedAt: sidecar first, FS creation date as a display fallback for pre-card files.
        let addedAt = card?.addedAt
            ?? ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date)
        return LoRAItem(id: name, fileName: name, url: url, tier: insp.tier, note: insp.note,
                        trigger: trigger, defaultScale: (scales ?? loadDefaultScales())[name],
                        about: card?.about ?? "", addedAt: addedAt,
                        provenance: card?.provenance ?? Self.publishedProvenance(fileName: name))
    }

    /// Provenance fallback for adapters the in-app trainer published BEFORE identity cards
    /// existed (publish names files "<trigger>-<tier>-<run8>.safetensors" — see
    /// TrainingViewModel.publishedName). Derived on the fly, never persisted.
    private static func publishedProvenance(fileName: String) -> String? {
        guard let r = fileName.range(of: "-(klein4B|klein9B)-([0-9A-Fa-f]{8})\\.safetensors$",
                                     options: .regularExpression) else { return nil }
        let run8 = String(fileName[r.lowerBound...].split(separator: "-").last?.prefix(8) ?? "")
        return "Published from the in-app trainer (run \(run8.lowercased()))"
    }
}
