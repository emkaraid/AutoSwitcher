//
//  DictionaryView.swift
//  AutoSwitcher
//
//  Phase 7: user-managed whitelist. Words listed here are never auto-
//  corrected, regardless of how the heuristic feels about them.
//

import SwiftUI

struct DictionaryView: View {
    @State private var words: [String] = []
    @State private var newWord: String = ""
    @State private var selection: Set<String> = []
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n.t("dict.title"))
                .font(.headline)
            Text(l10n.t("dict.subtitle"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField(l10n.t("dict.placeholder"), text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addWord)
                Button(l10n.t("dict.add"), action: addWord)
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            List(selection: $selection) {
                ForEach(words, id: \.self) { word in
                    Text(word)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))

            HStack {
                Spacer()
                Button(l10n.t("dict.remove"), action: removeSelected)
                    .disabled(selection.isEmpty)
            }
        }
        .padding(16)
        .onAppear(perform: load)
    }

    // MARK: - Persistence (UserDefaults string-array)

    private func load() {
        words = UserDefaults.standard.stringArray(forKey: AppSettings.Keys.whitelistWords) ?? []
    }

    private func save() {
        UserDefaults.standard.set(words, forKey: AppSettings.Keys.whitelistWords)
    }

    private func addWord() {
        let trimmed = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !words.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            words.append(trimmed)
            words.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            save()
        }
        newWord = ""
    }

    private func removeSelected() {
        guard !selection.isEmpty else { return }
        words.removeAll { selection.contains($0) }
        selection.removeAll()
        save()
    }
}
