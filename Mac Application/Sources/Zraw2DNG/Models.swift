import Foundation

enum ZRAWError: Error, LocalizedError {
    case failedToOpenFile(String)
    case invalidFormat(String)
    case decodingFailed(String)
    case dngWriteFailed(String)
    case audioExtractionFailed(String)
    case debayerFailed(String)

    var errorDescription: String? {
        switch self {
        case .failedToOpenFile(let msg): return msg
        case .invalidFormat(let msg): return msg
        case .decodingFailed(let msg): return msg
        case .dngWriteFailed(let msg): return msg
        case .audioExtractionFailed(let msg): return msg
        case .debayerFailed(let msg): return msg
        }
    }
}

enum QueueStatus: Equatable {
    case pending
    case loading
    case ready
    case processing(Int, Int)
    case completed
    case failed(String)
    case cancelled
    case warning(String)

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .loading: return "Loading..."
        case .ready: return "Ready"
        case .processing(let n, let total): return "\(n)/\(total)"
        case .completed: return "Done"
        case .failed(let e): return "Failed: \(e)"
        case .cancelled: return "Cancelled"
        case .warning(let msg): return "⚠ \(msg)"
        }
    }

    var isTerminal: Bool {
        if case .completed = self { return true }
        if case .failed = self { return true }
        if case .cancelled = self { return true }
        if case .warning = self { return true }
        return false
    }
}

enum CompressionOption: Int, CaseIterable, Identifiable {
    case uncompressed = 0
    case jpeg = 1

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .uncompressed: return "Uncompressed"
        case .jpeg: return "Lossless JPEG"
        }
    }
}

enum CameraModelOverride: String, CaseIterable, Identifiable, Sendable {
    case auto = ""
    case bmpcc6k = "Blackmagic Pocket Cinema Camera 6K"
    case bmpcc4k = "Blackmagic Pocket Cinema Camera 4K"
    case ursa = "Blackmagic URSA"
    case ursa46 = "Blackmagic URSA 4.6K"
    case varicam = "Panasonic Varicam RAW"
    case dji = "DJI FC4280"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto (from MOV)"
        default: return rawValue
        }
    }

    var dngCameraModel: String {
        switch self {
        case .dji: return "FC4280"
        default: return rawValue
        }
    }
}

struct ProcessingOptions: Sendable {
    var compression: CompressionOption = .uncompressed
    var outputDir: URL?
    var cameraModelOverride: CameraModelOverride = .auto
    var baselineExposure: Double = 3.0
    var baselineExposureUserSet = false
    var maxConcurrentFrames = 4
}

struct QueueItem: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    var status: QueueStatus = .pending
    var movieInfo: ZRAWMovInfo?
    var zcamInfo: ZCAMFileInfo?
    var error: String?
}
