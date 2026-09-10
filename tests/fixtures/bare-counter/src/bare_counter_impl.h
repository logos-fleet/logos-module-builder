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

logos_events:
    // The counter's one event, and the reason it has one: the Native container
    // drives a Bare module through the emit callback of the module-impl C ABI,
    // and only a module that actually emits proves that half reaches a
    // subscriber. Declared here so the generated cdylib sidecar emits the
    // typed body -- nothing in the Bare artifact is hand-written.
    void counted(int64_t value);
};
