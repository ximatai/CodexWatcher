import SwiftUI

/// Preserve the email's layout while covering it visually and hiding it from accessibility.
struct PrivacyMask: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .hidden()
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.secondary.opacity(0.18))
                        .frame(height: 12)
                }
                .accessibilityHidden(true)
                .allowsHitTesting(false)
                .help("敏感信息已隐藏")
        } else {
            content
        }
    }
}

extension View {
    func privacyMasked(_ enabled: Bool) -> some View {
        modifier(PrivacyMask(enabled: enabled))
    }
}
