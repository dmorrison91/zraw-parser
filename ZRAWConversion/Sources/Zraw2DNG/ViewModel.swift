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
        queue[index].status = .pending
        queue[index].error = nil
        await loadItems()
    }

    func clearAll() {
        batchTask?.cancel()
        queue.removeAll()
        isProcessing = false
        statusMessage = "Ready"
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
                    await MainActor.run { queue[i].status = .cancelled }
                    continue
                }

                await MainActor.run {
                    queue[i].status = .processing(0, queue[i].movieInfo?.frameCount ?? 0)
                }

                do {
                    try await processFile(at: i)
                    await MainActor.run { queue[i].status = .completed }
                } catch {
                    if Task.isCancelled {
                        await MainActor.run { queue[i].status = .cancelled }
                    } else {
                        let msg = error.localizedDescription
                        await MainActor.run {
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
        for i in queue.indices {
            if case .processing = queue[i].status {
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

        let totalFrames = info.frameCount
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

        // Debug: log parsed timecode info
        if info.hasTimecode {
            print("[zraw] Start TC: \(info.timecodeString) @ \(info.timecodeFps) fps | " +
                  "hours=\(info.timecodeHours) mins=\(info.timecodeMinutes) " +
                  "secs=\(info.timecodeSeconds) frames=\(info.timecodeFrames)")
        } else {
            print("[zraw] No timecode track found in MOV")
        }

        // Audio extraction
        if info.hasAudio {
            do {
                try await extractAudio(from: item.url, outputDir: workDir, clipName: clipName, info: info)
            } catch {
                queue[index].error = "Audio extraction failed: \(error.localizedDescription)"
            }
        }

        let tcHours = info.timecodeHours
        let tcMins = info.timecodeMinutes
        let tcSecs = info.timecodeSeconds
        let tcFrames = info.timecodeFrames
        let tcFps = info.timecodeFps

        let reel = tcFps > 0 ? clipName.components(separatedBy: "_").first ?? clipName : ""

        // Debug: log expected timecode for first and last frames
        if info.hasTimecode && tcFps > 0 {
            let firstTC = timecodeForFrame(0, tcHours: tcHours, tcMins: tcMins, tcSecs: tcSecs, tcFrames: tcFrames, fps: tcFps)
            let lastTC = timecodeForFrame(totalFrames - 1, tcHours: tcHours, tcMins: tcMins, tcSecs: tcSecs, tcFrames: tcFrames, fps: tcFps)
            print("[zraw] Frame 0 TC: \(firstTC.hours):\(firstTC.minutes):\(firstTC.seconds):\(firstTC.frames)")
            print("[zraw] Frame \(totalFrames - 1) TC: \(lastTC.hours):\(lastTC.minutes):\(lastTC.seconds):\(lastTC.frames)")
        }

        try await processDNG(fileURL: item.url, chunkOffsets: info.chunkOffsets,
                             sampleSizes: info.sampleSizes, info: info,
                             firstFrameInfo: firstFrameInfo,
                             workDir: workDir, clipName: clipName, cameraModel: cameraModel,
                             comp: comp, baselineExposure: baselineExposure,
                             tcHours: tcHours, tcMins: tcMins, tcSecs: tcSecs, tcFrames: tcFrames,
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
        let totalFrames = chunkOffsets.count
        let fi = firstFrameInfo
        let compRaw = Int32(comp.rawValue)
        let cam = cameraModel
        let be = baselineExposure
        let hasTc = info.hasTimecode
        let fps = tcFps
        let rn = reel
        let maxConcurrent = options.maxConcurrentFrames

        let frameErrors = LockedArray<String>()

        try await withThrowingTaskGroup(of: (Int, Error?).self) { group in
            var nextFrame = 0
            var active = 0
            var completed = 0

            func submitNext() {
                while nextFrame < totalFrames && active < maxConcurrent {
                    let frameIdx = nextFrame
                    nextFrame += 1
                    active += 1

                    group.addTask { [frameIdx] in
                        try Task.checkCancellation()
                        let tcf = timecodeForFrame(frameIdx, tcHours: tcHours, tcMins: tcMins,
                                                    tcSecs: tcSecs, tcFrames: tcFrames, fps: fps)
                        let dngPath = workDir.appendingPathComponent(
                            String(format: "%@_%04d.dng", clipName, frameIdx + 1)
                        ).path

                        do {
                            try await Task.detached {
                                let fh = try FileHandle(forReadingFrom: fileURL)
                                try fh.seek(toOffset: chunkOffsets[frameIdx])
                                guard let frameData = try fh.read(upToCount: Int(sampleSizes[frameIdx])) else {
                                    throw ZRAWError.decodingFailed("Failed to read frame \(frameIdx)")
                                }
                                try fh.close()
                                try zrawProcessFrame(
                                    data: frameData,
                                    frameInfo: fi,
                                    dngPath: dngPath,
                                    compressionType: compRaw,
                                    cameraModel: cam,
                                    baselineExposure: be,
                                    wbKelvin: fi.wbKelvin,
                                    hasTimecode: hasTc,
                                    timecodeHours: tcf.hours,
                                    timecodeMinutes: tcf.minutes,
                                    timecodeSeconds: tcf.seconds,
                                    timecodeFrames: tcf.frames,
                                    timecodeFps: fps,
                                    framerateNum: framerateNum,
                                    framerateDen: framerateDen,
                                    reelName: rn
                                )
                            }.value
                            return (frameIdx, nil)
                        } catch {
                            return (frameIdx, error)
                        }
                    }
                }
            }

            submitNext()

            for try await (frameIdx, error) in group {
                active -= 1
                completed += 1
                if let error = error {
                    frameErrors.append("Frame \(frameIdx + 1): \(error.localizedDescription)")
                }

                await MainActor.run {
                    queue[index].status = .processing(completed, totalFrames)
                }

                submitNext()
            }
        }

        // Retry missing frames
        let missingFrames = (0..<totalFrames).compactMap { i -> Int? in
            let path = workDir.appendingPathComponent(String(format: "%@_%04d.dng", clipName, i + 1))
            return fileManager.fileExists(atPath: path.path) ? nil : i
        }

        for missingIdx in missingFrames {
            let tcf = timecodeForFrame(missingIdx, tcHours: tcHours, tcMins: tcMins,
                                        tcSecs: tcSecs, tcFrames: tcFrames, fps: fps)
            let dngPath = workDir.appendingPathComponent(
                String(format: "%@_%04d.dng", clipName, missingIdx + 1)
            ).path

            do {
                try await Task.detached {
                    let fh = try FileHandle(forReadingFrom: fileURL)
                    try fh.seek(toOffset: chunkOffsets[missingIdx])
                    guard let frameData = try fh.read(upToCount: Int(sampleSizes[missingIdx])) else {
                        throw ZRAWError.decodingFailed("Failed to read frame \(missingIdx) (retry)")
                    }
                    try fh.close()
                    try zrawProcessFrame(
                        data: frameData,
                        frameInfo: fi,
                        dngPath: dngPath,
                        compressionType: compRaw,
                        cameraModel: cam,
                        baselineExposure: be,
                        wbKelvin: fi.wbKelvin,
                        hasTimecode: hasTc,
                        timecodeHours: tcf.hours,
                        timecodeMinutes: tcf.minutes,
                        timecodeSeconds: tcf.seconds,
                        timecodeFrames: tcf.frames,
                        timecodeFps: fps,
                        framerateNum: framerateNum,
                        framerateDen: framerateDen,
                        reelName: rn
                    )
                }.value
            } catch {
                frameErrors.append("Frame \(missingIdx + 1) (retry): \(error.localizedDescription)")
            }
        }

        let errors = frameErrors.values
        if !errors.isEmpty {
            let msg = errors.joined(separator: "\n")
            await MainActor.run {
                if let existing = queue[index].error {
                    queue[index].error = "\(existing)\n\(msg)"
                } else {
                    queue[index].error = msg
                }
            }
        }
    }

    // MARK: - Audio Extraction

    private func extractAudio(from fileURL: URL, outputDir: URL, clipName: String,
                               info: ZRAWMovInfo) async throws
    {
        let asset = AVURLAsset(url: fileURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else { return }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
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

        var audioData = Data()
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if Task.isCancelled { break }
            if let blockBuffer = sampleBuffer.dataBuffer {
                var ptr: UnsafeMutablePointer<Int8>?
                var len: Int = 0
                CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                           totalLengthOut: &len, dataPointerOut: &ptr)
                if let p = ptr {
                    audioData.append(UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self), count: len)
                }
            }
        }

        guard !Task.isCancelled else { return }

        let wavPath = outputDir.appendingPathComponent("\(clipName).wav")
        let writer = WAVWriter(
            numChannels: UInt16(info.audioChannels),
            sampleRate: UInt32(info.audioSampleRate),
            bitsPerSample: UInt16(info.audioSampleSize),
            reelName: info.hasTimecode ? clipName.components(separatedBy: "_").first : nil,
            timecode: info.hasTimecode ? (info.timecodeHours, info.timecodeMinutes, info.timecodeSeconds, info.timecodeFrames) : nil,
            timecodeFps: info.hasTimecode ? info.timecodeFps : nil
        )
        try writer.write(audioData: audioData, to: wavPath)
    }
}

// MARK: - Helpers

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

// Thread-safe array wrapper for concurrent error collection
private final class LockedArray<T>: @unchecked Sendable {
    private var storage: [T] = []
    private let lock = NSLock()

    func append(_ element: T) {
        lock.lock(); defer { lock.unlock() }
        storage.append(element)
    }

    var values: [T] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
