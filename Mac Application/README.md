# zraw-parser

C library for decoding and processing ZRAW video files (Z CAM cameras). Extracts frames, metadata (white balance, color matrices, timecode), and outputs DNG sequences or debayered RGB frames.

## Features

- Parse ZRAW frames from MOV/QuickTime containers
- Decompress CFA sensor data
- Extract frame metadata: white balance gains, color correction matrices, black levels, color temperature
- Write DNG files with full CinemaDNG metadata (timecode, frame rate, reel name, color matrices)
- Debayer to RGB with LogC3 encoding pipeline
- WAV audio extraction with iXML/bext timecode metadata

## Building

```bash
swift build -c release
```

Requires macOS 15.0+, Xcode 16+, and OpenSSL 3.x (`libcrypto` via Homebrew).

## Usage

### Zraw2DNG App

The Zraw2DNG app provides a drag-and-drop interface for converting ZRAW files to DNG sequences.

**1. Import files**

Click "Import Files…" or drag-and-drop `.mov` / `.zraw` files onto the window. Each file is analysed for video resolution, frame count, frame rate, audio, timecode, and camera model. Files that do not contain a ZRAW track are flagged with a warning.

**2. Queue**

Each imported file appears as a row showing resolution, fps, frame count, audio info, timecode, and camera model. Tap a row to select it (red outline), then use the Reset or Remove buttons to manage the queue.

**3. Options**

- **Compression** — Uncompressed (up to 16-bit linear) or Lossless JPEG (smaller files, visually lossless)
- **Model** — Auto (detects camera model from MOV metadata) or manual override: Blackmagic Pocket Cinema Camera 6K/4K, Blackmagic URSA/4.6K, Panasonic Varicam RAW, DJI FC8282. Sets the camera model tag in DNG metadata. Varicam automatically sets baseline exposure to 0.0.
- **Baseline Exposure** — -6.0 to +6.0 in 0.5-stop increments (default 3.0). Controls the Baseline Exposure tag written into each DNG, which affects how the image is interpreted by raw developers. Recommendation: test the exposure value against a ProRes recording at the same ISO rating to find the correct offset for your camera.
- **Concurrent frames** — number of frames to decode in parallel per file (defaults to core count minus one). Higher values use more CPU but may reduce per-frame overhead on systems with many cores.
- **Output** — optional custom output directory (defaults to each source file's parent folder). Click Browse… to choose or type a path.

**4. Convert**

Click "Start Convert". Files process one at a time; frames within each file are decoded in parallel up to the configured concurrency limit. Each row shows a per-file progress bar and frame counter. The footer shows an xx/yy file counter. The overall progress bar at the bottom tracks the entire queue.

Audio tracks are automatically extracted as WAV files (with iXML and Broadcast Audio Extension timecode metadata) alongside the DNG sequence.

Click "Cancel" to stop. Partially processed files are marked as cancelled; already-complete files are kept.

**5. Log**

Toggle the Log panel at the bottom of the window to view console output. Use "Copy All" to copy the log to the clipboard or "Clear" to reset.














### As a library

Link against `libzraw.a` and include the C API headers:

```c
#include "libzraw.h"
#include "CppBridge.h"

ZRAWMovInfo_C info;
zraw_open_mov("clip.mov", &info);

// Iterate frames...
for (int i = 0; i < info.frame_count; i++) {
    ZRAWFrameInfo_C frameInfo;
    zraw_parse_frame(frameData[i], frameSize, &frameInfo);
    // ...
}
```

## Credits

- **tiny_dng_writer** — MIT-licensed single-header DNG writer by Syoyo Fujita
- **libzraw** — ZRAW decoding library
- **TinyMovFileLibrary** — C++ MOV/MP4 atom parser

Based on the original zraw-parser by Storyboard Creativity.
