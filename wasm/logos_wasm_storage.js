// THE DURABLE STORE BEHIND A `web` VARIANT — linked into the glue with --pre-js.
//
// WHY THIS FILE EXISTS. An emscripten image has a filesystem, and that is the
// trap: every `std::fs` write a module core makes inside a webview SUCCEEDS,
// reads back correctly for the life of the page, and is gone on the next load,
// because MEMFS is the image's own linear memory. A module cannot detect that
// and no error is raised anywhere. So the host mounts something durable and
// tells the module where it is (logos_module_set_context's persistence path),
// and the module asks for the barrier with logos_rust_sdk::storage::commit —
// `logos_storage_commit` on this side.
//
// WHY --pre-js AND NOT C++. The mount has to be populated BEFORE main() runs:
// a module reads its state in on_context_ready, which is the first thing the
// image does. IDBFS's populate is asynchronous and the image is built without
// Asyncify (single-threaded, nothing here may block on a promise — ADR 0004),
// so the only place to wait is emscripten's own `preRun` + run-dependency
// mechanism, which is JS by construction. Baked into the glue rather than set
// by the worker, so the node harness, the shipped Worker and a page loading the
// glue directly all get the same behaviour without repeating it.
//
// THE BACKENDS, in the order they are chosen:
//
//   nodefs  a real host directory, when the embedder named one in
//           `Module.logosStorageHostDir`. That is a test harness driving the
//           image without a browser: NODEFS writes straight through, so it is
//           durable with no barrier at all and `commit` is a no-op success.
//   idbfs   the shipping path: the browser's IndexedDB, populated at startup
//           and written back by `commit`. A Worker (and a WKWebView) has
//           IndexedDB; this is what makes a key survive a page reload.
//   memfs   neither is available. The module still runs and still has a
//           filesystem — it just has no durable one, and `commit` says so
//           (-1) rather than reporting a success nothing backs.

var LOGOS_STORAGE_DIR = '/logos-data';

// The directory the module is told to persist into. Fixed rather than derived
// from the module name: one image serves one module, and the mount is the whole
// of that module's private store.
Module['logosStorageDir'] = LOGOS_STORAGE_DIR;

Module['preRun'] = (Module['preRun'] || []).concat(function () {
  var dir = Module['logosStorageDir'] || LOGOS_STORAGE_DIR;
  var hostDir = Module['logosStorageHostDir'];

  try {
    FS.mkdirTree(dir);
  } catch (e) {
    Module['logosStorageBackend'] = 'memfs';
    err('logos-wasm-storage: cannot create ' + dir + ': ' + e);
    return;
  }

  if (hostDir) {
    try {
      FS.mount(NODEFS, { root: hostDir }, dir);
      Module['logosStorageBackend'] = 'nodefs';
      return;
    } catch (e) {
      Module['logosStorageBackend'] = 'memfs';
      err('logos-wasm-storage: cannot mount ' + hostDir + ': ' + e);
      return;
    }
  }

  if (typeof indexedDB === 'undefined' || !indexedDB) {
    // Not a failure: a plain node run and some embedded webviews have no
    // IndexedDB, and a module that runs without persistence is better than one
    // that refuses to start. `commit` is what reports the regime.
    Module['logosStorageBackend'] = 'memfs';
    return;
  }

  try {
    FS.mount(IDBFS, {}, dir);
  } catch (e) {
    Module['logosStorageBackend'] = 'memfs';
    err('logos-wasm-storage: cannot mount IDBFS: ' + e);
    return;
  }
  Module['logosStorageBackend'] = 'idbfs';

  // THE POPULATE, AND THE REASON main() WAITS FOR IT. A run dependency is the
  // documented way to hold `run()` — and therefore main(), and therefore the
  // image's hello — until an asynchronous startup step finishes. Without it a
  // module would answer its first call against an empty store and then have the
  // real one appear underneath it.
  addRunDependency('logos-storage-populate');
  FS.syncfs(true, function (e) {
    if (e) {
      // The mount is there and empty. Report it and carry on: a module with no
      // previous state is a normal first run, and refusing to start would turn
      // a recoverable browser condition into a module that never loads.
      Module['logosStorageSyncError'] = String(e);
      err('logos-wasm-storage: could not populate from IndexedDB: ' + e);
    }
    removeRunDependency('logos-storage-populate');
  });
});

// THE BARRIER. Called from the image through `logos_storage_commit`.
//
//   0   handed to the durable medium
//  -1   there is no durable medium here (memfs)
//  >0   the PREVIOUS write-back failed; the reason is on the console
//
// It does not wait. FS.syncfs completes on the browser's event loop and this
// image cannot block on it without Asyncify, so a failure is raised by the NEXT
// commit rather than by the one that caused it — reported late, never dropped.
// That is the contract logos_rust_sdk::storage documents.
Module['logosStorageCommit'] = function () {
  var backend = Module['logosStorageBackend'];
  if (backend === 'nodefs') return 0;   // straight through to the host filesystem
  if (backend !== 'idbfs') return -1;   // nothing durable is mounted

  var previous = Module['logosStorageSyncError'];
  Module['logosStorageSyncError'] = null;
  FS.syncfs(false, function (e) {
    if (e) {
      Module['logosStorageSyncError'] = String(e);
      err('logos-wasm-storage: could not write back to IndexedDB: ' + e);
    }
  });
  return previous ? 1 : 0;
};
