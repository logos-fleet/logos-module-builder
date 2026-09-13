#include "WebCounterBackend.h"

#include <QJsonDocument>
#include <QJsonObject>

// THE DOOR EXISTS ONLY WHERE THE CHANNEL DOES. logos_web_module_call.h is put
// on the include path by logos_wasm_view_module() and by nothing else, so a
// backend shared with a desktop plugin guards it — the plugin reaches its
// dependencies through modules() over LogosAPI, which is the door it has.
#ifdef __EMSCRIPTEN__
#  include "logos_web_module_call.h"
#endif

WebCounterBackend::WebCounterBackend(QObject* parent)
    : WebCounterSimpleSource(parent)
{
    setCount(0);
    setStatus(QStringLiteral("ready"));
}

void WebCounterBackend::increment()
{
    setCount(count() + 1);
    setStatus(QStringLiteral("count = %1").arg(count()));
}

int WebCounterBackend::add(int a, int b)
{
    return a + b;
}

void WebCounterBackend::callPeer(QString module, QString method)
{
#ifdef __EMSCRIPTEN__
    setStatus(QStringLiteral("calling %1.%2…").arg(module, method));
    logos::web::callModuleAsync(
        module, method, QJsonArray{},
        [this](const logos::web::ModuleCallResult& res) {
            QJsonObject out;
            out.insert(QStringLiteral("ok"), res.ok);
            if (res.ok) {
                out.insert(QStringLiteral("value"), res.value);
            } else {
                out.insert(QStringLiteral("code"), res.errorCode);
                out.insert(QStringLiteral("error"), res.error);
            }
            setLastCall(QString::fromUtf8(
                QJsonDocument(out).toJson(QJsonDocument::Compact)));
            setStatus(res.ok ? QStringLiteral("call ok")
                             : QStringLiteral("call failed"));
        });
#else
    // NOT A STUB THAT PRETENDS. A desktop plugin has LogosAPI and reaches its
    // dependencies through modules(); this slot is the wasm image's door and
    // says so rather than answering something a caller might believe.
    setLastCall(QStringLiteral(
        "{\"ok\":false,\"code\":\"no host channel\",\"error\":"
        "\"callPeer is the wasm image's door; this build is the desktop plugin\"}"));
    setStatus(QStringLiteral("callPeer: %1.%2 refused (native build)")
                  .arg(module, method));
#endif
}
