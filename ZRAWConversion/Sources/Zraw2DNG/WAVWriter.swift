
import Foundation

struct WAVWriter {
    let numChannels: UInt16
    let sampleRate: UInt32
    let bitsPerSample: UInt16
    let reelName: String?
    let timecode: (hours: UInt8, minutes: UInt8, seconds: UInt8, frames: UInt8)?
    let timecodeFps: UInt32?

    init(numChannels: UInt16, sampleRate: UInt32, bitsPerSample: UInt16,
         reelName: String? = nil,
         timecode: (hours: UInt8, minutes: UInt8, seconds: UInt8, frames: UInt8)? = nil,
         timecodeFps: UInt32? = nil) {
        self.numChannels = numChannels
        self.sampleRate = sampleRate
        self.bitsPerSample = bitsPerSample
        self.reelName = reelName
        self.timecode = timecode
        self.timecodeFps = timecodeFps
    }

    func write(audioData: Data, to url: URL) throws {
        guard numChannels > 0, sampleRate > 0, bitsPerSample > 0 else {
            throw ZRAWError.audioExtractionFailed("Invalid WAV parameters (channels=\(numChannels), rate=\(sampleRate), bits=\(bitsPerSample))")
        }
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(audioData.count)

        var wav = Data()

        // RIFF header
        wav.append("RIFF".data(using: .ascii)!)
        // Placeholder for file size
        let fileSizePos = wav.count
        wav.append(contentsOf: [UInt8](repeating: 0, count: 4))
        wav.append("WAVE".data(using: .ascii)!)

        // bext chunk (Broadcast Audio Extension)
        let bextData = buildBextChunk()
        if !bextData.isEmpty {
            wav.append("bext".data(using: .ascii)!)
            var bextSize = UInt32(bextData.count).littleEndian
            withUnsafeBytes(of: &bextSize) { wav.append(contentsOf: $0) }
            wav.append(bextData)
            // Pad to even size
            if bextData.count % 2 != 0 { wav.append(UInt8(0)) }
        }

        // iXML chunk
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
        let audioFmt = UInt16(1).littleEndian  // PCM
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

        // Description (256 bytes)
        bext.append("Zraw2DNG audio".data(using: .ascii)!)
        bext.append(contentsOf: [UInt8](repeating: 0, count: 256 - bext.count))

        // Originator (32 bytes)
        bext.append("Zraw2DNG".data(using: .ascii)!)
        bext.append(contentsOf: [UInt8](repeating: 0, count: 32 - 8))

        // OriginatorRef (32 bytes)
        let ref = reelName ?? "ZRAW"
        bext.append(ref.data(using: .ascii)!)
        bext.append(contentsOf: [UInt8](repeating: 0, count: 32 - ref.utf8.count))

        // OriginationDate (10 bytes) - yyyy:mm:dd
        bext.append("0000:00:00".data(using: .ascii)!)

        // OriginationTime (8 bytes) - hh:mm:ss
        let tcStr = String(format: "%02d:%02d:%02d", tc.hours, tc.minutes, tc.seconds)
        bext.append(tcStr.data(using: .ascii)!)

        // TimeReference (8 bytes) - samples since midnight
        // Use precise rational arithmetic: totalSamples = totalFrames * sampleRate * fd / ts
        // where fps = ts/fd.  Using nominal fps ensures integer frames-per-second division.
        let fps = timecodeFps ?? 24
        let totalFrames = UInt64(tc.hours) * 3600 * UInt64(fps)
                        + UInt64(tc.minutes) * 60 * UInt64(fps)
                        + UInt64(tc.seconds) * UInt64(fps)
                        + UInt64(tc.frames)
        // sampleRate is always divisible by fps for standard rates (48000/24, 48000/25, 48000/30)
        let samples = totalFrames * UInt64(sampleRate) / UInt64(fps)
        withUnsafeBytes(of: samples.littleEndian) { bext.append(contentsOf: $0) }

        // Version (2 bytes)
        bext.append(contentsOf: [UInt8](repeating: 0, count: 2))

        // UMID (64 bytes)
        bext.append(contentsOf: [UInt8](repeating: 0, count: 64))

        // Loudness values (2 bytes each × 4 = 8 bytes)
        bext.append(contentsOf: [UInt8](repeating: 0, count: 8))

        // Reserved (180 bytes)
        bext.append(contentsOf: [UInt8](repeating: 0, count: 180))

        // CodingHistory (variable)
        bext.append("PCM=16, Fs=\(sampleRate), CH=\(numChannels)".data(using: .ascii)!)

        return bext
    }

    private func buildIXMLChunk() -> Data {
        guard let tc = timecode else { return Data() }
        let fps = timecodeFps ?? 24
        let tcStr = String(format: "%02d:%02d:%02d:%02d", tc.hours, tc.minutes, tc.seconds, tc.frames)
        let reel = reelName ?? ""
        // Nominal fps is always NDF (24, 25, 30); only 29.97/59.94 use DF
        // DaVinci expects NDF for Z CAM integer timecode counters
        let timecodeFlag = "NDF"

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <BWFXML>
            <IXML_VERSION>1.5</IXML_VERSION>
            <SPEED>
                <MASTER_SPEED>\(fps)/1</MASTER_SPEED>
                <CURRENT_SPEED>\(fps)/1</CURRENT_SPEED>
                <TIMECODE_RATE>\(fps)/1</TIMECODE_RATE>
                <TIMECODE_FLAG>\(timecodeFlag)</TIMECODE_FLAG>
            </SPEED>
            <BEXT>
                <TimeReference>0</TimeReference>
            </BEXT>
            <PROJECT>
            </PROJECT>
            <SCENE>
            </SCENE>
            <TAPE>
                <Reel>\(reel.xmlEscaped)</Reel>
            </TAPE>
            <NOTE>
            </NOTE>
            <BWFORIGINATOR>Zraw2DNG</BWFORIGINATOR>
            <BWFORIGINATORREF>\(reel.xmlEscaped)</BWFORIGINATORREF>
            <TRACK_LIST>
                <TRACK Count="1">
                    <CHANNEL INDEX="1">\(tcStr)</CHANNEL>
                </TRACK>
            </TRACK_LIST>
            <TIMECODE>
                <START_TC>\(tcStr)</START_TC>
                <FRAME_RATE>\(fps)</FRAME_RATE>
            </TIMECODE>
        </BWFXML>
        """
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
