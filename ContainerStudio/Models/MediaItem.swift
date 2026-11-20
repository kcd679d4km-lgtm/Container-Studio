//
//  MediaItem.swift
//  ContainerStudio
//

import Foundation

enum MediaCategory: String, CaseIterable, Identifiable {
    case all = "Все"
    case video = "Видео/Кружки"
    case audio = "Аудио"
    case photo = "Фото"
    case sticker = "Стикеры"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .video: return "video.fill"
        case .audio: return "waveform"
        case .photo: return "photo.fill"
        case .sticker: return "face.smiling.fill"
        }
    }
}

enum MediaSortOrder: String, CaseIterable, Identifiable {
    case dateDescending = "По дате (новые)"
    case dateAscending = "По дате (старые)"
    case sizeDescending = "По размеру (большие)"
    case sizeAscending = "По размеру (малые)"

    var id: String { rawValue }
}

struct MediaItem: Identifiable, Hashable {
    let id: String
    let url: URL
    let relativePath: String
    let fileName: String
    let fileSize: UInt64
    let modificationDate: Date
    let category: MediaCategory
    let detectedExtension: String
    let isRoundVideo: Bool

    var displayFileName: String {
        if url.pathExtension.lowercased() == detectedExtension {
            return fileName
        }
        return "\(fileName).\(detectedExtension)"
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }

    var canSaveToPhotos: Bool {
        ["mp4", "mov", "jpg", "png"].contains(detectedExtension)
    }

    var supportsAVPlayer: Bool {
        ["mp4", "mov", "m4a", "mp3"].contains(detectedExtension)
    }
}
