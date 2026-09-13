#include "bare_counter_impl.h"

#include <fstream>
#include <iterator>

#ifdef __EMSCRIPTEN__
// THE BARRIER, supplied by the Wasm host this module's translation units are
// linked into (logos-module-builder's wasm/logos_wasm_host.cpp). Declared
// rather than included because a fixture must not depend on the host's headers,
// and guarded because on every other target the symbol does not exist -- and
// does not need to, since a native write is already durable.
extern "C" int logos_storage_commit(void);
#endif

namespace {
int64_t g_value = 0;

const char* kNote = "/note.txt";
}

int64_t BareCounterImpl::increment(int64_t amount)
{
    g_value += amount;
    // The generated event body marshals this into JSON and hands it to
    // whatever emit callback the host installed.
    counted(g_value);
    return g_value;
}

int64_t BareCounterImpl::current()
{
    return g_value;
}

void BareCounterImpl::reset()
{
    g_value = 0;
}

int64_t BareCounterImpl::add(int64_t a, int64_t b)
{
    return a + b;
}

bool BareCounterImpl::remember(const std::string& text)
{
    const std::string& root = instancePersistencePath();
    if (root.empty()) return false;

    {
        std::ofstream out(root + kNote, std::ios::binary | std::ios::trunc);
        if (!out) return false;
        out << text;
        out.flush();
        if (!out) return false;
    }

#ifdef __EMSCRIPTEN__
    // Without this the write is in the image's filesystem and nowhere else.
    if (logos_storage_commit() != 0) return false;
#endif
    return true;
}

std::string BareCounterImpl::recall()
{
    const std::string& root = instancePersistencePath();
    if (root.empty()) return {};
    std::ifstream in(root + kNote, std::ios::binary);
    if (!in) return {};
    return std::string((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
}

void BareCounterImpl::panic()
{
    // No return, and no cleanup: the point is a module whose image cannot be
    // trusted afterwards, so that "restart it" is the only honest recovery.
    __builtin_trap();
}
