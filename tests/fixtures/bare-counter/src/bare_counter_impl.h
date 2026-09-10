#pragma once

// The counter — a leaf universal C++ module and the first consumer of the
// Bare module output. Universal authoring means the whole file is Qt-free:
// the builder derives the LIDL contract from these signatures and generates
// both the Qt-plugin glue (for a Qt host) and the module-impl C ABI wrapper
// (for a no-Qt host). The Bare artifact is that second one, alone.

#include <cstdint>

#include <logos_module_context.h>

class BareCounterImpl : public LogosModuleContext {
public:
    BareCounterImpl() = default;
    ~BareCounterImpl() = default;

    int64_t increment(int64_t amount);
    int64_t current();
    void reset();
};
