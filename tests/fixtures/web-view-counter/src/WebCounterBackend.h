#pragma once

// THE BACKEND, AND ONLY THE BACKEND. Separate from the plugin object next to
// it, which is what gives this module a `web` variant: the plugin inherits
// LogosViewPluginBase and holds a LogosAPI, neither of which exists inside a
// Qt-for-WebAssembly image, while this class is the .rep source and nothing
// else. metadata.json's `web.view_backend` names it.

#include "rep_web_counter_source.h"

class WebCounterBackend : public WebCounterSimpleSource {
    Q_OBJECT

public:
    explicit WebCounterBackend(QObject* parent = nullptr);

public slots:
    void increment() override;
    int add(int a, int b) override;
};
