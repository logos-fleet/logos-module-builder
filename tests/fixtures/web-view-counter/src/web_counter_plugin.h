#pragma once
#include <QObject>
#include <QString>
#include "web_counter_interface.h"
#include "LogosViewPluginBase.h"

class LogosAPI;
class WebCounterBackend;

// The DESKTOP shape: a plugin object that owns a backend. Nothing in here
// reaches the wasm image — see WebCounterBackend.h.
class WebCounterPlugin : public QObject,
                         public WebCounterInterface,
                         public WebCounterViewPluginBase
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID WebCounterInterface_iid FILE "metadata.json")
    Q_INTERFACES(WebCounterInterface)

public:
    explicit WebCounterPlugin(QObject* parent = nullptr);
    ~WebCounterPlugin() override;

    QString name()    const override { return "web_counter"; }
    QString version() const override { return "1.0.0"; }

    Q_INVOKABLE void initLogos(LogosAPI* api);

private:
    WebCounterBackend* m_backend = nullptr;
};
