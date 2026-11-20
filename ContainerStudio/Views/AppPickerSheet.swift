//
//  AppPickerSheet.swift
//  ContainerStudio
//

import SwiftUI

struct AppPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var provider: ContainerAccessProvider
    @Binding var selectedApp: AppContainerInfo?

    @State private var searchText = ""

    private var filteredApps: [AppContainerInfo] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return provider.installedApps }
        return provider.installedApps.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.bundleID.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if provider.isScanningApps {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(provider.scanStatusText.isEmpty ? "Сканирование контейнеров..." : provider.scanStatusText)
                                    .font(.subheadline)
                            }
                            ProgressView(value: provider.scanProgress, total: 1.0)
                                .tint(.orange)
                        }
                        .padding(.vertical, 4)

                        Button(role: .destructive) {
                            provider.cancelAppDiscovery()
                        } label: {
                            Label("Отменить поиск", systemImage: "xmark.circle")
                        }
                    } header: {
                        Label("Индексация", systemImage: "magnifyingglass")
                    }
                }

                if filteredApps.isEmpty && !provider.isScanningApps {
                    Section {
                        ContentUnavailableView {
                            Label("Приложения не найдены", systemImage: "app.dashed")
                        } description: {
                            Text(provider.installedApps.isEmpty
                                 ? "Нажмите «Обновить», чтобы просканировать контейнеры данных приложений."
                                 : "Нет совпадений для «\(searchText)».")
                        } actions: {
                            if provider.installedApps.isEmpty {
                                Button("Сканировать контейнеры") {
                                    provider.discoverAppContainers(forceRefresh: true)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                } else {
                    Section {
                        ForEach(filteredApps) { app in
                            Button {
                                selectedApp = app
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: app.isSystemApp ? "gear.circle.fill" : "app.fill")
                                        .font(.title2)
                                        .foregroundStyle(app.isSystemApp ? .secondary : .orange)
                                        .frame(width: 32)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(app.name)
                                            .font(.body)
                                            .fontWeight(.medium)
                                            .foregroundStyle(.primary)

                                        Text(app.bundleID)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    VStack(alignment: .trailing, spacing: 3) {
                                        Text(app.formattedSize)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()

                                        if selectedApp?.id == app.id {
                                            Image(systemName: "checkmark")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    } header: {
                        Label("Контейнеры (\(filteredApps.count))", systemImage: "square.stack.3d.up.fill")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Выбор приложения")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Имя или Bundle ID")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        provider.discoverAppContainers(forceRefresh: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(provider.isScanningApps)
                }
            }
            .onAppear {
                if provider.installedApps.isEmpty && !provider.isScanningApps {
                    provider.discoverAppContainers()
                }
            }
        }
    }
}
