// THE WASM HOST — a Bare module and logos-protocol's web transport, compiled to
// WebAssembly and serving one module inside a Web Worker (slice 26).
//
// WHAT THIS IMAGE IS. Every other host in the stack LOADS a module: the Native
// container dlopen()s a Bare artifact, the subprocess container spawns one, the
// Web container opens a page. This one IS the module — the module's own
// translation units are linked into it, and there is nothing to load, because a
// wasm image has no dlopen and the App Store's rule (ADR 0003) is the reason the
// web variant exists at all. One module per image, one image per Worker.
//
// WHAT IT TALKS. The web transport, unchanged: the same Call / Result /
// Subscribe / Unsubscribe / Event / Token / Methods / MethodsResult messages as
// JSON over an IMessageChannel, and the channel here is the Worker's own message
// port. The page that spawned the Worker relays those texts to the container,
// which is why the container needs no wasm-specific code and why the same
// artifact runs behind a WKWebView on a phone.
//
//     core ── web transport ──> container ── webview bridge ──> loader page
//                                                                    |
//                                                       worker.postMessage
//                                                                    v
//                                                              THIS IMAGE
//
// WHAT IT IS NOT. It is not a Logos CORE: it publishes no registry, resolves no
// name but its own, and holds no other module's credentials. And it makes no
// outbound calls — a wasm module with dependencies is a later slice, and it will
// arrive as a second door over the same channel rather than by linking a
// consumer stack in here (see implementations/wasm/wasm_lp_abi.cpp).
//
// SINGLE-THREADED, BY CONSTRUCTION. No pthreads, no ASYNCIFY: a Worker is one
// event loop, dispatch runs on it, and every reply this file produces is
// produced on the stack of the message that asked for it. That is also the whole
// of the concurrency argument for the state below.

#include "logos_module_impl.h"

#include "incoming_call_handler.h"
#include "json_mapping.h"
#include "message_channel.h"
#include "rpc_message.h"
#include "web_rpc_connection.h"

#include <emscripten.h>

#include <nlohmann/json.hpp>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <utility>
#include <vector>

// The module this image serves. Defined by the build (-DLOGOS_WASM_MODULE_NAME),
// never discovered: a module's identity on this wire is the channel it answers
// on, and the name is only how the core addresses it.
#ifndef LOGOS_WASM_MODULE_NAME
#  error "LOGOS_WASM_MODULE_NAME must be defined by the build"
#endif

namespace {

using json = nlohmann::json;
using namespace logos::plain;

const std::string kModuleName = LOGOS_WASM_MODULE_NAME;

// ── the channel: the Worker's own message port ──────────────────────────────
//
// OUT. `postMessage` inside a Worker's global scope sends to whoever spawned it,
// and that is both the shipping path and the whole binding — no addressing, no
// framing, no length prefix, which is exactly the shape IMessageChannel was cut
// to (see message_channel.h).
//
// THE FALLBACK IS NOT A CONVENIENCE. A host that is only reachable through a
// Worker can only be tested through a browser, and the thing most worth testing
// about it -- that a Call really does reach the module's own code and come back
// as a Result -- has nothing to do with browsers. `Module.logosOut` is the same
// port with the transport substituted: a node harness installs it, calls
// _logos_wasm_deliver with a frame, and reads the answer. See the builder's
// tests/test-web-variant.nix.
//
// It cannot weaken the shipping path: in a Worker `postMessage` is always a
// function, so the first arm always wins there.
EM_JS(void, logos_wasm_post, (const char* text), {
    var payload = UTF8ToString(text);
    if (typeof postMessage === 'function') { postMessage(payload); return; }
    if (Module['logosOut']) { Module['logosOut'](payload); return; }
    // Neither: the image is running somewhere with no way back. Say so once
    // rather than dropping frames silently.
    if (!Module['_logosOutWarned']) {
        Module['_logosOutWarned'] = true;
        console.error('logos-wasm-host: no message port (no postMessage, no Module.logosOut)');
    }
});

// ── the durable store ───────────────────────────────────────────────────────
//
// The image's persistence path and the barrier that makes writes under it
// survive the page. Both halves live in wasm/logos_wasm_storage.js, linked into
// this glue with --pre-js; see that file for why the mount cannot be done from
// here (it has to be populated before main runs, and the populate is async).
//
// This side is three EM_JS calls -- the path, the backend's name, the barrier --
// and one export, because what the module needs is a path and a barrier and
// nothing else.
EM_JS(char*, logos_storage_dir_js, (), {
    // Double quotes throughout: an EM_JS body is a macro argument, so the C
    // preprocessor tokenises it first and reads a JS '' as an empty character
    // constant (-Winvalid-pp-token).
    var dir = Module["logosStorageDir"] || "";
    var len = lengthBytesUTF8(dir) + 1;
    var buf = _malloc(len);
    stringToUTF8(dir, buf, len);
    return buf;
});

EM_JS(char*, logos_storage_backend_js, (), {
    var name = Module["logosStorageBackend"] || "memfs";
    var len = lengthBytesUTF8(name) + 1;
    var buf = _malloc(len);
    stringToUTF8(name, buf, len);
    return buf;
});

EM_JS(int, logos_storage_commit_js, (), {
    return Module["logosStorageCommit"] ? Module["logosStorageCommit"]() : -1;
});

std::string takeJsString(char* owned)
{
    if (!owned) return {};
    std::string s(owned);
    free(owned);
    return s;
}

class WorkerPortChannel : public logos::web::IMessageChannel {
public:
    void setReceiver(Receiver receiver) override { m_receiver = std::move(receiver); }

    bool send(const std::string& message) override
    {
        if (!m_open) return false;
        logos_wasm_post(message.c_str());
        return true;
    }

    void close() override { m_open = false; m_receiver = nullptr; }
    bool isOpen() const override { return m_open; }

    // Called from JS, on the Worker's event loop. Never re-entrant with itself:
    // a worker delivers one message event at a time.
    void deliver(const std::string& text)
    {
        if (m_receiver) m_receiver(text);
    }

private:
    Receiver m_receiver;
    bool m_open = true;
};

// ── the module, as a provider ───────────────────────────────────────────────
//
// Mirrors logos-js-sdk's WebProvider case for case, deliberately: the two are
// the only two implementations of "a module answering the web transport from
// inside a sandbox", and a consumer must not be able to tell them apart. Where
// this file makes a choice, the comment says which of the two it is copying.
class WasmModuleProvider : public IncomingCallHandler {
public:
    void onCall(const CallMessage& req, CallReply reply) override
    {
        ResultMessage res;
        res.id = req.id;

        if (req.object != kModuleName) {
            res.ok = false;
            res.err = "object not published: " + req.object;
            res.errCode = "MODULE_NOT_LOADED";
            reply(std::move(res));
            return;
        }
        if (!authorized(req.authToken)) {
            res.ok = false;
            res.err = "unauthorized call to " + kModuleName + "." + req.method;
            res.errCode = "UNAUTHORIZED";
            reply(std::move(res));
            return;
        }

        json args = json::array();
        for (const RpcValue& a : req.args) args.push_back(rpcValueToJson(a));

        // WHO IS CALLING, for the duration of this dispatch and no longer. The
        // module's language binding surfaces it as logos::currentCaller(). A
        // web-transport peer is a module only once it has presented a token
        // this image was told about; before that it is genuinely unknown, and
        // saying so is the whole point of the "unknown" arm.
        const std::string caller = callerJson(req.authToken);
        logos_module_set_call_caller(caller.c_str());
        char* out = logos_module_dispatch(req.method.c_str(), args.dump().c_str());
        logos_module_set_call_caller(nullptr);

        if (!out) {
            // NULL is the ABI's "unknown method or structural failure". Same
            // code the JS provider answers with for an absent handler.
            res.ok = false;
            res.err = "unknown method " + kModuleName + "." + req.method;
            res.errCode = "METHOD_FAILED";
            reply(std::move(res));
            return;
        }

        const std::string text(out);
        logos_module_string_free(out);

        json value = json::parse(text, nullptr, /*allow_exceptions=*/false);
        if (value.is_discarded()) {
            res.ok = false;
            res.err = kModuleName + "." + req.method + ": module returned malformed JSON";
            res.errCode = "METHOD_FAILED";
            reply(std::move(res));
            return;
        }

        // THE CANONICAL ERROR OBJECT. logos_module_impl.h lets an implementation
        // report a structured failure as the RESULT of a call —
        // {"code","message","origin"} — rather than by returning NULL. Turning
        // it back into a failed Result here is what makes a wasm module's error
        // reach a consumer as an error instead of as a successful call whose
        // value happens to be a map with a "code" key.
        if (value.is_object() && value.contains("code") && value.contains("message")
            && value["code"].is_string() && value["message"].is_string()) {
            res.ok = false;
            res.errCode = value["code"].get<std::string>();
            res.err = value["message"].get<std::string>();
            reply(std::move(res));
            return;
        }

        res.ok = true;
        res.value = jsonToRpcValue(value);
        reply(std::move(res));
    }

    // INTROSPECTION IS NOT TOKEN-GATED. LogosObject::getMethods() takes no auth
    // token on any transport, so a conforming consumer has nothing to present —
    // and the Web container's own load verdict is a Methods round trip, so a
    // gate here would make this image report itself unloaded the moment its
    // credential arrived. Same decision, same reason, as the JS provider's.
    void onMethods(const MethodsMessage& req, MethodsReply reply) override
    {
        MethodsResultMessage res;
        res.id = req.id;
        if (req.object != kModuleName) {
            res.ok = false;
            res.err = "object not published: " + req.object;
            reply(std::move(res));
            return;
        }

        char* out = logos_module_get_methods();
        if (!out) {
            res.ok = false;
            res.err = kModuleName + ": the module reported no interface";
            reply(std::move(res));
            return;
        }
        const std::string text(out);
        logos_module_string_free(out);

        const json parsed = json::parse(text, nullptr, /*allow_exceptions=*/false);
        if (parsed.is_discarded() || !parsed.is_array()) {
            res.ok = false;
            res.err = kModuleName + ": the module's interface is not a JSON array";
            reply(std::move(res));
            return;
        }

        for (const json& entry : parsed) {
            if (!entry.is_object()) continue;
            MethodMetadata md;
            md.name        = entry.value("name", std::string{});
            md.signature   = entry.value("signature", std::string{});
            md.returnType  = entry.value("returnType", std::string{});
            md.isInvokable = entry.value("isInvokable", true);
            if (entry.contains("parameters") && entry["parameters"].is_array()) {
                for (const json& p : entry["parameters"])
                    md.parameters.items.push_back(jsonToRpcValue(p));
            }
            // An EVENT entry keeps its "type":"event" marker by riding in the
            // same list; MethodMetadata has no field for it, so it is carried in
            // the signature the module already published. Consumers that care
            // read the LIDL contract, not this.
            res.methods.push_back(std::move(md));
        }
        res.ok = true;
        reply(std::move(res));
    }

    // ONE SINK PER (object, event, connection) — the contract in
    // incoming_call_handler.h. There is exactly one connection in this image, so
    // the map is keyed by event name alone and `connectionId` only decides
    // whether a teardown clears it.
    void onSubscribe(const SubscribeMessage& req, EventSink sink,
                     const void* connectionId) override
    {
        if (req.object != kModuleName) return;
        m_connectionId = connectionId;
        m_sinks[req.eventName] = std::move(sink);
    }

    void onUnsubscribe(const UnsubscribeMessage& req, const void* connectionId) override
    {
        if (req.object != kModuleName || connectionId != m_connectionId) return;
        m_sinks.erase(req.eventName);
    }

    void onConnectionClosed(const void* connectionId) override
    {
        if (connectionId != m_connectionId) return;
        m_sinks.clear();
        m_connectionId = nullptr;
    }

    // THE DOOR SHUTS ON THE FIRST TOKEN. Until the core has told this image what
    // credential its callers will present, the image answers anyone — it has no
    // way to tell a legitimate first call from any other, and refusing would
    // make the load handshake unsatisfiable. From the first saved token on, a
    // Call must carry one of them. Copied from WebProvider.saveToken, including
    // that the tokens are not scoped per caller: on this wire identity is the
    // channel, and there is one channel.
    void onToken(const TokenMessage& req) override
    {
        if (req.token.empty()) return;
        m_tokens.insert(req.token);
        m_tokenOwner[req.token] = req.moduleName;
        // ...and into the image's own store, through the same door a Bare module
        // uses on a desktop host. That is what makes the module's own
        // logos::currentCaller() and any future outbound call see the grant.
        logos_module_accept_inbound_token(req.moduleName.c_str(), req.token.c_str());
    }

    // What the module emits, on its way to whoever subscribed. Installed as the
    // module-impl ABI's emit callback; runs on the Worker's event loop like
    // everything else here.
    void emitEvent(const std::string& eventName, const std::string& dataJson)
    {
        const json parsed = json::parse(dataJson, nullptr, /*allow_exceptions=*/false);

        EventMessage evt;
        evt.object = kModuleName;
        evt.eventName = eventName;
        if (parsed.is_array())
            for (const json& d : parsed) evt.data.push_back(jsonToRpcValue(d));

        // ONE COPY PER SUBSCRIBER, and a peer subscribed both by name and by
        // wildcard gets one — the same rule the JS provider's emit() states.
        const auto named = m_sinks.find(eventName);
        if (named != m_sinks.end()) { named->second(evt); return; }
        const auto wildcard = m_sinks.find(std::string{});
        if (wildcard != m_sinks.end()) wildcard->second(evt);
    }

private:
    bool authorized(const std::string& authToken) const
    {
        if (m_tokens.empty()) return true;
        return m_tokens.count(authToken) != 0;
    }

    // The document logos_module_set_call_caller takes. See its declaration in
    // logos_module_impl.h for the normative definition of each arm.
    std::string callerJson(const std::string& authToken) const
    {
        const auto it = m_tokenOwner.find(authToken);
        if (it == m_tokenOwner.end() || it->second.empty())
            return R"({"kind":"unknown"})";
        json o;
        o["kind"] = "module";
        o["name"] = it->second;
        return o.dump();
    }

    std::set<std::string> m_tokens;
    std::map<std::string, std::string> m_tokenOwner;
    std::map<std::string, EventSink> m_sinks;
    const void* m_connectionId = nullptr;
};

// The image's one channel and one connection. File statics rather than members
// of a host object: there is exactly one of each per wasm instance and the C
// entry points below have to reach them. The provider is main()'s own static --
// nothing outside main() names it, and the emit trampoline is handed it as
// userData.
double g_readyMs = 0.0;

std::shared_ptr<WorkerPortChannel> g_channel;
std::shared_ptr<logos::web::WebRpcConnection> g_connection;

void emitTrampoline(const char* eventName, const char* dataJson, void* userData)
{
    auto* provider = static_cast<WasmModuleProvider*>(userData);
    if (!provider || !eventName) return;
    provider->emitEvent(eventName, dataJson ? dataJson : "[]");
}

} // namespace

extern "C" {

// THE INBOUND HALF OF THE PORT. The Worker's `onmessage` calls this with the
// text it received. Exported by name (EMSCRIPTEN_KEEPALIVE plus the build's
// -sEXPORTED_FUNCTIONS) because the JS side reaches it through ccall.
EMSCRIPTEN_KEEPALIVE
void logos_wasm_deliver(const char* text)
{
    if (g_channel && text) g_channel->deliver(text);
}

// COLD INSTANTIATE TIME, in milliseconds, measured inside the image: from the
// first instruction of main() to the moment the module is serving. The page logs
// it beside the .wasm's byte size (acceptance criterion 5 of slice 26). Reported
// from in here rather than timed from JS because only this side knows when the
// module became answerable, as opposed to when the runtime finished loading.
EMSCRIPTEN_KEEPALIVE
double logos_wasm_ready_ms(void) { return g_readyMs; }

// THE DURABILITY BARRIER, as the module's core sees it.
//
// `logos_rust_sdk::storage::commit` (and its C++ equivalents) call this by
// name: on emscripten a write is not durable until the image's filesystem has
// been written back to the browser's IndexedDB, and nothing else in the stack
// knows to ask. Exported by name so a module core compiled in a separate
// translation unit -- or a separate LANGUAGE -- links against it.
//
//    0  handed over; the write-back is in flight
//   -1  there is no durable store in this environment (see the pre-js)
//   >0  the PREVIOUS write-back failed
//
// It cannot wait for the write-back: FS.syncfs finishes on the browser's event
// loop and this image is built without Asyncify. That is why a failure is
// reported by the NEXT call rather than by the one that caused it -- late, but
// never dropped.
EMSCRIPTEN_KEEPALIVE
int logos_storage_commit(void) { return logos_storage_commit_js(); }

} // extern "C"

int main()
{
    const auto started = std::chrono::steady_clock::now();

    static WasmModuleProvider provider;

    // The module's context, before the first dispatch, as the ABI requires.
    //
    // THE PERSISTENCE PATH IS REAL NOW. It used to be empty, with the comment
    // that MEMFS is the image's own memory and an honest empty path beats one
    // that silently loses data. Both halves of that are still true and neither
    // is the situation: the pre-js has mounted a durable filesystem at this
    // path and populated it from IndexedDB before this line ran, so a module's
    // on_context_ready reads its own previous state exactly as it does on a
    // desktop host. What the module still owes is the barrier
    // (`logos_storage_commit`), and where there is nothing durable to mount the
    // barrier is what says so -- the path stays usable for the life of the
    // page, which is strictly more than an empty one gave.
    const std::string storageDir = takeJsString(logos_storage_dir_js());
    const std::string storageBackend = takeJsString(logos_storage_backend_js());
    logos_module_set_context(("/logos/" + kModuleName).c_str(), kModuleName.c_str(),
                             storageDir.c_str());
    logos_module_set_emit_callback(&emitTrampoline, &provider);

    g_channel = std::make_shared<WorkerPortChannel>();
    g_connection = std::make_shared<logos::web::WebRpcConnection>(g_channel, &provider);
    g_connection->start();

    g_readyMs = std::chrono::duration<double, std::milli>(
                    std::chrono::steady_clock::now() - started).count();

    // The image is serving. Tell the page so, on the same port, with a message
    // that is NOT a transport frame: the loader page consumes it and does not
    // forward it. A "hello" rather than a silence, because the page has no other
    // way to distinguish "the wasm is still instantiating" from "the wasm is up
    // and the core has not spoken yet", and the container's load verdict depends
    // on the difference.
    json hello;
    hello["logosWasmHost"] = kModuleName;
    hello["readyMs"] = g_readyMs;
    hello["protocol"] = logos_module_get_protocol_version();
    // WHICH STORE THIS IMAGE GOT. A `web` variant that quietly fell back to
    // MEMFS behaves identically until the page is reloaded, so the regime is
    // announced rather than left to be discovered: the loader page logs it, and
    // a test can assert it.
    hello["storage"] = storageBackend;
    hello["storagePath"] = storageDir;
    logos_wasm_post(hello.dump().c_str());

    printf("logos-wasm-host: %s serving, ready in %.1f ms (storage: %s at %s)\n",
           kModuleName.c_str(), g_readyMs, storageBackend.c_str(), storageDir.c_str());
    fflush(stdout);

    // main() RETURNS and the runtime STAYS UP. Without this emscripten runs
    // atexit and tears down the module the moment main returns, taking the
    // connection with it — and the first message from the page would then reach
    // a freed provider. This is the supported way to say "this image is
    // event-driven".
    emscripten_exit_with_live_runtime();
    return 0;
}
