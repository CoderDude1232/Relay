//
//  FormattingComposer.swift
//  Relay
//
//  A UITextView-backed composer that exposes the selection range so the
//  formatting toolbar can wrap selected text with markdown syntax.
//

import SwiftUI
import UIKit

// MARK: - ComposerContext

/// Shared between the formatting toolbar and the underlying UITextView.
/// Wraps the selected text range with prefix/suffix markdown markers, or
/// inserts both markers at the cursor and positions it between them.
@Observable
final class ComposerContext {
    weak var textView: UITextView?

    func applyFormat(prefix: String, suffix: String) {
        guard let tv = textView, let sel = tv.selectedTextRange else { return }
        let selected = tv.text(in: sel) ?? ""
        tv.replace(sel, withText: prefix + selected + suffix)
        if selected.isEmpty,
           let newSel = tv.selectedTextRange,
           let pos = tv.position(from: newSel.start, offset: -suffix.count) {
            tv.selectedTextRange = tv.textRange(from: pos, to: pos)
        }
    }
}

// MARK: - FormattingTextEditor

/// A UITextView wrapped for SwiftUI. Drops in where a multiline TextField
/// would go; drives `text` binding and `isFocused` state, and wires itself
/// to a `ComposerContext` so the format toolbar can act on the selection.
struct FormattingTextEditor: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var maxLines: Int = 8
    var context: ComposerContext
    @Binding var isFocused: Bool
    /// When true, disables autocorrect/spell-check/smart punctuation so the
    /// keyboard doesn't learn or suggest from what's typed here ("incognito").
    var incognito: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Wrap text at the width SwiftUI proposes and cap the height at `maxLines`.
    /// Without this, a non-scrolling UITextView reports its single-line intrinsic
    /// width, so long text overflowed horizontally instead of wrapping.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView tv: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width < .greatestFiniteMagnitude else { return nil }
        let lineHeight = tv.font?.lineHeight ?? 20
        let maxH = lineHeight * CGFloat(maxLines)
            + tv.textContainerInset.top + tv.textContainerInset.bottom
        let fit = tv.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: min(fit.height, maxH))
    }

    func makeUIView(context ctx: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = ctx.coordinator
        tv.backgroundColor = .clear
        tv.font = .preferredFont(forTextStyle: .body)
        tv.textContainerInset = UIEdgeInsets(top: 9, left: 10, bottom: 9, right: 10)
        tv.isScrollEnabled = false
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        applyIncognito(to: tv)
        ctx.coordinator.setupPlaceholder(in: tv)
        context.textView = tv
        return tv
    }

    /// Sets the keyboard traits that suppress learning/suggestions. Toggling
    /// while focused requires reloadInputViews() for the keyboard to pick it up.
    private func applyIncognito(to tv: UITextView) {
        let newType: UITextAutocorrectionType = incognito ? .no : .default
        guard tv.autocorrectionType != newType else { return }
        tv.autocorrectionType = newType
        tv.spellCheckingType = incognito ? .no : .default
        tv.smartQuotesType = incognito ? .no : .default
        tv.smartDashesType = incognito ? .no : .default
        tv.smartInsertDeleteType = incognito ? .no : .default
        if tv.isFirstResponder { tv.reloadInputViews() }
    }

    func updateUIView(_ tv: UITextView, context ctx: Context) {
        context.textView = tv
        applyIncognito(to: tv)
        if tv.text != text { tv.text = text }
        ctx.coordinator.updatePlaceholder(in: tv)
        // Clamp height to maxLines.
        let lineHeight = tv.font?.lineHeight ?? 20
        let maxH = lineHeight * CGFloat(maxLines)
            + tv.textContainerInset.top + tv.textContainerInset.bottom
        let needs = tv.contentSize.height > maxH
        if tv.isScrollEnabled != needs {
            tv.isScrollEnabled = needs
            tv.invalidateIntrinsicContentSize()
        }
        // Drive focus from SwiftUI state.
        if isFocused && !tv.isFirstResponder {
            tv.becomeFirstResponder()
        } else if !isFocused && tv.isFirstResponder {
            tv.resignFirstResponder()
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: FormattingTextEditor
        private weak var placeholderLabel: UILabel?

        init(_ parent: FormattingTextEditor) { self.parent = parent }

        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
            updatePlaceholder(in: tv)
            tv.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_ tv: UITextView) {
            parent.isFocused = true
            updatePlaceholder(in: tv)
        }

        func textViewDidEndEditing(_ tv: UITextView) {
            parent.isFocused = false
            updatePlaceholder(in: tv)
        }

        func setupPlaceholder(in tv: UITextView) {
            let label = UILabel()
            label.font = tv.font
            label.textColor = .placeholderText
            label.translatesAutoresizingMaskIntoConstraints = false
            tv.insertSubview(label, at: 0)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(
                    equalTo: tv.leadingAnchor,
                    constant: tv.textContainerInset.left + tv.textContainer.lineFragmentPadding),
                label.topAnchor.constraint(
                    equalTo: tv.topAnchor,
                    constant: tv.textContainerInset.top),
            ])
            placeholderLabel = label
        }

        func updatePlaceholder(in tv: UITextView) {
            placeholderLabel?.text = parent.placeholder
            let shouldHide = !tv.text.isEmpty
            guard placeholderLabel?.isHidden != shouldHide else { return }
            UIView.animate(withDuration: 0.15) { self.placeholderLabel?.alpha = shouldHide ? 0 : 1 }
            if !shouldHide { placeholderLabel?.isHidden = false }
        }
    }
}
