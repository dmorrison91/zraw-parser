import Foundation

struct WAVWriter {
    let numChannels: UInt16
    let sampleRate: UInt32
    let bitsPerSample: UInt16
    let reelName: String?
    let timecode: (hours: UInt8, minutes: UInt8, seconds: UInt8, frames: UInt8)?
    let timecodeFps: UInt32?
    let framerate: Double
    let framerateNumerator: UInt32
    let framerateDenominator: UInt32

    private let originationDate: String = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy:MM:dd"
        return fmt.string(from: Date())
    }()

    init(numChannels: UInt16, sampleRate: UInt32, bitsPerSample: UInt16,
         reelName: String? = nil,
         timecode: (hours: UInt8, minutes: UInt8, seconds: UInt8, frames: UInt8)? = nil,
         timecodeFps: UInt32? = nil,
         framerate: Double = 24.0,
         framerateNumerator: UInt32 = 24,
         framerateDenominator: UInt32 = 1) {
        self.numChannels = numChannels
        self.sampleRate = sampleRate
        self.bitsPerSample = bitsPerSample
        self.reelName = reelName
        self.timecode = timecode
        self.timecodeFps = timecodeFps
        self.framerate = framerate
        self.framerateNumerator = framerateNumerator
        self.framerateDenominator = framerateDenominator
    }

    // NOTE: BEXT + iXML both written. BEXT TimeReference is what Resolve
    // actually reads for timeline positioning. iXML provides additional
    // metadata and the TimeReference override.

    // NOTE: bextTimeReference() removed — using inline Double calculation
    // with video framerate instead. Old helper preserved below:
    //
    // private func bextTimeReference(tc: (hours: UInt8, minutes: UInt8, seconds: UInt8, frames: UInt8),
    //                                 fps: UInt32, sampleRate: UInt32) -> UInt64 {
    //     let totalFrames = UInt64(tc.hours) * UInt64(fps) * 3600
    //                     + UInt64(tc.minutes) * UInt64(fps) * 60
    //                     + UInt64(tc.seconds) * UInt64(fps)
    //                     + UInt64(tc.frames)
    //     return totalFrames * UInt64(sampleRate) / UInt64(fps)
    // }

    func write(audioData: Data, to url: URL) throws {
        guard numChannels > 0, sampleRate > 0, bitsPerSample > 0 else {
            throw ZRAWError.audioExtractionFailed("Invalid WAV parameters (channels=\(numChannels), rate=\(sampleRate), bits=\(bitsPerSample))")
        }
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(audioData.count)
        let audioDurationSec = Double(audioData.count) / Double(byteRate)
        if dataSize > 0 {
            print("[wav] writing \(audioData.count) bytes (~\(String(format: "%.2f", audioDurationSec))s) to \(url.lastPathComponent)")
        }

        // Log timecode metadata for sync debugging
        if let tc = timecode {
            let tcStr = String(format: "%02d:%02d:%02d:%02d", tc.hours, tc.minutes, tc.seconds, tc.frames)
            print("[wav] TC start=\(tcStr) tc_fps=\(timecodeFps ?? 24) framerate=\(framerate) @ \(sampleRate) Hz")
        }

        var wav = Data()

        // RIFF header
        wav.append("RIFF".data(using: .ascii)!)
        let fileSizePos = wav.count
        wav.append(contentsOf: [UInt8](repeating: 0, count: 4))
        wav.append("WAVE".data(using: .ascii)!)

        // BEXT chunk — Resolve reads TimeReference for timeline positioning
        let bextData = buildBextChunk()
        if !bextData.isEmpty {
            wav.append("bext".data(using: .ascii)!)
            var bextSize = UInt32(bextData.count).littleEndian
            withUnsafeBytes(of: &bextSize) { wav.append(contentsOf: $0) }
            wav.append(bextData)
            if bextData.count % 2 != 0 { wav.append(UInt8(0)) }
        }

        // iXML chunk — additional metadata
        let ixmlData = buildIXMLChunk()
        if !ixmlData.isEmpty {
            wav.append("iXML".data(using: .ascii)!)
            var ixmlSize = UInt32(ixmlData.count).littleEndian
            withUnsafeBytes(of: &ixmlSize) { wav.append(contentsOf: $0) }
            wav.append(ixmlData)
            if ixmlData.count % 2 != 0 { wav.append(UInt8(0)) }
        }

        // fmt chunk
        wav.append("fmt ".data(using: .ascii)!)
        let fmtSize = UInt32(16).littleEndian
        withUnsafeBytes(of: fmtSize) { wav.append(contentsOf: $0) }
        let audioFmt = UInt16(1).littleEndian
        withUnsafeBytes(of: audioFmt) { wav.append(contentsOf: $0) }
        withUnsafeBytes(of: numChannels.littleEndian) { wav.append(contentsOf: $0) }
        withUnsafeBytes(of: sampleRate.littleEndian) { wav.append(contentsOf: $0) }
        withUnsafeBytes(of: byteRate.littleEndian) { wav.append(contentsOf: $0) }
        withUnsafeBytes(of: blockAlign.littleEndian) { wav.append(contentsOf: $0) }
        withUnsafeBytes(of: bitsPerSample.littleEndian) { wav.append(contentsOf: $0) }

        // data chunk
        wav.append("data".data(using: .ascii)!)
        var ds = dataSize.littleEndian
        withUnsafeBytes(of: &ds) { wav.append(contentsOf: $0) }
        wav.append(audioData)

        // Update file size
        let totalSize = UInt32(wav.count - 8).littleEndian
        wav.replaceSubrange(fileSizePos..<fileSizePos+4, with: withUnsafeBytes(of: totalSize) { Data($0) })

        try wav.write(to: url)
    }

    private func buildBextChunk() -> Data {
        guard let tc = timecode else { return Data() }
        var bext = Data()

        // Description (256 bytes) — zeroed to match SigmaFP reference
        bext.append(contentsOf: [UInt8](repeating: 0, count: 256))

        // Originator (32 bytes) — zeroed to match SigmaFP reference
        bext.append(contentsOf: [UInt8](repeating: 0, count: 32))

        // OriginatorRef (32 bytes) — zeroed to match SigmaFP reference
        bext.append(contentsOf: [UInt8](repeating: 0, count: 32))

        // OriginationDate (10 bytes)
        bext.append(originationDate.prefix(10).data(using: .ascii)!)

        // OriginationTime (8 bytes)
        let otcStr = String(format: "%02d:%02d:%02d", tc.hours, tc.minutes, tc.seconds)
        bext.append(otcStr.data(using: .ascii)!)

        // TimeReference (8 bytes) — computed at video framerate (e.g. 23.976)
        // so the WAV matches the DNG's frame count to sample offset.
        let totalSeconds = Double(tc.hours) * 3600.0
                         + Double(tc.minutes) * 60.0
                         + Double(tc.seconds)
                         + Double(tc.frames) / framerate
        let samples = UInt64((totalSeconds * Double(sampleRate)).rounded())
        print("[bext] TimeReference=\(samples) (tc=\(otcStr):\(tc.frames) framerate=\(framerate))")
        withUnsafeBytes(of: samples.littleEndian) { bext.append(contentsOf: $0) }

        // Version (2 bytes)
        bext.append(contentsOf: [UInt8](repeating: 0, count: 2))

        // UMID (64 bytes)
        bext.append(contentsOf: [UInt8](repeating: 0, count: 64))

        // Loudness values (8 bytes)
        bext.append(contentsOf: [UInt8](repeating: 0, count: 8))

        // Reserved (180 bytes)
        bext.append(contentsOf: [UInt8](repeating: 0, count: 180))

        // CodingHistory — zeroed to match SigmaFP reference
        bext.append(contentsOf: [UInt8](repeating: 0, count: 0))

        return bext
    }

    private func buildIXMLChunk() -> Data {
        guard let tc = timecode else { return Data() }
        let fps = timecodeFps ?? 24

        // Minimal iXML matching SigmaFP reference format
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <BWFXML>
        <IXML_VERSION>1.5</IXML_VERSION>
        <SPEED>
        <MASTER_SPEED>\(fps)/1</MASTER_SPEED>
        <CURRENT_SPEED>\(fps)/1</CURRENT_SPEED>
        <TIMECODE_RATE>\(fps)/1</TIMECODE_RATE>
        <TIMECODE_FLAG>NDF</TIMECODE_FLAG>
        </SPEED>
        </BWFXML>
        """

        let logTc = String(format: "%02d:%02d:%02d:%02d", tc.hours, tc.minutes, tc.seconds, tc.frames)
        print("[ixml] minimal iXML: tc=\(logTc) fps=\(fps)")
        print("[ixml] full iXML:\n\(xml)")

        return xml.data(using: .utf8) ?? Data()
    }
}


extension String {
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

extension UInt16 {
    var data: Data { Swift.withUnsafeBytes(of: self) { Data($0) } }
}

extension UInt32 {
    var data: Data { Swift.withUnsafeBytes(of: self) { Data($0) } }
}
