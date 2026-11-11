import SwiftUI
import AppKit

struct StatusDot: View {
    let active: Bool

    var body: some View {
        Circle()
            .fill(active ? Color.green : Color.secondary.opacity(0.45))
            .frame(width: 8, height: 8)
            .background { if active { Circle().fill(Color.green.opacity(0.25)).frame(width: 14, height: 14) } }
            .frame(width: 14, height: 14)
            .accessibilityHidden(true)
    }
}

struct StatePill: View {
    let state: String
    let active: Bool

    var body: some View {
        Text(state.capitalized)
            .font(.caption.weight(.medium))
            .foregroundStyle(active ? Color.green : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background((active ? Color.green : Color.secondary).opacity(0.14), in: Capsule())
    }
}

struct TagPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

struct SymbolTile: View {
    let symbol: String
    var tint: Color = .accentColor
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct SheetHeader: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        HStack(spacing: 14) {
            SymbolTile(symbol: symbol, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title3.weight(.semibold))
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct InlineError: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct ConsoleView: View {
    let text: String
    let placeholder: String
    var wraps = false
    var follows = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(wraps ? .vertical : [.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text.isEmpty ? placeholder : text)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(text.isEmpty ? .tertiary : .primary)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    Color.clear.frame(height: 1).id(ConsoleView.end)
                }
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
            .onChange(of: text) { if follows { proxy.scrollTo(ConsoleView.end, anchor: .bottom) } }
        }
    }

    private static let end = "console-end"
}

@MainActor func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
