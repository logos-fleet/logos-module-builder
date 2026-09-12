#include "WebCounterBackend.h"

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
