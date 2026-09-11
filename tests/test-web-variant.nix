# Integration test for the `web` output — the Wasm host and its loader page,
# laid out as an LGX `web` variant.
#
# The derivation under test already gated itself (buildWebModule's
# installCheckPhase: the image is wasm, the glue carries it, no template
# placeholder survived, the manifest names the entry). Realising it here is
# therefore most of the assertion. What this file adds is what that gate cannot
# see from inside its own build:
#
#   * THE IMAGE ANSWERS THE WEB TRANSPORT. A node harness installs the image's
#     message port (logos_wasm_post's Module.logosOut fallback — see
#     wasm/logos_wasm_host.cpp), hands it a real Call frame and reads a real
#     Result back. add(1, 2) is 3, through the JSON envelope, the codec, RpcPeer,
#     the provider and the module's own C++, with no browser anywhere. That is
#     slice 26's acceptance criterion minus the container, and it is the only
#     part of this that could be wrong in a way the build cannot see.
#   * PER IMAGE. Two instantiations of the same glue are two wasm instances with
#     two linear memories, which is exactly what "two Wasm hosts in two
#     webviews" is to the property under test: the second image is not shut by
#     the first one's token and does not see the first one's counter.
#   * the loader page and the worker AGREE. They are two files substituted
#     independently, and a mismatch between the glue filename the worker imports
#     and the one the build emitted is a module that never loads, with no build
#     error anywhere.
#   * a Qt plugin shape has NO `web` output, for the same reason it has no
#     `bare` one.
#
# WHAT THE LINK ALREADY PROVED, so it is not asserted again: that the protocol
# is IN the image. A Bare artifact leaves lp_token_save undefined for its host
# to supply; wasm-ld has no such mode for an executable and fails the link by
# name on the first unresolved symbol. There is nothing to check afterwards —
# and nothing that COULD be checked, since wasm-opt minifies the export names
# and a linked image's symbol table is seven single letters.
{ pkgs, mkLogosModule, fixturesRoot }:

let
  counter = mkLogosModule {
    src = fixturesRoot + "/bare-counter";
    configFile = fixturesRoot + "/bare-counter/metadata.json";
  };

  system = pkgs.stdenv.hostPlatform.system;
  counterWeb = counter.packages.${system}.web;

  # Same admission rule as `bare`: a Qt plugin object holding a LogosAPI has no
  # protocol-free form, so it cannot be compiled into a Wasm host either. Pure
  # evaluation — nothing is built.
  noWeb = label: fixture:
    let m = mkLogosModule {
          src = fixturesRoot + "/${fixture}";
          configFile = fixturesRoot + "/${fixture}/metadata.json";
        };
    in if m.packages.${system} ? web
       then builtins.throw "FAIL: ${label} (${fixture}) must not expose a `web` output"
       else true;

  qtPluginsHaveNoWeb =
    noWeb "a hand-written Qt core module" "test-framework-module"
    && noWeb "a ui_qml view backend" "qml-module";

in assert qtPluginsHaveNoWeb; pkgs.runCommand "web-variant-tests" {
  nativeBuildInputs = [ pkgs.nodejs ];
} ''
  set -euo pipefail

  variant=${counterWeb}/bare_counter_web
  test -d "$variant" || { echo "FAIL: no bare_counter_web/ directory in the output"; exit 1; }

  for f in index.html manifest.json logos-wasm-worker.js bare_counter_wasm.js \
           bare_counter_wasm_image.wasm wasm-host.json; do
    test -s "$variant/$f" || { echo "FAIL: $f missing from the web variant"; exit 1; }
  done
  echo "PASS: the web variant carries the Wasm host, the loader page and the manifest"

  # ── the two JS files agree ────────────────────────────────────────────────
  glue=$(sed -n "s/.*importScripts('\([^']*\)').*/\1/p" "$variant/logos-wasm-worker.js")
  test "$glue" = "bare_counter_wasm.js" \
    || { echo "FAIL: the worker imports '$glue', the build emitted bare_counter_wasm.js"; exit 1; }
  grep -q "new Worker('logos-wasm-worker.js')" "$variant/index.html" \
    || { echo "FAIL: the loader page does not spawn logos-wasm-worker.js"; exit 1; }
  echo "PASS: the loader page, the worker and the glue name each other correctly"

  # The size the page logs is the size of the image that shipped.
  measured=$(sed -n 's/.*"wasmBytes":\([0-9]*\).*/\1/p' "$variant/wasm-host.json")
  actual=$(wc -c < "$variant/bare_counter_wasm_image.wasm" | tr -d ' ')
  test "$measured" = "$actual" \
    || { echo "FAIL: wasm-host.json says $measured bytes, the image is $actual"; exit 1; }
  grep -q "const WASM_BYTES = $actual;" "$variant/index.html" \
    || { echo "FAIL: the loader page does not carry the measured wasm size"; exit 1; }
  echo "PASS: wasm size $actual bytes, recorded in wasm-host.json and in the page"

  # ── the image, driven ─────────────────────────────────────────────────────
  cp "$variant/bare_counter_wasm.js" ./host.js
  cat > drive.js <<'JS'
  // A message port for the wasm image, and a transcript of what it says.
  //
  // This is the Worker's job done in a dozen lines of node: hand the image a
  // frame, collect what comes back. Every frame below is exactly what the Web
  // container puts on the wire -- a {type, payload} envelope, the tags from
  // logos-protocol's MessageType -- so nothing here stands in for the
  // transport, only for the browser.
  const factory = require('./host.js');

  const CALL = 1, RESULT = 2, TOKEN = 6, METHODS = 7, METHODS_RESULT = 8;

  const fail = (why, transcript) => {
    console.error('FAIL: ' + why);
    if (transcript) console.error(JSON.stringify(transcript, null, 2));
    process.exit(1);
  };

  // One wasm image, with its port wired to an array.
  async function spawn() {
    const heard = [];
    let hello = null;
    const mod = await factory({
      logosOut: (text) => {
        let msg;
        try { msg = JSON.parse(text); } catch (e) { heard.push({ raw: text }); return; }
        if (msg.logosWasmHost) { hello = msg; return; }
        heard.push(msg);
      },
      print: () => {}, printErr: () => {},
    });
    const deliver = mod.cwrap('logos_wasm_deliver', null, ['string']);
    return {
      heard,
      hello: () => hello,
      send: (type, payload) => deliver(JSON.stringify({ type, payload })),
      result: (id) => heard.find((m) => m.type === RESULT && m.payload.id === id),
    };
  }

  (async () => {
    const a = await spawn();

    // The image announced itself before the factory settled: main() runs during
    // instantiation and posts its hello there.
    const hello = a.hello();
    if (!hello || hello.logosWasmHost !== 'bare_counter') {
      fail('the image did not announce itself: ' + JSON.stringify(hello));
    }
    if (!(hello.readyMs >= 0)) fail('no cold instantiate time reported');

    // INTROSPECTION, which is also the container's load verdict.
    a.send(METHODS, { id: 1, authToken: "", object: 'bare_counter' });

    // THE ACCEPTANCE CRITERION. add(1, 2) through the whole stack.
    a.send(CALL, { id: 2, authToken: "", object: 'bare_counter', method: 'add', args: [1, 2] });

    // State, to prove the image is one live module across calls.
    a.send(CALL, { id: 3, authToken: "", object: 'bare_counter', method: 'increment', args: [5] });
    a.send(CALL, { id: 4, authToken: "", object: 'bare_counter', method: 'current', args: [] });

    // A method that does not exist must be refused, not answered.
    a.send(CALL, { id: 5, authToken: "", object: 'bare_counter', method: 'nope', args: [] });

    // A call addressed to another module is not this image's to answer.
    a.send(CALL, { id: 6, authToken: "", object: 'other_module', method: 'add', args: [1, 2] });

    const methodsResult = a.heard.find((m) => m.type === METHODS_RESULT);
    if (!methodsResult || !methodsResult.payload.ok) fail('the image answered no Methods', a.heard);
    const names = methodsResult.payload.methods.map((m) => m.name).sort();
    for (const want of ['add', 'current', 'increment', 'reset']) {
      if (!names.includes(want)) fail('the published interface is missing ' + want + ': ' + names);
    }

    const add = a.result(2);
    if (!add || !add.payload.ok || add.payload.value !== 3) fail('add(1,2) did not answer 3', a.heard);

    const inc = a.result(3);
    if (!inc || inc.payload.value !== 5) fail('increment(5) did not answer 5', a.heard);
    const cur = a.result(4);
    if (!cur || cur.payload.value !== 5) {
      fail('current() did not answer 5 -- the image is not one live module', a.heard);
    }

    const unknown = a.result(5);
    if (!unknown || unknown.payload.ok) fail('an unknown method was answered', a.heard);

    const other = a.result(6);
    if (!other || other.payload.ok || other.payload.errCode !== 'MODULE_NOT_LOADED') {
      fail('a call to another module was not refused as MODULE_NOT_LOADED', a.heard);
    }

    // THE DOOR SHUTS. Once the core has told the image what its callers
    // present, a call without that token is refused -- the page half of ADR
    // 0005, validated inside the sandbox rather than only in the host.
    a.send(TOKEN, { authToken: "", moduleName: 'core', token: 'tok-abc' });
    a.send(CALL, { id: 7, authToken: "", object: 'bare_counter', method: 'add', args: [1, 2] });
    a.send(CALL, { id: 8, authToken: 'tok-abc', object: 'bare_counter', method: 'add', args: [2, 2] });

    const untokened = a.result(7);
    if (!untokened || untokened.payload.ok || untokened.payload.errCode !== 'UNAUTHORIZED') {
      fail('the door did not shut after a token arrived', a.heard);
    }
    const tokened = a.result(8);
    if (!tokened || !tokened.payload.ok || tokened.payload.value !== 4) {
      fail('a call carrying the token was not answered', a.heard);
    }

    console.log('PASS: add(1,2)=3 through the web transport, in wasm');
    console.log('PASS: the interface publishes ' + names.join(', '));
    console.log('PASS: state survives calls; unknown method, foreign object and '
                + 'untokened call are each refused');

    // ── PER IMAGE: two Wasm hosts cannot see each other's tokens ────────────
    //
    // Slice 26's third criterion, and the reason it is checkable here at all is
    // that "two Wasm hosts in two webviews" and "two instantiations of the same
    // glue in one node process" are the same thing to the property being
    // tested: a wasm instance owns its linear memory and shares none of it, so
    // image B has its own WasmTokenStore and its own provider state.
    //
    // Image A above has been given a token and shut its door. B has not. If any
    // of that state were shared -- a file-static reachable across instances, a
    // token store hoisted into the JS glue -- B's untokened call would be
    // refused too, and B's own counter would already be at 5.
    const b = await spawn();
    b.send(CALL, { id: 20, authToken: "", object: 'bare_counter', method: 'add', args: [1, 2] });
    b.send(CALL, { id: 21, authToken: 'tok-abc', object: 'bare_counter', method: 'add', args: [1, 2] });
    b.send(CALL, { id: 22, authToken: "", object: 'bare_counter', method: 'current', args: [] });

    const bOpen = b.result(20);
    if (!bOpen || !bOpen.payload.ok || bOpen.payload.value !== 3) {
      fail("a second image was refused A's caller -- the token store is shared", b.heard);
    }
    // ...and A's token is not one B knows: B's door is still open, so it accepts
    // anyone, which is a different statement from "B recognises tok-abc". The
    // asymmetry that MATTERS is that B was not shut by A's Token frame, and
    // that is what id 20 shows.
    const bTokened = b.result(21);
    if (!bTokened || !bTokened.payload.ok) fail('a second image refused a call outright', b.heard);

    const bState = b.result(22);
    if (!bState || bState.payload.value !== 0) {
      fail("a second image sees the first image's counter state", b.heard);
    }
    console.log("PASS: a second Wasm host has its own token store and its own state");

    console.log('cold instantiate: ' + hello.readyMs.toFixed(1) + ' ms, protocol ' + hello.protocol);
  })().catch((e) => { console.error('FAIL: ' + ((e && e.stack) || e)); process.exit(1); });
  JS

  node drive.js

  mkdir -p $out
  cp "$variant/wasm-host.json" $out/
  echo "web-variant tests passed" > $out/result
''
