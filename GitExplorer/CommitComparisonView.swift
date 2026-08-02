import SwiftUI

struct ComparisonView: View {
    @Environment(\.dismiss) private var dismiss
    let branch: String
    let diff: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(branch) compared with HEAD").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(diff.isEmpty ? "No differences." : diff)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }
}

