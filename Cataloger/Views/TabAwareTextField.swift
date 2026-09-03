import SwiftUI
import UIKit

/// A `UITextField`/`UITextView` wrapper that intercepts the hardware Tab
/// key directly via its UIKit delegate.
///
/// SwiftUI's `.onKeyPress(.tab)` does **not** reliably fire while a
/// `TextField`/`TextEditor` has focus on iOS: the underlying
/// `UITextField`/`UITextView` consumes Tab as an ordinary
/// whitespace-insertion character at the responder level, before SwiftUI's
/// key event bridge gets a chance to see it. The only reliable fix is to
/// own the delegate callback (`shouldChangeCharactersIn`/
/// `shouldChangeTextIn`) and block the insertion there.
struct TabAwareTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var isMultiline: Bool = false
    var isFocused: Bool
    var onFocus: () -> Void
    var onTab: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIView {
        if isMultiline {
            let textView = UITextView()
            textView.delegate = context.coordinator
            textView.font = .preferredFont(forTextStyle: .body)
            textView.backgroundColor = .clear
            textView.isScrollEnabled = true
            textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
            textView.textContainer.lineFragmentPadding = 0
            textView.text = text
            return textView
        } else {
            let textField = UITextField()
            textField.delegate = context.coordinator
            textField.placeholder = placeholder
            textField.text = text
            textField.borderStyle = .none
            textField.returnKeyType = .next
            return textField
        }
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Critical: keep the coordinator's copy of this struct current.
        // Without this, the coordinator's delegate callbacks keep firing
        // against whatever `self` existed at makeCoordinator() time —
        // stale closures, stale bindings — which is what caused focus to
        // behave erratically after the very first render.
        context.coordinator.parent = self

        // Guard against feedback loops: don't stomp the live edit / cursor
        // position by reassigning text that already matches.
        if let textView = uiView as? UITextView {
            if textView.text != text { textView.text = text }
        } else if let textField = uiView as? UITextField {
            if textField.text != text { textField.text = text }
        }

        // Synchronous, not dispatched async — async here was racing against
        // SwiftUI's own rapid re-renders while typing, causing
        // becomeFirstResponder/resignFirstResponder calls to fire out of
        // order and jump focus unpredictably.
        if isFocused, !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFocused, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate, UITextViewDelegate {
        var parent: TabAwareTextField
        init(_ parent: TabAwareTextField) { self.parent = parent }

        // MARK: Single-line (UITextField)

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if string == "\t" {
                parent.onTab()
                return false
            }
            return true
        }

        func textFieldDidChangeSelection(_ textField: UITextField) {
            parent.text = textField.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.onFocus()
        }

        // MARK: Multi-line (UITextView)

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\t" {
                parent.onTab()
                return false
            }
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocus()
        }
    }
}
