//
//  FontItem.swift
//  ContainerStudio
//

import Foundation

enum FontFormat: String, CaseIterable {
    case ttf
    case otf
    case ttc
    case woff2

    var supportsCoreTextPreview: Bool {
        self != .woff2
    }
}

struct FontItem: Identifiable, Hashable {
    let id: String
    let url: URL
    let relativePath: String
    let fileName: String
    let fileSize: UInt64
    let format: FontFormat
    var isModified: Bool
    var backupRecord: FontBackupRecord?

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }
}
