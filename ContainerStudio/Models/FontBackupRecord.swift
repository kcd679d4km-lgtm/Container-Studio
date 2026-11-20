//
//  FontBackupRecord.swift
//  ContainerStudio
//

import Foundation

struct FontBackupRecord: Codable, Identifiable, Hashable {
    let id: String
    let bundleID: String
    let originalRelativePath: String
    let originalPath: String
    let originalFileName: String
    let backupPath: String
    let pathHash: String
    let backupDate: Date
    let originalSize: UInt64

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(originalSize), countStyle: .file)
    }
}
