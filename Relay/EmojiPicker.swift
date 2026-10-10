//
//  EmojiPicker.swift
//  Relay
//
//  Emoji grid for the composer and the reaction tray. iOS has no presentable
//  system emoji picker, so this is a curated, categorized set.
//

import SwiftUI

/// Quick reactions shown first in the reaction tray.
let quickReactions = ["❤️", "👍", "👎", "😂", "😮", "😢"]

struct EmojiPicker: View {
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16, pinnedViews: .sectionHeaders) {
                    ForEach(EmojiCatalog.categories, id: \.name) { category in
                        Section {
                            LazyVGrid(columns: columns, spacing: 6) {
                                ForEach(category.emoji, id: \.self) { emoji in
                                    Button {
                                        onPick(emoji)
                                        dismiss()
                                    } label: {
                                        Text(emoji).font(.system(size: 32))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        } header: {
                            Text(category.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .background(.bar)
                        }
                    }
                }
                .padding(.horizontal)
            }
            .navigationTitle("Emoji")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

enum EmojiCatalog {
    struct Category {
        let name: String
        let emoji: [String]
    }

    static let categories: [Category] = [
        Category(name: "Smileys", emoji: [
            "😀", "😃", "😄", "😁", "😆", "😅", "🤣", "😂", "🙂", "🙃", "😉", "😊",
            "😇", "🥰", "😍", "🤩", "😘", "😗", "😚", "😋", "😛", "😜", "🤪", "😝",
            "🤗", "🤔", "🤨", "😐", "😑", "😶", "🙄", "😏", "😴", "😪", "😌", "😔",
            "🤤", "😷", "🤒", "🤕", "🤮", "🥵", "🥶", "😵", "🤯", "🤠", "🥳", "😎",
            "🤓", "😕", "😟", "🙁", "😮", "😯", "😲", "😳", "🥺", "😦", "😰", "😢",
            "😭", "😱", "😖", "😞", "😤", "😡", "🤬", "💀", "👻", "👽", "🤖", "🎃",
        ]),
        Category(name: "Gestures & People", emoji: [
            "👋", "🤚", "✋", "🖐️", "👌", "🤌", "🤏", "✌️", "🤞", "🤟", "🤘", "👈",
            "👉", "👆", "👇", "☝️", "👍", "👎", "✊", "👊", "🤛", "🤜", "👏", "🙌",
            "👐", "🤲", "🙏", "💪", "🫶", "💅", "👀", "🧠", "🫦", "👶", "🧑", "👨",
            "👩", "🧔", "👮", "🕵️", "💃", "🕺", "🧗", "🏃", "🚶", "🧘",
        ]),
        Category(name: "Hearts & Symbols", emoji: [
            "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💔", "❣️", "💕",
            "💞", "💓", "💗", "💖", "💘", "💝", "💯", "✨", "⭐️", "🌟", "💫", "🔥",
            "💥", "💦", "💤", "🎉", "🎊", "✅", "❌", "❓", "❗️", "⚠️", "🚫", "🔴",
        ]),
        Category(name: "Animals & Nature", emoji: [
            "🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐨", "🐯", "🦁", "🐮",
            "🐷", "🐸", "🐵", "🐔", "🐧", "🐦", "🦄", "🐝", "🦋", "🐢", "🐙", "🐳",
            "🌵", "🌲", "🌴", "🌸", "🌻", "🌹", "🍀", "🍁", "🌈", "☀️", "🌙", "⚡️",
        ]),
        Category(name: "Food & Drink", emoji: [
            "🍏", "🍎", "🍐", "🍊", "🍋", "🍌", "🍉", "🍇", "🍓", "🫐", "🍒", "🍑",
            "🥭", "🍍", "🥥", "🥝", "🍅", "🥑", "🌽", "🌶️", "🍔", "🍟", "🍕", "🌭",
            "🌮", "🌯", "🍜", "🍣", "🍩", "🍪", "🎂", "🍰", "🍫", "🍿", "☕️", "🍺",
        ]),
        Category(name: "Activities & Objects", emoji: [
            "⚽️", "🏀", "🏈", "⚾️", "🎾", "🏐", "🎱", "🏓", "🏸", "🥅", "🎯", "🎮",
            "🎲", "🎸", "🎹", "🎺", "🎧", "🎤", "🎬", "📷", "💻", "📱", "⌚️", "💡",
            "🔑", "🎁", "📚", "✏️", "📌", "🔒", "⏰", "🚗", "✈️", "🚀", "🏠", "💰",
        ]),
    ]
}

extension String {
    /// True for short all-emoji messages, which render large without a bubble.
    var isJumbomojiCandidate: Bool {
        let characters = Array(trimmingCharacters(in: .whitespacesAndNewlines))
        guard !characters.isEmpty, characters.count <= 3 else { return false }
        return characters.allSatisfy(\.isEmoji)
    }
}

extension Character {
    var isEmoji: Bool {
        guard let first = unicodeScalars.first else { return false }
        // Multi-scalar clusters (ZWJ sequences, flags, skin-tone modifiers,
        // VS16 presentation) are emoji; single scalars must explicitly
        // request emoji presentation so plain digits/"#"/"*" don't count.
        if unicodeScalars.count > 1 {
            return first.properties.isEmoji || first.value >= 0x1F000
        }
        return first.properties.isEmojiPresentation
    }
}
