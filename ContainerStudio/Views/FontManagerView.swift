//
//  FontManagerView.swift
//  ContainerStudio
//

import SwiftUI
import UniformTypeIdentifiers

struct FontManagerView: View {
    @Bindable var provider: ContainerAccessProvider
    @State private var service = FontSwapperService()

    @State private var selectedApp: AppContainerInfo?
    @State private var showAppPicker = false
    @State private var showBackupsSheet = false
    @State private var targetFontForReplace: FontItem?
    @State private var showFileImporter = false
    @State private var alertMessage: String?

    private static let fontUTTypes: [UTType] = {
        var types: [UTType] = [.font]
        if let ttf = UTType(filenameExtension: "ttf") { types.append(ttf) }
        if let otf = UTType(filenameExtension: "otf") { types.append(otf) }
        return types
    }()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showAppPicker = true
                    } label: {
                        HStack {
                            Label(selectedApp?.name ?? "Выбрать приложение", systemImage: "app.badge")
                                .foregroundStyle(.primary)
                            Spacer()
                            if let selectedApp {
                                Text(selectedApp.formattedSize)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let selectedApp {
                        Button {
                            service.scanFonts(in: selectedApp)
                        } label: {
                            Label("Найти шрифты", systemImage: "textformat.alt")
                        }
                        .disabled(service.isScanning)
                    }
                } header: {
                    Label("Источник", systemImage: "folder.fill")
                }

                if service.isScanning {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(service.statusMessage)
                                .font(.subheadline)
                        }
                        Button(role: .destructive) {
                            service.cancelScan()
                        } label: {
                            Label("Отменить", systemImage: "xmark.circle")
                        }
                    } header: {
                        Label("Сканирование", systemImage: "hourglass")
                    }
                }

                if !service.fonts.isEmpty {
                    Section {
                        ForEach(service.fonts) { item in
                            FontRowView(
                                item: item,
                                onReplace: {
                                    targetFontForReplace = item
                                    showFileImporter = true
                                },
                                onRestore: {
                                    if let record = item.backupRecord {
                                        restoreFont(record)
                                    }
                                }
                            )
                        }
                    } header: {
                        Label("Шрифты (\(service.fonts.count))", systemImage: "textformat")
                    }
                } else if !service.isScanning && selectedApp != nil {
                    Section {
                        ContentUnavailableView(
                            "Шрифты не найдены",
                            systemImage: "textformat",
                            description: Text("В Documents и Library выбранного приложения нет файлов .ttf, .otf, .ttc или .woff2.")
                        )
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Шрифты")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showBackupsSheet = true
                    } label: {
                        Label("Бэкапы", systemImage: "clock.arrow.circlepath")
                    }
                }
            }
            .sheet(isPresented: $showAppPicker) {
                AppPickerSheet(provider: provider, selectedApp: $selectedApp)
            }
            .sheet(isPresented: $showBackupsSheet) {
                FontBackupsView(service: service)
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: Self.fontUTTypes,
                allowsMultipleSelection: false
            ) { result in
                handleImportResult(result)
            }
            .onChange(of: selectedApp) { _, newApp in
                if let newApp {
                    service.scanFonts(in: newApp)
                }
            }
            .alert("Шрифты", isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("ОК", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        guard let target = targetFontForReplace, let app = selectedApp else { return }
        switch result {
        case .success(let urls):
            guard let sourceURL = urls.first else { return }
            do {
                try service.replaceFont(target, with: sourceURL, for: app)
                alertMessage = "Шрифт «\(target.fileName)» успешно заменён. Оригинал сохранён в резервную копию."
            } catch {
                alertMessage = "Ошибка подмены: \(error.localizedDescription)"
            }
        case .failure(let error):
            alertMessage = "Не удалось выбрать файл: \(error.localizedDescription)"
        }
    }

    private func restoreFont(_ record: FontBackupRecord) {
        do {
            try service.restoreOriginal(for: record)
            alertMessage = "Оригинальный шрифт «\(record.originalFileName)» восстановлен."
        } catch {
            alertMessage = "Ошибка восстановления: \(error.localizedDescription)"
        }
    }
}

private struct FontRowView: View {
    let item: FontItem
    let onReplace: () -> Void
    let onRestore: () -> Void

    @State private var previewFont: UIFont?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(item.fileName)
                    .font(.headline)
                    .lineLimit(1)

                if item.isModified {
                    Text("Изменён")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }

                Spacer()

                Text(item.formattedSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text(item.relativePath)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if item.format.supportsCoreTextPreview {
                Text("Съешь ещё этих мягких французских булок, 1234567890")
                    .font(previewFont.map { Font($0) } ?? .body)
                    .lineLimit(2)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(.systemBackground))
                    )
            } else {
                Text("Предпросмотр недоступен для формата .woff2")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 10) {
                Button {
                    onReplace()
                } label: {
                    Label("Заменить", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if item.isModified && item.backupRecord != nil {
                    Button(role: .destructive) {
                        onRestore()
                    } label: {
                        Label("Восстановить оригинал", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
        .task(id: "\(item.id)_\(item.isModified)") {
            guard item.format.supportsCoreTextPreview else { return }
            let url = item.url
            let loaded = await Task.detached(priority: .utility) {
                FontSwapperService.loadUIFont(from: url, size: 17)
            }.value
            self.previewFont = loaded
        }
    }
}
