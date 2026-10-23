import SwiftUI
import Charts
import MonarchCore

enum Palette {
    static let background = Color(red: 0.97, green: 0.96, blue: 0.93)
    static let forest = Color(red: 0.13, green: 0.29, blue: 0.24)
    static let mint = Color(red: 0.77, green: 0.88, blue: 0.71)
    static let ink = Color(red: 0.15, green: 0.19, blue: 0.17)
    static let secondary = Color(red: 0.43, green: 0.47, blue: 0.43)
    static let line = Color(red: 0.89, green: 0.89, blue: 0.85)
    static let orange = Color(red: 0.76, green: 0.39, blue: 0.21)
}

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 24))
    }
}

struct SectionLabel: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        HStack {
            Text(title).font(.system(.headline, design: .rounded))
            Spacer()
            if let detail { Text(detail).font(.caption).foregroundStyle(Palette.secondary) }
        }
    }
}

struct AmountText: View {
    let amount: Decimal
    var currency = "USD"
    var body: some View { Text(Money.format(amount, currency: currency)).monospacedDigit() }
}

struct Metric: View {
    let title: String
    let value: Decimal
    var color: Color = Palette.ink
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(Palette.secondary)
            AmountText(amount: value).font(.system(.title3, design: .rounded, weight: .semibold)).foregroundStyle(color).minimumScaleFactor(0.7).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EntryRow: View {
    let transaction: TransactionRecord
    let category: CategoryRecord?
    var body: some View {
        HStack(spacing: 12) {
            Text(category?.emoji ?? "📦").font(.title3).frame(width: 44, height: 44).background(Palette.background, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(transaction.merchant).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if !transaction.isReviewed { Circle().fill(Palette.orange).frame(width: 5, height: 5) }
                }
                Text(transaction.isPending ? "Pending" : category?.name ?? "Uncategorized").font(.caption).foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 4)
            AmountText(amount: transaction.amount).font(.subheadline.weight(.medium)).foregroundStyle(transaction.amount > 0 ? Palette.forest : Palette.ink)
        }.padding(.vertical, 5).foregroundStyle(Palette.ink)
    }
}

struct EmptyCard: View {
    let title: String
    let message: String
    let symbol: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(Palette.forest)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 24)
    }
}

struct MonthPicker: View {
    @Binding var month: Date
    var body: some View {
        HStack {
            Button { month = LedgerDate.shifting(month, months: -1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36) }.accessibilityLabel("Previous month")
            Spacer()
            Text(month, format: .dateTime.month(.wide).year()).font(.headline)
            Spacer()
            Button { month = LedgerDate.shifting(month, months: 1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 36) }.accessibilityLabel("Next month")
        }.foregroundStyle(Palette.forest)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).frame(maxWidth: .infinity).padding(.vertical, 16)
            .foregroundStyle(.white).background(Palette.forest.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
    }
}

struct AppToolbar: ViewModifier {
    @Environment(AppState.self) private var app
    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { app.showingMenu = true } label: { Image(systemName: "square.grid.2x2").foregroundStyle(Palette.forest) }.accessibilityLabel("More screens")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 5) { Circle().fill(Palette.forest).frame(width: 5, height: 5); Text("SANDBOX").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1) }
                        .padding(.horizontal, 9).padding(.vertical, 6).background(Palette.mint.opacity(0.4), in: Capsule())
                }
            }
            .toolbarBackground(Palette.background, for: .navigationBar)
    }
}

struct AppErrorBanner: ViewModifier {
    @Environment(AppState.self) private var app
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let message = app.errorMessage, !app.isObscured, !app.isLocked {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Something needs attention").font(.caption.weight(.semibold))
                        Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button { app.errorMessage = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss error")
                }.foregroundStyle(Palette.ink).padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).padding(12)
            }
        }
    }
}

extension View {
    func appToolbar() -> some View { modifier(AppToolbar()) }
    func appErrors() -> some View { modifier(AppErrorBanner()) }
}
