//
//  AppContainerInfo.swift
//  ContainerStudio
//

import Foundation

struct AppContainerInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let bundleID: String
    let containerURL: URL
    var dataSize: UInt64?

    var formattedSize: String {
        guard let dataSize else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(dataSize), countStyle: .file)
    }

    var isSystemApp: Bool {
        bundleID.hasPrefix("com.apple.")
    }
}
