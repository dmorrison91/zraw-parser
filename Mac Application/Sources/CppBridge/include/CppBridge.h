#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int has_video;
    uint16_t video_width;
    uint16_t video_height;
    uint32_t zraw_version;
    double framerate;
    uint32_t framerate_num;
    uint32_t framerate_den;
    uint32_t frame_count;
    uint64_t* chunk_offsets;
    uint64_t* sample_sizes;

    int has_audio;
    uint16_t audio_channels;
    uint16_t audio_sample_size;
    double audio_sample_rate;

    int has_timecode;
    uint8_t timecode_hours;
    uint8_t timecode_minutes;
    uint8_t timecode_seconds;
    uint8_t timecode_frames;
    uint32_t timecode_fps;

    char camera_model[64];
} ZRAWMovInfo_C;

typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t bits_per_pixel;
    uint32_t awb_gain_r;
    uint32_t awb_gain_g;
    uint32_t awb_gain_b;
    uint16_t cfa_black_levels[4];
    uint16_t wb_kelvin;
    int32_t ccm[9];
    uint16_t ccm_temp;
    uint16_t white_level;
} ZRAWFrameInfo_C;

int zraw_open_mov(const char* path, ZRAWMovInfo_C* info);
void zraw_free_mov_info(ZRAWMovInfo_C* info);

// Parse a ZRAW frame to get metadata (no decompression)
int zraw_parse_frame(const uint8_t* frame_data, int size, ZRAWFrameInfo_C* info);

// Decompress a ZRAW frame into 16-bit CFA pixels
int zraw_decompress_frame(const uint8_t* frame_data, int size,
                          uint16_t* pixels, int pixel_count);

// Write DNG from pre-processed 16-bit CFA pixels
int zraw_write_dng(const uint16_t* pixels, int width, int height,
                   int bits_per_pixel, const uint16_t* cfa_black_levels,
                   uint32_t awb_gain_r, uint32_t awb_gain_g, uint32_t awb_gain_b,
                   const char* dng_path,
                   int compression_type,
                   const char* camera_model);

// Full pipeline: parse + decompress + write DNG
int zraw_process_frame(const uint8_t* frame_data, int size,
                       const ZRAWFrameInfo_C* frame_info,
                       const char* dng_path,
                       int compression_type,
                       const char* camera_model,
                       double baseline_exposure,
                       uint16_t wb_kelvin,
                       int has_timecode,
                       uint8_t tc_hours, uint8_t tc_mins, uint8_t tc_secs, uint8_t tc_frames,
                       uint32_t tc_fps,
                       uint32_t framerate_num, uint32_t framerate_den,
                       const char* reel_name);

// Debayer CFA 16-bit pixels to interleaved float RGB
// rgb_output must be width * height * 3 * sizeof(float)
int zraw_debayer_to_rgb(const uint16_t* cfa_pixels, int width, int height,
                         int bits_per_pixel, float* rgb_output);

// Apply white balance + color matrix + optional ARRI LogC3 encoding to RGB float
// rgb is modified in-place (width * height * 3 floats)
int zraw_apply_color_pipeline(float* rgb, int width, int height,
                               uint32_t awb_gain_r, uint32_t awb_gain_g, uint32_t awb_gain_b,
                               const int32_t* ccm, int has_ccm,
                               int apply_logc3);

// Set error message (thread-safe)
void zraw_set_error(const char* msg);

const char* zraw_last_error(void);

// ------------------- Multi-Decoder API -------------------

typedef struct {
    const char* dng_dir;
    const char* clip_name;
    const char* camera_model;
    int compression_type;
    double baseline_exposure;
    uint32_t framerate_num;
    uint32_t framerate_den;
    const char* reel_name;
    int has_timecode;
    uint32_t tc_hours;
    uint32_t tc_minutes;
    uint32_t tc_seconds;
    uint32_t tc_frames;
    uint32_t tc_fps;
} ZRAWDecodeOptions_C;

typedef struct {
    size_t total_frames;
    size_t frames_written;
    size_t frames_failed;
} ZRAWDecodeResult_C;

void* zraw_multi_decoder_create(int num_threads);
void  zraw_multi_decoder_destroy(void* decoder);
int   zraw_multi_decoder_process(void* decoder, const char* mov_path,
                                 const uint64_t* offsets, const uint64_t* sizes, uint64_t frame_count,
                                 const ZRAWDecodeOptions_C* options,
                                 ZRAWDecodeResult_C* result);
size_t zraw_multi_decoder_get_total(void* decoder);
size_t zraw_multi_decoder_get_processed(void* decoder);

#ifdef __cplusplus
}
#endif
