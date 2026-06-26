#pragma once
#include "libzraw.h"
#include <vector>
#include <thread>
#include <atomic>
#include <mutex>
#include <queue>
#include <condition_variable>
#include <string>
#include <functional>
#include <chrono>

struct FrameLocation {
    uint64_t offset_in_file = 0;
    uint32_t size = 0;
};

template<typename T>
class ThreadSafeQueue {
    std::queue<T> queue;
    mutable std::mutex mutex;
    std::condition_variable cv;
    bool finished = false;

public:
    void push(T item);
    bool pop(T& item);
    void set_finished();
};

struct RawFrame {
    std::vector<uint8_t> data;
    size_t frame_index;

    RawFrame() : frame_index(0) {}
    RawFrame(std::vector<uint8_t>&& d, size_t i) : data(std::move(d)), frame_index(i) {}
};

using DecodedFrameCallback = std::function<void(
    const RawFrame& raw_frame,
    const zraw_frame_info_t& info,
    const uint16_t* cfa_data,
    size_t cfa_size_in_bytes
)>;

class ZrawMultiDecoder {
public:
    explicit ZrawMultiDecoder(int num_threads = 0);
    ~ZrawMultiDecoder();

    struct DecodeResult {
        size_t total_frames = 0;
        size_t successful = 0;
        size_t failed = 0;
        std::vector<size_t> failed_indices;
    };

    DecodeResult process_file(const std::string& mov_path,
                             const std::vector<FrameLocation>& frame_locations,
                             DecodedFrameCallback callback,
                             bool enable_retry = true,
                             int max_retries = 2);

    size_t get_total_frames() const { return total_frames.load(); }
    size_t get_frames_processed() const { return frames_processed.load(); }
    int    get_worker_count() const { return num_workers; }

private:
    void reader_thread(std::ifstream& file, const std::vector<FrameLocation>& locations);
    void worker_thread(int thread_id, DecodedFrameCallback callback);
    void retry_failed_frames(DecodedFrameCallback callback);

    int num_workers;
    std::vector<ZRAW_DECODER_HANDLE> decoders;

    ThreadSafeQueue<RawFrame> frame_queue;
    std::atomic<size_t> total_frames{0};
    std::atomic<size_t> frames_processed{0};

    std::vector<std::pair<size_t, std::vector<uint8_t>>> failed_frames;
    std::mutex failed_mutex;
};
