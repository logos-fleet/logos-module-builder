#include "bare_relay_impl.h"

// The generated umbrella over metadata.json#dependencies. Included here rather
// than in the header so the codegen's header parser only sees the contract.
#include "logos_sdk.h"

int64_t BareRelayImpl::addTo(int64_t amount)
{
    return modules().bare_counter.increment(amount);
}

int64_t BareRelayImpl::peek()
{
    return modules().bare_counter.current();
}
