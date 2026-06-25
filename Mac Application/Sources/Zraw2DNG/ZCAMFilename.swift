import Foundation

struct ZCAMFileInfo {
    let cameraId: String
    let reelNumber: Int
    let clipNumber: Int
    let dateString: String
    let timeString: String
    let segmentNumber: Int

    var clipName: String {
        "\(cameraId)\(String(format: "%03d", reelNumber))_C\(String(format: "%04d", clipNumber))"
    }

    var reelName: String {
        "\(cameraId)\(String(format: "%03d", reelNumber))"
    }

    static func parse(from url: URL) -> ZCAMFileInfo? {
        let filename = url.deletingPathExtension().lastPathComponent
        // Pattern: A077_C0033_20240511235035_001
        // Groups:   camera reel  clip     date        time    segment
        let pattern = #/^([A-Za-z])(\d{3})_C(\d{4})_(\d{8})(\d{6})_(\d{3})$/#
        guard let match = try? pattern.firstMatch(in: filename) else { return nil }

        return ZCAMFileInfo(
            cameraId: String(match.1),
            reelNumber: Int(match.2) ?? 0,
            clipNumber: Int(match.3) ?? 0,
            dateString: String(match.4),
            timeString: String(match.5),
            segmentNumber: Int(match.6) ?? 0
        )
    }

    static func clipName(from url: URL) -> String {
        if let info = parse(from: url) {
            return info.clipName
        }
        return url.deletingPathExtension().lastPathComponent
    }
}
