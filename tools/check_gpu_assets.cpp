#include "../entry/src/main/cpp/vivid_buffer_cache.h"
#include <cassert>
#include <chrono>
#include <iostream>

int main() {
    VividBufferCache cache;
    std::vector<uint8_t> input(4 * 1024 * 1024, 77);
    auto first = cache.obtain(1, input.data(), input.size());
    auto begin = std::chrono::steady_clock::now();
    for (int i=0;i<500;++i) assert(cache.obtain(1,input.data(),input.size()).get()==first.get());
    auto cached = std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count();
    volatile uint64_t checksum = 0;
    begin = std::chrono::steady_clock::now();
    for(int i=0;i<500;++i) {
        std::vector<uint8_t> copied(input);
        uint64_t hash=1469598103934665603ULL;
        for(auto v:copied) hash=(hash^v)*1099511628211ULL;
        checksum=checksum+hash;
    }
    auto old = std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count();
    for(uint32_t id=2;id<=8;++id) cache.obtain(id,input.data(),input.size());
    assert((*first)[0]==77); // In-flight frame survives LRU eviction.
    assert(cache.obtain(1,input.data(),input.size()).get()!=first.get());
    input[0]=17;
    auto changed=cache.obtain(9,input.data(),input.size());
    assert((*changed)[0]==17 && (*first)[0]==77);
    assert(cache.obtain(0,input.data(),32).get()!=cache.obtain(0,input.data(),32).get());
    std::cout<<"PASS immutable asset reuse, bounded eviction, async lifetime, new revision invalidation\n"
             <<"synthetic_4MiB_500_frames_old_copy_hash_ms="<<old<<" cached_ms="<<cached<<"\n";
}
