//
//  FontBackupsView.swift
//  ContainerStudio
//

import SwiftUI

struct FontBackupsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var service: FontSwapperService

    @State private var alertMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if service.allBackups.isEmpty {
                    ContentUnavailableView(
                        "Резервных копий нет",
                        systemImage: "externaldrive.badge.checkmark",
                        description: Text("Перед каждой подменой шрифта оригинал автоматически сохраняется в Application Support/FontBackups.")
                    )
                } else {
                    Section {
                        ForEach(service.allBackups) { record in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(record.originalFileName)
                                        .font(.headline)
                                    Spacer()
                                    Text(record.formattedSize)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Text(record.bundleID)
                                    .font(.caption)
                                    .foregroundStyle(.orange)

                                Text(record.originalRelativePath)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)

                                HStack {
                                    Text(record.backupDate.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)

                                    Spacer()

                                    Button("Восстановить оригинал") {
                                        restore(record)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                                .padding(.top, 2)
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        Label("Сохранённые оригиналы (\(service.allBackups.count))", systemImage: "clock.arrow.circlepath")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Бэкапы шрифтов")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                service.loadRegistry()
            }
            .alert("Резервная копия", isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("ОК", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    private func restore(_ record: FontBackupRecord) {
        do {
            try service.restoreOriginal(for: record)
            alertMessage = "Оригинальный шрифт «\(record.originalFileName)» восстановлен."
        } catch {
            alertMessage = "Ошибка восстановления: \(error.localizedDescription)"
        }
    }
}
