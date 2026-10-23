import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var app
    var body: some View {
        @Bindable var state = app
        ZStack {
            TabView(selection: $state.selectedTab) {
                NavigationStack { DashboardView() }.tabItem { Label("Dashboard", systemImage: "square.grid.2x2.fill") }.tag(0)
                NavigationStack { AccountsView() }.tabItem { Label("Accounts", systemImage: "building.columns") }.tag(1)
                NavigationStack { TransactionsView() }.tabItem { Label("Transactions", systemImage: "list.bullet.rectangle") }.tag(2)
                NavigationStack { BudgetView() }.tabItem { Label("Budget", systemImage: "chart.pie") }.tag(3)
                NavigationStack { CashFlowView() }.tabItem { Label("Cash flow", systemImage: "chart.bar.xaxis") }.tag(4)
            }
            .toolbarBackground(.white, for: .tabBar)
            if app.isLocked || app.isObscured {
                Palette.background.ignoresSafeArea()
                VStack(spacing: 24) {
                    Image(systemName: "leaf.fill").font(.system(size: 44)).foregroundStyle(Palette.forest)
                    Text("A little peace of mind.").font(.system(.title2, design: .serif))
                    if app.isLocked && !app.isObscured {
                        Button("Unlock your finances") { Task { await app.unlock() } }.buttonStyle(PrimaryButtonStyle()).padding(.horizontal, 40).disabled(app.isAuthenticating)
                        if let message = app.lockMessage { Text(message).font(.caption).foregroundStyle(Palette.secondary).multilineTextAlignment(.center).padding(.horizontal, 40) }
                    }
                }
            }
        }
        .sheet(isPresented: $state.showingMenu) { NavigationStack { MoreView() }.appErrors() }
        .appErrors()
        .overlay(alignment: .top) {
            if !app.isLocked && !app.isObscured && !app.syncMessage.isEmpty {
                HStack { ProgressView(); Text(app.syncMessage).font(.caption) }.padding(12).background(.regularMaterial, in: Capsule()).padding(.top, 4)
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = app.notice, !app.isLocked && !app.isObscured {
                HStack(alignment: .top) {
                    Text(notice).font(.caption)
                    Button { app.notice = nil } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Dismiss notification")
                }.padding(14).background(Palette.mint, in: RoundedRectangle(cornerRadius: 16)).padding(.horizontal).padding(.bottom, 64)
            }
        }
    }
}

struct MoreView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section("Your money") {
                NavigationLink { ReceiptsView() } label: { Label("Receipts", systemImage: "doc.text.viewfinder") }
                NavigationLink { HSAView() } label: { Label("HSA receipts", systemImage: "cross.case") }
                NavigationLink { ShipmentsView() } label: { Label("Shipments", systemImage: "shippingbox") }
                NavigationLink { ReceivablesView() } label: { Label("Money owed to you", systemImage: "person.2") }
                NavigationLink { RecurringView() } label: { Label("Recurring", systemImage: "calendar") }
                NavigationLink { LoansView() } label: { Label("Loans", systemImage: "graduationcap") }
                NavigationLink { InvestmentsView() } label: { Label("Investments", systemImage: "chart.line.uptrend.xyaxis") }
            }
            Section("Plan ahead") {
                NavigationLink { InsightsView() } label: { Label("Insights", systemImage: "sparkles") }
                NavigationLink { ForecastView() } label: { Label("Forecast", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                NavigationLink { CashFlowView() } label: { Label("Reports", systemImage: "chart.bar.doc.horizontal") }
            }
            Section("Make it yours") {
                NavigationLink { RulesView() } label: { Label("Rules", systemImage: "line.3.horizontal.decrease") }
                NavigationLink { CategoriesView() } label: { Label("Categories", systemImage: "square.grid.3x3") }
                NavigationLink { SettingsView() } label: { Label("Settings & connections", systemImage: "gearshape") }
            }
        }.navigationTitle("Your space").scrollContentBackground(.hidden).background(Palette.background)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
    }
}
