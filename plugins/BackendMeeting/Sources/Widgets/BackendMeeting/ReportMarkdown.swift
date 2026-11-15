import SwiftUI

/// The report's bullet list: bold themes, nested chantier items, inline markdown.
struct ReportMarkdown: View {
    let markdown: String
    var limit: Int = .max

    struct Line: Equatable {
        let level: Int
        let text: String
    }

    static func lines(_ markdown: String) -> [Line] {
        markdown.split(separator: "\n").compactMap { raw in
            let indent = raw.prefix { $0 == " " }.count
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let text = trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") ? String(trimmed.dropFirst(2)) : trimmed
            return Line(level: indent >= 2 ? 1 : 0, text: text)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.lines(markdown).prefix(limit).enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(line.level == 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: line.level == 0 ? 6 : 4, height: line.level == 0 ? 6 : 4)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                    Text((try? AttributedString(markdown: line.text)) ?? AttributedString(line.text))
                        .font(line.level == 0 ? .callout : .callout)
                        .foregroundStyle(line.level == 0 ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CGFloat(line.level) * 18)
            }
        }
        .textSelection(.enabled)
    }
}
