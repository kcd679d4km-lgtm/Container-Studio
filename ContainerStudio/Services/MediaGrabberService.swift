//
//  MediaGrabberService.swift
//  ContainerStudio
//

import AVFoundation
import Foundation
import Observation
import Photos

@Observable
final class MediaGrabberService {
    private(set) var items: [MediaItem] = []
    private(set) var isScanning: Bool = false
    private(set) var scannedFilesCount: Int = 0
    private(set) var statusMessage: String = ""

    private var scanTask: Task<Void, Never>?
    private let accessProvider = ContainerAccessProvider.shared

    private static let minimumFileSize: UInt64 = 4096 // 4 КБ
    private static let roundVideoMaxBytes: UInt64 = 25 * 1024 * 1024 // 25 МБ

    @MainActor
    func cancelScan() {
        scanTask?.cancel()
        isScanning = false
        statusMessage = "Сканирование отменено"
    }

    @MainActor
    func scanMedia(in app: AppContainerInfo) {
        scanTask?.cancel()
        items = []
        scannedFilesCount = 0
        isScanning = true
        statusMessage = "Подготовка к сканированию..."

        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let rootURL = app.containerURL
            let targetFolders = ["Documents", "Library"].map {
                rootURL.appendingPathComponent($0, isDirectory: true)
            }

            var candidateFiles: [(url: URL, size: UInt64, date: Date, relativePath: String)] = []

            for folderURL in targetFolders {
                if Task.isCancelled { break }
                self.accessProvider.ensureAccess(to: folderURL)
                self.collectCandidateFiles(
                    in: folderURL,
                    containerRoot: rootURL,
                    into: &candidateFiles
                )
            }

            if Task.isCancelled {
                await MainActor.run {
                    self.isScanning = false
                    self.statusMessage = "Сканирование отменено"
                }
                return
            }

            await MainActor.run {
                self.statusMessage = "Анализ сигнатур (\(candidateFiles.count) файлов)..."
            }

            var discovered: [MediaItem] = []
            var processed = 0

            await withTaskGroup(of: MediaItem?.self) { group in
                let maxConcurrent = 6
                var iterator = candidateFiles.makeIterator()

                for _ in 0..<maxConcurrent {
                    if let next = iterator.next() {
                        group.addTask { [weak self] in
                            guard !Task.isCancelled else { return nil }
                            return await self?.inspectFile(next)
                        }
                    }
                }

                for await result in group {
                    if Task.isCancelled { break }
                    processed += 1
                    if let mediaItem = result {
                        discovered.append(mediaItem)
                    }

                    if processed % 25 == 0 || processed == candidateFiles.count {
                        let currentCount = processed
                        let foundCount = discovered.count
                        await MainActor.run {
                            self.scannedFilesCount = currentCount
                            self.statusMessage = "Проверено \(currentCount) из \(candidateFiles.count) • Найдено: \(foundCount)"
                        }
                    }

                    if let next = iterator.next(), !Task.isCancelled {
                        group.addTask { [weak self] in
                            guard !Task.isCancelled else { return nil }
                            return await self?.inspectFile(next)
                        }
                    }
                }
            }

            discovered.sort { $0.modificationDate > $1.modificationDate }

            await MainActor.run {
                self.items = discovered
                self.isScanning = false
                self.statusMessage = "Найдено медиафайлов: \(discovered.count)"
            }
        }
    }

    private nonisolated func collectCandidateFiles(
        in directory: URL,
        containerRoot: URL,
        into results: inout [(url: URL, size: UInt64, date: Date, relativePath: String)]
    ) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsPackageDescendants],
            errorHandler: { url, _ in
                // Попытка запросить токен для закрытой подпапки, не прерывая обход
                self.accessProvider.ensureAccess(to: url)
                return true
            }
        ) else {
            return
        }

        let rootPrefix = containerRoot.path.hasSuffix("/") ? containerRoot.path : containerRoot.path + "/"

        for case let fileURL as URL in enumerator {
            if Task.isCancelled { return }
            do {
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                if values.isDirectory == true {
                    accessProvider.ensureAccess(to: fileURL)
                    continue
                }
                guard values.isRegularFile == true,
                      let fileSize = values.fileSize,
                      UInt64(fileSize) >= Self.minimumFileSize else {
                    continue
                }

                let modDate = values.contentModificationDate ?? Date.distantPast
                let relPath = fileURL.path.hasPrefix(rootPrefix)
                    ? String(fileURL.path.dropFirst(rootPrefix.count))
                    : fileURL.lastPathComponent

                results.append((fileURL, UInt64(fileSize), modDate, relPath))
            } catch {
                // Игнорируем CocoaError / POSIXError на отдельном файле
                continue
            }
        }
    }

    private nonisolated func inspectFile(
        _ entry: (url: URL, size: UInt64, date: Date, relativePath: String)
    ) async -> MediaItem? {
        accessProvider.ensureAccess(to: entry.url)

        guard let header = readMagicHeader(at: entry.url) else {
            return nil
        }

        guard let detected = detectFormat(header: header, relativePath: entry.relativePath, fileExtension: entry.url.pathExtension.lowercased()) else {
            return nil
        }

        var isRoundVideo = false
        if detected.category == .video && entry.size <= Self.roundVideoMaxBytes {
            isRoundVideo = await checkIfRoundVideo(url: entry.url, ext: detected.ext)
        }

        return MediaItem(
            id: entry.url.path,
            url: entry.url,
            relativePath: entry.relativePath,
            fileName: entry.url.lastPathComponent,
            fileSize: entry.size,
            modificationDate: entry.date,
            category: detected.category,
            detectedExtension: detected.ext,
            isRoundVideo: isRoundVideo
        )
    }

    private nonisolated func readMagicHeader(at url: URL) -> [UInt8]? {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard let data = try handle.read(upToCount: 32), data.count >= 4 else {
                return nil
            }
            return [UInt8](data)
        } catch {
            return nil
        }
    }

    private nonisolated func detectFormat(
        header: [UInt8],
        relativePath: String,
        fileExtension: String
    ) -> (category: MediaCategory, ext: String)? {
        let count = header.count

        // 1. Аудио: OggS (0x4F 0x67 0x67 0x53)
        if count >= 4 && header[0] == 0x4F && header[1] == 0x67 && header[2] == 0x67 && header[3] == 0x53 {
            return (.audio, "ogg")
        }

        // 2. Аудио: ID3 (0x49 0x44 0x33) или MP3 frame sync (0xFF 0xFB / 0xFF 0xF3 / 0xFF 0xF2)
        if count >= 3 && header[0] == 0x49 && header[1] == 0x44 && header[2] == 0x33 {
            return (.audio, "mp3")
        }
        if count >= 2 && header[0] == 0xFF && (header[1] == 0xFB || header[1] == 0xF3 || header[1] == 0xF2) {
            return (.audio, "mp3")
        }

        // 3. Изображения: JPEG (0xFF 0xD8 0xFF), PNG (0x89 0x50 0x4E 0x47), WebP (RIFF + WEBP)
        if count >= 3 && header[0] == 0xFF && header[1] == 0xD8 && header[2] == 0xFF {
            return (.photo, "jpg")
        }
        if count >= 4 && header[0] == 0x89 && header[1] == 0x50 && header[2] == 0x4E && header[3] == 0x47 {
            return (.photo, "png")
        }
        if count >= 12 &&
            header[0] == 0x52 && header[1] == 0x49 && header[2] == 0x46 && header[3] == 0x46 && // RIFF
            header[8] == 0x57 && header[9] == 0x45 && header[10] == 0x42 && header[11] == 0x50 { // WEBP
            return (.photo, "webp")
        }

        // 4. ISO Base Media (ftyp со смещением 4: 0x66 0x74 0x79 0x70)
        if count >= 12 && header[4] == 0x66 && header[5] == 0x74 && header[6] == 0x79 && header[7] == 0x70 {
            // Проверяем ftypM4A (0x4D 0x34 0x41)
            if header[8] == 0x4D && header[9] == 0x34 && header[10] == 0x41 {
                return (.audio, "m4a")
            }
            // Проверяем QuickTime ftypqt
            if header[8] == 0x71 && header[9] == 0x74 {
                return (.video, "mov")
            }
            return (.video, "mp4")
        }

        // 5. Стикеры (.tgs): Gzip-заголовок 0x1F 0x8B в директориях кэша стикеров
        if count >= 2 && header[0] == 0x1F && header[1] == 0x8B {
            let lowerPath = relativePath.lowercased()
            if fileExtension == "tgs" ||
                lowerPath.contains("sticker") ||
                lowerPath.contains("tgs") ||
                lowerPath.contains("emoji") {
                return (.sticker, "tgs")
            }
        }

        return nil
    }

    private nonisolated func checkIfRoundVideo(url: URL, ext: String) async -> Bool {
        // Для проверки через AVAsset создаём временную ссылку/копию с расширением, если файл без расширения
        var assetURL = url
        var tempURL: URL?

        if url.pathExtension.lowercased() != ext {
            let candidateTemp = FileManager.default.temporaryDirectory
                .appendingPathComponent("probe_\(UUID().uuidString).\(ext)")
            do {
                try FileManager.default.copyItem(at: url, to: candidateTemp)
                assetURL = candidateTemp
                tempURL = candidateTemp
            } catch {
                return false
            }
        }

        defer {
            if let tempURL {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        let asset = AVURLAsset(url: assetURL)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { return false }
            let naturalSize = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let transformed = naturalSize.applying(transform)
            let width = abs(transformed.width)
            let height = abs(transformed.height)
            guard width > 0 && height > 0 else { return false }
            let ratio = width / height
            return abs(ratio - 1.0) <= 0.08
        } catch {
            return false
        }
    }

    // MARK: - Экспорт и упаковка

    nonisolated func prepareExportURL(for item: MediaItem) throws -> URL {
        accessProvider.ensureAccess(to: item.url)
        let exportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContainerStudioExport", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

        let destination = exportDir.appendingPathComponent(item.displayFileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: item.url, to: destination)
        return destination
    }

    nonisolated func createZipArchive(for items: [MediaItem]) throws -> URL {
        let fm = FileManager.default
        let stagingDir = fm.temporaryDirectory.appendingPathComponent("MediaExport_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        defer {
            try? fm.removeItem(at: stagingDir)
        }

        var usedNames: [String: Int] = [:]
        for item in items {
            accessProvider.ensureAccess(to: item.url)
            let baseName = (item.displayFileName as NSString).deletingPathExtension
            let ext = (item.displayFileName as NSString).pathExtension
            var finalName = item.displayFileName
            if let count = usedNames[finalName] {
                usedNames[finalName] = count + 1
                finalName = ext.isEmpty ? "\(baseName)_\(count)" : "\(baseName)_\(count).\(ext)"
            } else {
                usedNames[finalName] = 1
            }

            let target = stagingDir.appendingPathComponent(finalName)
            try? fm.copyItem(at: item.url, to: target)
        }

        var coordinatorError: NSError?
        var copyError: Error?
        let zipOutputURL = fm.temporaryDirectory.appendingPathComponent("ContainerStudio_Media_\(Int(Date().timeIntervalSince1970)).zip")
        if fm.fileExists(atPath: zipOutputURL.path) {
            try? fm.removeItem(at: zipOutputURL)
        }

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: stagingDir, options: .forUploading, error: &coordinatorError) { zippedURL in
            do {
                try fm.copyItem(at: zippedURL, to: zipOutputURL)
            } catch {
                copyError = error
            }
        }

        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
        return zipOutputURL
    }

    func saveToPhotoLibrary(item: MediaItem) async throws {
        guard item.canSaveToPhotos else {
            throw NSError(domain: "ContainerStudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Формат .\(item.detectedExtension) не поддерживается галереей «Фото»"])
        }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "ContainerStudio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Нет доступа к галерее «Фото». Разрешите доступ в Настройках."])
        }

        let tempURL = try prepareExportURL(for: item)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try await PHPhotoLibrary.shared().performChanges {
            if item.category == .video {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: tempURL)
            } else {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: tempURL)
            }
        }
    }
}
