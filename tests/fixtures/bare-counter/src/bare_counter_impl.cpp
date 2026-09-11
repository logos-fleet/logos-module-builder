#include "bare_counter_impl.h"

namespace {
int64_t g_value = 0;
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

void BareCounterImpl::panic()
{
    // No return, and no cleanup: the point is a module whose image cannot be
    // trusted afterwards, so that "restart it" is the only honest recovery.
    __builtin_trap();
}
