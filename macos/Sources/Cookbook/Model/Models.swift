import AppKit
import Foundation

/// Shared UI/conversion types (not app state — that lives in AppModel).

enum ConvertMode: String, CaseIterable, Identifiable {
    case xtch
    case pdf
    var id: String { rawValue }
}

struct DeviceInfo: Identifiable, Hashable, Codable {
    var key: String
    var label: String
    var width: Int
    var height: Int
    var supersample: Int
    var orientation: String
    var id: String { key }

    var menuTitle: String {
        let name = label.isEmpty ? key : label
        return "\(name) (\(width)×\(height))"
    }

    /// Native panel pixels after applying landscape swap.
    var panelSize: (width: Int, height: Int) {
        orientation == "landscape" ? (height, width) : (width, height)
    }
}

struct InputFile: Identifiable, Hashable {
    var path: String
    var stage: String?
    var message: String?
    var percent: Double?
    var detectedLanguage: String?
    var outputPath: String?
    var log: [String] = []
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var canPreviewXtch: Bool {
        guard let outputPath else { return false }
        return URL(fileURLWithPath: outputPath).pathExtension.lowercased() == "xtch"
    }
}

struct PreviewSession: Identifiable {
    let id = UUID()
    let path: String
    var title: String
    var status: String
    var images: [NSImage] = []
}

struct DeviceDraft: Identifiable, Hashable {
    var id = UUID()
    var key: String
    var label: String
    var width: Int
    var height: Int
    var supersample: Int
    var orientation: String
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let s): return s
        }
    }
}
