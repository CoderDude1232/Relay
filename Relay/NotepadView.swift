//
//  NotepadView.swift
//  Relay
//
//  Shared notepad per conversation, synced as ordinary encrypted messages whose
//  body is "__relay_notepad__<content>". The receiver strips the prefix and
//  stores the content in its local KV store.
//

import SecureStorage
import SwiftUI

// MARK: - Constants

let notepadPrefix = "__relay_notepad__"

// MARK: - View

struct NotepadView: View {
    let service: MessagingService
    let conversationId: String
    let peerName: String

    @Environment(\.dismiss) private var dismiss
    @State private var content: String = ""
    @State private var originalContent: String = ""
    @State private var isSaving = false
    @State private var lastSaved: Date?
    @FocusState private var focused: Bool

    private var hasUnsavedChanges: Bool { content != originalContent }

    var body: some View {
        NavigationStack {
            TextEditor(text: $content)
                .font(.body)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .focused($focused)
                .navigationTitle("Shared Notepad")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task { await save() }
                        } label: {
                            if isSaving {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Send").bold()
                            }
                        }
                        .disabled(isSaving)
                    }
                    ToolbarItem(placement: .bottomBar) {
                        if hasUnsavedChanges {
                            Label("Unsaved changes", systemImage: "circle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .symbolRenderingMode(.hierarchical)
                        } else if let lastSaved {
                            Text("Synced \(lastSaved.formatted(date: .omitted, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
        }
        .onAppear {
            let loaded = service.notepadContent(for: conversationId)
            content = loaded
            originalContent = loaded
            focused = true
        }
        .presentationDetents([.large])
    }

    private func save() async {
        let text = content
        isSaving = true
        defer { isSaving = false }
        await service.sendNotepadUpdate(text, in: conversationId)
        originalContent = text
        lastSaved = Date()
    }
}
