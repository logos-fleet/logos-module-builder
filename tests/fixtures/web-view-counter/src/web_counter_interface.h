#pragma once
#include <QObject>
#include <QString>
#include "interface.h"

class WebCounterInterface : public PluginInterface {
public:
    virtual ~WebCounterInterface() = default;
};

#define WebCounterInterface_iid "logos.test.web_counter/1.0"
Q_DECLARE_INTERFACE(WebCounterInterface, WebCounterInterface_iid)
