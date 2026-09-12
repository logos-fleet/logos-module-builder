#include "web_counter_plugin.h"
#include "WebCounterBackend.h"

WebCounterPlugin::WebCounterPlugin(QObject* parent) : QObject(parent) { }

WebCounterPlugin::~WebCounterPlugin() = default;

void WebCounterPlugin::initLogos(LogosAPI* api)
{
    Q_UNUSED(api)
    if (m_backend) return;
    m_backend = new WebCounterBackend(this);
    setBackend(m_backend);
}
