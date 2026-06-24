#include "include/CppBridge.h"

#include <cstring>
#include <string>
#include <vector>
#include <fstream>
#include <sstream>
#include <algorithm>
#include <cctype>

#define LIB_ZRAW_STATIC
#include "libzraw.h"

#define TINY_DNG_WRITER_IMPLEMENTATION
#include "tiny_dng_writer.h"

#include "TinyMovFileLibrary.hpp"

#pragma mark - Error Handling

#include <mutex>
static std::mutex s_errMutex;
static std::string s_lastError;

#define SET_ERROR(msg) do { \
    std::lock_guard<std::mutex> lock(s_errMutex); \
    s_lastError = (msg); \
} while(0)

void zraw_set_error(const char* msg) {
    SET_ERROR(msg ? msg : "Unknown error");
}

const char* zraw_last_error(void) {
    std::lock_guard<std::mutex> lock(s_errMutex);
    return s_lastError.c_str();
}

#pragma mark - MOV Container

static uint8_t bcd_to_bin(uint8_t bcd) {
    return ((bcd >> 4) & 0x0F) * 10 + (bcd & 0x0F);
}

int zraw_open_mov(const char* path, ZRAWMovInfo_C* info) {
    try {
        memset(info, 0, sizeof(*info));

        TinyMovFileReader reader;
        TinyMovFile mov = reader.OpenMovFile(path);
        if (mov.Path().empty()) {
            SET_ERROR("Failed to open MOV file");
            return -1;
        }

        for (auto& track : mov.Tracks()) {
            auto mediaType = track.Media().Type();

            if (mediaType == TinyMovTrackMedia::Type_t::Video) {
                auto& descs = track.Media().Info().DescriptionTable().VideoDescriptionTable();
                if (descs.empty()) continue;
                auto& desc = descs[0];

                uint32_t fmt = desc.DataFormat();
                if (fmt == MKTAG('z','r','a','w')) {
                    info->has_video = 1;
                    auto ext = desc.Ext_ZRAW();
                    info->zraw_version = ext.version;
                    info->video_width = (uint16_t)desc.Width();
                    info->video_height = (uint16_t)desc.Height();

                    auto& sizes = track.Media().Info().SampleSizes();
                    auto& offsets = track.Media().Info().ChunkOffsets();
                    info->frame_count = (uint32_t)sizes.size();

                    if (info->frame_count > 0) {
                        info->chunk_offsets = (uint64_t*)malloc(info->frame_count * sizeof(uint64_t));
                        info->sample_sizes = (uint64_t*)malloc(info->frame_count * sizeof(uint64_t));
                        if (!info->chunk_offsets || !info->sample_sizes) {
                            free(info->chunk_offsets); info->chunk_offsets = nullptr;
                            free(info->sample_sizes); info->sample_sizes = nullptr;
                            SET_ERROR("Out of memory allocating frame offset/size tables");
                            return -1;
                        }
                        for (uint32_t i = 0; i < info->frame_count; i++) {
                            info->chunk_offsets[i] = offsets[i];
                            info->sample_sizes[i] = sizes[i];
                        }
                    }

                    double dur = (double)mov.Duration();
                    double ts = (double)mov.TimeScale();
                    if (dur > 0 && ts > 0) {
                        info->framerate = (double)info->frame_count / (dur / ts);
                    }

                    // Extract precise frame rate rational from video media
                    auto& vmedia = track.Media();
                    auto& stts = vmedia.Info().TimeToSample().Entries();
                    if (!stts.empty()) {
                        info->framerate_num = vmedia.TimeScale();
                        info->framerate_den = stts[0].sample_duration;
                    } else {
                        info->framerate_num = (uint32_t)(info->framerate + 0.5);
                        info->framerate_den = 1;
                    }
                }
            }
            else if (mediaType == TinyMovTrackMedia::Type_t::Audio) {
                info->has_audio = 1;
                auto& descs = track.Media().Info().DescriptionTable().AudioDescriptionTable();
                if (!descs.empty()) {
                    auto& adesc = descs[0];
                    info->audio_channels = adesc.NumberOfChannels();
                    info->audio_sample_size = adesc.SampleSize();
                    {
                        uint32_t sr_fixed = adesc.SampleRate();
                        info->audio_sample_rate = (sr_fixed >> 16) + (double)(sr_fixed & 0xFFFF) / 65536.0;
                    }
                }
            }
            else if (mediaType == TinyMovTrackMedia::Type_t::Timecode) {
                info->has_timecode = 1;
                fprintf(stderr, "[zraw] timecode track detected\n");
                auto& tdesc = track.Media().Info().DescriptionTable().TimecodeDescriptionTable();
                if (!tdesc.empty()) {
                    uint32_t tc_ts = tdesc[0].TimeScale();
                    uint32_t tc_fd = tdesc[0].FrameDuration();
                    if (tc_fd > 0) {
                        info->timecode_fps = (tc_ts + tc_fd / 2) / tc_fd;
                    }
                }

                auto& tcOffsets = track.Media().Info().ChunkOffsets();
                auto& tcSizes = track.Media().Info().SampleSizes();
                uint32_t tcForcedSize = track.Media().Info().ForcedSampleSize();

                if (!tcOffsets.empty()) {
                    uint64_t tcOffset = tcOffsets[0];
                    uint32_t tcSize = tcForcedSize > 0 ? tcForcedSize : (tcSizes.empty() ? 4 : (uint32_t)tcSizes[0]);
                    if (tcSize >= 4) {
                        std::ifstream movFile(path, std::ios::binary);
                        if (!movFile.is_open() || !movFile.seekg(tcOffset)) {
                            // file already opened successfully earlier; skip timecode on seek failure
                            return 0;
                        }
                        uint8_t tcBytes[4] = {0};
                        if (!movFile.read((char*)tcBytes, 4)) {
                            return 0;
                        }

                        uint8_t raw_h = tcBytes[0];
                        uint8_t raw_m = tcBytes[1];
                        uint8_t raw_s = tcBytes[2];
                        uint8_t raw_f = tcBytes[3];

                        fprintf(stderr, "[zraw] timecode raw at offset %llu: %02x %02x %02x %02x\n",
                                (unsigned long long)tcOffset, raw_h, raw_m, raw_s, raw_f);

                        auto is_bcd = [](uint8_t v) -> bool {
                            return ((v >> 4) & 0x0F) < 10 && (v & 0x0F) < 10;
                        };

                        if (is_bcd(raw_h) && is_bcd(raw_m) && is_bcd(raw_s) && is_bcd(raw_f)) {
                            info->timecode_hours = bcd_to_bin(raw_h);
                            info->timecode_minutes = bcd_to_bin(raw_m);
                            info->timecode_seconds = bcd_to_bin(raw_s);
                            info->timecode_frames = bcd_to_bin(raw_f);
                            fprintf(stderr, "[zraw] timecode BCD: %02d:%02d:%02d:%02d @ %d fps\n",
                                    info->timecode_hours, info->timecode_minutes,
                                    info->timecode_seconds, info->timecode_frames,
                                    info->timecode_fps);
                        } else {
                            // Not BCD — interpret as big-endian uint32 frame counter (Z CAM convention)
                            uint32_t frame_count = ((uint32_t)raw_h << 24)
                                                  | ((uint32_t)raw_m << 16)
                                                  | ((uint32_t)raw_s << 8)
                                                  | (uint32_t)raw_f;
                            if (frame_count > 0 && info->timecode_fps > 0) {
                                // Z CAM stores frame counter at nominal fps (e.g. 24), not precise ts/fd
                                uint32_t ts = tdesc[0].TimeScale();
                                uint32_t fd = tdesc[0].FrameDuration();
                                uint32_t fps_nominal = (ts + fd / 2) / fd;
                                info->timecode_hours = (uint8_t)(frame_count / (fps_nominal * 3600));
                                info->timecode_minutes = (uint8_t)((frame_count / (fps_nominal * 60)) % 60);
                                info->timecode_seconds = (uint8_t)((frame_count / fps_nominal) % 60);
                                info->timecode_frames = (uint8_t)(frame_count % fps_nominal);
                                // Update timecode_fps to match the nominal fps used for conversion
                                info->timecode_fps = fps_nominal;
                            } else {
                                info->timecode_hours = 0;
                                info->timecode_minutes = 0;
                                info->timecode_seconds = 0;
                                info->timecode_frames = 0;
                            }
                        }
                    }
                }
            }
        }

        // Detect camera model from metadata
        auto& keys = mov.Metadata().Keys();
        auto& values = mov.Metadata().Values();
        std::string cameraModel = "Blackmagic Pocket Cinema Camera 6K";

        if (keys.size() == values.size()) {
            for (size_t i = 0; i < keys.size(); i++) {
                auto& kd = keys[i].Data();
                std::string keyStr(kd.begin(), kd.end());
                if (keyStr.find("camera-model") != std::string::npos ||
                    keyStr.find("CameraModel") != std::string::npos) {
                    auto& vd = values[i].Data();
                    if (!vd.empty()) {
                        std::string valStr(vd.begin(), vd.end());
                        valStr.erase(std::remove(valStr.begin(), valStr.end(), '\0'), valStr.end());
                        if (!valStr.empty()) {
                            cameraModel = valStr;
                            if (cameraModel.find("Z CAM") == std::string::npos) {
                                cameraModel = "Z CAM " + cameraModel;
                            }
                        }
                    }
                    break;
                }
            }
        }
        strncpy(info->camera_model, cameraModel.c_str(), sizeof(info->camera_model) - 1);
        info->camera_model[sizeof(info->camera_model) - 1] = '\0';

        return 0;
    }
    catch (const std::exception& e) {
        SET_ERROR(e.what());
        return -1;
    }
    catch (...) {
        SET_ERROR("Unknown error in zraw_open_mov");
        return -1;
    }
}

void zraw_free_mov_info(ZRAWMovInfo_C* info) {
    if (info->chunk_offsets) free(info->chunk_offsets);
    if (info->sample_sizes) free(info->sample_sizes);
    memset(info, 0, sizeof(*info));
}

#pragma mark - Frame Parse / Decompress

int zraw_parse_frame(const uint8_t* frame_data, int size, ZRAWFrameInfo_C* info) {
    memset(info, 0, sizeof(*info));

    auto decoder = zraw_decoder__create();
    if (!decoder) {
        SET_ERROR("Failed to create ZRAW decoder");
        return -1;
    }

    auto st = zraw_decoder__read_hisi_frame(decoder, (void*)frame_data, size);
    if (st != ZRAW_DECODER_STATE__FRAME_IS_READ) {
        SET_ERROR("Failed to read ZRAW frame");
        zraw_decoder__free(decoder);
        return -1;
    }

    zraw_frame_info_t raw_info;
    st = zraw_decoder__get_hisi_frame_info(decoder, raw_info);
    if (st != ZRAW_DECODER_STATE__STANDBY) {
        SET_ERROR("Failed to get ZRAW frame info");
        zraw_decoder__free(decoder);
        return -1;
    }

    info->width = raw_info.width_in_photodiodes;
    info->height = raw_info.height_in_photodiodes;
    info->bits_per_pixel = raw_info.bits_per_photodiode_value;
    info->awb_gain_r = raw_info.awb_gain_r;
    info->awb_gain_g = raw_info.awb_gain_g;
    info->awb_gain_b = raw_info.awb_gain_b;
    memcpy(info->cfa_black_levels, raw_info.cfa_black_levels, 4 * sizeof(uint16_t));
    info->wb_kelvin = raw_info.wb_in_K;
    memcpy(info->ccm, raw_info.ccm_values, 9 * sizeof(int32_t));
    info->ccm_temp = raw_info.ccm_temp;
    info->white_level = (uint16_t)((1 << raw_info.bits_per_photodiode_value) - 1);

    zraw_decoder__free(decoder);
    return 0;
}

int zraw_decompress_frame(const uint8_t* frame_data, int size,
                          uint16_t* pixels, int pixel_count)
{
    auto decoder = zraw_decoder__create();
    if (!decoder) {
        SET_ERROR("Failed to create ZRAW decoder");
        return -1;
    }

    auto st = zraw_decoder__read_hisi_frame(decoder, (void*)frame_data, size);
    if (st != ZRAW_DECODER_STATE__FRAME_IS_READ) {
        SET_ERROR("Failed to read ZRAW frame for decompression");
        zraw_decoder__free(decoder);
        return -1;
    }

    st = zraw_decoder__decompress_hisi_frame(decoder);
    if (st != ZRAW_DECODER_STATE__FRAME_IS_DECOMPRESSED) {
        const char* msg = zraw_decoder__exception_message();
        SET_ERROR(msg ? msg : "Failed to decompress ZRAW frame");
        zraw_decoder__free(decoder);
        return -1;
    }

    st = zraw_decoder__get_decompressed_CFA(decoder, pixels, pixel_count * (int)sizeof(uint16_t));
    if (st != ZRAW_DECODER_STATE__STANDBY) {
        SET_ERROR("Failed to get decompressed CFA data");
        zraw_decoder__free(decoder);
        return -1;
    }

    zraw_decoder__free(decoder);
    return 0;
}

#pragma mark - DNG Writing Helper

static int kelvin_to_illuminant(uint16_t temp) {
    if (temp == 0 || temp < 3000) return 17;
    if (temp < 4000) return 24;
    if (temp < 5500) return 23;
    if (temp < 6500) return 21;
    return 22;
}

static bool ccm_is_valid(const int32_t* ccm) {
    if (!ccm) return false;
    for (int i = 0; i < 9; i++) {
        if (ccm[i] != 0) return true;
    }
    return false;
}

static int write_dng_from_pixels(const uint16_t* pixels, int w, int h, int bits,
                                   const uint16_t* cfa_black_levels,
                                   uint32_t awb_gain_r, uint32_t awb_gain_g, uint32_t awb_gain_b,
                                   const int32_t* ccm, uint16_t ccm_temp,
                                   const char* dng_path,
                                   int compression_type,
                                   const char* camera_model,
                                   double baseline_exposure,
                                   uint16_t wb_kelvin,
                                   int has_timecode,
                                   uint8_t tc_hours, uint8_t tc_mins, uint8_t tc_secs, uint8_t tc_frames,
                                   uint32_t tc_fps,
                                   uint32_t framerate_num, uint32_t framerate_den,
                                   const char* reel_name)
{
    try {
        // --- Build DNG ---
        tinydngwriter::DNGImage dng_image;
        dng_image.SetBigEndian(false);

        dng_image.SetSubfileType(false, false, false);
        dng_image.SetImageWidth(w);
        dng_image.SetImageLength(h);
        dng_image.SetRowsPerStrip(h);
        dng_image.SetSamplesPerPixel(1);

        uint16_t bps[1] = {(uint16_t)bits};
        dng_image.SetBitsPerSample(1, bps);

        dng_image.SetPlanarConfig(tinydngwriter::PLANARCONFIG_CONTIG);
        dng_image.SetCompression(
            compression_type == 1
                ? tinydngwriter::COMPRESSION_NEW_JPEG
                : tinydngwriter::COMPRESSION_NONE
        );
        dng_image.SetPhotometric(tinydngwriter::PHOTOMETRIC_CFA);
        dng_image.SetXResolution(300.0);
        dng_image.SetYResolution(300.0);
        dng_image.SetOrientation(tinydngwriter::ORIENTATION_TOPLEFT);
        dng_image.SetResolutionUnit(tinydngwriter::RESUNIT_NONE);
        dng_image.SetImageDescription("[Storyboard Creativity] ZRAW -> DNG converter generated image.");
        dng_image.SetUniqueCameraModel(camera_model);

        double matrix2[] = {
            0.6770, -0.1895, -0.0744,
            -0.5232, 1.3145, 0.2303,
            -0.1664, 0.2691, 0.5703
        };
        dng_image.SetColorMatrix2(3, matrix2);
        dng_image.SetCalibrationIlluminant2(21);

        if (ccm_is_valid(ccm) && ccm_temp > 0) {
            double ccm_double[9];
            for (int i = 0; i < 9; i++) {
                ccm_double[i] = (double)ccm[i] / 1000.0;
            }
            uint16_t illum = kelvin_to_illuminant(ccm_temp);
            fprintf(stderr, "[zraw] Using ZRAW CCM (%dK, illuminant %d)\n", ccm_temp, illum);
            dng_image.SetColorMatrix1(3, ccm_double);
            dng_image.SetCalibrationIlluminant1(illum);
        } else {
            double matrix1[] = {
                0.9784, -0.4995, 0.0,
                -0.3625, 1.1454, 0.2475,
                -0.0961, 0.2097, 0.6377
            };
            dng_image.SetColorMatrix1(3, matrix1);
            dng_image.SetCalibrationIlluminant1(17);
        }

        double analog_balance[] = {1.0, 1.0, 1.0};
        dng_image.SetAnalogBalance(3, analog_balance);

        // BaselineExposure
        dng_image.SetBaselineExposure(baseline_exposure);
        fprintf(stderr, "[zraw] BaselineExposure: %.1f\n", baseline_exposure);

        // AsShotNeutral from camera AWB gains (DaVinci Resolve raw controls uses this)
        if (awb_gain_r > 0 && awb_gain_g > 0 && awb_gain_b > 0) {
            double neutral[] = {
                (double)awb_gain_g / (double)awb_gain_r,
                1.0,
                (double)awb_gain_g / (double)awb_gain_b
            };
            fprintf(stderr, "[zraw] AsShotNeutral: %.4f, %.4f, %.4f\n", neutral[0], neutral[1], neutral[2]);
            dng_image.SetAsShotNeutral(3, neutral);
        }

        dng_image.SetBlackLevelRepeatDim(2, 2);
        dng_image.SetBlackLevel(4, cfa_black_levels);

        dng_image.SetDNGVersion(1, 4, 0, 0);
        dng_image.SetDNGBackwardVersion(1, 2, 0, 0);
        dng_image.SetCFARepeatPatternDim(2, 2);
        uint8_t cfa_pattern[4] = {0, 1, 1, 2};
        dng_image.SetCFAPattern(4, cfa_pattern);

        double white_levels[1] = {(double)((1 << bits) - 1)};
        dng_image.SetWhiteLevelRational(1, white_levels);

        // CinemaDNG timecode metadata
        if (has_timecode && tc_fps > 0) {
            fprintf(stderr, "[zraw] DNG timecode: %02d:%02d:%02d:%02d @ %d fps, reel=%s\n",
                    tc_hours, tc_mins, tc_secs, tc_frames, tc_fps,
                    reel_name ? reel_name : "");
            dng_image.SetFrameRate(framerate_num > 0 ? framerate_num : tc_fps,
                                   framerate_den > 0 ? framerate_den : 1);
            dng_image.SetCameraFrameRate(framerate_num > 0 ? framerate_num : tc_fps,
                                         framerate_den > 0 ? framerate_den : 1);
            dng_image.SetImageCaptureFrameRate(framerate_num > 0 ? static_cast<int32_t>(framerate_num) : static_cast<int32_t>(tc_fps),
                                               framerate_den > 0 ? static_cast<int32_t>(framerate_den) : 1);
            dng_image.SetCinemaDNGFrameRate(framerate_num > 0 ? static_cast<int32_t>(framerate_num) : static_cast<int32_t>(tc_fps),
                                            framerate_den > 0 ? static_cast<int32_t>(framerate_den) : 1);
            dng_image.SetTimeCode(tc_frames, tc_secs, tc_mins, tc_hours);
            dng_image.SetReelTimeCode(tc_frames, tc_secs, tc_mins, tc_hours, 1);
            if (reel_name && strlen(reel_name) > 0) {
                dng_image.SetReelName(std::string(reel_name));
            }
        }

        if (compression_type == 1) {
            dng_image.SetImageDataJpeg(pixels, w, h, bits);
        } else {
            dng_image.SetImageDataPacked(pixels, w * h, bits, true);
        }

        tinydngwriter::DNGWriter dng_writer(false);
        dng_writer.AddImage(&dng_image);

        std::string err;
        if (!dng_writer.WriteToFile(dng_path, &err)) {
            SET_ERROR(err.c_str());
            return -1;
        }

        return 0;
    }
    catch (const std::exception& e) {
        SET_ERROR(e.what());
        return -1;
    }
    catch (...) {
        SET_ERROR("Unknown error writing DNG");
        return -1;
    }
}

#pragma mark - DNG Writing API

int zraw_write_dng(const uint16_t* pixels, int width, int height,
                   int bits_per_pixel, const uint16_t* cfa_black_levels,
                   uint32_t awb_gain_r, uint32_t awb_gain_g, uint32_t awb_gain_b,
                   const char* dng_path,
                   int compression_type,
                   const char* camera_model)
{
    return write_dng_from_pixels(pixels, width, height, bits_per_pixel,
                                  cfa_black_levels,
                                  awb_gain_r, awb_gain_g, awb_gain_b,
                                  NULL, 0,
                                  dng_path, compression_type, camera_model,
                                  3.5, 0, 0, 0, 0, 0, 0, 0, 0, 0, "");
}

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
                       const char* reel_name)
{
    try {
        auto decoder = zraw_decoder__create();
        if (!decoder) {
            SET_ERROR("Failed to create ZRAW decoder");
            return -1;
        }

        auto st = zraw_decoder__read_hisi_frame(decoder, (void*)frame_data, size);
        if (st != ZRAW_DECODER_STATE__FRAME_IS_READ) {
            SET_ERROR("Failed to read ZRAW frame");
            zraw_decoder__free(decoder);
            return -1;
        }

        st = zraw_decoder__decompress_hisi_frame(decoder);
        if (st != ZRAW_DECODER_STATE__FRAME_IS_DECOMPRESSED) {
            const char* msg = zraw_decoder__exception_message();
            SET_ERROR(msg ? msg : "Failed to decompress ZRAW frame");
            zraw_decoder__free(decoder);
            return -1;
        }

        uint32_t w = frame_info->width;
        uint32_t h = frame_info->height;
        uint32_t bits = frame_info->bits_per_pixel;
        int pixel_count = (int)(w * h);

        std::vector<uint16_t> image_data(pixel_count);
        auto cfa_state = zraw_decoder__get_decompressed_CFA(decoder, image_data.data(), (int)(image_data.size() * sizeof(uint16_t)));
        if (cfa_state != ZRAW_DECODER_STATE__STANDBY) {
            SET_ERROR("Failed to get decompressed CFA");
            zraw_decoder__free(decoder);
            return -1;
        }
        zraw_decoder__free(decoder);

        fprintf(stderr, "[zraw] process_frame timecode: has=%d %02d:%02d:%02d:%02d @ %d fps, framerate=%d/%d\n",
                has_timecode, tc_hours, tc_mins, tc_secs, tc_frames, tc_fps,
                framerate_num, framerate_den);

        int ret = write_dng_from_pixels(image_data.data(), w, h, bits,
                                         frame_info->cfa_black_levels,
                                         frame_info->awb_gain_r,
                                         frame_info->awb_gain_g,
                                         frame_info->awb_gain_b,
                                         frame_info->ccm, frame_info->ccm_temp,
                                         dng_path,
                                         compression_type,
                                         camera_model,
                                         baseline_exposure,
                                         wb_kelvin,
                                         has_timecode,
                                         tc_hours, tc_mins, tc_secs, tc_frames,
                                         tc_fps,
                                         framerate_num, framerate_den,
                                         reel_name);
        return ret;
    }
    catch (const std::exception& e) {
        SET_ERROR(e.what());
        return -1;
    }
    catch (...) {
        SET_ERROR("Unknown error in zraw_process_frame");
        return -1;
    }
}

#pragma mark - Debayer

static inline int clip_int(int v, int lo, int hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

int zraw_debayer_to_rgb(const uint16_t* cfa_pixels, int width, int height,
                         int bits_per_pixel, float* rgb_output) {
    if (!cfa_pixels || !rgb_output || width < 2 || height < 2) {
        SET_ERROR("Invalid debayer parameters");
        return -1;
    }
    try {
        float scale = 1.0f / (float)((1 << bits_per_pixel) - 1);
        // Bilinear demosaic for RGGB Bayer pattern
        // Pattern:
        //   R G
        //   G B
        for (int y = 0; y < height; y++) {
            for (int x = 0; x < width; x++) {
                int idx = y * width + x;
                int out_idx = idx * 3;
                float r, g, b;

                if (y % 2 == 0 && x % 2 == 0) {
                    // Red pixel
                    r = (float)cfa_pixels[idx];
                    // G from horizontal neighbors
                    int g_count = 0; float g_sum = 0;
                    if (x > 0) { g_sum += (float)cfa_pixels[y * width + (x - 1)]; g_count++; }
                    if (x < width - 1) { g_sum += (float)cfa_pixels[y * width + (x + 1)]; g_count++; }
                    if (y > 0) { g_sum += (float)cfa_pixels[(y - 1) * width + x]; g_count++; }
                    if (y < height - 1) { g_sum += (float)cfa_pixels[(y + 1) * width + x]; g_count++; }
                    g = g_sum / (float)g_count;
                    // B from diagonal neighbors
                    int b_count = 0; float b_sum = 0;
                    if (x > 0 && y > 0) { b_sum += (float)cfa_pixels[(y - 1) * width + (x - 1)]; b_count++; }
                    if (x < width - 1 && y > 0) { b_sum += (float)cfa_pixels[(y - 1) * width + (x + 1)]; b_count++; }
                    if (x > 0 && y < height - 1) { b_sum += (float)cfa_pixels[(y + 1) * width + (x - 1)]; b_count++; }
                    if (x < width - 1 && y < height - 1) { b_sum += (float)cfa_pixels[(y + 1) * width + (x + 1)]; b_count++; }
                    b = b_count > 0 ? b_sum / (float)b_count : 0;
                } else if (y % 2 == 0 && x % 2 == 1) {
                    // Green pixel in even row
                    g = (float)cfa_pixels[idx];
                    // R from left/right
                    int r_count = 0; float r_sum = 0;
                    if (x > 0) { r_sum += (float)cfa_pixels[y * width + (x - 1)]; r_count++; }
                    if (x < width - 1) { r_sum += (float)cfa_pixels[y * width + (x + 1)]; r_count++; }
                    r = r_sum / (float)r_count;
                    // B from top/bottom
                    int b_count = 0; float b_sum = 0;
                    if (y > 0) { b_sum += (float)cfa_pixels[(y - 1) * width + x]; b_count++; }
                    if (y < height - 1) { b_sum += (float)cfa_pixels[(y + 1) * width + x]; b_count++; }
                    b = b_count > 0 ? b_sum / (float)b_count : 0;
                } else if (y % 2 == 1 && x % 2 == 0) {
                    // Green pixel in odd row
                    g = (float)cfa_pixels[idx];
                    // B from left/right
                    int b_count = 0; float b_sum = 0;
                    if (x > 0) { b_sum += (float)cfa_pixels[y * width + (x - 1)]; b_count++; }
                    if (x < width - 1) { b_sum += (float)cfa_pixels[y * width + (x + 1)]; b_count++; }
                    b = b_count > 0 ? b_sum / (float)b_count : 0;
                    // R from top/bottom
                    int r_count = 0; float r_sum = 0;
                    if (y > 0) { r_sum += (float)cfa_pixels[(y - 1) * width + x]; r_count++; }
                    if (y < height - 1) { r_sum += (float)cfa_pixels[(y + 1) * width + x]; r_count++; }
                    r = r_count > 0 ? r_sum / (float)r_count : 0;
                } else {
                    // Blue pixel
                    b = (float)cfa_pixels[idx];
                    // G from horizontal neighbors
                    int g_count = 0; float g_sum = 0;
                    if (x > 0) { g_sum += (float)cfa_pixels[y * width + (x - 1)]; g_count++; }
                    if (x < width - 1) { g_sum += (float)cfa_pixels[y * width + (x + 1)]; g_count++; }
                    if (y > 0) { g_sum += (float)cfa_pixels[(y - 1) * width + x]; g_count++; }
                    if (y < height - 1) { g_sum += (float)cfa_pixels[(y + 1) * width + x]; g_count++; }
                    g = g_sum / (float)g_count;
                    // R from diagonal neighbors
                    int r_count = 0; float r_sum = 0;
                    if (x > 0 && y > 0) { r_sum += (float)cfa_pixels[(y - 1) * width + (x - 1)]; r_count++; }
                    if (x < width - 1 && y > 0) { r_sum += (float)cfa_pixels[(y - 1) * width + (x + 1)]; r_count++; }
                    if (x > 0 && y < height - 1) { r_sum += (float)cfa_pixels[(y + 1) * width + (x - 1)]; r_count++; }
                    if (x < width - 1 && y < height - 1) { r_sum += (float)cfa_pixels[(y + 1) * width + (x + 1)]; r_count++; }
                    r = r_count > 0 ? r_sum / (float)r_count : 0;
                }

                rgb_output[out_idx] = r * scale;
                rgb_output[out_idx + 1] = g * scale;
                rgb_output[out_idx + 2] = b * scale;
            }
        }
        return 0;
    }
    catch (const std::exception& e) {
        SET_ERROR(e.what());
        return -1;
    }
    catch (...) {
        SET_ERROR("Unknown error in debayer");
        return -1;
    }
}

#pragma mark - Color Pipeline

// ARRI LogC3 encoding curve
static inline float logc3_encode(float x) {
    if (x < 0.0f) return 0.0f;
    if (x < 0.0003f) return 5.0f * x + 0.045f;
    return 0.247190f * log10f(24.7920f * x + 1.0f) + 0.385537f;
}

int zraw_apply_color_pipeline(float* rgb, int width, int height,
                               uint32_t awb_gain_r, uint32_t awb_gain_g, uint32_t awb_gain_b,
                               const int32_t* ccm, int has_ccm,
                               int apply_logc3) {
    if (!rgb || width < 1 || height < 1) {
        SET_ERROR("Invalid color pipeline parameters");
        return -1;
    }
    try {
        int pixel_count = width * height;

        // White balance gains
        float wb_r = (awb_gain_r > 0 && awb_gain_g > 0) ? (float)awb_gain_g / (float)awb_gain_r : 1.0f;
        float wb_b = (awb_gain_b > 0 && awb_gain_g > 0) ? (float)awb_gain_g / (float)awb_gain_b : 1.0f;

        // Color matrix from camera RGB to XYZ
        float cm[9] = {1,0,0, 0,1,0, 0,0,1};
        if (has_ccm && ccm) {
            // CCM is camera_RGB_to_XYZ (fixed-point * 1000)
            for (int i = 0; i < 9; i++) {
                cm[i] = (float)ccm[i] / 1000.0f;
            }
        }

        // XYZ to ARRI Wide Gamut matrix (computed from AWG primaries + D65)
        float xyz_to_awg[9] = {
            2.094f, -0.591f, -0.353f,
            -0.829f, 1.765f, 0.024f,
            0.035f, -0.074f, 0.918f
        };

        // Combined: camera_RGB → XYZ → AWG
        float combined[9];
        if (has_ccm && ccm) {
            for (int i = 0; i < 3; i++) {
                for (int j = 0; j < 3; j++) {
                    combined[i * 3 + j] = 0;
                    for (int k = 0; k < 3; k++) {
                        combined[i * 3 + j] += xyz_to_awg[i * 3 + k] * cm[k * 3 + j];
                    }
                }
            }
        }

        for (int i = 0; i < pixel_count; i++) {
            float r = rgb[i * 3];
            float g = rgb[i * 3 + 1];
            float b = rgb[i * 3 + 2];

            // White balance
            r *= wb_r;
            b *= wb_b;

            if (has_ccm && ccm) {
                float cr = r * combined[0] + g * combined[1] + b * combined[2];
                float cg = r * combined[3] + g * combined[4] + b * combined[5];
                float cb = r * combined[6] + g * combined[7] + b * combined[8];
                r = cr; g = cg; b = cb;
            }

            // Clamp to [0, 1]
            r = r < 0 ? 0 : (r > 1 ? 1 : r);
            g = g < 0 ? 0 : (g > 1 ? 1 : g);
            b = b < 0 ? 0 : (b > 1 ? 1 : b);

            if (apply_logc3) {
                r = logc3_encode(r);
                g = logc3_encode(g);
                b = logc3_encode(b);
            }

            rgb[i * 3] = r;
            rgb[i * 3 + 1] = g;
            rgb[i * 3 + 2] = b;
        }
        return 0;
    }
    catch (const std::exception& e) {
        SET_ERROR(e.what());
        return -1;
    }
    catch (...) {
        SET_ERROR("Unknown error in color pipeline");
        return -1;
    }
}
