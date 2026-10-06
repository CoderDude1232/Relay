//
//  IncognitoKeyboard.swift
//  Relay
//
//  Applies the "Incognito Keyboard" preference (default ON) to SwiftUI text
//  fields and search fields: autocorrection/QuickType off, so the system
//  keyboard doesn't learn from or suggest what's typed in Relay.
//  (The message composer applies the same preference to its UITextView.)
//

import SwiftUI

private struct IncognitoKeyboardModifier: ViewModifier {
    @AppStorage(PrivacyPreferences.incognitoKeyboardKey) private var incognito = true

    func body(content: Content) -> some View {
        content.autocorrectionDisabled(incognito)
    }
}

extension View {
    /// Honors Settings → Privacy → Incognito Keyboard for every text input in
    /// this view (including `.searchable` fields).
    func incognitoKeyboard() -> some View {
        modifier(IncognitoKeyboardModifier())
    }
}
