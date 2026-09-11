#pragma once
#include <QString>
#include "view_counter_interface.h"
#include "LogosViewPluginBase.h"
#include "rep_view_counter_source.h"

class LogosAPI;

// The whole module: the .rep's typed source IS the backend, so the plugin
// object and the view object are the same QObject. Small on purpose — what
// this fixture exercises is the ARTIFACT (one framework, Qt bound upward,
// QML in its own qrc), not a module design.
class ViewCounterPlugin : public ViewCounterSimpleSource,
                          public ViewCounterInterface,
                          public ViewCounterViewPluginBase
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID ViewCounterInterface_iid FILE "metadata.json")
    Q_INTERFACES(ViewCounterInterface)

public:
    explicit ViewCounterPlugin(QObject* parent = nullptr);

    QString name()    const override { return "view_counter"; }
    QString version() const override { return "1.0.0"; }

    Q_INVOKABLE void initLogos(LogosAPI* api);

    void increment() override;
    int add(int a, int b) override;

private:
    LogosAPI* m_logosAPI = nullptr;
};
