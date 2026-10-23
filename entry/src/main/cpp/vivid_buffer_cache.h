#pragma once
#include <cstdint>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>

// Buffer IDs identify immutable ArkTS assets, never addresses or camera IDs.
// Async jobs retain shared ownership even if the bounded cache evicts an asset.
class VividBufferCache {
    struct Entry {
        std::shared_ptr<const std::vector<uint8_t>> bytes;
        uint64_t used;
    };
    std::mutex mutex;
    std::unordered_map<uint32_t, Entry> entries;
    size_t total = 0;
    uint64_t clock = 0;
    static constexpr size_t budget = 16 * 1024 * 1024;
public:
    std::shared_ptr<const std::vector<uint8_t>> obtain(uint32_t id, const uint8_t* data, size_t size) {
        std::lock_guard<std::mutex> lock(mutex);
        auto found = entries.find(id);
        if (found != entries.end() && found->second.bytes->size() == size) {
            found->second.used = ++clock;
            return found->second.bytes;
        }
        auto bytes = std::make_shared<const std::vector<uint8_t>>(data, data + size);
        if (!id || size > budget) return bytes;
        if (found != entries.end()) { total -= found->second.bytes->size(); entries.erase(found); }
        while (total + size > budget && !entries.empty()) {
            auto oldest = entries.begin();
            for (auto it = entries.begin(); it != entries.end(); ++it)
                if (it->second.used < oldest->second.used) oldest = it;
            total -= oldest->second.bytes->size(); entries.erase(oldest);
        }
        entries.emplace(id, Entry{bytes, ++clock}); total += size;
        return bytes;
    }
};
