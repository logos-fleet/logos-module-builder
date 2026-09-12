// THE LOADER OF A `ui_qml` MODULE'S `web` VARIANT — the page half of ADR 0004.
//
// It brings up two wasm images and joins them, and that is the whole of it:
//
//     the app's BUNDLED QML runtime          the module's OWN backend image
//     (~26 MB, downloaded once, shared)      (~4 MB, one per module)
//        Qt Quick + Logos design system         QRemoteObjectHost + the .rep
//        + LogosWebRuntime                      + LogosWebCallRouter
//                    └────── MessageChannel (QtRO) ──────┘
//                                    │
//                    window.logosChannelReady (the container)
//
//   1. load the runtime from where the app serves it, and this module's backend
//      from beside this document;
//   2. give each image one end of a fresh MessageChannel — the runtime calls its
//      own end `backend`, the backend image calls its own end `runtime`;
//   3. bind the container's channel to the backend image, so
//      `logos.callModuleAsync` from the view can reach a native module;
//   4. fetch this module's QML document and install it into the runtime.
//
// A SECOND MODULE COSTS STEPS 2–4 AND NOT STEP 1, which is slice 27's fourth
// criterion: the runtime is one download for the whole app.
//
// THIS PAGE MUST BE SERVED, not opened as a file. It fetches its own QML
// document and loads the runtime out of another directory, and `file://` gives
// neither. That is a real difference from the Bare `web` variant, whose loader
// survives file:// precisely because its image is base64-embedded in its glue —
// here the container has to put the package behind a scheme (a
// WKURLSchemeHandler on iOS, WebViewAssetLoader on Android, the desktop
// container's own handler), which it does for every variant anyway.
//
// A MODULE-ID EXPORT, not an inline script, so that the page a container ships
// is fifteen lines naming this file and the assertions a test makes are made
// against the SAME code the container runs.

// Where the app serves its bundled QML runtime. The container sets it; the
// default is a sibling directory so that a developer can serve a variant next
// to an unpacked runtime with no host at all.
const DEFAULT_RUNTIME_BASE = 'logos-runtime/';

// The runtime's own two files, named here because they are the runtime's
// contract with every variant, not this module's business.
const RUNTIME_GLUE = 'logos_qml_runtime.js';
const RUNTIME_ENTRY = 'logos_qml_runtime_entry';
const QT_LOADER = 'qtloader.js';

// The runtime's own name for its half of the wire, and this image's for its
// half. A port name is PROCESS-LOCAL — it is what a process calls a port it was
// handed, never a rendezvous — so the two ends name their own halves and are
// free to use different words for one channel.
const RUNTIME_PORT = 'backend';
const BACKEND_PORT = 'runtime';

function loadScript(url) {
  return new Promise((resolve, reject) => {
    const el = document.createElement('script');
    el.src = url;
    el.onload = () => resolve();
    el.onerror = () => reject(new Error('could not load ' + url));
    document.head.appendChild(el);
  });
}

// Bring up one `ui_qml` module's web variant in this page.
//
// `config` is what the build stamped into the page plus whatever the container
// overrode:
//
//   module        the module's name, as the core knows it
//   viewEntry     this module's QML document, relative to this directory
//   backendGlue   the backend image's emscripten glue, ditto
//   backendEntry  that glue's -sEXPORT_NAME
//   container     the element the runtime draws into
//   runtimeBase   where the app serves the bundled runtime
//   channelReady  a Promise of the container's five-method channel, or null
//
// Resolves with the two instances and the view, or rejects naming the step that
// failed — a page that cannot say WHICH of four things went wrong is a blank
// rectangle, which is exactly what a module that has not loaded yet looks like.
export async function startLogosWebView(config) {
  const runtimeBase = config.runtimeBase || DEFAULT_RUNTIME_BASE;

  // The runtime's glue and Qt's loader are shared by both images: qtloader.js
  // defines the global `qtLoad`, and loading it twice would be the same file
  // twice. The backend's glue is this module's own.
  await loadScript(runtimeBase + RUNTIME_GLUE);
  await loadScript(runtimeBase + QT_LOADER);
  await loadScript(config.backendGlue);

  if (typeof qtLoad !== 'function')
    throw new Error('qtloader.js did not define qtLoad; runtimeBase=' + runtimeBase);

  // locateFile, EXPLICITLY, and it is not belt-and-braces. Emscripten resolves
  // its `.wasm` against the directory of the script that defined the factory,
  // and a container is free to serve the shared runtime from anywhere — an
  // absolute path, another origin's scheme handler — while this page lives in
  // the module's own package. Left to the default, the runtime's 26 MB image is
  // fetched from beside THIS document, 404s, and emscripten aborts with
  // "both async and sync fetching of the wasm failed".
  const runtime = await qtLoad({
    qt: { entryFunction: window[RUNTIME_ENTRY], containerElements: [config.container] },
    locateFile: (path) => runtimeBase + path,
  });

  // NO CONTAINER ELEMENT for the backend, deliberately: it is a QCoreApplication
  // with no scene in it. Everything on screen belongs to the runtime, which is
  // the split ADR 0004 exists to make.
  const backend = await qtLoad({ qt: { entryFunction: window[config.backendEntry] } });

  // ONE CHANNEL, TWO IMAGES. Created here because a page is the only thing that
  // can: neither image can look the other up, and there is no directory in a
  // browser to look one up in (ADR 0005).
  const channel = new MessageChannel();
  runtime.logosAdoptMessagePort(RUNTIME_PORT, channel.port1);
  backend.logosAdoptMessagePort(BACKEND_PORT, channel.port2);

  // THE OTHER WIRE: the container's. It carries logos-protocol frames, which
  // are what `logos.callModuleAsync` from this module's QML turns into once the
  // runtime has remoted it to the backend image's call router.
  //
  // Bound before the view is installed, so a view that calls out from
  // Component.onCompleted is not racing the bridge. A page with no container —
  // a developer serving the variant by hand — still renders; only the calls to
  // other modules fail, and they say so.
  if (config.channelReady) {
    const hostChannel = await config.channelReady;
    hostChannel.setReceiver((text) => backend.logosViewHostDeliver(text));
    backend.logosViewHostSetSink((text) => hostChannel.send(text));
  }

  // THE MODULE'S QML, AS TEXT. Qt's network layer refuses the custom schemes
  // that replace `file://` in a webview, so the page fetches the document and
  // the runtime compiles the string (ADR 0004). It is also why a variant's QML
  // is an ordinary file in the package rather than a resource in an image.
  const response = await fetch(config.viewEntry);
  if (!response.ok)
    throw new Error('could not fetch ' + config.viewEntry + ': HTTP ' + response.status);
  const qml = await response.text();

  if (!runtime.logosInstallModuleView(config.module, qml))
    throw new Error(config.module + ': ' + runtime.logosRuntimeLastError());

  return { module: config.module, runtime, backend };
}
