#include "zraw_multi_decoder.h"
#include <iostream>
#include <fstream>
#include <chrono>

// ================================================================
// ThreadSafeQueue Implementation
// ================================================================
template<typename T>
void ThreadSafeQueue<T>::push(T item) {
    std::lock_guard<std::mutex> lock(mutex);
    queue.push(std::move(item));
    cv.notify_all();                    // Wake all workers when new work arrives
}

template<typename T>
bool ThreadSafeQueue<T>::pop(T& item) {
    std::unique_lock<std::mutex> lock(mutex);
    cv.wait(lock, [this]{ return !queue.empty() || finished; });

    if (queue.empty()) return false;

    item = std::move(queue.front());
    queue.pop();

    if (!queue.empty()) {
        cv.notify_one();                // Wake another worker if more work remains
    }
    return true;
}

template<typename T>
void ThreadSafeQueue<T>::set_finished() {
    std::lock_guard<std::mutex> lock(mutex);
    finished = true;
    cv.notify_all();
}

// ================================================================
// ZrawMultiDecoder Implementation
// ================================================================
ZrawMultiDecoder::ZrawMultiDecoder(int num_threads)
{
    num_workers = (num_threads > 0) ? num_threads : std::thread::hardware_concurrency();
    if (num_workers < 1) num_workers = 4;

    decoders.resize(num_workers);
    for (auto& h : decoders)
        h = zraw_decoder__create();

    std::cout << "[ZrawMultiDecoder] Initialized with " << num_workers << " worker threads.\n";
}

ZrawMultiDecoder::~ZrawMultiDecoder()
{
    for (auto h : decoders)
        if (h) zraw_decoder__free(h);
}

ZrawMultiDecoder::DecodeResult ZrawMultiDecoder::process_file(
    const std::string& mov_path,
    const std::vector<FrameLocation>& frame_locations,
    DecodedFrameCallback callback,
    bool enable_retry,
    int max_retries)
{
    DecodeResult result;
    auto overall_start = std::chrono::steady_clock::now();

    if (frame_locations.empty()) {
        std::cerr << "[Error] No frame locations provided.\n";
        return result;
    }

    total_frames.store(frame_locations.size());

    std::ifstream file(mov_path, std::ios::binary);
    if (!file.is_open()) {
        std::cerr << "[Error] Failed to open " << mov_path << std::endl;
        return result;
    }

    std::thread reader([this, &file, &frame_locations]() {
        reader_thread(file, frame_locations);
    });

    std::vector<std::thread> workers;
    for (int i = 0; i < num_workers; ++i) {
        workers.emplace_back([this, i, callback]() {
            worker_thread(i, callback);
        });
    }

    reader.join();
    for (auto& w : workers) w.join();

    result.total_frames = total_frames.load();
    result.successful = frames_processed.load();
    result.failed = failed_frames.size();

    if (enable_retry && !failed_frames.empty() && max_retries > 0) {
        std::cout << "[Retry] Starting retry pass for " << failed_frames.size() << " frames...\n";
        retry_failed_frames(callback);
    }

    auto total_sec = std::chrono::duration<double>(std::chrono::steady_clock::now() - overall_start).count();
    std::cout << "[Summary] " << result.successful << "/" << result.total_frames 
              << " frames decoded in " << total_sec << "s (" 
              << (result.total_frames > 0 ? result.total_frames / total_sec : 0) << " fps)\n";

    return result;
}

void ZrawMultiDecoder::reader_thread(std::ifstream& file, const std::vector<FrameLocation>& locations)
{
    std::cout << "[Reader] Starting to feed " << locations.size() << " frames...\n";
    std::vector<uint8_t> buffer;

    for (size_t i = 0; i < locations.size(); ++i) {
        const auto& loc = locations[i];

        file.seekg(loc.offset_in_file);
        if (!file) {
            std::cerr << "[Reader] Seek failed at frame " << i << std::endl;
            break;
        }

        buffer.resize(loc.size);
        if (!file.read(reinterpret_cast<char*>(buffer.data()), loc.size)) {
            std::cerr << "[Reader] Read failed at frame " << i << std::endl;
            break;
        }

        RawFrame frame;
        frame.data = std::move(buffer);
        frame.frame_index = i;

        frame_queue.push(std::move(frame));

        if (i % 20 == 0) {
            std::cout << "[Reader] Fed " << i << "/" << locations.size() << " frames\n";
        }
    }

    frame_queue.set_finished();
    std::cout << "[Reader] Finished feeding all frames.\n";
}

void ZrawMultiDecoder::worker_thread(int thread_id, DecodedFrameCallback callback)
{
    RawFrame frame;
    while (frame_queue.pop(frame)) {
        ZRAW_DECODER_HANDLE decoder = decoders[thread_id];

        // === CRITICAL: Reset decoder state before every frame ===
        zraw_decoder__reset(decoder);

        auto t0 = std::chrono::steady_clock::now();

        // 1. Read raw frame
        auto state = zraw_decoder__read_hisi_frame(decoder, 
            frame.data.data(), (int)frame.data.size());

        if (state != ZRAW_DECODER_STATE__FRAME_IS_READ) {
            std::lock_guard<std::mutex> lock(failed_mutex);
            failed_frames.emplace_back(frame.frame_index, std::move(frame.data));
            continue;
        }

        // 2. Decompress
        state = zraw_decoder__decompress_hisi_frame(decoder);
        if (state != ZRAW_DECODER_STATE__FRAME_IS_DECOMPRESSED) {
            std::lock_guard<std::mutex> lock(failed_mutex);
            failed_frames.emplace_back(frame.frame_index, std::move(frame.data));
            continue;
        }

        // 3. Get frame info
        zraw_frame_info_t info{};
        zraw_decoder__get_hisi_frame_info(decoder, info);

        // 4. Get decompressed CFA
        size_t pixel_count = (size_t)info.width_in_photodiodes * info.height_in_photodiodes;
        std::vector<uint16_t> cfa(pixel_count);

        state = zraw_decoder__get_decompressed_CFA(decoder, 
            cfa.data(), (int)(pixel_count * sizeof(uint16_t)));

        // SUCCESS CHECK: Library returns STANDBY on success for this call
        if (state == ZRAW_DECODER_STATE__STANDBY && callback) {
            callback(frame, info, cfa.data(), pixel_count * sizeof(uint16_t));
        } else {
            std::lock_guard<std::mutex> lock(failed_mutex);
            failed_frames.emplace_back(frame.frame_index, std::move(frame.data));
        }

        auto decode_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - t0).count();

        frames_processed.fetch_add(1, std::memory_order_relaxed);

        if (frame.frame_index % 5 == 0) {
            std::cout << "[Worker " << thread_id << "] Frame " << frame.frame_index 
                      << " | " << decode_ms << " ms\n";
        }
    }
}

void ZrawMultiDecoder::retry_failed_frames(DecodedFrameCallback callback)
{
    // TODO: Implement retry logic if needed in the future
    failed_frames.clear();
}
