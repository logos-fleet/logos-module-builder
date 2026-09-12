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
            reply(std::move(res));
            return;
        }
        if (!g_backend) {
            res.ok = false;
            res.err = kModuleName + ": the view backend has not been built yet";
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
        reply(std::move(res));
    }

    void onSubscribe(const SubscribeMessage&, EventSink, const void*) override { }
    void onUnsubscribe(const UnsubscribeMessage&, const void*) override { }
    void onConnectionClosed(const void*) override { }

    void onToken(const TokenMessage& req) override
    {
        if (req.token.empty())
            return;
        m_tokens[req.moduleName] = req.token;
    }

    // The credential to present when calling `moduleName`. Empty when the core
    // has granted none, which a target module is free to refuse.
    std::string tokenFor(const std::string& moduleName) const
    {
        const auto it = m_tokens.find(moduleName);
        return it == m_tokens.end() ? std::string{} : it->second;
    }

private:
    std::map<std::string, std::string> m_tokens;
};

// The image's one of each. File statics because the embind entry points below
// are free functions and there is exactly one of each per wasm instance.
double g_readyMs = 0.0;
QRemoteObjectHost* g_host = nullptr;
LogosWebCallRouter* g_router = nullptr;
std::shared_ptr<PageChannel> g_channel;
std::shared_ptr<logos::web::WebRpcConnection> g_connection;
ViewHostHandler* g_handler = nullptr;

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
void dispatchModuleCall(const QString& requestId, const QString& module,
                        const QString& method, const QString& argsJson)
{
    if (!g_connection || !g_channel || !g_channel->isOpen()) {
        g_router->complete(requestId,
                           errorPayload(QStringLiteral("no host channel"), module, method,
                                        QStringLiteral("the page has bound no container bridge")));
        return;
    }

    CallMessage call;
    call.id = g_connection->nextId();
    call.object = module.toStdString();
    call.method = method.toStdString();
    call.authToken = g_handler->tokenFor(call.object);

    const json args = json::parse(argsJson.toStdString(), nullptr, /*allow_exceptions=*/false);
    if (args.is_array())
        for (const json& a : args)
            call.args.push_back(jsonToRpcValue(a));

    g_connection->sendCallAsync(std::move(call), [requestId, module, method](ResultMessage res) {
        if (!res.ok) {
            g_router->complete(requestId,
                               errorPayload(QString::fromStdString(
                                                res.errCode.empty() ? "call failed" : res.errCode),
                                            module, method,
                                            QString::fromStdString(res.err)));
            return;
        }
        // A SUCCESS IS THE BARE VALUE, exactly as the desktop bridge serialises
        // it — `JSON.parse(payload)` in a view is the return value, and only a
        // failure is an object with `error` in it.
        g_router->complete(requestId,
                           QString::fromStdString(rpcValueToJson(res.value).dump()));
    });
}

} // namespace

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
