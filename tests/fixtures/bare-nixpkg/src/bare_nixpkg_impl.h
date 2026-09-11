#pragma once

// A leaf universal module that is ordinary in every way but one: its only
// third-party dependency comes from `nix.packages` in metadata.json rather
// than from the SDK, and its source #includes that package's headers.
//
// That single property is what this fixture exists to cross-compile, because
// a native build hides it and an iOS one does not. Why, and what the builder
// does about it: lib/buildBareModule.nix (`modulePrefixes`).
//
// Boost, because that is the case measured: capability_module's only Boost use
// is boost/uuid, which is header-only -- so nothing links and the failure was
// purely about the include path and find_package().

#include <string>

#include <logos_module_context.h>

class BareNixpkgImpl : public LogosModuleContext {
public:
    BareNixpkgImpl() = default;
    ~BareNixpkgImpl() = default;

    // Returns a random UUID in 8-4-4-4-12 form, produced by the declared
    // package. Its VALUE is not what the check reads -- the artifact existing
    // at all is -- but it has to be a real call, or the compiler would be free
    // to drop the include and the fixture would stop proving anything.
    std::string uuid();
};
