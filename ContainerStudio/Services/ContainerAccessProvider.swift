//
//  ContainerAccessProvider.swift
//  ContainerStudio
//

import Foundation
import Observation
import UIKit

@Observable
final class ContainerAccessProvider {
    static let shared = ContainerAccessProvider()

    struct LogEntry: Identifiable, Hashable {
        let id = UUID()
        let timestamp: Date
        let message: String
    }

    private(set) var logs: [LogEntry] = []
    private(set) var activeAppGroup: String?
    private(set) var isProviderReady: Bool = false
    private(set) var statusDescription: String = "Не инициализирован"
    private(set) var deviceModel: String = ""
    private(set) var iosVersion: String = ""

    private(set) var installedApps: [AppContainerInfo] = []
    private(set) var isScanningApps: Bool = false
    private(set) var scanProgress: Double = 0
    private(set) var scanStatusText: String = ""

    private let handleLock = NSLock()
    private var activeHandles: [String: Int64] = [:]
    private var appScanTask: Task<Void, Never>?
    private var isAppScanCancelled = false

    private static let appContainersRoot = "/private/var/mobile/Containers/Data/Application"
    private static let fallbackAppGroup = "group.com.containerstudio.app"

    private init() {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        self.iosVersion = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        self.deviceModel = Self.humanReadableDeviceModel()
    }

    deinit {
        releaseAllHandles()
    }

    @MainActor
    func appendLog(_ message: String) {
        logs.append(LogEntry(timestamp: Date(), message: message))
    }

    @MainActor
    func clearLogs() {
        logs.removeAll()
    }

    @MainActor
    func initializeProvider() {
        logs.removeAll()

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        appendLog("[*] ContainerStudio v\(version) (Release)")
        appendLog("[*] Running on iOS \(iosVersion), \(deviceModel)")

        let detectedGroup = cs_active_app_group()
        let groupID = detectedGroup ?? Self.fallbackAppGroup
        self.activeAppGroup = detectedGroup

        if let detectedGroup {
            appendLog("(wq) Using app group: \(detectedGroup)")
            if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: detectedGroup) {
                let probe = grantAccess(to: Self.appContainersRoot)
                if probe.success || FileManager.default.fileExists(atPath: groupURL.path) {
                    isProviderReady = true
                    statusDescription = "Готов к работе"
                    appendLog("[+] Container provider ready")
                } else {
                    isProviderReady = false
                    statusDescription = "Ошибка: \(probe.error)"
                    appendLog("[-] Provider probe failed: \(probe.error)")
                }
            } else {
                isProviderReady = false
                statusDescription = "App Group недоступен в песочнице"
                appendLog("[-] App group container URL unavailable for \(groupID)")
            }
        } else {
            isProviderReady = false
            statusDescription = "Отсутствует entitlement App Groups"
            appendLog("(wq) Using app group: <none> (fallback: \(Self.fallbackAppGroup))")
            appendLog("[-] Missing com.apple.security.application-groups entitlement")
        }
    }

    @discardableResult
    nonisolated func grantAccess(to path: String, preferredAltFlags: Bool? = nil) -> (success: Bool, handle: Int64, error: String) {
        guard !path.isEmpty else {
            return (false, -1, "Пустой путь")
        }

        let normalized = (path as NSString).standardizingPath

        handleLock.lock()
        if let existing = activeHandles[normalized], existing >= 0 {
            handleLock.unlock()
            return (true, existing, "cached")
        }
        handleLock.unlock()

        let groupID = cs_active_app_group() ?? Self.fallbackAppGroup
        let isAppGroupPath = normalized.contains("/Containers/Shared/AppGroup")
        let isIOS26Plus = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
        let initialAlt = preferredAltFlags ?? (isAppGroupPath && isIOS26Plus)

        var res = worse_query(normalized, groupID, initialAlt, false)
        if res < 0 && res != -255 && res != -1 {
            res = worse_query(normalized, groupID, !initialAlt, false)
        }

        if res >= 0 {
            handleLock.lock()
            activeHandles[normalized] = res
            handleLock.unlock()
            return (true, res, "ok")
        }

        return (false, res, Self.describeWorseQueryError(res))
    }

    nonisolated func ensureAccess(to url: URL) {
        _ = grantAccess(to: url.path)
        let parent = url.deletingLastPathComponent().path
        if !parent.isEmpty && parent != "/" {
            _ = grantAccess(to: parent)
        }
    }

    nonisolated func releaseAllHandles() {
        handleLock.lock()
        let handles = activeHandles.values
        activeHandles.removeAll()
        handleLock.unlock()

        for handle in handles where handle >= 0 {
            worse_query_release(handle)
        }
    }

    @MainActor
    func cancelAppDiscovery() {
        isAppScanCancelled = true
        appScanTask?.cancel()
        isScanningApps = false
        scanStatusText = "Поиск отменён"
    }

    @MainActor
    func discoverAppContainers(forceRefresh: Bool = false) {
        if isScanningApps { return }
        if !forceRefresh && !installedApps.isEmpty { return }

        isScanningApps = true
        isAppScanCancelled = false
        scanProgress = 0
        scanStatusText = "Определение границы inode..."
        appendLog("[*] Scanning app data containers...")

        appScanTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let rootPath = Self.appContainersRoot
            var candidatePaths: [String] = []

            // 1. Try direct directory listing first if container access permits
            _ = self.grantAccess(to: rootPath)
            if let direct = try? FileManager.default.contentsOfDirectory(atPath: rootPath) {
                candidatePaths = direct
                    .filter { !$0.hasPrefix(".") }
                    .map { (rootPath as NSString).appendingPathComponent($0) }
            }

            // 2. Fall back to pathleak inode enumeration (standard on iOS 26)
            if candidatePaths.isEmpty {
                let baseline = self.computeBaselineInode()
                let maxInode = baseline > 0 ? baseline : 7_500_000

                await MainActor.run {
                    self.scanStatusText = "Перебор контейнеров (pathleak)..."
                }

                let leaked = pathleak_with_progress(
                    rootPath,
                    maxInode,
                    { [weak self] in
                        self?.isAppScanCancelled ?? true
                    },
                    { [weak self] current, total, found in
                        let fraction = total > 0 ? Double(current) / Double(total) : 0
                        Task { @MainActor [weak self] in
                            self?.scanProgress = fraction
                            self?.scanStatusText = "Найдено контейнеров: \(found) (\(Int(fraction * 100))%)"
                        }
                    }
                ) ?? []

                candidatePaths = leaked
            }

            if self.isAppScanCancelled || Task.isCancelled {
                await MainActor.run {
                    self.isScanningApps = false
                    self.appendLog("[!] Container scan cancelled")
                }
                return
            }

            let displayNamesMap = cs_all_bundle_display_names()
            var discovered: [AppContainerInfo] = []

            for path in candidatePaths {
                if self.isAppScanCancelled || Task.isCancelled { break }
                let url = URL(fileURLWithPath: path, isDirectory: true)
                _ = self.grantAccess(to: path)

                guard let bundleID = self.resolveBundleID(forContainerAt: url) else {
                    continue
                }

                let displayName = displayNamesMap[bundleID]
                    ?? cs_display_name_for_bundle_id(bundleID)
                    ?? Self.fallbackDisplayName(from: bundleID)

                let dataSize = self.measureAppDataSize(at: url)

                discovered.append(
                    AppContainerInfo(
                        id: path,
                        name: displayName,
                        bundleID: bundleID,
                        containerURL: url,
                        dataSize: dataSize
                    )
                )
            }

            discovered.sort {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

            await MainActor.run {
                self.installedApps = discovered
                self.isScanningApps = false
                self.scanProgress = 1.0
                self.scanStatusText = "Найдено приложений: \(discovered.count)"
                self.appendLog("[+] Discovered \(discovered.count) app containers")
            }
        }
    }

    private nonisolated func computeBaselineInode() -> UInt64 {
        let fm = FileManager.default
        let probeURL = fm.temporaryDirectory.appendingPathComponent(".cs_inode_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: probeURL) }

        do {
            try Data("cs".utf8).write(to: probeURL)
            var st = stat()
            if stat(probeURL.path, &st) == 0 {
                return UInt64(st.st_ino)
            }
        } catch {
            return 0
        }
        return 0
    }

    private nonisolated func resolveBundleID(forContainerAt containerURL: URL) -> String? {
        if let xattrBID = cs_bundle_id_from_xattr(containerURL.path), !xattrBID.isEmpty {
            return xattrBID
        }

        let metadataURL = containerURL.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
        _ = grantAccess(to: metadataURL.path)
        if let data = try? Data(contentsOf: metadataURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let bid = plist["MCMMetadataIdentifier"] as? String,
           !bid.isEmpty {
            return bid
        }

        return nil
    }

    nonisolated func measureAppDataSize(at containerURL: URL) -> UInt64 {
        var total: UInt64 = 0
        for subfolder in ["Documents", "Library"] {
            let subURL = containerURL.appendingPathComponent(subfolder, isDirectory: true)
            _ = grantAccess(to: subURL.path)
            total += safeDirectorySize(at: subURL)
        }
        return total
    }

    private nonisolated func safeDirectorySize(at url: URL) -> UInt64 {
        let fm = FileManager.default
        var total: UInt64 = 0

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        for case let fileURL as URL in enumerator {
            do {
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values.isRegularFile == true, let size = values.fileSize, size > 0 {
                    total += UInt64(size)
                }
            } catch {
                continue
            }
        }

        return total
    }

    private static func fallbackDisplayName(from bundleID: String) -> String {
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    private static func describeWorseQueryError(_ code: Int64) -> String {
        switch code {
        case -1: return "App Group недоступен"
        case -2: return "Не удалось загрузить libsystem_containermanager"
        case -3: return "Ошибка создания container_query"
        case -4: return "Не удалось создать symlink в Caches"
        case -5: return "containermanagerd отклонил запрос"
        case -6: return "Ядро отклонило выдачу sandbox token"
        case -255: return "Целевой путь не существует"
        default: return "Код ошибки \(code)"
        }
    }

    private static func humanReadableDeviceModel() -> String {
        let identifier = cs_device_machine_identifier()
        let map: [String: String] = [
            "iPhone15,2": "iPhone 14 Pro",
            "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15",
            "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro",
            "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,1": "iPhone 16 Pro",
            "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16",
            "iPhone17,4": "iPhone 16 Plus",
            "iPhone17,5": "iPhone 16e"
        ]
        return map[identifier] ?? identifier
    }
}
