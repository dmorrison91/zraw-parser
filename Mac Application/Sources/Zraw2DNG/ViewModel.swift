 import Foundation
import AVFoundation
import AppKit
import CoreMedia
@preconcurrency import CppBridge

@MainActor
class ViewModel: ObservableObject {
    @Published var queue: [QueueItem] = []
    @Published var options = ProcessingOptions()
    @Published var isProcessing = false
    @Published var statusMessage = "Ready"
    @Published var outputPathText = ""
    @Published var logMessages: [String] = []
    @Published var showLog = false

    private let fileManager = FileManager.default
    private var batchTask: Task<Void, Never>?
    private var stderrPipe: Pipe?

    private let logQueue = DispatchQueue(label: "log", qos: .utility)

    init() {
        let cores = ProcessInfo.processInfo.processorCount
        options.maxConcurrentFrames = max(1, cores - 1)
        setupLogCapture()
    }

    func appendLog(_ msg: String) {
        logMessages.append(msg)
        if logMessages.count > 1000 {
            logMessages.removeFirst(logMessages.count - 500)
        }
    }

    private func setupLogCapture() {
        let pipe = Pipe()
        stderrPipe = pipe
        setvbuf(__stderrp, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8), !str.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.appendLog(str.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    var canConvert: Bool {
        !isProcessing && queue.contains(where: {
            switch $0.status {
            case .ready, .cancelled: return true
            default: return false
            }
        })
    }

    var overallProgressValue: Double {
        var total = 0, completed = 0
        for item in queue {
            switch item.status {
            case .completed:
                if let info = item.movieInfo { total += info.frameCount; completed += info.frameCount }
            case .processing(let n, let t):
                total += t; completed += n
            case .ready, .pending, .loading:
                if let info = item.movieInfo { total += info.frameCount }
            case .failed, .cancelled, .warning:
                break
            }
        }
        return total > 0 ? Double(completed) / Double(total) : 0
    }

    var queueProgressText: String {
        let total = queue.count
        let done = queue.filter { if case .completed = $0.status { return true }; return false }.count
        return "\(done)/\(total) complete"
    }

    func selectCameraModel(_ model: CameraModelOverride) {
        options.cameraModelOverride = model
        guard !options.baselineExposureUserSet else { return }
        options.baselineExposure = model == .varicam ? 0.0 : 3.0
    }

    func setBaselineExposure(_ val: Double) {
        options.baselineExposure = val
        options.baselineExposureUserSet = true
    }

    // MARK: - Actions

    func addFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, UTType(filenameExtension: "zraw")].compactMap { $0 }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard let self, response == .OK else { return }
            for url in panel.urls {
                if !queue.contains(where: { $0.url == url }) {
                    queue.append(QueueItem(url: url, status: .pending))
                }
            }
            Task { await self.loadItems() }
        }
    }

    func addURLs(_ urls: [URL]) {
        for url in urls {
            if !queue.contains(where: { $0.url == url }) {
                queue.append(QueueItem(url: url, status: .pending))
            }
        }
        Task { await loadItems() }
    }

    func removeItems(at offsets: IndexSet) {
        guard !isProcessing else {
            let activeIndex = queue.indices.first { if case .processing = queue[$0].status { return true }; return false }
            let removable = offsets.filter { $0 != activeIndex }
            guard !removable.isEmpty else { return }
            queue.remove(atOffsets: IndexSet(removable))
            return
        }
        queue.remove(atOffsets: offsets)
    }

    func moveItems(fromOffsets: IndexSet, toOffset: Int) {
        queue.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    func resetItem(at index: Int) async {
        guard index < queue.count else { return }
        // Reset to pending without reloading the file — info is already parsed.
        // The item will be picked up by the next explicit Start Queue click.
        queue[index].status = .pending
        queue[index].error = nil
    }

    func clearAll() {
        cancelConversion()
        // Remove queue on next MainActor cycle so any in-flight MainActor.run blocks drain first
        Task { @MainActor in
            queue.removeAll()
        }
    }

    func chooseOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose output directory"
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            options.outputDir = url
            outputPathText = url.path
        }
    }

    func confirmOutputPath() {
        let trimmed = outputPathText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            options.outputDir = nil
            return
        }
        let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        options.outputDir = url
    }

    // MARK: - Load Items

    private func loadItems() async {
        for i in queue.indices where queue[i].status == .pending {
            queue[i].status = .loading
            do {
                let info = try zrawOpenMov(path: queue[i].url.path)
                queue[i].movieInfo = info
                if info.hasTimecode {
                    print("[zraw] MOV timecode: \(info.timecodeString) @ \(info.timecodeFps) fps")
                } else {
                    print("[zraw] MOV timecode: none")
                }
                queue[i].zcamInfo = ZCAMFileInfo.parse(from: queue[i].url)
                queue[i].status = info.hasVideo && info.frameCount > 0 ? .ready : .warning("Not a ZRAW file — will be skipped")
                if info.hasVideo {
                    appendLog("\(queue[i].url.lastPathComponent): \(info.videoWidth)x\(info.videoHeight), \(info.frameCount) frames, \(String(format: "%.2f", info.framerate)) fps")
                }
            } catch {
                queue[i].status = .failed(error.localizedDescription)
                queue[i].error = error.localizedDescription
                appendLog("\(queue[i].url.lastPathComponent): ERROR — \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Start / Cancel

    func startConversion() {
        guard !isProcessing else { return }
        isProcessing = true
        statusMessage = "Converting..."
        appendLog("=== Conversion started (\(queue.filter { if case .ready = $0.status { return true }; return false }.count) files) ===")

        batchTask = Task { [weak self] in
            guard let self else { return }

            // Process files sequentially (one at a time) — re-check queue after each file
            while true {
                await loadItems()
                let i: Int
                if let next = queue.indices.first(where: {
                    switch queue[$0].status {
                    case .ready, .cancelled: return true
                    default: return false
                    }
                }) {
                    i = next
                } else {
                    if queue.allSatisfy({ if case .pending = $0.status { return false }; return true }) {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }

                guard !Task.isCancelled else {
                    await MainActor.run { guard queue.indices.contains(i) else { return }; queue[i].status = .cancelled }
                    continue
                }

                await MainActor.run {
                    guard queue.indices.contains(i) else { return }
                    queue[i].status = .processing(0, queue[i].movieInfo?.frameCount ?? 0)
                }

                do {
                    try await processFile(at: i)
                    // Respect cancellation — don't mark as completed if user cancelled mid-run
                    if Task.isCancelled {
                        await MainActor.run { guard queue.indices.contains(i) else { return }; queue[i].status = .cancelled }
                    } else {
                        await MainActor.run { guard queue.indices.contains(i) else { return }; queue[i].status = .completed }
                    }
                } catch {
                    if Task.isCancelled {
                        await MainActor.run { guard queue.indices.contains(i) else { return }; queue[i].status = .cancelled }
                    } else {
                        let msg = error.localizedDescription
                        await MainActor.run {
                            guard queue.indices.contains(i) else { return }
                            queue[i].status = .failed(msg)
                            queue[i].error = msg
                        }
                    }
                }
            }

            let ok = queue.filter { if case .completed = $0.status { return true }; return false }.count
            let fail = queue.filter { if case .failed = $0.status { return true }; return false }.count
            appendLog("=== Conversion complete: \(ok) succeeded, \(fail) failed ===")
            statusMessage = "Done — \(ok) succeeded, \(fail) failed"
            isProcessing = false

            if ok > 0, let doneItem = queue.first(where: { if case .completed = $0.status { return true }; return false }) {
                let parent = options.outputDir ?? doneItem.url.deletingLastPathComponent()
                NSWorkspace.shared.open(parent)
            }
        }
    }

    func cancelConversion() {
        batchTask?.cancel()
        // Cancel the entire queue — mark every non-terminal item as cancelled
        for i in queue.indices {
            if !queue[i].status.isTerminal {
                queue[i].status = .cancelled
            }
        }
        isProcessing = false
        statusMessage = "Cancelled — press Start Convert to resume"
    }

    // MARK: - Process Single File

    private func processFile(at index: Int) async throws {
        let item = queue[index]
        guard let info = item.movieInfo else { return }

        let outputDir = options.outputDir ?? item.url.deletingLastPathComponent()
        let clipName = item.zcamInfo?.clipName ?? item.url.deletingPathExtension().lastPathComponent
        let workDir = outputDir.appendingPathComponent(clipName)

        if !fileManager.fileExists(atPath: workDir.path) {
            try fileManager.createDirectory(at: workDir, withIntermediateDirectories: true)
        }

        let fileHandle = try FileHandle(forReadingFrom: item.url)
        defer { try? fileHandle.close() }

        let comp = options.compression
        let baselineExposure = options.baselineExposure
        let cameraModel: String
        if case .auto = options.cameraModelOverride {
            cameraModel = info.cameraModel
        } else {
            cameraModel = options.cameraModelOverride.dngCameraModel
        }

        // Parse first frame for metadata (all frames share the same)
        try fileHandle.seek(toOffset: info.chunkOffsets[0])
        guard let firstFrameData = try fileHandle.read(upToCount: Int(info.sampleSizes[0])) else {
            throw ZRAWError.decodingFailed("Failed to read first frame")
        }
        let firstFrameInfo = try zrawParseFrame(data: firstFrameData)

        // ——— Single source of truth for timecode ———
        // Compute the starting frame count ONCE, using the same formula as the
        // DNG callback in CppBridge.mm (see zraw_multi_decoder_process lambda).
        // Both DNG and WAV timecodes are derived from this single value so they
        // can never diverge.
        let tcFps = info.timecodeFps
        let tcStartFrames: UInt32
        if info.hasTimecode && tcFps > 0 {
            tcStartFrames = info.timecodeStartFrame
        } else {
            tcStartFrames = 0
        }
        // Reconstruct HH:MM:SS:FF using the identical arithmetic as the C++
        // DNG callback: total_tc = tc_start + frame_index, then divide out.
        let tcRecon = timecodeFromFrames(tcStartFrames, fps: tcFps)

        print("==========================================")
        print("[timecode] CLIP: \(clipName)")
        print("[timecode] Source info.timecodeString = \(info.timecodeString)")
        print("[timecode] tcFps  = \(tcFps)")
        print("[timecode] tcStartFrames = \(tcStartFrames)")
        print("[timecode] Reconstructed  = \(String(format: "%02d:%02d:%02d:%02d", tcRecon.hours, tcRecon.minutes, tcRecon.seconds, tcRecon.frames))")
        let matchStr = info.timecodeString == String(format: "%02d:%02d:%02d:%02d", tcRecon.hours, tcRecon.minutes, tcRecon.seconds, tcRecon.frames) ? "MATCH" : "MISMATCH"
        print("[timecode] Comparison: \(matchStr)")
        print("[timecode] Audio sample rate: \(info.audioSampleRate) Hz")
        print("==========================================")

        // Audio extraction — pass the reconstructed timecode (same as DNG)
        if info.hasAudio {
            do {
                try await extractAudio(from: item.url, outputDir: workDir, clipName: clipName, info: info,
                                       hasTimecode: info.hasTimecode && tcFps > 0,
                                       tcHours: tcRecon.hours, tcMinutes: tcRecon.minutes,
                                       tcSeconds: tcRecon.seconds, tcFrames: tcRecon.frames,
                                       timecodeFps: tcFps)
            } catch {
                queue[index].error = "Audio extraction failed: \(error.localizedDescription)"
            }
        }

        let reel = tcFps > 0 ? clipName.components(separatedBy: "_").first ?? clipName : ""

        // DNG processing — pass the same reconstructed timecode
        try await processDNG(fileURL: item.url, chunkOffsets: info.chunkOffsets,
                             sampleSizes: info.sampleSizes, info: info,
                             firstFrameInfo: firstFrameInfo,
                             workDir: workDir, clipName: clipName, cameraModel: cameraModel,
                             comp: comp, baselineExposure: baselineExposure,
                             tcHours: tcRecon.hours, tcMins: tcRecon.minutes,
                             tcSecs: tcRecon.seconds, tcFrames: tcRecon.frames,
                             tcFps: tcFps,
                             framerateNum: info.framerateNum, framerateDen: info.framerateDen,
                             reel: reel, index: index)
    }

    // MARK: - DNG Processing (Parallel)

    private func processDNG(fileURL: URL, chunkOffsets: [UInt64],
                             sampleSizes: [UInt64], info: ZRAWMovInfo,
                             firstFrameInfo: ZRAWFrameInfo,
                             workDir: URL, clipName: String, cameraModel: String,
                             comp: CompressionOption, baselineExposure: Double,
                             tcHours: UInt8, tcMins: UInt8, tcSecs: UInt8, tcFrames: UInt8,
                             tcFps: UInt32,
                             framerateNum: UInt32, framerateDen: UInt32,
                             reel: String, index: Int) async throws {
        print("[timecode] DNG opts: tc=\(tcHours):\(tcMins):\(tcSecs):\(tcFrames) @ \(tcFps) fps, framerate=\(framerateNum)/\(framerateDen)")

        let opts = ZRAWDecodeOptions(
            dngDir: workDir.path,
            clipName: clipName,
            cameraModel: cameraModel,
            compressionType: Int32(comp.rawValue),
            baselineExposure: baselineExposure,
            framerateNum: framerateNum,
            framerateDen: framerateDen,
            reelName: reel,
            hasTimecode: info.hasTimecode,
            tcHours: tcHours,
            tcMinutes: tcMins,
            tcSeconds: tcSecs,
            tcFrames: tcFrames,
            tcFps: tcFps
        )

        let decoder = ZrawMultiDecoder(numThreads: options.maxConcurrentFrames)

        let pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard !Task.isCancelled else { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { break }
                let processed = decoder.framesProcessed
                let total = decoder.totalFrames
                if total > 0 {
                    await MainActor.run {
                        guard let self else { return }
                        guard !self.queue[index].status.isTerminal else { return }
                        self.queue[index].status = .processing(processed, total)
                    }
                }
            }
        }

        defer { pollingTask.cancel() }

        let result = try await Task.detached {
            try decoder.process(movPath: fileURL.path, offsets: chunkOffsets, sizes: sampleSizes, options: opts)
        }.value

        if result.framesFailed > 0 {
            appendLog("\(clipName): \(result.framesFailed) frames failed")
        }
    }

    // MARK: - Audio Extraction

    private func extractAudio(from fileURL: URL, outputDir: URL, clipName: String,
                                info: ZRAWMovInfo,
                                hasTimecode: Bool,
                                tcHours: UInt8, tcMinutes: UInt8, tcSeconds: UInt8, tcFrames: UInt8,
                                timecodeFps: UInt32) async throws
    {
        let asset = AVURLAsset(url: fileURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else { return }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: info.audioSampleRate,
            AVLinearPCMBitDepthKey: info.audioSampleSize,
            AVNumberOfChannelsKey: info.audioChannels,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        reader.add(output)
        guard reader.startReading() else {
            throw ZRAWError.audioExtractionFailed(
                "AVAssetReader failed: \(reader.error?.localizedDescription ?? "unknown")"
            )
        }

        // Stream PCM samples to a temp file instead of accumulating in memory
        let tempPCM = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(clipName)_pcm.raw")
        FileManager.default.createFile(atPath: tempPCM.path, contents: nil, attributes: nil)
        let pcmFH = try FileHandle(forWritingTo: tempPCM)
        var totalBytes: UInt64 = 0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            if Task.isCancelled { break }

            autoreleasepool {
                if let blockBuffer = sampleBuffer.dataBuffer {
                    var ptr: UnsafeMutablePointer<Int8>?
                    var len: Int = 0
                    let status = CMBlockBufferGetDataPointer(
                        blockBuffer, atOffset: 0,
                        lengthAtOffsetOut: &len,
                        totalLengthOut: nil,
                        dataPointerOut: &ptr
                    )
                    if status == kCMBlockBufferNoErr, let p = ptr, len > 0 {
                        let data = Data(bytes: p, count: len)
                        pcmFH.write(data)
                        totalBytes += UInt64(data.count)
                    }
                } else {
                    var blockBufForList: CMBlockBuffer?
                    var listSize: Int = 0
                    let os = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                        sampleBuffer,
                        bufferListSizeNeededOut: &listSize,
                        bufferListOut: nil,
                        bufferListSize: 0,
                        blockBufferAllocator: nil,
                        blockBufferMemoryAllocator: nil,
                        flags: 0,
                        blockBufferOut: &blockBufForList
                    )
                    if os == noErr, listSize > 0 {
                        let abl = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
                        abl.initialize(to: AudioBufferList(
                            mNumberBuffers: UInt32(info.audioChannels),
                            mBuffers: AudioBuffer()
                        ))
                        defer { abl.deinitialize(count: 1); abl.deallocate() }

                        let os2 = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                            sampleBuffer,
                            bufferListSizeNeededOut: nil,
                            bufferListOut: abl,
                            bufferListSize: listSize,
                            blockBufferAllocator: nil,
                            blockBufferMemoryAllocator: nil,
                            flags: 0,
                            blockBufferOut: &blockBufForList
                        )
                        if os2 == noErr {
                            let bufList = UnsafeMutableAudioBufferListPointer(abl)
                            for i in 0..<bufList.count {
                                let buf = bufList[i]
                                if let data = buf.mData, buf.mDataByteSize > 0 {
                                    let chunk = Data(bytes: data, count: Int(buf.mDataByteSize))
                                    pcmFH.write(chunk)
                                    totalBytes += UInt64(chunk.count)
                                }
                            }
                        }
                    }
                }
            }
        }

        try pcmFH.close()

        guard reader.status != .failed else {
            try? FileManager.default.removeItem(at: tempPCM)
            let msg = reader.error?.localizedDescription ?? "unknown error"
            throw ZRAWError.audioExtractionFailed("AVAssetReader failed mid-stream: \(msg)")
        }

        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: tempPCM)
            return
        }

        let byteRatePerSample = UInt32(info.audioChannels) * UInt32(info.audioSampleSize / 8)
        let videoDuration = Double(info.frameCount) / info.framerate
        let expectedBytes = Int(videoDuration * Double(info.audioSampleRate) * Double(byteRatePerSample))
        print("[audio] \(clipName): expected ~\(expectedBytes) bytes, got \(totalBytes) bytes")

        // Log WAV timecode
        let tcStr = String(format: "%02d:%02d:%02d:%02d", tcHours, tcMinutes, tcSeconds, tcFrames)
        if hasTimecode {
            let totalSec = Double(tcHours) * 3600.0 + Double(tcMinutes) * 60.0 + Double(tcSeconds) + Double(tcFrames) / info.framerate
            let sampleRef = UInt64((totalSec * Double(info.audioSampleRate)).rounded())
            print("[wav] \(clipName): TIME=\(tcStr) tc_fps=\(timecodeFps) framerate=\(info.framerate) TimeReference=\(sampleRef) @ \(Int(info.audioSampleRate)) Hz")
        } else {
            print("[wav] \(clipName): TIME=none (no timecode)")
        }

        let wavPath = outputDir.appendingPathComponent("\(clipName).wav")

        let writer = WAVWriter(
            numChannels: UInt16(info.audioChannels),
            sampleRate: UInt32(info.audioSampleRate),
            bitsPerSample: UInt16(info.audioSampleSize),
            reelName: hasTimecode ? clipName.components(separatedBy: "_").first : nil,
            timecode: hasTimecode ? (tcHours, tcMinutes, tcSeconds, tcFrames) : nil,
            timecodeFps: hasTimecode ? timecodeFps : nil,
            framerate: info.framerate,
            framerateNumerator: info.framerateNum,
            framerateDenominator: info.framerateDen
        )
        try writer.writeStreaming(pcmURL: tempPCM, to: wavPath)

        // Clean up temp PCM file
        try? FileManager.default.removeItem(at: tempPCM)
    }
}

// MARK: - Helpers

/// Reconstruct HH:MM:SS:FF from total frame count, using the same
/// formula as the DNG callback in CppBridge.mm:
///   total_tc = tc_start + frame_index
///   h = total_tc / (fps * 3600)
///   m = (total_tc / (fps * 60)) % 60
///   s = (total_tc / fps) % 60
///   f = total_tc % fps
private func timecodeFromFrames(_ frames: UInt32, fps: UInt32) -> (hours: UInt8, minutes: UInt8, seconds: UInt8, frames: UInt8) {
    guard fps > 0 else { return (0, 0, 0, 0) }
    return (
        UInt8(frames / (fps * 3600)),
        UInt8((frames / (fps * 60)) % 60),
        UInt8((frames / fps) % 60),
        UInt8(frames % fps)
    )
}

private func timecodeForFrame(_ frameIndex: Int,
                               tcHours: UInt8, tcMins: UInt8, tcSecs: UInt8, tcFrames: UInt8,
                               fps: UInt32) -> (hours: UInt8, minutes: UInt8, seconds: UInt8, frames: UInt8) {
    guard fps > 0 else { return (0, 0, 0, 0) }
    let total = UInt32(tcHours) * fps * 3600
               + UInt32(tcMins) * fps * 60
               + UInt32(tcSecs) * fps
               + UInt32(tcFrames)
               + UInt32(frameIndex)
    return (
        UInt8(total / (fps * 3600)),
        UInt8((total / (fps * 60)) % 60),
        UInt8((total / fps) % 60),
        UInt8(total % fps)
    )
}


