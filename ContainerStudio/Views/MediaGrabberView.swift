//
//  MediaGrabberView.swift
//  ContainerStudio
//

import SwiftUI

struct MediaGrabberView: View {
    @Bindable var provider: ContainerAccessProvider
    @State private var service = MediaGrabberService()

    @State private var selectedApp: AppContainerInfo?
    @State private var showAppPicker = false
    @State private var selectedCategory: MediaCategory = .all
    @State private var sortOrder: MediaSortOrder = .dateDescending
    @State private var previewItem: MediaItem?

    @State private var editMode: EditMode = .inactive
    @State private var selectedIDs: Set<String> = []
    @State private var zipShareURL: URL?
    @State private var showZipShare = false
    @State private var isCreatingZip = false
    @State private var errorMessage: String?

    private var filteredItems: [MediaItem] {
        let base = selectedCategory == .all
            ? service.items
            : service.items.filter { $0.category == selectedCategory }

        switch sortOrder {
        case .dateDescending:
            return base.sorted { $0.modificationDate > $1.modificationDate }
        case .dateAscending:
            return base.sorted { $0.modificationDate < $1.modificationDate }
        case .sizeDescending:
            return base.sorted { $0.fileSize > $1.fileSize }
        case .sizeAscending:
            return base.sorted { $0.fileSize < $1.fileSize }
        }
    }

    var body: some View {
        NavigationStack {
            List(selection: $selectedIDs) {
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
                            service.scanMedia(in: selectedApp)
                        } label: {
                            Label("Сканировать медиафайлы", systemImage: "waveform.and.magnifyingglass")
                        }
                        .disabled(service.isScanning)
                    }
                } header: {
                    Label("Источник", systemImage: "folder.fill")
                }

                if service.isScanning {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(service.statusMessage)
                                    .font(.subheadline)
                            }
                            Button(role: .destructive) {
                                service.cancelScan()
                            } label: {
                                Label("Отменить сканирование", systemImage: "xmark.circle")
                            }
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Label("Сканирование", systemImage: "hourglass")
                    }
                }

                if !service.items.isEmpty {
                    Section {
                        Picker("Категория", selection: $selectedCategory) {
                            ForEach(MediaCategory.allCases) { category in
                                Text(category.rawValue).tag(category)
                            }
                        }
                        .pickerStyle(.menu)

                        Picker("Сортировка", selection: $sortOrder) {
                            ForEach(MediaSortOrder.allCases) { order in
                                Text(order.rawValue).tag(order)
                            }
                        }
                        .pickerStyle(.menu)
                    } header: {
                        Label("Фильтры (\(filteredItems.count))", systemImage: "line.3.horizontal.decrease.circle")
                    }

                    Section {
                        ForEach(filteredItems) { item in
                            Button {
                                if editMode == .inactive {
                                    previewItem = item
                                }
                            } label: {
                                mediaRow(item)
                            }
                            .tag(item.id)
                            .contextMenu {
                                Button {
                                    previewItem = item
                                } label: {
                                    Label("Просмотреть", systemImage: "eye")
                                }

                                if item.canSaveToPhotos {
                                    Button {
                                        Task {
                                            do {
                                                try await service.saveToPhotoLibrary(item: item)
                                            } catch {
                                                errorMessage = error.localizedDescription
                                            }
                                        }
                                    } label: {
                                        Label("Сохранить в Фото", systemImage: "square.and.arrow.down")
                                    }
                                }
                            }
                        }
                    } header: {
                        Label("Найденные файлы", systemImage: "photo.stack.fill")
                    }
                } else if !service.isScanning && selectedApp != nil {
                    Section {
                        ContentUnavailableView(
                            "Нет найденных медиафайлов",
                            systemImage: "photo.on.rectangle.angled",
                            description: Text("Нажмите «Сканировать медиафайлы» для поиска по Magic Bytes в Documents и Library.")
                        )
                    }
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, $editMode)
            .navigationTitle("Медиа")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !filteredItems.isEmpty {
                        if editMode == .active && !selectedIDs.isEmpty {
                            Button {
                                exportSelectedAsZip()
                            } label: {
                                if isCreatingZip {
                                    ProgressView()
                                } else {
                                    Label("ZIP (\(selectedIDs.count))", systemImage: "archivebox.fill")
                                }
                            }
                            .disabled(isCreatingZip)
                        }

                        EditButton()
                    }
                }
            }
            .sheet(isPresented: $showAppPicker) {
                AppPickerSheet(provider: provider, selectedApp: $selectedApp)
            }
            .sheet(item: $previewItem) { item in
                MediaPreviewSheet(item: item, service: service)
            }
            .sheet(isPresented: $showZipShare) {
                if let zipShareURL {
                    ActivityShareSheet(activityItems: [zipShareURL])
                }
            }
            .onChange(of: selectedApp) { _, newApp in
                selectedIDs.removeAll()
                editMode = .inactive
                if let newApp {
                    service.scanMedia(in: newApp)
                }
            }
            .alert("Ошибка", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("ОК", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func mediaRow(_ item: MediaItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.category.systemImage)
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.displayFileName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if item.isRoundVideo {
                        Text("Кружок")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                }

                Text(item.relativePath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(item.formattedSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Text(".\(item.detectedExtension.uppercased())")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func exportSelectedAsZip() {
        let chosen = filteredItems.filter { selectedIDs.contains($0.id) }
        guard !chosen.isEmpty else { return }

        isCreatingZip = true
        Task.detached(priority: .userInitiated) {
            do {
                let zipURL = try service.createZipArchive(for: chosen)
                await MainActor.run {
                    self.zipShareURL = zipURL
                    self.isCreatingZip = false
                    self.showZipShare = true
                }
            } catch {
                await MainActor.run {
                    self.isCreatingZip = false
                    self.errorMessage = "Ошибка упаковки ZIP: \(error.localizedDescription)"
                }
            }
        }
    }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
