/* LGPL-2.1-or-later. Decoder-worker allocation domains; headers preserve 64-byte alignment. */
void *av_wam_reservation_begin(size_t limit);
size_t av_wam_reservation_used(void *opaque);
int av_wam_reservation_exhausted(void *opaque);
size_t av_wam_reservation_end(void *opaque);

typedef struct WamReservation {
    atomic_size_t used;
    atomic_uint references;
    atomic_int exhausted;
    size_t limit;
} WamReservation;
typedef union WamAllocation {
    struct { WamReservation *owner; size_t size, charge; } value;
    unsigned char alignment[64];
} WamAllocation;
#include <pthread.h>
static pthread_key_t wam_reservation_key;
static pthread_once_t wam_reservation_once = PTHREAD_ONCE_INIT;
static atomic_int wam_reservation_key_ready;
static void wam_create_reservation_key(void)
{
    if (!pthread_key_create(&wam_reservation_key, NULL))
        atomic_store_explicit(&wam_reservation_key_ready, 1, memory_order_release);
}
static WamReservation *wam_current_reservation(void)
{
    return atomic_load_explicit(&wam_reservation_key_ready, memory_order_acquire)
        ? pthread_getspecific(wam_reservation_key) : NULL;
}
__attribute__((destructor)) static void wam_delete_reservation_key(void)
{
    if (atomic_load_explicit(&wam_reservation_key_ready, memory_order_acquire))
        pthread_key_delete(wam_reservation_key);
}

void *av_wam_reservation_begin(size_t limit)
{
    WamReservation *r;
    pthread_once(&wam_reservation_once, wam_create_reservation_key);
    if (!atomic_load_explicit(&wam_reservation_key_ready, memory_order_acquire) || wam_current_reservation() || limit < sizeof(*r) || limit > UINT32_MAX)
        return NULL;
    r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    atomic_init(&r->used, sizeof(*r));
    atomic_init(&r->references, 1);
    atomic_init(&r->exhausted, 0);
    r->limit = limit;
    if (pthread_setspecific(wam_reservation_key, r)) { free(r); return NULL; }
    return r;
}
size_t av_wam_reservation_used(void *opaque)
{
    WamReservation *r = opaque;
    return r ? atomic_load_explicit(&r->used, memory_order_relaxed) : 0;
}
int av_wam_reservation_exhausted(void *opaque)
{
    WamReservation *r = opaque;
    return r && atomic_load_explicit(&r->exhausted, memory_order_relaxed);
}
size_t av_wam_reservation_end(void *opaque)
{
    WamReservation *r = opaque;
    size_t remaining;
    if (!r || r != wam_current_reservation()) return SIZE_MAX;
    pthread_setspecific(wam_reservation_key, NULL);
    remaining = atomic_load_explicit(&r->used, memory_order_relaxed) - sizeof(*r);
    if (atomic_fetch_sub_explicit(&r->references, 1, memory_order_acq_rel) == 1)
        free(r);
    return remaining;
}
static void *wam_allocate(size_t size, WamReservation *r)
{
    WamAllocation *header = NULL;
    size_t charge, used;
    if (size > atomic_load_explicit(&max_alloc_size, memory_order_relaxed) ||
        size > SIZE_MAX - 127) return NULL;
    charge = ((size + 63) & ~(size_t)63) + 64;
    if (r) {
        used = atomic_load_explicit(&r->used, memory_order_relaxed);
        do {
            if (charge > r->limit || used > r->limit - charge) {
                atomic_store_explicit(&r->exhausted, 1, memory_order_relaxed);
                return NULL;
            }
        } while (!atomic_compare_exchange_weak_explicit(&r->used, &used, used + charge,
                                                        memory_order_relaxed, memory_order_relaxed));
        atomic_fetch_add_explicit(&r->references, 1, memory_order_relaxed);
    }
    if (posix_memalign((void **)&header, 64, charge)) header = NULL;
    if (!header) {
        if (r) {
            atomic_fetch_sub_explicit(&r->used, charge, memory_order_relaxed);
            atomic_fetch_sub_explicit(&r->references, 1, memory_order_relaxed);
        }
        return NULL;
    }
    header->value.owner = r;
    header->value.size = size;
    header->value.charge = charge;
    return header + 1;
}
void *av_malloc(size_t size)
{
    return wam_allocate(size, wam_current_reservation());
}
void av_free(void *ptr)
{
    WamAllocation *header;
    WamReservation *r;
    size_t charge;
    if (!ptr) return;
    header = (WamAllocation *)ptr - 1;
    r = header->value.owner;
    charge = header->value.charge;
    free(header);
    if (r) {
        atomic_fetch_sub_explicit(&r->used, charge, memory_order_relaxed);
        if (atomic_fetch_sub_explicit(&r->references, 1, memory_order_acq_rel) == 1)
            free(r);
    }
}
void *av_realloc(void *ptr, size_t size)
{
    WamAllocation *header;
    void *replacement;
    if (!ptr) return av_malloc(size);
    header = (WamAllocation *)ptr - 1;
    replacement = wam_allocate(size, header->value.owner);
    if (!replacement) return NULL;
    memcpy(replacement, ptr, FFMIN(size, header->value.size));
    av_free(ptr);
    return replacement;
}
