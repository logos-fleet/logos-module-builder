#pragma once
#include <QObject>
#include <QString>
#include "interface.h"

class ViewCounterInterface : public PluginInterface {
public:
    virtual ~ViewCounterInterface() = default;
};

#define ViewCounterInterface_iid "logos.test.view_counter/1.0"
Q_DECLARE_INTERFACE(ViewCounterInterface, ViewCounterInterface_iid)
