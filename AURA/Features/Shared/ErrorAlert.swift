import SwiftUI

extension View {
    /// Presents an alert whenever `message` holds text, and clears it on dismissal.
    ///
    /// The obvious shorthand — `isPresented: .constant(message != nil)` — produces an alert that
    /// cannot dismiss itself, because SwiftUI's write-back has nowhere to go. This derives a real
    /// two-way binding so tapping OK actually clears the state.
    func errorAlert(title: String = "Something went wrong", message: Binding<String?>) -> some View {
        alert(
            title,
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { isPresented in
                    if !isPresented { message.wrappedValue = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }

    /// A neutral confirmation of something that already happened.
    func infoAlert(title: String = "Done", message: Binding<String?>) -> some View {
        alert(
            title,
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { isPresented in
                    if !isPresented { message.wrappedValue = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

extension Error {
    /// The user-facing sentence for this error, preferring AURA's own wording.
    var auraDescription: String {
        (self as? AuraError)?.errorDescription ?? localizedDescription
    }
}
