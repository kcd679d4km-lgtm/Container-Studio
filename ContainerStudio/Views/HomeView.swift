//
//  HomeView.swift
//  ContainerStudio
//

import SwiftUI
import UIKit

struct HomeView: View {
    @Bindable var provider: ContainerAccessProvider
    @State private var copiedLogs = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Устройство", value: provider.deviceModel)
                    LabeledContent("Версия iOS", value: provider.iosVersion)
                    LabeledContent("App Group", value: provider.activeAppGroup ?? "Не задан")
                    LabeledContent("Статус") {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(provider.isProviderReady ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(provider.statusDescription)
                                .foregroundStyle(provider.isProviderReady ? AnyShapeStyle(.primary) : AnyShapeStyle(.red))
                        }
                    }
                } header: {
                    Label("Окружение", systemImage: "iphone")
                } footer: {
                    Text("Доступ к контейнерам выполняется через App Groups и container_query (worse_query / pathleak).")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 4) {
                                    ForEach(provider.logs) { entry in
                                        Text(entry.message)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(logColor(for: entry.message))
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    Color.clear
                                        .frame(height: 1)
                                        .id("log-bottom")
                                }
                                .padding(12)
                            }
                            .frame(minHeight: 220, maxHeight: 300)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color(.systemBackground))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
                            )
                            .onChange(of: provider.logs.count) { _, _ in
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo("log-bottom", anchor: .bottom)
                                }
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                } header: {
                    Label("Консоль диагностики", systemImage: "terminal.fill")
                }

                Section {
                    Button {
                        provider.initializeProvider()
                    } label: {
                        Label("Переинициализировать доступ", systemImage: "arrow.clockwise")
                    }

                    Button {
                        let text = provider.logs.map(\.message).joined(separator: "\n")
                        UIPasteboard.general.string = text
                        copiedLogs = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copiedLogs = false
                        }
                    } label: {
                        Label(
                            copiedLogs ? "Скопировано в буфер" : "Скопировать лог",
                            systemImage: copiedLogs ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .disabled(provider.logs.isEmpty)
                } header: {
                    Label("Действия", systemImage: "wrench.and.screwdriver.fill")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Главная")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        provider.initializeProvider()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Обновить статус")
                }
            }
        }
    }

    private func logColor(for line: String) -> Color {
        if line.hasPrefix("[+]") { return .green }
        if line.hasPrefix("[-]") { return .red }
        if line.hasPrefix("[!]") { return .orange }
        if line.hasPrefix("(wq)") { return .orange }
        return .primary
    }
}
