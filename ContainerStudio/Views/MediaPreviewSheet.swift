//
//  MediaPreviewSheet.swift
//  ContainerStudio
//

import AVKit
import SwiftUI
import UIKit

struct MediaPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    let service: MediaGrabberService

    @State private var player: AVPlayer?
    @State private var exportURL: URL?
    @State private var loadedImage: UIImage?
    @State private var imageScale: CGFloat = 1.0
    @State private var isSavingPhotos = false
    @State private var alertMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if item.supportsAVPlayer {
                    VStack(spacing: 16) {
                        if let player {
                            VideoPlayer(player: player)
                                .frame(maxWidth: .infinity, maxHeight: item.category == .audio ? 220 : .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .padding()
                        } else {
                            ProgressView("Подготовка плеера...")
                        }

                        if item.category == .audio {
                            metadataList
                        }
                    }
                } else if item.category == .photo {
                    GeometryReader { _ in
                        ScrollView([.horizontal, .vertical], showsIndicators: false) {
                            if let loadedImage {
                                Image(uiImage: loadedImage)
                                    .resizable()
                                    .scaledToFit()
                                    .scaleEffect(imageScale)
                                    .gesture(
                                        MagnifyGesture()
                                            .onChanged { value in
                                                imageScale = max(1.0, min(value.magnification, 5.0))
                                            }
                                    )
                                    .onTapGesture(count: 2) {
                                        withAnimation(.spring(duration: 0.25)) {
                                            imageScale = imageScale > 1.0 ? 1.0 : 2.5
                                        }
                                    }
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                ProgressView("Загрузка изображения...")
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    }
                    .background(Color(.systemBackground))
                } else {
                    metadataList
                }
            }
            .navigationTitle(item.displayFileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть") {
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if item.canSaveToPhotos {
                        Button {
                            Task { await saveToPhotos() }
                        } label: {
                            if isSavingPhotos {
                                ProgressView()
                            } else {
                                Image(systemName: "square.and.arrow.down")
                            }
                        }
                        .disabled(isSavingPhotos)
                    }

                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            .alert("Статус", isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("ОК", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
            .onAppear {
                preparePreview()
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
        }
    }

    private var metadataList: some View {
        List {
            Section {
                LabeledContent("Файл", value: item.displayFileName)
                LabeledContent("Формат", value: ".\(item.detectedExtension.uppercased())")
                if item.isRoundVideo {
                    LabeledContent("Тип", value: "Видеокружок (1:1)")
                }
                LabeledContent("Размер", value: item.formattedSize)
                LabeledContent("Изменён", value: item.modificationDate.formatted(date: .abbreviated, time: .shortened))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Относительный путь")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(item.relativePath)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            } header: {
                Label("Метаданные", systemImage: "info.circle")
            }

            if let exportURL {
                Section {
                    ShareLink(item: exportURL) {
                        Label("Экспортировать файл", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func preparePreview() {
        do {
            let prepared = try service.prepareExportURL(for: item)
            self.exportURL = prepared

            if item.supportsAVPlayer {
                let avPlayer = AVPlayer(url: prepared)
                self.player = avPlayer
                avPlayer.play()
            } else if item.category == .photo {
                self.loadedImage = UIImage(contentsOfFile: prepared.path)
            }
        } catch {
            alertMessage = "Не удалось подготовить файл: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func saveToPhotos() async {
        isSavingPhotos = true
        defer { isSavingPhotos = false }
        do {
            try await service.saveToPhotoLibrary(item: item)
            alertMessage = "Сохранено в медиатеку «Фото»."
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}
