// THE WORKER SIDE OF THE WASM HOST.
//
// Everything this file does is move opaque JSON texts between the wasm image and
// whoever spawned the Worker. It never decodes a transport message, holds no
// token and knows no module name — the same deliberate ignorance
// logoscore-webhost has about the page it runs.
//
//   page ── worker.postMessage ──> onmessage ──> _logos_wasm_deliver (wasm)
//   wasm ── postMessage ─────────────────────> page's worker.onmessage
//
// `<MODULE>_wasm.js` is emscripten's own glue, emitted beside this file and
// loaded with importScripts. It is built with -sMODULARIZE, so it defines a
// factory rather than starting anything: nothing runs until the call below, and
// the messages that arrive before the runtime is up are QUEUED rather than
// dropped. That queue is load-bearing. The core starts talking the moment the
// container publishes the module — the first frame is usually the wildcard
// Subscribe that ModuleProxy installs from its constructor — and a wasm image
// takes milliseconds to instantiate.

const pending = [];
let deliver = null;

// SET ONCE, BY A TRAP, AND NEVER CLEARED. A wasm trap — a Rust panic, an
// abort(), an out-of-bounds — leaves the instance in the engine's "unusable"
// state: every later call into it throws too, on top of a linear memory that was
// abandoned mid-mutation. So the image stops being spoken to here, rather than
// answering garbage for the rest of the page's life.
let trapped = false;

// THE FAILURE BOUNDARY, and the reason the image runs in a Worker at all
// (slice 26's fourth criterion). A trap raised inside `deliver` unwinds into
// THIS frame, because a wasm trap reaches JS as a thrown RuntimeError — so the
// choice of what happens next is made here rather than by the browser.
//
// It is caught rather than left to propagate for two reasons. An uncaught error
// in a Worker reaches the page as an `error` event with, under -sASSERTIONS=0,
// no usable message; and it leaves the Worker alive and apparently willing to
// take the next frame. Catching it lets the page be told WHAT died, once, and
// lets this side refuse everything after.
function deliverGuarded(text) {
  if (trapped) return;
  try {
    deliver(text);
  } catch (err) {
    trapped = true;
    // The image is gone. Say so with the reason, on the same port the frames
    // use; the loader page treats this exactly as it treats the Worker's own
    // `error` event, which is still installed as the backstop for a trap that
    // happens outside a delivered frame.
    self.postMessage(JSON.stringify({
      logosWasmTrap: String((err && err.message) || err),
    }));
  }
}

self.onmessage = (event) => {
  const text = typeof event.data === 'string' ? event.data : JSON.stringify(event.data);
  if (deliver) deliverGuarded(text);
  else if (!trapped) pending.push(text);
};

importScripts('LOGOS_WASM_GLUE_JS');

// LOGOS_WASM_FACTORY is the -sEXPORT_NAME the build gave the factory. It returns
// a promise of the instantiated module; `main()` has run by the time it settles,
// so the image is already serving and has already posted its hello.
LOGOS_WASM_FACTORY({
  // Emscripten's default printErr writes to console.error, which a headless
  // webview swallows. Route both streams at the page so a module's own printf
  // reaches whoever is looking at the host's log.
  print: (line) => self.postMessage(JSON.stringify({ logosWasmLog: String(line) })),
  printErr: (line) => self.postMessage(JSON.stringify({ logosWasmLog: String(line), stderr: true })),
}).then((mod) => {
  deliver = mod.cwrap('logos_wasm_deliver', null, ['string']);
  while (pending.length && !trapped) deliverGuarded(pending.shift());
}).catch((err) => {
  // A wasm image that cannot instantiate is a module that failed to load, and
  // the container settles that by asking the page for its module and getting
  // nothing. Say why anyway: the alternative is a silent 30-second timeout.
  self.postMessage(JSON.stringify({
    logosWasmError: String((err && err.message) || err),
  }));
});
