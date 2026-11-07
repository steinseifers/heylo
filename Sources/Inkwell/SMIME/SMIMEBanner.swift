import SwiftUI

/// One line above a message that tells whether it is signed and/or encrypted, like Apple Mail's header badges.
struct SMIMEBanner: View {
    var status: SMIMEStatus

    private var symbol: String {
        if status.problem != nil && !status.signatureValid { return "exclamationmark.triangle.fill" }
        if status.signed && status.signatureValid && status.trusted { return "checkmark.seal.fill" }
        if status.signed && status.signatureValid { return "seal" }
        return status.encrypted ? "lock.fill" : "seal"
    }
    private var tint: Color {
        if status.problem != nil && !status.signatureValid { return .red }
        if status.signed && status.signatureValid && status.trusted { return .green }
        return .orange
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                if status.encrypted { Text("Encrypted").font(.subheadline.weight(.semibold)) }
                if status.signed {
                    if status.signatureValid {
                        let who = status.signerEmail ?? "–"
                        if status.trusted { Text("Signed by \(who)").font(.subheadline.weight(.semibold)) }
                        else { Text("Signed by \(who), certificate not trusted").font(.subheadline.weight(.semibold)) }
                    } else {
                        Text("Signature invalid").font(.subheadline.weight(.semibold))
                    }
                }
                if let problem = status.problem { Text(LocalizedStringKey(problem)).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer()
        }
        .padding(12)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
