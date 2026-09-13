#pragma once
// THE SECOND DOOR — a `web` variant's view backend calling ANOTHER module.
//
// The Wasm host's header states the rule this implements: "a wasm module with
// dependencies is a later slice, and it will arrive as a second door over the
// same channel rather than by linking a consumer stack in here". This is that
// door, for a `type: ui_qml` module's backend image (slice 30, criterion 2).
//
// WHY IT IS NOT `modules().<dep>.<method>()`. A native module reaches its
// dependencies through generated typed clients over LogosAPI — Qt Remote
// Objects, a TokenManager and a capability handshake, none of which is in a
// wasm image and none of which could be: every one of those wrappers is
// SYNCHRONOUS, and this image is single-threaded with no ASYNCIFY (ADR 0004).
// A reply arrives as a message on the page's event loop, so a call that blocked
// waiting for one would deadlock the loop that is meant to deliver it. Not a
// missing feature — the target forbids it — which is why the door is async and
// only async, and why it is a different spelling rather than the same one.
//
// WHAT IT IS. The same outbound path `logos.callModuleAsync` already takes from
// a view's QML: a Call over logos-protocol's web transport, relayed by the page
// to the container, answered by the module's OWN LogosAPI on the native side
// (LogosApiRoutes) and therefore authorized by capability_module exactly as a
// native caller is. The container grants nothing of its own, and this image
// holds no other module's credentials — only the tokens the core pushed to it.
//
//   backend (this image) ── callModuleAsync ──> the page ──> the container
//                                                               |
//                                                   the native module, by name
//
// WHERE IT IS IMPLEMENTED: wasm/logos_view_wasm_host.cpp, which is linked into
// every view-backend image beside the backend's own translation units. There is
// deliberately NO other implementation — a backend source that calls this is a
// `web`-variant source, and a desktop plugin that included it would not link.
//
// ORDERING. Calls are delivered in the order they are made and their replies
// are NOT: the container answers each independently. A backend that needs a
// sequence chains it in the callbacks.

#include <QJsonArray>
#include <QJsonValue>
#include <QString>

#include <functional>

namespace logos {
namespace web {

// One call's outcome. `ok` is the ONLY reliable success test — a failed call
// leaves `value` null, and a null is also a perfectly good success value for a
// method that returns nothing. Same rule, and the same reason, as
// logos::AsyncResult on the native side.
struct ModuleCallResult {
    bool ok = false;
    QJsonValue value;
    // The protocol's code ("METHOD_FAILED", "no host channel", …) and the
    // human-readable half. Both empty on success.
    QString errorCode;
    QString error;
};

using ModuleCallCallback = std::function<void(const ModuleCallResult&)>;

// Call `method` on `module`, with `args` as the call's positional arguments.
//
// The callback runs LATER, on the page's event loop, exactly once. It is never
// invoked before this function returns — including in the failure cases, which
// are posted rather than delivered inline, so a caller never has to reason
// about a callback that fires while it is still setting itself up.
void callModuleAsync(const QString& module, const QString& method,
                     const QJsonArray& args, ModuleCallCallback callback);

// Whether the door is open: the page has bound the container's bridge and the
// channel is live. False during startup — this image is up before the
// container's bridge has resolved — and a call made in that window fails fast
// through the callback rather than hanging.
bool canCallModules();

} // namespace web
} // namespace logos
