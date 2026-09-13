// THE VIEW BACKEND'S WASM HOST — a `ui_qml` module's C++ backend compiled to
// WebAssembly against Qt-for-WebAssembly, serving its `.rep` source over Qt
// Remote Objects on an HTML MessagePort to the bundled QML runtime in the same
// page (ADR 0004, slice 27).
//
// TWO WASM IMAGES, ONE PAGE, and neither is the other's host:
//
//     ┌─ the bundled QML runtime (~26 MB, shipped with the app) ─┐
//     │  Qt Quick + Logos design system + LogosWebRuntime        │
//     │  the module's Counter.qml, installed at install time     │
//     └──────────────── QtRO over a MessagePort ─────────────────┘
//                                  │
//     ┌──────────── THIS IMAGE (the module's own, ~4 MB) ────────┐
//     │  QRemoteObjectHost + the .rep source + LogosWebCallRouter│
//     └──── logos-protocol's web transport, via the page ────────┘
//                                  │
//                          the Web container, the core
//
// WHY IT IS NOT slice 26's Wasm host. That one IS the module: a Bare module has
// no Qt in it, exports the module-impl C ABI, and answers the web transport
// directly. A `ui_qml` module's backend is a QObject generated from a `.rep`,
// reached by a REPLICA rather than by a Call, and QtRO is the only thing that
// speaks replicas. So this is a different image with a different link, and the
// two cannot be merged: putting Qt in the Bare host would put Qt in every
// headless module, and taking Qt out of this one would leave nothing to remote.
//
// WHY IT RUNS ON THE PAGE THREAD, where the Bare host runs in a Worker. Qt for
// WebAssembly is loaded by `qtloader.js`, which is DOM-bound, and Qt's own event
// dispatcher expects the browser's main loop. The failure boundary the Worker
// buys a Bare module is therefore not available here; what replaces it is that
// this image holds no other module's credentials and can crash only its own
// page, which is one webview of one module either way.
//
// SINGLE-THREADED, like everything else in the container: no pthreads, no
// ASYNCIFY. `QCoreApplication::exec()` RETURNS in a wasm image — the event loop
// is the browser's and main() falling off its end is the normal end of startup —
// so everything the page will call into is on the HEAP. That is the same finding
// the QML runtime's main.cpp records, and it costs a whole page of debugging to
// re-learn.

#include LOGOS_WASM_VIEW_BACKEND_HEADER

#include "LogosMessagePortTransport.h"
#include "LogosWebCallRouter.h"
#include "logos_web_module_call.h"

#include <QByteArray>
#include <QCoreApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QList>
#include <QMetaMethod>
#include <QMetaObject>
#include <QMetaProperty>
#include <QObject>
#include <QRemoteObjectHost>
#include <QString>
#include <QTimer>

// logos-protocol's wasm subset: the web transport, and nothing else in it needs
// Qt (it has none). This image is the one place in the system where the two
// stacks meet, and they meet by value — a JSON text in, a JSON text out.
#include "incoming_call_handler.h"
#include "json_mapping.h"
#include "message_channel.h"
#include "rpc_message.h"
#include "web_rpc_connection.h"

#include <nlohmann/json.hpp>

#include <chrono>
#include <cstdio>
#include <map>
#include <memory>
#include <string>
#include <utility>

#ifdef __EMSCRIPTEN__
#include <emscripten/val.h>
#include <emscripten/bind.h>
#endif

#ifndef LOGOS_WASM_MODULE_NAME
#  error "LOGOS_WASM_MODULE_NAME must be defined by the build"
#endif

namespace {

using json = nlohmann::json;
using namespace logos::plain;

const std::string kModuleName = LOGOS_WASM_MODULE_NAME;

// The name THIS image publishes its half of the channel under. Process-local,
// never a rendezvous (LogosMessagePortTransport's header says why): the runtime
// image calls its own half `backend`, this one calls its own half `runtime`, and
// they are free to do so because they are never in the same process.
const char* kRuntimePort = "runtime";

// The one backend this image hosts. A file static because the page's embind
// entry points are free functions and the protocol handler below is not its
// owner — there is exactly one per wasm instance, set once in main().
QObject* g_backend = nullptr;

// ── the page channel: logos-protocol's web transport, relayed by the page ───
//
// The container hands the page a five-method channel (`window.logosChannelReady`
// — the same seam the Bare variant's loader uses) and the page hands the texts
// to this. There is no addressing and no framing: an IMessageChannel is already
// message-oriented, which is the whole reason the web transport was cut to this
// shape.
class PageChannel : public logos::web::IMessageChannel {
public:
    void setReceiver(Receiver receiver) override { m_receiver = std::move(receiver); }

    bool send(const std::string& message) override
    {
#ifdef __EMSCRIPTEN__
        if (!m_open || m_sink.isNull() || m_sink.isUndefined())
            return false;
        m_sink(emscripten::val(message));
        return true;
#else
        (void)message;
        return false;
#endif
    }

    void close() override { m_open = false; m_receiver = nullptr; }
    bool isOpen() const override { return m_open; }

    // Called from JS on the page's event loop, one message at a time.
    void deliver(const std::string& text)
    {
        if (m_receiver)
            m_receiver(text);
    }

#ifdef __EMSCRIPTEN__
    // A PAGE WITH NO SINK IS THE ORDINARY STARTING STATE, not an error: this
    // image is up before the container's bridge has resolved. Calls made in
    // that window fail fast rather than hanging, which is what the view's own
    // timeout would otherwise have to absorb.
    void setSink(emscripten::val sink) { m_sink = sink; }
#endif

private:
    Receiver m_receiver;
    bool m_open = true;
#ifdef __EMSCRIPTEN__
    emscripten::val m_sink = emscripten::val::undefined();
#endif
};

// ── what this image will answer from the core: tokens, and nothing else ─────
//
// A `ui_qml` module's backend is reached by a REPLICA, not by a Call, so there
// is no inbound method dispatch here and a Call addressed to this image is
// refused rather than half-answered. What does arrive is the module's own
// credential, which the core sends once per grant and which every outbound call
// below has to carry.
//
// Deliberately not the Bare host's WasmTokenStore: that store exists so a
// module's generated glue can find its own tokens through the lp_* C ABI, and
// nothing in this image is generated glue.
class ViewHostHandler : public IncomingCallHandler {
public:
    void onCall(const CallMessage& req, CallReply reply) override
    {
        ResultMessage res;
        res.id = req.id;
        res.ok = false;
        res.errCode = "METHOD_FAILED";
        res.err = kModuleName + " is a view backend: its methods are reached "
                                "through a Qt Remote Objects replica, not by a call "
                                "on this transport";
        reply(std::move(res));
    }

    // INTROSPECTION IS THE CONTAINER'S LOAD VERDICT. WebContainer::awaitLoad
    // asks the page for its interface and treats an answer as "the module is
    // serving" — so this has to be answered even though onCall is not, and it
    // is the one place where the .rep's shape crosses to the protocol side.
    // Read off the live QObject's metaobject rather than from a generated
    // table: the metaobject IS what QtRO remotes, so the two cannot drift.
    //
    // Never token-gated, for the same reason the Bare host's is not:
    // LogosObject::getMethods() carries no auth token on any transport.
    void onMethods(const MethodsMessage& req, MethodsReply reply) override
    {
        MethodsResultMessage res;
        res.id = req.id;
        if (req.object != kModuleName) {
            res.ok = false;
            res.err = "object not published: " + req.object;
            std::printf("[logos-web-view %s] contract query for '%s' refused: "
                        "this image serves '%s'\n",
                        kModuleName.c_str(), req.object.c_str(), kModuleName.c_str());
            reply(std::move(res));
            return;
        }
        if (!g_backend) {
            res.ok = false;
            res.err = kModuleName + ": the view backend has not been built yet";
            std::printf("[logos-web-view %s] contract query: no backend yet\n",
                        kModuleName.c_str());
            reply(std::move(res));
            return;
        }

        const QMetaObject* meta = g_backend->metaObject();
        // From QObject's own offset up, so the twenty inherited members of
        // QObject and QRemoteObjectSource are not published as the module's API.
        for (int i = QObject::staticMetaObject.methodCount(); i < meta->methodCount(); ++i) {
            const QMetaMethod m = meta->method(i);
            if (m.methodType() != QMetaMethod::Slot && m.methodType() != QMetaMethod::Method)
                continue;
            if (m.access() != QMetaMethod::Public)
                continue;
            MethodMetadata md;
            md.name = m.name().toStdString();
            md.signature = m.methodSignature().toStdString();
            md.returnType = m.typeName() ? m.typeName() : "void";
            md.isInvokable = true;
            const QList<QByteArray> names = m.parameterNames();
            for (int p = 0; p < m.parameterCount(); ++p) {
                RpcMap param;
                param.emplace("name", RpcValue(std::string(
                    p < names.size() ? names.at(p).constData() : "")));
                param.emplace("type", RpcValue(std::string(
                    m.parameterMetaType(p).name() ? m.parameterMetaType(p).name() : "")));
                md.parameters.items.emplace_back(std::move(param));
            }
            res.methods.push_back(std::move(md));
        }
        res.ok = true;
        // SAID OUT LOUD, ONCE. Answering this is the container's whole load
        // verdict, and an empty answer is reported by the core as "the page
        // never published a module" -- a sentence about the page that names
        // nothing in it. The count is the one fact that separates "the query
        // never arrived" from "it arrived and this image had nothing to say".
        if (!m_introspected)
            std::printf("[logos-web-view %s] contract query answered: %zu method(s)\n",
                        kModuleName.c_str(), res.methods.size());
        reply(std::move(res));

        // ANSWERING THIS *IS* THE LOAD. WebContainer::awaitLoad asks the page
        // for its interface and takes an answer as the verdict, so the reply
        // just sent is the last thing the core was waiting for: commitLoad and
        // the registration of this module's token with capability_module happen
        // on the other side of it. See hostAdmitted().
        m_introspected = true;
    }

    void onSubscribe(const SubscribeMessage&, EventSink, const void*) override { }
    void onUnsubscribe(const UnsubscribeMessage&, const void*) override { }
    void onConnectionClosed(const void*) override { }

    void onToken(const TokenMessage& req) override
    {
        if (req.token.empty())
            return;
        m_tokens[req.moduleName] = req.token;
        // THE CORE HAS SPOKEN TO THIS PAGE. Every grant says so, including the
        // module's own credential, which the container delivers as the last
        // step of the load. See hostAdmitted() in logos_web_module_call.h for
        // why a backend has to wait for this before it calls out.
        m_admitted = true;
    }

    // Both halves of the load, from inside the page: the core minted this
    // module a credential and sent it, AND the container's contract query has
    // been answered.
    bool admitted() const { return m_admitted && m_introspected; }

    // The credential to present when calling `moduleName`. Empty when the core
    // has granted none, which a target module is free to refuse.
    std::string tokenFor(const std::string& moduleName) const
    {
        const auto it = m_tokens.find(moduleName);
        return it == m_tokens.end() ? std::string{} : it->second;
    }

private:
    std::map<std::string, std::string> m_tokens;
    bool m_admitted = false;
    bool m_introspected = false;
};

// The image's one of each. File statics because the embind entry points below
// are free functions and there is exactly one of each per wasm instance.
double g_readyMs = 0.0;
QRemoteObjectHost* g_host = nullptr;
LogosWebCallRouter* g_router = nullptr;
std::shared_ptr<PageChannel> g_channel;
std::shared_ptr<logos::web::WebRpcConnection> g_connection;
ViewHostHandler* g_handler = nullptr;

// ── one bare JSON value, across the two JSON libraries in this image ─────────
//
// QJsonDocument can neither serialise nor parse a value that is not an object
// or an array, and every value crossing the door is a BARE one: a call's
// argument, a reply's result, a view's payload. So each conversion wraps in a
// one-element array and unwraps after — which is also what keeps a returned
// `4` a `4` rather than `[4]`.
//
// The nlohmann half goes through the canonical JSON text rather than a
// QJsonValue <-> RpcValue converter written here: json_mapping.h already owns
// that mapping for the whole protocol, and a second one would drift on exactly
// the cases (a tagged byte string, a nested map) nobody tests twice.

QString bareJsonText(const QJsonValue& value)
{
    QJsonArray wrap;
    wrap.append(value);
    const QByteArray dumped = QJsonDocument(wrap).toJson(QJsonDocument::Compact);
    return QString::fromUtf8(dumped.mid(1, dumped.size() - 2));
}

// Discarded when the text is not JSON this image can carry, which the caller
// has to decide about — there is no RpcValue that means "unrepresentable".
json toProtocolJson(const QJsonValue& value)
{
    return json::parse(bareJsonText(value).toStdString(), nullptr,
                       /*allow_exceptions=*/false);
}

QJsonValue fromProtocolJson(const json& value)
{
    const QByteArray text = QByteArray::fromStdString(json::array({ value }).dump());
    return QJsonDocument::fromJson(text).array().at(0);
}

// The error envelope `logos.callModuleAsync`'s callback reads. Same shape as
// LogosQmlBridge's on the desktop and LogosWebPayload.h's in the runtime, so a
// view moved between containers keeps working: a failure has `error`, a success
// is the value itself.
QString errorPayload(const QString& error, const QString& module,
                     const QString& method, const QString& detail = QString())
{
    QJsonObject obj;
    obj.insert(QStringLiteral("error"), error);
    obj.insert(QStringLiteral("module"), module);
    obj.insert(QStringLiteral("method"), method);
    if (!detail.isEmpty())
        obj.insert(QStringLiteral("message"), detail);
    return QString::fromUtf8(QJsonDocument(obj).toJson(QJsonDocument::Compact));
}

// THE OTHER HALF OF `logos.callModuleAsync`. The view calls a NATIVE module by
// name; the runtime image has no protocol client and must not grow one (it is
// the app's bundled runtime, shared by every module), so the call is remoted to
// here and this image — which does have a client — makes it.
//
// ONE DOOR, TWO CALLERS. The QML above and the module's own C++ backend (through
// logos_web_module_call.h) reach the container by the same call, with the same
// token and the same failure modes; only the shape of the answer differs. That
// is deliberate: a second outbound path would be a second place for the
// credential rule to be got wrong.
void dispatchModuleCall(const QString& requestId, const QString& module,
                        const QString& method, const QString& argsJson)
{
    // Empty when `argsJson` is not a JSON array, which is a call with no
    // arguments — the same thing the router sends for one.
    logos::web::callModuleAsync(
        module, method, QJsonDocument::fromJson(argsJson.toUtf8()).array(),
        [requestId, module, method](const logos::web::ModuleCallResult& res) {
            if (!res.ok) {
                g_router->complete(requestId,
                                   errorPayload(res.errorCode.isEmpty()
                                                    ? QStringLiteral("call failed")
                                                    : res.errorCode,
                                                module, method, res.error));
                return;
            }
            // A SUCCESS IS THE BARE VALUE, exactly as the desktop bridge
            // serialises it — `JSON.parse(payload)` in a view is the return
            // value, and only a failure is an object with `error` in it.
            g_router->complete(requestId, bareJsonText(res.value));
        });
}

} // namespace

// ── the second door: logos_web_module_call.h ────────────────────────────────
//
// Defined HERE rather than in a file of its own because the connection, the
// channel and the token store are this image's file statics: a separate
// translation unit would have to be handed all three, and there is exactly one
// of each per wasm instance. The header states the contract; this is its only
// implementation anywhere.

namespace logos {
namespace web {

bool canCallModules()
{
    return g_connection && g_channel && g_channel->isOpen();
}

bool hostAdmitted()
{
    return canCallModules() && g_handler && g_handler->admitted();
}

void callModuleAsync(const QString& module, const QString& method,
                     const QJsonArray& args, ModuleCallCallback callback)
{
    // POSTED, NOT DELIVERED INLINE. The header promises the callback never runs
    // before this function returns, and a caller setting itself up around the
    // call would otherwise have to survive re-entry on the one path — the
    // failure path — it is least likely to have thought about.
    const auto fail = [callback](const QString& code, const QString& message) {
        if (!callback) return;
        QTimer::singleShot(0, [callback, code, message]() {
            ModuleCallResult res;
            res.ok = false;
            res.errorCode = code;
            res.error = message;
            callback(res);
        });
    };

    if (!canCallModules()) {
        fail(QStringLiteral("no host channel"),
             QStringLiteral("the page has bound no container bridge"));
        return;
    }
    if (module.isEmpty() || method.isEmpty()) {
        fail(QStringLiteral("INVALID_ARG"),
             QStringLiteral("a module call needs both a module name and a method name"));
        return;
    }

    CallMessage call;
    call.id = g_connection->nextId();
    call.object = module.toStdString();
    call.method = method.toStdString();
    // The credential the CORE granted this module for that target, and nothing
    // else. Empty when none was granted, which the target is free to refuse —
    // this image mints nothing and asserts no identity of its own (ADR 0005).
    call.authToken = g_handler->tokenFor(call.object);

    for (const QJsonValue& a : args) {
        const json arg = toProtocolJson(a);
        call.args.push_back(arg.is_discarded() ? RpcValue() : jsonToRpcValue(arg));
    }

    g_connection->sendCallAsync(std::move(call), [callback](ResultMessage res) {
        if (!callback) return;
        ModuleCallResult out;
        out.ok = res.ok;
        if (!res.ok) {
            out.errorCode = QString::fromStdString(
                res.errCode.empty() ? "call failed" : res.errCode);
            out.error = QString::fromStdString(res.err);
            callback(out);
            return;
        }
        out.value = fromProtocolJson(rpcValueToJson(res.value));
        callback(out);
    });
}

} // namespace web
} // namespace logos

#ifdef __EMSCRIPTEN__

namespace {

// THE PAGE'S WHOLE API for this image, and no Qt type crosses. `logosAdopt-
// MessagePort` is the transport's own export and is not repeated here.
//
//   logosViewHostSetSink(fn)   where protocol frames bound for the container go
//   logosViewHostDeliver(text) one protocol frame arriving from the container
//   logosViewHostModule()      which module this image serves
//   logosViewHostServing()     whether the QtRO source is up
//   logosViewHostReadyMs()     cold instantiate time, measured inside the image

void logosViewHostSetSink(emscripten::val sink)
{
    if (g_channel)
        g_channel->setSink(sink);
}

void logosViewHostDeliver(std::string text)
{
    if (g_channel)
        g_channel->deliver(text);
}

std::string logosViewHostModule() { return kModuleName; }

// THE BACKEND'S STATE, AS JSON, and not a debugging afterthought: it is the
// only thing about this image a page can observe without the module's QML
// cooperating. A container's devtools read it to say what a view is bound to,
// and the browser end-to-end reads it to tell "the button did nothing" apart
// from "the button drove the backend and the view did not repaint" — two
// failures with nothing else to separate them from outside the canvas.
//
// Q_PROPERTYs only, from the .rep's own offset up, so QObject's `objectName`
// is not published as module state. Read-only: the far side of this wire is a
// page, and a page must not be able to set a backend's properties behind the
// replica's back.
std::string logosViewHostBackendJson()
{
    if (!g_backend)
        return "{}";
    const QMetaObject* meta = g_backend->metaObject();
    QJsonObject obj;
    for (int i = QObject::staticMetaObject.propertyCount(); i < meta->propertyCount(); ++i) {
        const QMetaProperty prop = meta->property(i);
        if (!prop.isReadable())
            continue;
        obj.insert(QString::fromUtf8(prop.name()),
                   QJsonValue::fromVariant(prop.read(g_backend)));
    }
    return QString::fromUtf8(QJsonDocument(obj).toJson(QJsonDocument::Compact)).toStdString();
}

bool logosViewHostServing() { return g_host != nullptr; }

double logosViewHostReadyMs() { return g_readyMs; }

} // namespace

EMSCRIPTEN_BINDINGS(logos_view_wasm_host)
{
    emscripten::function("logosViewHostSetSink", &logosViewHostSetSink);
    emscripten::function("logosViewHostDeliver", &logosViewHostDeliver);
    emscripten::function("logosViewHostModule", &logosViewHostModule);
    emscripten::function("logosViewHostBackendJson", &logosViewHostBackendJson);
    emscripten::function("logosViewHostServing", &logosViewHostServing);
    emscripten::function("logosViewHostReadyMs", &logosViewHostReadyMs);
}

#endif // __EMSCRIPTEN__

int main(int argc, char* argv[])
{
    const auto started = std::chrono::steady_clock::now();

    // ON THE HEAP, ALL OF IT. See the file header: exec() returns here and
    // anything on main()'s stack would be gone before the page's first call.
    auto* app = new QCoreApplication(argc, argv);

    LogosMessagePortTransport::registerTransport();

    g_backend = new LOGOS_WASM_VIEW_BACKEND_CLASS;

    g_handler = new ViewHostHandler;
    g_channel = std::make_shared<PageChannel>();
    g_connection = std::make_shared<logos::web::WebRpcConnection>(g_channel, g_handler);
    g_connection->start();

    g_router = new LogosWebCallRouter;
    g_router->setHandler(&dispatchModuleCall);

    // LISTENING BEFORE THE PAGE HAS HANDED A PORT OVER, and that is the ordinary
    // order rather than a race: MessagePortServer holds the name and takes the
    // port the moment `logosAdoptMessagePort` publishes it. Enabling remoting
    // now also means QtRO's object list is written the instant the wire appears,
    // which is what the runtime's replica is waiting for.
    g_host = new QRemoteObjectHost(
        LogosMessagePortTransport::url(QLatin1StringView(kRuntimePort)));

    // DYNAMIC REMOTING UNDER THE MODULE'S OWN NAME, not the .rep class's. The
    // runtime acquires by module name (`logos.module("counter")`) because a page
    // cannot dlopen the generated replica factory that would give it a typed
    // one; the properties, slots and signals it reads off the wire are the
    // .rep's either way.
    g_host->enableRemoting(g_backend, QString::fromStdString(kModuleName));
    g_host->enableRemoting(g_router, LogosWebCallRouter::sourceName());

    g_readyMs = std::chrono::duration<double, std::milli>(
                    std::chrono::steady_clock::now() - started).count();

    return app->exec();
}
