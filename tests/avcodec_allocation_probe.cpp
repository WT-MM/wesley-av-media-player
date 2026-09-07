#include "media/avcodec/allocation_probe.hpp"
#include <malloc/malloc.h>
#include <pthread.h>
#include <os/lock.h>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <new>
#include <atomic>
#include <cstring>
#include <dlfcn.h>
namespace {
struct Entry { void* pointer{}; std::size_t bytes{}; };
struct Counts { std::uint64_t allocations{}, frees{}, locks{}, cppNew{}; };
struct CallSite { const char* image{}; const char* symbol{}; unsigned domain{}, kind{}; std::uint64_t calls{}; };
struct Probe {
  CallSite sites[512]{};
  std::uint64_t siteOverflow{};
  Entry entries[65536]{};
  Counts counts[3]{};
  std::size_t live{}, peak{};
  unsigned domain{};
  std::uint64_t frames{}, overflow{};
  bool inside{};
};
struct Slot { std::atomic<std::uintptr_t> thread{}; Probe probe; };
Slot slots[32];
Probe* currentProbe() noexcept {
  const auto thread=reinterpret_cast<std::uintptr_t>(pthread_self());
  for (auto& slot:slots) if(slot.thread.load(std::memory_order_relaxed)==thread)return &slot.probe;
  return nullptr;
}
void attribute(Probe& s, unsigned kind, void* caller) noexcept {
  Dl_info info{};
  if (!dladdr(caller, &info)) { ++s.siteOverflow; return; }
  for (auto& site:s.sites) {
    if (!site.calls || (site.image==info.dli_fname && site.symbol==info.dli_sname &&
                       site.domain==s.domain && site.kind==kind)) {
      if (!site.calls) site={info.dli_fname,info.dli_sname,s.domain,kind,0};
      ++site.calls; return;
    }
  }
  ++s.siteOverflow;
}
void allocation(void* p, void* caller) noexcept {
  auto* current=currentProbe();if(!current)return;
  auto& s=*current;
  if (!p || !s.domain || s.inside) return;
  s.inside=true;
  ++s.counts[s.domain].allocations;
  attribute(s,0,caller);
  const auto size=malloc_size(p);
  const auto start=(reinterpret_cast<std::uintptr_t>(p)>>4U)%65536;
  bool stored=false;
  for (std::size_t n=0;n<65536;++n) {
    auto& entry=s.entries[(start+n)%65536];
    if (!entry.pointer || entry.pointer==reinterpret_cast<void*>(1)) {
      entry={p,size};stored=true;break;
    }
  }
  if (!stored) ++s.overflow;
  else { s.live+=size; if(s.live>s.peak)s.peak=s.live; }
  s.inside=false;
}
void deallocation(void* p) noexcept {
  auto* current=currentProbe();if(!current)return;
  auto& s=*current;
  if (!p || !s.domain || s.inside) return;
  s.inside=true;
  ++s.counts[s.domain].frees;
  const auto start=(reinterpret_cast<std::uintptr_t>(p)>>4U)%65536;
  for (std::size_t n=0;n<65536;++n) {
    auto& entry=s.entries[(start+n)%65536];
    if (!entry.pointer) break;
    if(entry.pointer==p) {s.live-=entry.bytes;entry={reinterpret_cast<void*>(1),0};break;}
  }
  s.inside=false;
}
void lockAttempt(void* caller) noexcept {
  if(auto* p=currentProbe();p && p->domain && !p->inside) {
    p->inside=true; ++p->counts[p->domain].locks; attribute(*p,1,caller); p->inside=false;
  }
}
void* countedMalloc(std::size_t n) {void* p=malloc(n);allocation(p,__builtin_return_address(0));return p;}
void* countedCalloc(std::size_t n,std::size_t size) {void* p=calloc(n,size);allocation(p,__builtin_return_address(0));return p;}
void countedFree(void* p) {deallocation(p);free(p);}
void* countedRealloc(void* p,std::size_t n) {
  deallocation(p);void* q=realloc(p,n);allocation(q?q:p,__builtin_return_address(0));return q;
}
int countedAlign(void** p,std::size_t a,std::size_t n) {int r=posix_memalign(p,a,n);if(!r)allocation(*p,__builtin_return_address(0));return r;}
int countedMutex(pthread_mutex_t* p) {lockAttempt(__builtin_return_address(0));return pthread_mutex_lock(p);}
int countedTryMutex(pthread_mutex_t* p) {lockAttempt(__builtin_return_address(0));return pthread_mutex_trylock(p);}
int countedRead(pthread_rwlock_t* p) {lockAttempt(__builtin_return_address(0));return pthread_rwlock_rdlock(p);}
int countedWrite(pthread_rwlock_t* p) {lockAttempt(__builtin_return_address(0));return pthread_rwlock_wrlock(p);}
void countedUnfair(os_unfair_lock_t p) {lockAttempt(__builtin_return_address(0));os_unfair_lock_lock(p);}
#define INTERPOSE(replacement, original) \
__attribute__((used,section("__DATA,__interpose"))) static const struct {const void* a;const void* b;} hook_##original{reinterpret_cast<const void*>(&replacement),reinterpret_cast<const void*>(&original)}
INTERPOSE(countedMalloc,malloc);
INTERPOSE(countedCalloc,calloc);
INTERPOSE(countedRealloc,realloc);
INTERPOSE(countedAlign,posix_memalign);
INTERPOSE(countedFree,free);
INTERPOSE(countedMutex,pthread_mutex_lock);
INTERPOSE(countedTryMutex,pthread_mutex_trylock);
INTERPOSE(countedRead,pthread_rwlock_rdlock);
INTERPOSE(countedWrite,pthread_rwlock_wrlock);
INTERPOSE(countedUnfair,os_unfair_lock_lock);
}
void* operator new(std::size_t n) {
  if(auto* p=currentProbe();p && p->domain)++p->counts[p->domain].cppNew;
  if(auto* p=countedMalloc(n?n:1))return p;
  throw std::bad_alloc();
}
void* operator new[](std::size_t n) {return ::operator new(n);}
void operator delete(void* p) noexcept {countedFree(p);}
void operator delete[](void* p) noexcept {countedFree(p);}
namespace wam::media::avcodec {
void allocationProbeBegin() noexcept {
  for(auto& slot:slots) {
    std::uintptr_t expected=0;
    if(!slot.thread.compare_exchange_strong(expected,1))continue;
    std::memset(&slot.probe,0,sizeof(slot.probe));slot.probe.domain=1;
    slot.thread.store(reinterpret_cast<std::uintptr_t>(pthread_self()));return;
  }
  std::abort();
}
unsigned allocationProbeDomain(unsigned domain) noexcept {auto* p=currentProbe();if(!p)return 0;auto old=p->domain;p->domain=domain;return old;}
void allocationProbeFrame() noexcept {if(auto* p=currentProbe())++p->frames;}
void allocationProbeEnd() noexcept {
  auto& probe=*currentProbe();
  probe.domain=0;
  const auto& a=probe.counts[1];const auto& b=probe.counts[2];
  if (probe.frames && !a.allocations) { std::fputs("AllocationProbeNotInterposed\n",stderr);std::abort(); }
  std::printf("{\"probe\":\"worker_lifetime\",\"frames\":%llu,\"worker_allocations\":%llu,\"worker_locks\":%llu,\"worker_cpp_new\":%llu,\"adapter_allocations_including_frameworks\":%llu,\"adapter_locks_including_frameworks\":%llu,\"adapter_cpp_new\":%llu,\"peak_tracked_heap_bytes\":%zu,\"remaining_tracked_heap_bytes\":%zu,\"table_overflow\":%llu}\n",
    probe.frames,a.allocations,a.locks,a.cppNew,b.allocations,b.locks,b.cppNew,probe.peak,probe.live,probe.overflow);
  if (probe.siteOverflow) { std::fputs("AllocationAttributionOverflow\n",stderr); std::abort(); }
  std::uint64_t attributed[3][2]{};
  for (const auto& site:probe.sites) if(site.calls) {
    attributed[site.domain][site.kind]+=site.calls;
    std::printf("{\"probe\":\"call_site\",\"domain\":%u,\"kind\":\"%s\",\"image\":\"%s\",\"symbol\":\"%s\",\"calls\":%llu}\n",
        site.domain,site.kind?"lock":"allocation",site.image?site.image:"unknown",site.symbol?site.symbol:"unknown",site.calls);
  }
  for (unsigned domain=1;domain<3;++domain)
    if (attributed[domain][0]!=probe.counts[domain].allocations || attributed[domain][1]!=probe.counts[domain].locks) std::abort();
  for(auto& slot:slots)if(&slot.probe==&probe){slot.thread.store(0);break;}
}
}
