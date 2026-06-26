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

    /// Write WAV by streaming raw PCM data from a file on disk.
    /// Never accumulates the full audio data in memory — the WAV is built
    /// sequentially via FileHandle, and the PCM payload is read in 64KB chunks.
    /// - Parameters:
    ///   - pcmURL: URL of a file containing raw PCM samples (no headers).
    ///   - wavURL: Destination URL for the complete WAV file.
    func writeStreaming(pcmURL: URL, to wavURL: URL) throws {
        guard numChannels > 0, sampleRate > 0, bitsPerSample > 0 else {
            throw ZRAWError.audioExtractionFailed("Invalid WAV parameters (channels=\(numChannels), rate=\(sampleRate), bits=\(bitsPerSample))")
        }
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let attrs = try FileManager.default.attributesOfItem(atPath: pcmURL.path)
        let pcmFileSize = (attrs[.size] as? UInt64) ?? 0
        let dataSize = UInt32(pcmFileSize)
        let audioDurationSec = Double(pcmFileSize) / Double(byteRate)
        if dataSize > 0 {
            print("[wav] streaming \(pcmFileSize) bytes (~\(String(format: "%.2f", audioDurationSec))s) to \(wavURL.lastPathComponent)")
        }

        if let tc = timecode {
            let tcStr = String(format: "%02d:%02d:%02d:%02d", tc.hours, tc.minutes, tc.seconds, tc.frames)
            print("[wav] TC start=\(tcStr) tc_fps=\(timecodeFps ?? 24) framerate=\(framerate) @ \(sampleRate) Hz")
        }

        // Create output file and open for writing
        try FileManager.default.createDirectory(at: wavURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: wavURL.path, contents: nil, attributes: nil)
        let wavFH = try FileHandle(forWritingTo: wavURL)
        defer { try? wavFH.close() }

        // RIFF header (placeholder for file size, filled at end)
        wavFH.write("RIFF".data(using: .ascii)!)
        let fileSizeOffset = wavFH.offsetInFile
        var placeholder32: UInt32 = 0
        withUnsafeBytes(of: &placeholder32) { wavFH.write(Data($0)) }
        wavFH.write("WAVE".data(using: .ascii)!)

        // BEXT chunk
        let bextData = buildBextChunk()
        if !bextData.isEmpty {
            wavFH.write("bext".data(using: .ascii)!)
            var bextSize = UInt32(bextData.count).littleEndian
            withUnsafeBytes(of: &bextSize) { wavFH.write(Data($0)) }
            wavFH.write(bextData)
            if bextData.count % 2 != 0 { wavFH.write(Data([UInt8(0)])) }
        }

        // iXML chunk
        let ixmlData = buildIXMLChunk()
        if !ixmlData.isEmpty {
            wavFH.write("iXML".data(using: .ascii)!)
            var ixmlSize = UInt32(ixmlData.count).littleEndian
            withUnsafeBytes(of: &ixmlSize) { wavFH.write(Data($0)) }
            wavFH.write(ixmlData)
            if ixmlData.count % 2 != 0 { wavFH.write(Data([UInt8(0)])) }
        }

        // fmt chunk
        wavFH.write("fmt ".data(using: .ascii)!)
        var fmtSize = UInt32(16).littleEndian
        withUnsafeBytes(of: &fmtSize) { wavFH.write(Data($0)) }
        var audioFmt = UInt16(1).littleEndian
        withUnsafeBytes(of: &audioFmt) { wavFH.write(Data($0)) }
        var channelsLE = numChannels.littleEndian
        withUnsafeBytes(of: &channelsLE) { wavFH.write(Data($0)) }
        var rateLE = sampleRate.littleEndian
        withUnsafeBytes(of: &rateLE) { wavFH.write(Data($0)) }
        var byteRateLE = byteRate.littleEndian
        withUnsafeBytes(of: &byteRateLE) { wavFH.write(Data($0)) }
        var blockAlignLE = blockAlign.littleEndian
        withUnsafeBytes(of: &blockAlignLE) { wavFH.write(Data($0)) }
        var bitsLE = bitsPerSample.littleEndian
        withUnsafeBytes(of: &bitsLE) { wavFH.write(Data($0)) }

        // data chunk header (placeholder for size)
        wavFH.write("data".data(using: .ascii)!)
        var ds = dataSize.littleEndian
        withUnsafeBytes(of: &ds) { wavFH.write(Data($0)) }

        // Stream PCM payload from the raw file in 64KB chunks
        let readFH = try FileHandle(forReadingFrom: pcmURL)
        defer { try? readFH.close() }
        let chunkSize = 65536
        var totalRead: UInt64 = 0
        while totalRead < pcmFileSize {
            let remaining = pcmFileSize - totalRead
            let thisChunk = min(remaining, UInt64(chunkSize))
            let data = readFH.readData(ofLength: Int(thisChunk))
            if data.isEmpty { break }
            wavFH.write(data)
            totalRead += UInt64(data.count)
        }

        // Patch the RIFF file size at the beginning
        let endOffset = wavFH.offsetInFile
        var totalSize = UInt32(endOffset - 8).littleEndian
        try wavFH.seek(toOffset: fileSizeOffset)
        withUnsafeBytes(of: &totalSize) { wavFH.write(Data($0)) }
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
