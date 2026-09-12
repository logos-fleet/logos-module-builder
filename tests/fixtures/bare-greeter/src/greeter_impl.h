#pragma once

// THE NATIVE MODULE A `web` VARIANT CALLS BY NAME.
//
// `logos.callModuleAsync("greeter", "greet", ["logos"], cb)` from a module's QML
// leaves the page as a real logos-protocol Call, crosses the container's
// channel, and is routed by the host as the calling module. What it needs on the
// far end is an ORDINARY module — nothing about it knows a page exists — and the
// smallest honest one is a string in, a string out: a scalar would not prove the
// payload survived the trip, and a stateful method's right answer depends on how
// many times the harness ran.
//
// Universal authoring, so the builder's `bare` output is available: the image
// the host dlopens into its own process, with no Qt and no subprocess. That
// keeps a container check to one process -- the page, the core and this module
// -- which is why this fixture is Bare rather than a Qt plugin.
//
// logos-module-builder's wasm/browser-e2e answers the same name and method from
// a JavaScript stub, and logos-basecamp's web-container-test loads THIS. The two
// harnesses assert the same string because they stand in for each other.

#include <string>

#include <logos_module_context.h>

class GreeterImpl : public LogosModuleContext {
public:
    GreeterImpl() = default;
    ~GreeterImpl() = default;

    std::string greet(const std::string& who);
};
