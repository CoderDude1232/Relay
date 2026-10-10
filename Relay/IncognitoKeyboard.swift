//
//  IncognitoKeyboard.swift
//  Relay
//
//  Applies the Incognito Keyboard preference to SwiftUI text and search
//  fields by turning off autocorrection, so the system keyboard doesn't learn
//  from what's typed. The composer's UITextView handles this separately.
//

import SwiftUI

private struct IncognitoKeyboardModifier: ViewModifier {
    @AppStorage(PrivacyPreferences.incognitoKeyboardKey) private var incognito = true

    func body(content: Content) -> some View {
        content.autocorrectionDisabled(incognito)
    }
}

extension View {
    /// Applies the Incognito Keyboard setting to every text input in this
    /// view, including `.searchable` fields.
    func incognitoKeyboard() -> some View {
        modifier(IncognitoKeyboardModifier())
    }
}
