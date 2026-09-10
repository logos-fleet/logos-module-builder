#pragma once

// Forwards to bare_counter through the typed, Qt-free `modules()` surface.
// For a universal (header-first cdylib) module those dependency wrappers call
// the logos-protocol C ABI directly, so this module's Bare artifact must come
// out with `lp_invoke` UNDEFINED — the host image supplies it. That is the
// property the bare-modules check asserts.

#include <cstdint>

#include <logos_module_context.h>

class BareRelayImpl : public LogosModuleContext {
public:
    BareRelayImpl() = default;
    ~BareRelayImpl() = default;

    int64_t addTo(int64_t amount);
    int64_t peek();
};
