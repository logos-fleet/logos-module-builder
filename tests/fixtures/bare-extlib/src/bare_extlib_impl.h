#pragma once

// A leaf universal C++ module that CALLS an external native library — the one
// thing a Bare module cannot do by cross-compiling its own sources, because
// the library comes from somewhere else entirely.
//
// The call below is what makes the fixture worth anything: a module that only
// DECLARES `nix.external_libraries` would link and pass every gate with the
// library silently absent.

#include <cstdint>

#include <logos_module_context.h>

class BareExtlibImpl : public LogosModuleContext {
public:
    BareExtlibImpl() = default;
    ~BareExtlibImpl() = default;

    // Answers with whatever the external library says, so the symbol has to
    // resolve at LINK time for the artifact to exist at all.
    int64_t answer();
};
