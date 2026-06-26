import Foundation
@preconcurrency import CppBridge

struct ZRAWMovInfo {
    let hasVideo: Bool
    let videoWidth: Int
    let videoHeight: Int
    let zrawVersion: Int
    let framerate: Double
    let framerateNum: UInt32
    let framerateDen: UInt32
    let frameCount: Int
    let chunkOffsets: [UInt64]
    let sampleSizes: [UInt64]

    let hasAudio: Bool
    let audioChannels: Int
    let audioSampleSize: Int
    let audioSampleRate: Double

    var hasTimecode: Bool
    var timecodeHours: UInt8
    var timecodeMinutes: UInt8
    var timecodeSeconds: UInt8
    var timecodeFrames: UInt8
    var timecodeFps: UInt32

    let cameraModel: String

    var timecodeStartFrame: UInt32 {
        guard hasTimecode, timecodeFps > 0 else { return 0 }
        let fps = timecodeFps
        return UInt32(timecodeHours) * fps * 3600
             + UInt32(timecodeMinutes) * fps * 60
             + UInt32(timecodeSeconds) * fps
             + UInt32(timecodeFrames)
    }

    var timecodeString: String {
        guard hasTimecode else { return "--:--:--:--" }
        return String(format: "%02d:%02d:%02d:%02d",
                      timecodeHours, timecodeMinutes, timecodeSeconds, timecodeFrames)
    }

    init(_ info: ZRAWMovInfo_C) {
        hasVideo = info.has_video != 0
        videoWidth = Int(info.video_width)
        videoHeight = Int(info.video_height)
        zrawVersion = Int(info.zraw_version)
        framerate = info.framerate
        framerateNum = info.framerate_num
        framerateDen = info.framerate_den
        frameCount = Int(info.frame_count)
        hasAudio = info.has_audio != 0
        audioChannels = Int(info.audio_channels)
        audioSampleSize = Int(info.audio_sample_size)
        audioSampleRate = info.audio_sample_rate
        hasTimecode = info.has_timecode != 0
        timecodeHours = info.timecode_hours
        timecodeMinutes = info.timecode_minutes
        timecodeSeconds = info.timecode_seconds
        timecodeFrames = info.timecode_frames
        timecodeFps = info.timecode_fps
        cameraModel = withUnsafeBytes(of: info.camera_model) {
            String(cString: $0.baseAddress!.assumingMemoryBound(to: UInt8.self))
        }

        var offsets: [UInt64] = []
        if let ptr = info.chunk_offsets {
            for i in 0..<Int(info.frame_count) { offsets.append(ptr[i]) }
        }
        chunkOffsets = offsets

        var sizes: [UInt64] = []
        if let ptr = info.sample_sizes {
            for i in 0..<Int(info.frame_count) { sizes.append(ptr[i]) }
        }
        sampleSizes = sizes
    }
}

struct ZRAWFrameInfo {
    let width: UInt32
    let height: UInt32
    let bitsPerPixel: UInt32
    let awbGainR: UInt32
    let awbGainG: UInt32
    let awbGainB: UInt32
    let cfaBlackLevels: [UInt16]
    let wbKelvin: UInt16
    let ccm: [Int32]
    let ccmTemp: UInt16
    let whiteLevel: UInt16

    init(_ info: ZRAWFrameInfo_C) {
        width = info.width
        height = info.height
        bitsPerPixel = info.bits_per_pixel
        awbGainR = info.awb_gain_r
        awbGainG = info.awb_gain_g
        awbGainB = info.awb_gain_b
        cfaBlackLevels = [
            info.cfa_black_levels.0,
            info.cfa_black_levels.1,
            info.cfa_black_levels.2,
            info.cfa_black_levels.3
        ]
        wbKelvin = info.wb_kelvin
        ccm = [
            info.ccm.0, info.ccm.1, info.ccm.2,
            info.ccm.3, info.ccm.4, info.ccm.5,
            info.ccm.6, info.ccm.7, info.ccm.8
        ]
        ccmTemp = info.ccm_temp
        whiteLevel = info.white_level
    }
}

func zrawOpenMov(path: String) throws -> ZRAWMovInfo {
    var info = ZRAWMovInfo_C()
    let ret = path.withCString { cPath in
        zraw_open_mov(cPath, &info)
    }
    guard ret == 0 else {
        let err = String(cString: zraw_last_error())
        throw ZRAWError.failedToOpenFile(err)
    }
    defer { zraw_free_mov_info(&info) }
    return ZRAWMovInfo(info)
}

func zrawProcessFrame(data: Data, frameInfo: ZRAWFrameInfo, dngPath: String,
                       compressionType: Int32,
                       cameraModel: String,
                       baselineExposure: Double,
                       wbKelvin: UInt16,
                       hasTimecode: Bool,
                       timecodeHours: UInt8, timecodeMinutes: UInt8,
                       timecodeSeconds: UInt8, timecodeFrames: UInt8,
                       timecodeFps: UInt32,
                       framerateNum: UInt32, framerateDen: UInt32,
                       reelName: String) throws
{
    guard !data.isEmpty else { throw ZRAWError.invalidFormat("Empty frame data") }
    let ret = data.withUnsafeBytes { buf in
        frameInfo.withCStruct { fiPtr in
            dngPath.withCString { pathPtr in
                cameraModel.withCString { modelPtr in
                    reelName.withCString { reelPtr in
                        zraw_process_frame(
                            buf.bindMemory(to: UInt8.self).baseAddress,
                            Int32(data.count),
                            fiPtr,
                            pathPtr,
                            compressionType,
                            modelPtr,
                            baselineExposure,
                            wbKelvin,
                            hasTimecode ? 1 : 0,
                            timecodeHours, timecodeMinutes, timecodeSeconds, timecodeFrames,
                            timecodeFps,
                            framerateNum, framerateDen,
                            reelPtr
                        )
                    }
                }
            }
        }
    }
    guard ret == 0 else {
        let err = String(cString: zraw_last_error())
        throw ZRAWError.dngWriteFailed(err)
    }
}

// MARK: - Frame-level C wrappers (non-isolated helpers)

func zrawParseFrame(data: Data) throws -> ZRAWFrameInfo {
    guard !data.isEmpty else { throw ZRAWError.invalidFormat("Empty frame data") }
    var cInfo = ZRAWFrameInfo_C()
    let ret = data.withUnsafeBytes { buf in
        zraw_parse_frame(
            buf.bindMemory(to: UInt8.self).baseAddress,
            Int32(data.count),
            &cInfo
        )
    }
    guard ret == 0 else {
        let err = String(cString: zraw_last_error())
        throw ZRAWError.decodingFailed(err)
    }
    return ZRAWFrameInfo(cInfo)
}

func zrawDecodeFrame(data: Data, info: ZRAWFrameInfo) throws -> [UInt16] {
    guard !data.isEmpty else { throw ZRAWError.invalidFormat("Empty frame data") }
    let pixelCount = Int(info.width) * Int(info.height)
    var pixels = [UInt16](repeating: 0, count: pixelCount)
    let ret = data.withUnsafeBytes { buf in
        zraw_decompress_frame(
            buf.bindMemory(to: UInt8.self).baseAddress,
            Int32(data.count),
            &pixels,
            Int32(pixelCount)
        )
    }
    guard ret == 0 else {
        let err = String(cString: zraw_last_error())
        throw ZRAWError.decodingFailed(err)
    }
    return pixels
}

// MARK: - Debayer + Color Pipeline

func zrawDebayerToRGB(cfaPixels: [UInt16], width: Int, height: Int, bitsPerPixel: Int) throws -> [Float] {
    let count = width * height * 3
    var rgb = [Float](repeating: 0, count: count)
    let ret = rgb.withUnsafeMutableBufferPointer { buf in
        cfaPixels.withUnsafeBufferPointer { cfa in
            zraw_debayer_to_rgb(cfa.baseAddress, Int32(width), Int32(height), Int32(bitsPerPixel), buf.baseAddress)
        }
    }
    guard ret == 0 else {
        let err = String(cString: zraw_last_error())
        throw ZRAWError.debayerFailed(err)
    }
    return rgb
}

func zrawApplyColorPipeline(rgb: inout [Float], width: Int, height: Int,
                             awbGainR: UInt32, awbGainG: UInt32, awbGainB: UInt32,
                             ccm: [Int32]?, applyLogC3: Bool) throws {
    let hasCCM = (ccm != nil) ? 1 : 0
    let ret = rgb.withUnsafeMutableBufferPointer { buf in
        if let ccm = ccm {
            return ccm.withUnsafeBufferPointer { ccmBuf in
                zraw_apply_color_pipeline(buf.baseAddress, Int32(width), Int32(height),
                                           awbGainR, awbGainG, awbGainB,
                                           ccmBuf.baseAddress, Int32(hasCCM),
                                           applyLogC3 ? 1 : 0)
            }
        } else {
            return zraw_apply_color_pipeline(buf.baseAddress, Int32(width), Int32(height),
                                               awbGainR, awbGainG, awbGainB,
                                               nil, Int32(hasCCM),
                                               applyLogC3 ? 1 : 0)
        }
    }
    guard ret == 0 else {
        let err = String(cString: zraw_last_error())
        throw ZRAWError.debayerFailed(err)
    }
}

// MARK: - Filename Timecode Parser

func parseTimecodeFromFilename(_ url: URL) -> (hours: UInt8, minutes: UInt8, seconds: UInt8)? {
    let name = url.deletingPathExtension().lastPathComponent
    guard let digitsRange = name.range(of: #"\d{14}"#, options: .regularExpression) else { return nil }
    let ts = name[digitsRange]
    guard ts.count == 14 else { return nil }
    let s = ts.startIndex
    guard let h = UInt8(ts[ts.index(s, offsetBy: 8)..<ts.index(s, offsetBy: 10)]), h < 24,
          let m = UInt8(ts[ts.index(s, offsetBy: 10)..<ts.index(s, offsetBy: 12)]), m < 60,
          let sec = UInt8(ts[ts.index(s, offsetBy: 12)..<ts.index(s, offsetBy: 14)]), sec < 60 else { return nil }
    return (h, m, sec)
}

// MARK: - Helper: convert ZRAWFrameInfo to C struct pointer

extension ZRAWFrameInfo {
    func withCStruct<T>(_ body: (UnsafePointer<ZRAWFrameInfo_C>) throws -> T) rethrows -> T {
        var cStruct = ZRAWFrameInfo_C()
        cStruct.width = width
        cStruct.height = height
        cStruct.bits_per_pixel = bitsPerPixel
        cStruct.awb_gain_r = awbGainR
        cStruct.awb_gain_g = awbGainG
        cStruct.awb_gain_b = awbGainB
        cStruct.cfa_black_levels.0 = cfaBlackLevels[0]
        cStruct.cfa_black_levels.1 = cfaBlackLevels[1]
        cStruct.cfa_black_levels.2 = cfaBlackLevels[2]
        cStruct.cfa_black_levels.3 = cfaBlackLevels[3]
        cStruct.wb_kelvin = wbKelvin
        cStruct.ccm.0 = ccm[0]; cStruct.ccm.1 = ccm[1]; cStruct.ccm.2 = ccm[2]
        cStruct.ccm.3 = ccm[3]; cStruct.ccm.4 = ccm[4]; cStruct.ccm.5 = ccm[5]
        cStruct.ccm.6 = ccm[6]; cStruct.ccm.7 = ccm[7]; cStruct.ccm.8 = ccm[8]
        cStruct.ccm_temp = ccmTemp
        cStruct.white_level = whiteLevel
        return try withUnsafePointer(to: &cStruct) { ptr in
            try body(ptr)
        }
    }
}

// MARK: - Multi-Decoder

struct ZRAWDecodeOptions {
    let dngDir: String
    let clipName: String
    let cameraModel: String
    let compressionType: Int32
    let baselineExposure: Double
    let framerateNum: UInt32
    let framerateDen: UInt32
    let reelName: String
    let hasTimecode: Bool
    let tcHours: UInt8
    let tcMinutes: UInt8
    let tcSeconds: UInt8
    let tcFrames: UInt8
    let tcFps: UInt32

    func withCStruct<T>(_ body: (UnsafePointer<ZRAWDecodeOptions_C>) throws -> T) rethrows -> T {
        var opts = ZRAWDecodeOptions_C()
        return try dngDir.withCString { dngDirPtr in
            try clipName.withCString { clipNamePtr in
                try cameraModel.withCString { modelPtr in
                    try reelName.withCString { reelPtr in
                        opts.dng_dir = dngDirPtr
                        opts.clip_name = clipNamePtr
                        opts.camera_model = modelPtr
                        opts.compression_type = compressionType
                        opts.baseline_exposure = baselineExposure
                        opts.framerate_num = framerateNum
                        opts.framerate_den = framerateDen
                        opts.reel_name = reelPtr
                        opts.has_timecode = hasTimecode ? 1 : 0
                        opts.tc_hours = UInt32(tcHours)
                        opts.tc_minutes = UInt32(tcMinutes)
                        opts.tc_seconds = UInt32(tcSeconds)
                        opts.tc_frames = UInt32(tcFrames)
                        opts.tc_fps = tcFps
                        return try withUnsafePointer(to: &opts) { ptr in
                            try body(ptr)
                        }
                    }
                }
            }
        }
    }
}

struct ZRAWDecodeResult {
    let totalFrames: Int
    let framesWritten: Int
    let framesFailed: Int

    init(_ c: ZRAWDecodeResult_C) {
        totalFrames = Int(c.total_frames)
        framesWritten = Int(c.frames_written)
        framesFailed = Int(c.frames_failed)
    }
}

final class ZrawMultiDecoder: @unchecked Sendable {
    private let ptr: UnsafeMutableRawPointer

    init(numThreads: Int = 0) {
        ptr = zraw_multi_decoder_create(Int32(numThreads))
    }

    deinit {
        zraw_multi_decoder_destroy(ptr)
    }

    var totalFrames: Int {
        Int(zraw_multi_decoder_get_total(ptr))
    }

    var framesProcessed: Int {
        Int(zraw_multi_decoder_get_processed(ptr))
    }

    func process(movPath: String, offsets: [UInt64], sizes: [UInt64], options: ZRAWDecodeOptions) throws -> ZRAWDecodeResult {
        var result = ZRAWDecodeResult_C()
        let ret = movPath.withCString { pathPtr in
            options.withCStruct { optsPtr in
                zraw_multi_decoder_process(ptr, pathPtr, offsets, sizes, UInt64(offsets.count), optsPtr, &result)
            }
        }
        guard ret == 0 else {
            let err = String(cString: zraw_last_error())
            throw ZRAWError.decodingFailed(err)
        }
        return ZRAWDecodeResult(result)
    }
}
