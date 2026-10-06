import SwiftUI

extension View {
    public func errorAlert(
        _ title: LocalizedStringKey,
        message: Binding<String?>
    ) -> some View {
        modifier(StringErrorAlertModifier(title: title, message: message))
    }

}

private struct StringErrorAlertModifier: ViewModifier {
    let title: LocalizedStringKey
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.alert(
            title,
            isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )
        ) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(verbatim: message ?? "")
        }
    }
}
