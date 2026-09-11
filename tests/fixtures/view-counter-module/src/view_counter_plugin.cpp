#include "view_counter_plugin.h"

ViewCounterPlugin::ViewCounterPlugin(QObject* parent)
    : ViewCounterSimpleSource(parent)
{
    setCount(0);
    setStatus(QStringLiteral("Ready"));
}

void ViewCounterPlugin::initLogos(LogosAPI* api)
{
    m_logosAPI = api;
    setBackend(this);
    setStatus(QStringLiteral("Connected"));
}

void ViewCounterPlugin::increment()
{
    setCount(count() + 1);
    setStatus(QStringLiteral("count = %1").arg(count()));
}

int ViewCounterPlugin::add(int a, int b)
{
    const int result = a + b;
    setStatus(QStringLiteral("%1 + %2 = %3").arg(a).arg(b).arg(result));
    return result;
}
