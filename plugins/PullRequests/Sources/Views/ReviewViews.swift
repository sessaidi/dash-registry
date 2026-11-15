import DashKit
import DashKitUI
import SwiftUI

struct ReviewBadge: View {
    let review: PRReview?

    var body: some View {
        Group {
            switch review?.status {
            case "done":
                Image(systemName: review?.verdict == "approve" ? "checkmark.seal.fill" : review?.verdict == "request_changes" ? "xmark.seal.fill" : "text.bubble.fill")
                    .foregroundStyle(riskColor)
            case "running", "queued":
                ProgressView().controlSize(.small)
            case "failed":
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
            default:
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
            }
        }
        .frame(width: 20)
        .help(review.map { "\($0.status) · \($0.verdict) · risk \($0.risk)" } ?? "Not reviewed")
    }

    private var riskColor: Color {
        switch review?.risk {
        case "high": .red
        case "medium": .orange
        default: .green
        }
    }
}

struct ReviewView: View {
    let review: PRReview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ReviewBadge(review: review)
                Text(review.isFromChat ? "Dashii review from chat" : "Dashii review").font(.headline)
                if review.status == "done" {
                    Text("\(review.verdict.replacing("_", with: " ")) · risk \(review.risk)").foregroundStyle(.secondary)
                } else {
                    Text(review.status).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(review.headSHA.prefix(7)) · \(review.createdAt.relative)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if let error = review.error { Text(error).foregroundStyle(.red) }
            if !review.summary.isEmpty { Text(review.summary).textSelection(.enabled) }
            ForEach(review.findings, id: \.self) { finding in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(finding.severity.uppercased())
                            .font(.caption2.bold())
                            .foregroundStyle(finding.severity == "blocker" || finding.severity == "major" ? .red : .orange)
                        Text(finding.title).bold()
                    }
                    Text(finding.line > 0 ? "\(finding.file):\(finding.line)" : finding.file).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(finding.detail).font(.callout).textSelection(.enabled)
                    if !finding.suggestion.isEmpty { Text("→ \(finding.suggestion)").font(.callout).foregroundStyle(.secondary) }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
            }
            if !review.testing.isEmpty {
                Text("Testing: \(review.testing)").font(.callout)
            }
        }
    }
}

/// The PR description with inline Markdown (bold, code, links); Dash's block renderer is app-internal.
struct InlineMarkdown: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
