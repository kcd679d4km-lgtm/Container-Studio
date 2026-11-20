//
//  FontSwapperService.swift
//  ContainerStudio
//

import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import Observation
import UIKit

@Observable
final class FontSwapperService {
    private(set) var fonts: [FontItem] = []
    private(set) var allBackups: [FontBackupRecord] = []
    private(set) var isScanning: Bool = false
    private(set) var statusMessage: String = ""

    private var scanTask: Task<Void, Never>?
    private let accessProvider = ContainerAccessProvider.shared

    private static let supportedExtensions: Set<String> = ["ttf", "otf", "ttc", "woff2"]

    init() {
        loadRegistry()
    }

    // MARK: - Хранилище бэкапов

    private var backupsRootURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("FontBackups", isDirectory: true)
    }

    private var registryURL: URL {
        backupsRootURL.appendingPathComponent("registry.json")
    }

    func loadRegistry() {
        let fm = FileManager.default
        try? fm.createDirectory(at: backupsRootURL, withIntermediateDirectories: true)

        guard fm.fileExists(atPath: registryURL.path),
              let data = try? Data(contentsOf: registryURL),
              let decoded = try? JSONDecoder().decode([FontBackupRecord].self, from: data) else {
            allBackups = []
            return
        }
        allBackups = decoded.sorted { $0.backupDate > $1.backupDate }
    }

    private func saveRegistry() throws {
        try FileManager.default.createDirectory(at: backupsRootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(allBackups)
        try data.write(to: registryURL, options: .atomic)
    }

    // MARK: - Сканирование шрифтов

    @MainActor
    func cancelScan() {
        scanTask?.cancel()
        isScanning = false
        statusMessage = "Поиск отменён"
    }

    @MainActor
    func scanFonts(in app: AppContainerInfo) {
        scanTask?.cancel()
        fonts = []
        isScanning = true
        statusMessage = "Поиск шрифтов в Documents и Library..."
        loadRegistry()

        let currentBackups = allBackups.filter { $0.bundleID == app.bundleID }
        let backupByPath = Dictionary(uniqueKeysWithValues: currentBackups.map { ($0.originalPath, $0) })

        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let rootURL = app.containerURL
            let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
            var found: [FontItem] = []

            for folder in ["Documents", "Library"] {
                if Task.isCancelled { break }
                let folderURL = rootURL.appendingPathComponent(folder, isDirectory: true)
                self.accessProvider.ensureAccess(to: folderURL)

                guard let enumerator = FileManager.default.enumerator(
                    at: folderURL,
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
                    options: [.skipsPackageDescendants],
                    errorHandler: { url, _ in
                        self.accessProvider.ensureAccess(to: url)
                        return true
                    }
                ) else {
                    continue
                }

                for case let fileURL as URL in enumerator {
                    if Task.isCancelled { break }
                    do {
                        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
                        if values.isDirectory == true {
                            self.accessProvider.ensureAccess(to: fileURL)
                            continue
                        }
                        guard values.isRegularFile == true else { continue }

                        let ext = fileURL.pathExtension.lowercased()
                        guard let format = FontFormat(rawValue: ext) else { continue }

                        let size = UInt64(max(0, values.fileSize ?? 0))
                        let relPath = fileURL.path.hasPrefix(rootPrefix)
                            ? String(fileURL.path.dropFirst(rootPrefix.count))
                            : fileURL.lastPathComponent

                        let backupRecord = backupByPath[fileURL.path]

                        found.append(
                            FontItem(
                                id: fileURL.path,
                                url: fileURL,
                                relativePath: relPath,
                                fileName: fileURL.lastPathComponent,
                                fileSize: size,
                                format: format,
                                isModified: backupRecord != nil,
                                backupRecord: backupRecord
                            )
                        )
                    } catch {
                        continue
                    }
                }
            }

            found.sort {
                $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending
            }

            await MainActor.run {
                self.fonts = found
                self.isScanning = false
                self.statusMessage = "Найдено шрифтов: \(found.count)"
            }
        }
    }

    // MARK: - Живой предпросмотр шрифта через CoreText

    nonisolated static func loadUIFont(from url: URL, size: CGFloat = 17) -> UIFont? {
        ContainerAccessProvider.shared.ensureAccess(to: url)
        guard let data = try? Data(contentsOf: url),
              let provider = CGDataProvider(data: data as CFData),
              let cgFont = CGFont(provider) else {
            return nil
        }
        let ctFont = CTFontCreateWithGraphicsFont(cgFont, size, nil, nil)
        return ctFont as UIFont
    }

    // MARK: - Подмена и обязательный бэкап

    @MainActor
    func replaceFont(_ item: FontItem, with sourceURL: URL, for app: AppContainerInfo) throws {
        let securityScoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if securityScoped { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let newFontData = try Data(contentsOf: sourceURL)
        guard !newFontData.isEmpty else {
            throw NSError(domain: "ContainerStudio", code: 10, userInfo: [NSLocalizedDescriptionKey: "Выбранный файл шрифта пуст"])
        }

        accessProvider.ensureAccess(to: item.url)

        let fm = FileManager.default
        let pathHash = Self.sha256Hex(item.relativePath)
        let backupFolder = backupsRootURL
            .appendingPathComponent(app.bundleID, isDirectory: true)
            .appendingPathComponent(pathHash, isDirectory: true)
        let backupFileURL = backupFolder.appendingPathComponent(item.fileName)

        // Обязательный бэкап оригинала: если бэкап уже существует — не перезаписываем его
        var activeRecord = allBackups.first { $0.originalPath == item.url.path }
        if !fm.fileExists(atPath: backupFileURL.path) {
            try fm.createDirectory(at: backupFolder, withIntermediateDirectories: true)
            try fm.copyItem(at: item.url, to: backupFileURL)

            let record = FontBackupRecord(
                id: "\(app.bundleID)::\(pathHash)",
                bundleID: app.bundleID,
                originalRelativePath: item.relativePath,
                originalPath: item.url.path,
                originalFileName: item.fileName,
                backupPath: backupFileURL.path,
                pathHash: pathHash,
                backupDate: Date(),
                originalSize: item.fileSize
            )
            allBackups.removeAll { $0.originalPath == item.url.path }
            allBackups.insert(record, at: 0)
            try saveRegistry()
            activeRecord = record
        } else if activeRecord == nil {
            let attrs = try? fm.attributesOfItem(atPath: backupFileURL.path)
            let origSize = (attrs?[.size] as? NSNumber)?.uint64Value ?? item.fileSize
            let record = FontBackupRecord(
                id: "\(app.bundleID)::\(pathHash)",
                bundleID: app.bundleID,
                originalRelativePath: item.relativePath,
                originalPath: item.url.path,
                originalFileName: item.fileName,
                backupPath: backupFileURL.path,
                pathHash: pathHash,
                backupDate: Date(),
                originalSize: origSize
            )
            allBackups.insert(record, at: 0)
            try saveRegistry()
            activeRecord = record
        }

        // Перезапись целевого файла с точным сохранением оригинального имени
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: item.url.path)
        try newFontData.write(to: item.url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: item.url.path)

        if let index = fonts.firstIndex(where: { $0.id == item.id }) {
            fonts[index].isModified = true
            fonts[index].backupRecord = activeRecord
        }
    }

    @MainActor
    func restoreOriginal(for record: FontBackupRecord) throws {
        let fm = FileManager.default
        let backupURL = URL(fileURLWithPath: record.backupPath)
        let targetURL = URL(fileURLWithPath: record.originalPath)

        guard fm.fileExists(atPath: backupURL.path) else {
            throw NSError(domain: "ContainerStudio", code: 11, userInfo: [NSLocalizedDescriptionKey: "Файл резервной копии не найден"])
        }

        accessProvider.ensureAccess(to: targetURL)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: targetURL.path)

        let originalData = try Data(contentsOf: backupURL)
        try originalData.write(to: targetURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: targetURL.path)

        // Удаляем бэкап после успешного восстановления
        try? fm.removeItem(at: backupURL)
        let hashFolder = backupURL.deletingLastPathComponent()
        if let contents = try? fm.contentsOfDirectory(atPath: hashFolder.path), contents.isEmpty {
            try? fm.removeItem(at: hashFolder)
        }

        allBackups.removeAll { $0.id == record.id }
        try saveRegistry()

        if let index = fonts.firstIndex(where: { $0.url.path == record.originalPath }) {
            fonts[index].isModified = false
            fonts[index].backupRecord = nil
        }
    }

    private static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
