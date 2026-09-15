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
#   * THE MODULE'S STORE SURVIVES ITS IMAGE. An emscripten image HAS a
#     filesystem, so a `web` variant that persists nothing durable looks
#     identical to one that does until the page reloads. Driven across two
#     images, which is what a reload is to a module's store: the first writes
#     and commits, the second reads it back. And the fallback is asserted too --
#     with nothing durable mounted the image SAYS so and `remember` refuses to
#     claim a durability it does not have, which is the whole difference between
#     a module that knows it lost the data and one that does not.
#   * THE MODULE SEES WHO IS CALLING IT. A `web` variant is the only place in
#     the stack where the caller cannot ride on the token -- the container
#     presents the module's OWN root credential on every call it relays -- so
#     the identity travels as a field on the Call and the image believes it over
#     the token it was handed. Asserted where the two DISAGREE, because agreeing
#     is what the broken version did (logos-workspace#129).
#   * A PANIC IS A MODULE FAILURE AND NOT A PAGE CRASH. The counter's `panic`
#     method runs __builtin_trap() -- what a Rust core built `panic = "abort"`
#     compiles a panic to on wasm32. Driven three ways: the image traps rather
#     than answering; the SHIPPED worker catches it, names it once and stops
#     feeding the dead instance; and a fresh image serves immediately, from
#     zero, which is what makes "restart it" the honest recovery here.
#   * a Qt plugin shape has NO `web` output, for the same reason it has no
#     `bare` one.
#
# WHAT THE LINK ALREADY PROVED, so it is not asserted again: that the protocol
# is IN the image. A Bare artifact leaves lp_token_save undefined for its host
# to supply; wasm-ld has no such mode for an executable and fails the link by
# name on the first unresolved symbol. There is nothing to check afterwards —
# and nothing that COULD be checked, since wasm-opt minifies the export names
# and a linked image's symbol table is seven single letters.
#
#   * THE TWO GATES OF ADR 0009. A module that declares `platform: true` gets no
#     `web` output at all, and a module with dependencies gets one only when the
#     PINNED protocol can make an outbound call. Both are pure evaluation and
#     both are differential against the counter this file realises below.
#   * THE OUTBOUND DOOR, driven. A `codegen.rust` module with a dependency
#     compiles, links, and CALLS that dependency out of the image: the harness
#     below is the target, it mints the credential the door asks
#     capability_module for, it sees its own token on the frame that follows,
#     and it answers. Then the mirror: a capability_module that grants nothing
#     leaves the target undialled, because a door that forwarded a call it was
#     not granted would be a hole. That is what could not be done at all before
#     lp_client_create / lp_invoke_async existed on wasm32, and the one part of
#     it a link cannot establish.
{ pkgs, mkLogosModule, fixturesRoot
, # Does the pinned logos-protocol's wasm subset define lp_client_create /
  # lp_client_destroy / lp_invoke_async? Passed in rather than read here,
  # because this file is handed
  # `pkgs` and not the protocol flake -- and because the assertion below is
  # "the `web` output follows the pin", which needs the pin as an input.
  hasOutboundDoor ? false }:

let
  # Sources and metadata are named separately because ONE fixture pair below
  # deliberately mixes them (`bare-counter-platform` is a metadata file over
  # bare-counter's sources); everywhere else the two are the same directory,
  # which is what `moduleFixture` says.
  moduleAt = srcFixture: configFixture: mkLogosModule {
    src = fixturesRoot + "/${srcFixture}";
    configFile = fixturesRoot + "/${configFixture}/metadata.json";
  };
  moduleFixture = fixture: moduleAt fixture fixture;

  counter = moduleFixture "bare-counter";

  system = pkgs.stdenv.hostPlatform.system;
  counterWeb = counter.packages.${system}.web;

  # Same admission rule as `bare`: a Qt plugin object holding a LogosAPI has no
  # protocol-free form, so it cannot be compiled into a Wasm host either. Pure
  # evaluation — nothing is built.
  #
  # NOT "no ui_qml module has a `web` output" — since slice 27 one can, and it
  # is a different artifact entirely (its QML plus a Qt-wasm view backend; see
  # test-web-view-variant.nix). What both fixtures below assert is that neither
  # gets THIS one, the Bare Wasm host, and the two admission rules cannot
  # collide: `packaged_as_cdylib` is false for every ui_qml module, and
  # `web.view_backend` is refused on everything that is not one.
  noWebFor = label: m:
    let pkgsOf = m.packages.${system}; in
    if pkgsOf ? web
    then builtins.throw "FAIL: ${label} must not expose a `web` output"
    else if pkgsOf ? "${m.config.name}-web"
    then builtins.throw ("FAIL: ${label} must not expose a `"
                         + "${m.config.name}-web` output either -- the two names "
                         + "are one output and dropping only the short one leaves "
                         + "the variant reachable")
    else true;

  noWeb = label: fixture:
    noWebFor "${label} (${fixture})" (moduleFixture fixture);

  qtPluginsHaveNoWeb =
    noWeb "a hand-written Qt core module" "test-framework-module"
    && noWeb "a QML-only ui_qml module" "qml-module";

  # ── ADR 0009 GATE 1: `platform: true` ────────────────────────────────────
  #
  # THE SAME SOURCES AS `counter` ABOVE, under a metadata file that adds one
  # key. `counter.packages.<sys>.web` is realised further down this file, so the
  # pair is a differential: the only thing that can account for the absence here
  # is the declaration, and the fixture cannot rot into a module that has no
  # `web` output for some other reason without the positive half failing first.
  #
  # And the gate is SURGICAL -- the Platform module keeps its `bare` artifact,
  # which is the form it actually ships in. A gate that took that too would
  # remove the module from every phone instead of from the Store.
  platformCounter = moduleAt "bare-counter" "bare-counter-platform";
  platformModuleHasNoWeb =
    noWebFor "a module declaring `platform: true`" platformCounter;
  platformModuleKeepsBare =
    if platformCounter.packages.${system} ? bare then true
    else builtins.throw ("FAIL: a `platform: true` module must keep its `bare` "
                         + "output -- it is always part of a shell's Bundled set");

  # ── ADR 0009 GATE 2: dependencies, against the pinned protocol ───────────
  #
  # `bare_relay` calls `bare_counter` through modules(), so its image needs the
  # outbound door -- which the wasm subset publishes as `hasOutboundDoor`
  # (logos-protocol nix/wasm.nix). Before this gate the module published a
  # `web` output that could only ever fail at wasm-ld.
  #
  # ONE THING THIS DOES NOT CLAIM, and it is worth saying where the fixture is:
  # that bare_relay's `web` output BUILDS. It is a universal C++ module calling
  # the SYNCHRONOUS generated wrapper, and the sync door is deliberately absent
  # on wasm32 (a Worker is one event loop; ADR 0004), so its image fails at
  # wasm-ld naming `lp_invoke` -- which IS the designed diagnosis for a module
  # that has not switched spellings. The gate is about whether the protocol pin
  # CAN carry an outbound call; `web-rust-caller` below is the fixture that
  # proves one, through the async twin a `web` variant is meant to use.
  #
  # Asserted as a FUNCTION OF THE PIN and not as a flat "modules with
  # dependencies have no web output": the day logos-protocol ships the client
  # side, `hasOutboundDoor` is true, the output comes back, and this assertion
  # follows it rather than having to be deleted. test-bare-modules.nix pins the
  # other half -- that the Bare artifact leaves lp_invoke undefined on purpose.
  relay = moduleFixture "bare-relay";
  relayWebMatchesThePin =
    let hasWeb = relay.packages.${system} ? web; in
    if hasOutboundDoor == hasWeb then true
    else if hasOutboundDoor
    then builtins.throw ("FAIL: the pinned logos-protocol declares an outbound "
                         + "door, so a module with dependencies must get a `web` "
                         + "output again -- bare_relay has none")
    else builtins.throw ("FAIL: the pinned logos-protocol wasm subset cannot make "
                         + "an outbound call, so bare_relay (which calls "
                         + "bare_counter) must have no `web` output; it has one, "
                         + "and it can only fail at wasm-ld");

  # ── THE OUTBOUND DOOR'S FIXTURE ──────────────────────────────────────────
  #
  # A `codegen.rust` module whose ONLY interesting property is that it calls its
  # dependency. Rust rather than C++ because the generated async client is the
  # surface a `web` variant is meant to use and the one the sync gate leaves
  # standing -- if logos-rust-sdk's `cfg(not(target_os = "emscripten"))` had
  # taken the async twin with the sync one, this fixture would not compile.
  #
  # Its dependency is a CONTRACT ONLY (`dependency_overrides` at a committed
  # .lidl): the target is the node harness below, which is what makes this a
  # test about a frame on a wire rather than about a second module's build.
  webRustCaller = moduleFixture "web-rust-caller";
  webRustCallerWeb = webRustCaller.packages.${system}.web;

in
assert qtPluginsHaveNoWeb;
assert platformModuleHasNoWeb;
assert platformModuleKeepsBare;
assert relayWebMatchesThePin;

pkgs.runCommand "web-variant-tests" {
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
  const fs = require('fs');
  const os = require('os');
  const path = require('path');

  const CALL = 1, RESULT = 2, TOKEN = 6, METHODS = 7, METHODS_RESULT = 8;

  const fail = (why, transcript) => {
    console.error('FAIL: ' + why);
    if (transcript) console.error(JSON.stringify(transcript, null, 2));
    process.exit(1);
  };

  // One wasm image, with its port wired to an array.
  async function spawn(opts = {}) {
    const heard = [];
    let hello = null;
    const mod = await factory(Object.assign({
      logosOut: (text) => {
        let msg;
        try { msg = JSON.parse(text); } catch (e) { heard.push({ raw: text }); return; }
        if (msg.logosWasmHost) { hello = msg; return; }
        heard.push(msg);
      },
      print: () => {}, printErr: () => {},
    }, opts));
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
    for (const want of ['add', 'callerIdentity', 'current', 'increment', 'recall',
                        'remember', 'reset']) {
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

    // ── WHO THE MODULE THINKS IS CALLING ───────────────────────────────────
    //
    // A RELAY CANNOT BE IDENTIFIED BY ITS TOKEN, and this image is only ever
    // reached through one. The container presents the relayed module's OWN root
    // credential on every call it forwards -- it holds no other -- so the
    // token-owner derivation answers this image ITS OWN NAME for every caller
    // in the fleet. Measured on a device before the fix:
    // keystore_module.caller_identity(), asked by wallet_ui, answered
    // `module "keystore_module"`, and every name-gated method on that module
    // then refused everybody (logos-workspace#129).
    //
    // So the caller travels as DATA on the Call, beside the token, and the
    // three frames below are the whole contract from inside the image: the
    // field is believed, it beats the token derivation even when the two
    // DISAGREE (which is the shipping case, not a corner), and an absent one
    // still falls back so a peer that predates the field is unchanged.
    //
    // 'tok-abc' is filed under 'core' from the door-shuts case above, which is
    // what makes the disagreement real: without the field this image would say
    // module:core.
    a.send(CALL, { id: 9,  authToken: 'tok-abc', object: 'bare_counter',
                   method: 'callerIdentity', args: [],
                   caller: JSON.stringify({ kind: 'module', name: 'wallet_ui' }) });
    a.send(CALL, { id: 10, authToken: 'tok-abc', object: 'bare_counter',
                   method: 'callerIdentity', args: [] });
    a.send(CALL, { id: 11, authToken: 'tok-abc', object: 'bare_counter',
                   method: 'callerIdentity', args: [],
                   caller: JSON.stringify({ kind: 'host' }) });

    const named = a.result(9);
    if (!named || !named.payload.ok || named.payload.value !== 'module:wallet_ui') {
      fail('a relayed call did not name its caller to the module: '
           + JSON.stringify(named && named.payload), a.heard);
    }
    const derived = a.result(10);
    if (!derived || !derived.payload.ok || derived.payload.value !== 'module:core') {
      fail('a call with no caller field lost the token-owner fallback: '
           + JSON.stringify(derived && derived.payload), a.heard);
    }
    const host = a.result(11);
    if (!host || !host.payload.ok || host.payload.value !== 'host') {
      fail('the host anchor arm did not survive the wire: '
           + JSON.stringify(host && host.payload), a.heard);
    }
    console.log('PASS: the module sees the CALL\'s caller (module:wallet_ui, host), '
                + 'and the token-owner fallback when none was named');

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

    // ── THE MODULE'S STORE SURVIVES ITS IMAGE ───────────────────────────────
    //
    // An emscripten image HAS a filesystem, which is why this needs asserting
    // at all: without the host's mount every write below succeeds, reads back
    // correctly for the life of the image, and is gone — the exact shape of a
    // `web` variant that looks right in a demo and loses a user's key on the
    // next page load. So the property is stated across two images, which is
    // what a page reload is to a module's store.
    //
    // NODEFS stands in for IndexedDB. It is not a weaker statement about the
    // thing under test: the mount, the populate-before-main, the persistence
    // path in the module context and the `logos_storage_commit` the module
    // calls are one code path with the backend chosen at the bottom of it
    // (wasm/logos_wasm_storage.js). IndexedDB itself needs a browser, and what
    // a browser would add here is a test of IndexedDB.
    const store = fs.mkdtempSync(path.join(os.tmpdir(), 'logos-web-store-'));

    const writer = await spawn({ logosStorageHostDir: store });
    const writerHello = writer.hello();
    if (!writerHello || writerHello.storage !== 'nodefs') {
      fail('the image did not mount the store it was given: ' + JSON.stringify(writerHello));
    }
    if (!writerHello.storagePath) fail('the image reported no persistence path', writerHello);

    writer.send(CALL, { id: 50, authToken: "", object: 'bare_counter',
                        method: 'remember', args: ['a key survives a reload'] });
    const wrote = writer.result(50);
    if (!wrote || !wrote.payload.ok || wrote.payload.value !== true) {
      fail('remember() did not report a durable write', writer.heard);
    }

    // It reached the HOST filesystem, not just the image's view of one.
    const onDisk = fs.readdirSync(store);
    if (!onDisk.includes('note.txt')) {
      fail('nothing reached the durable store: ' + JSON.stringify(onDisk));
    }

    // ...and a SECOND image, which is what the page after a reload is, reads it
    // back. The first image's linear memory is not shared with it; the only
    // path from one to the other is the store.
    const reader = await spawn({ logosStorageHostDir: store });
    reader.send(CALL, { id: 51, authToken: "", object: 'bare_counter', method: 'recall', args: [] });
    const recalled = reader.result(51);
    if (!recalled || !recalled.payload.ok || recalled.payload.value !== 'a key survives a reload') {
      fail('a second image did not recall what the first one stored', reader.heard);
    }
    console.log('PASS: a write committed by one image is read back by the next');

    // AND THE FALLBACK IS HONEST. With no host directory and no IndexedDB —
    // which is plain node, and is also an embedded webview with storage
    // disabled — the image still runs and still has a filesystem, so the write
    // SUCCEEDS at the language level. `remember` returns false anyway, because
    // logos_storage_commit reported that nothing durable is mounted. That
    // refusal is the whole difference between a module that knows it lost the
    // data and one that does not.
    const noStore = await spawn();
    const noStoreHello = noStore.hello();
    if (!noStoreHello || noStoreHello.storage !== 'memfs') {
      fail('an image with no durable store did not say so: ' + JSON.stringify(noStoreHello));
    }
    noStore.send(CALL, { id: 60, authToken: "", object: 'bare_counter',
                         method: 'remember', args: ['this cannot last'] });
    const ephemeral = noStore.result(60);
    if (!ephemeral || !ephemeral.payload.ok || ephemeral.payload.value !== false) {
      fail('a write with no durable store was reported as durable', noStore.heard);
    }
    // ...and it is still readable within the image, which is what makes the
    // fallback usable for the life of a page rather than merely broken.
    noStore.send(CALL, { id: 61, authToken: "", object: 'bare_counter', method: 'recall', args: [] });
    const stillThere = noStore.result(61);
    if (!stillThere || stillThere.payload.value !== 'this cannot last') {
      fail('the memfs fallback did not even hold the write in-image', noStore.heard);
    }
    console.log('PASS: with no durable store the image says so and refuses to claim durability');

    // ── A PANIC IS A TRAP, AND A TRAP LEAVES THE IMAGE DEAD ─────────────────
    //
    // Slice 26's fourth criterion, at the only level this harness can see it:
    // the module's `panic` method runs __builtin_trap(), which is what a Rust
    // core built `panic = "abort"` compiles a panic to on wasm32. The engine
    // turns it into a RuntimeError that unwinds out of the call INTO JS -- which
    // is the whole reason the failure can be contained at all, and what the
    // Worker catches (drive-trap.js drives the shipped worker and asserts that).
    const c = await spawn();
    c.send(CALL, { id: 30, authToken: "", object: 'bare_counter', method: 'add', args: [1, 2] });
    const cAdd = c.result(30);
    if (!cAdd || cAdd.payload.value !== 3) fail('a third image did not serve', c.heard);

    let trapped = null;
    try {
      c.send(CALL, { id: 31, authToken: "", object: 'bare_counter', method: 'panic', args: [] });
    } catch (e) {
      trapped = e;
    }
    if (!trapped) fail('panic() did not trap: the image answered and kept running', c.heard);
    if (c.result(31)) fail('panic() answered a Result before trapping', c.heard);
    console.log('PASS: a panic inside the module traps the image (' + trapped + ')');

    // ...and a FRESH image is a clean one. This is what makes "restart it" the
    // right recovery for a Wasm host and a lie for a module whose state died
    // with it: the image keeps nothing outside its own linear memory, so a new
    // one serves immediately and starts from zero.
    const d = await spawn();
    d.send(CALL, { id: 40, authToken: "", object: 'bare_counter', method: 'add', args: [1, 2] });
    d.send(CALL, { id: 41, authToken: "", object: 'bare_counter', method: 'current', args: [] });
    const dAdd = d.result(40);
    if (!dAdd || dAdd.payload.value !== 3) {
      fail('an image made after a trap does not serve', d.heard);
    }
    const dState = d.result(41);
    if (!dState || dState.payload.value !== 0) {
      fail('an image made after a trap inherited state', d.heard);
    }
    console.log('PASS: an image made after a trap serves, from zero');

    console.log('cold instantiate: ' + hello.readyMs.toFixed(1) + ' ms, protocol ' + hello.protocol);
  })().catch((e) => { console.error('FAIL: ' + ((e && e.stack) || e)); process.exit(1); });
  JS

  node drive.js

  # ── the Worker, driven ────────────────────────────────────────────────────
  #
  # The file above drives the wasm image. This one drives the SHIPPED
  # logos-wasm-worker.js -- the real file, with the build's own substitutions in
  # it -- inside a vm context that stands in for the Worker global scope. What it
  # is asserting is the half of criterion 4 that belongs to this repo: a trap
  # inside a delivered frame does not escape as an unnamed error and does not
  # leave a dead image apparently willing to take the next call. It is reported,
  # once, with its reason, on the same port the frames use; the loader page turns
  # that into a closed channel, and the container into a module failure.
  cp "$variant/logos-wasm-worker.js" ./worker.js
  cat > drive-trap.js <<'JS'
  const fs = require('fs');
  const vm = require('vm');

  const CALL = 1, RESULT = 2;
  const fail = (why, seen) => {
    console.error('FAIL: ' + why);
    if (seen) console.error(JSON.stringify(seen, null, 2));
    process.exit(1);
  };

  const source = fs.readFileSync('./worker.js', 'utf8');
  if (!/LogosWasmModule\(/.test(source)) {
    fail('the shipped worker does not call the factory the build named');
  }

  // Everything the Worker global scope gives this file. `logosOut` is the
  // image's own port (see logos_wasm_post in wasm/logos_wasm_host.cpp) and it
  // lands in the same transcript as the worker's own postMessage, because in a
  // real Worker both go to the page.
  const posted = [];
  const sandbox = {
    console,
    setTimeout,
    JSON,
    importScripts: () => {
      const factory = require('./host.js');
      sandbox.LogosWasmModule = (opts) =>
        factory(Object.assign({}, opts, { logosOut: (text) => posted.push(text) }));
    },
    self: {
      postMessage: (text) => posted.push(text),
      close: () => { sandbox.self.closed = true; },
    },
  };
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);

  // The transcript as messages. Read fresh each time, because everything below
  // asserts on what the worker had posted by that point.
  const heard = () => posted
    .map((t) => { try { return JSON.parse(t); } catch (e) { return null; } })
    .filter((m) => m);
  const control = (key) => heard().filter((m) => m[key] !== undefined);
  const results = () => heard().filter((m) => m.type === RESULT);

  const deliver = (payload) =>
    sandbox.self.onmessage({ data: JSON.stringify({ type: CALL, payload }) });

  (async () => {
    // The factory's promise settles on a microtask; nothing here may run before
    // the worker has installed its deliver function.
    await new Promise((resolve) => setTimeout(resolve, 200));

    if (control('logosWasmHost').length !== 1) {
      fail('the worker did not relay the image\'s hello', posted);
    }

    deliver({ id: 1, authToken: "", object: 'bare_counter', method: 'add', args: [1, 2] });
    const answered = results().find((m) => m.payload.id === 1);
    if (!answered || answered.payload.value !== 3) fail('the worker did not relay add(1,2)', posted);

    // THE TRAP. Delivered exactly as the page delivers any other frame.
    deliver({ id: 2, authToken: "", object: 'bare_counter', method: 'panic', args: [] });

    const traps = control('logosWasmTrap');
    if (traps.length !== 1) {
      fail('a trap inside a delivered frame was not reported as logosWasmTrap', posted);
    }
    if (!traps[0].logosWasmTrap) fail('the trap was reported with no reason', posted);
    if (results().find((m) => m.payload.id === 2)) fail('the trapping call answered a Result', posted);

    // AND THE DOOR STAYS SHUT. A wasm instance that trapped is unusable; a
    // worker that kept feeding it would answer garbage, or throw again, for the
    // rest of the page's life.
    const before = posted.length;
    deliver({ id: 3, authToken: "", object: 'bare_counter', method: 'add', args: [1, 2] });
    if (posted.length !== before) {
      fail('the worker kept talking to a trapped image', posted.slice(before));
    }

    console.log('PASS: a trap in the image is reported once, with its reason, and '
                + 'the worker stops delivering');
  })().catch((e) => { console.error('FAIL: ' + ((e && e.stack) || e)); process.exit(1); });
  JS

  node drive-trap.js

  # ── the loader page turns that report into a closed channel ───────────────
  #
  # A page is HTML and a DOM, and there is no browser in this derivation -- so
  # what is checkable here is that the shipped page HANDLES the report the worker
  # was just seen to produce, and answers it by closing the channel, which is the
  # only thing the host can hear. The end-to-end proof is a
  # `logoscore --container web` run.
  grep -q 'logosWasmTrap' "$variant/index.html" \
    || { echo "FAIL: the loader page ignores the worker's trap report"; exit 1; }
  grep -q 'channel.close()' "$variant/index.html" \
    || { echo "FAIL: the loader page does not close the channel when the image dies"; exit 1; }
  grep -q 'worker.onerror' "$variant/index.html" \
    || { echo "FAIL: the loader page has no backstop for a trap outside a frame"; exit 1; }
  echo "PASS: the loader page reports a dead image by closing its channel"

  # ── THE OUTBOUND DOOR, DRIVEN ─────────────────────────────────────────────
  #
  # Everything above is a call going INTO an image. This is one coming out, and
  # it is the half that did not exist: lp_client_create / lp_invoke_async on
  # wasm32, over the same connection the host installed
  # (logos::wasm::setOutboundConnection in wasm/logos_wasm_host.cpp).
  #
  # THE HARNESS IS THE FAR SIDE OF THE CHANNEL, which is what makes this
  # checkable without a browser, a container or a second module: the image's one
  # message port is `Module.logosOut` here, so a frame the image SENDS is an
  # entry in the transcript, and a reply is a `logos_wasm_deliver` away. The
  # target module `stub_target` exists only as a .lidl; node answers for it.
  #
  # WHY capability_module APPEARS. The image holds no credential for its
  # dependency at startup -- the core pushes a module its OWN token and its
  # callers', never an outbound one -- so the door runs the same requestModule
  # handshake a native client runs transparently on its first call. Both
  # outcomes are driven below, because the refusal is the security-relevant one.
  caller=${webRustCallerWeb}/web_rust_caller_web
  test -d "$caller" || { echo "FAIL: the rust caller has no web variant"; exit 1; }
  cp "$caller/web_rust_caller_wasm.js" ./caller-host.js
  cat > drive-outbound.js <<'JS'
  const factory = require('./caller-host.js');
  const CALL = 1, RESULT = 2;

  const fail = (why, transcript) => {
    console.error('FAIL: ' + why);
    if (transcript) console.error(JSON.stringify(transcript, null, 2));
    process.exit(1);
  };

  async function spawn() {
    const heard = [];
    const mod = await factory({
      logosOut: (text) => {
        let msg;
        try { msg = JSON.parse(text); } catch (e) { return; }
        if (msg.logosWasmHost) return;
        heard.push(msg);
      },
      print: () => {}, printErr: () => {},
    });
    const deliver = mod.cwrap('logos_wasm_deliver', null, ['string']);
    return {
      heard,
      send: (type, payload) => deliver(JSON.stringify({ type, payload })),
      result: (id) => heard.find((m) => m.type === RESULT && m.payload.id === id),
      // Frames the IMAGE sent, i.e. its outbound calls.
      outbound: () => heard.filter((m) => m.type === CALL),
    };
  }

  (async () => {
    // ── the granted path ────────────────────────────────────────────────────
    const a = await spawn();
    a.send(CALL, { id: 1, authToken: "", object: 'web_rust_caller',
                   method: 'kick', args: [5] });

    const dispatched = a.result(1);
    if (!dispatched || !dispatched.payload.ok || dispatched.payload.value !== 'dispatched') {
      fail('kick() did not answer -- the module never ran', a.heard);
    }
    // ASYNC, AND THE TRANSCRIPT SAYS SO: nothing has answered the outbound call
    // yet, so the module has no result to report.
    a.send(CALL, { id: 2, authToken: "", object: 'web_rust_caller', method: 'last', args: [] });
    const inFlight = a.result(2);
    // Double quotes for the empty string, throughout: this script lives inside
    // a nix indented string, where a bare pair of single quotes ENDS it.
    if (!inFlight || inFlight.payload.value !== "") {
      fail('last() answered before the dependency did -- the door is not async',
           a.heard);
    }

    const handshake = a.outbound()[0];
    if (!handshake || handshake.payload.object !== 'capability_module'
        || handshake.payload.method !== 'requestModule') {
      fail('the image did not ask capability_module for a token', a.heard);
    }
    if (handshake.payload.args[1] !== 'stub_target') {
      fail('the handshake did not name the target: '
           + JSON.stringify(handshake.payload.args), a.heard);
    }
    a.send(RESULT, { id: handshake.payload.id, ok: true, value: 'tok-for-stub' });

    // ...and only NOW is the target dialled, carrying the token it was granted.
    const call = a.outbound()[1];
    if (!call || call.payload.object !== 'stub_target' || call.payload.method !== 'increment') {
      fail('the image did not call its dependency after being granted a token', a.heard);
    }
    if (call.payload.args[0] !== 5) {
      fail('the outbound call lost its argument: ' + JSON.stringify(call.payload.args));
    }
    if (call.payload.authToken !== 'tok-for-stub') {
      fail('the outbound frame carries authToken='
           + JSON.stringify(call.payload.authToken)
           + ', not the credential capability_module granted');
    }

    // The stub answers, and the reply has to reach the module's own callback.
    a.send(RESULT, { id: call.payload.id, ok: true, value: 15 });
    a.send(CALL, { id: 3, authToken: "", object: 'web_rust_caller', method: 'last', args: [] });
    const landed = a.result(3);
    if (!landed || landed.payload.value !== 'ok:15') {
      fail('the reply did not land in the callback: '
           + JSON.stringify(landed && landed.payload), a.heard);
    }
    console.log('PASS: a wasm image called its dependency and the reply landed '
                + 'in the callback, on a token capability_module granted it');

    // ONCE PER TARGET. The grant went into the image's own store, so a second
    // call does not re-run the handshake.
    const before = a.outbound().length;
    a.send(CALL, { id: 4, authToken: "", object: 'web_rust_caller', method: 'kick', args: [7] });
    const second = a.outbound()[before];
    if (!second || second.payload.object !== 'stub_target') {
      fail('the second call did not go straight to the target', a.heard.slice(-4));
    }
    if (second.payload.authToken !== 'tok-for-stub') {
      fail('the remembered token was not presented on the second call');
    }
    console.log('PASS: the capability handshake runs once per target, not once per call');

    // ── the refusal ─────────────────────────────────────────────────────────
    //
    // A fresh image, because the one above now holds a credential. This is the
    // property the issue calls the hole: a door that forwarded a call it was
    // not granted would put an unauthorized frame on the container's wire and
    // leave the decision to whatever the far side happens to check.
    const b = await spawn();
    b.send(CALL, { id: 1, authToken: "", object: 'web_rust_caller',
                   method: 'kick', args: [5] });
    const ask = b.outbound()[0];
    if (!ask || ask.payload.object !== 'capability_module') {
      fail('the second image did not run the handshake', b.heard);
    }
    b.send(RESULT, { id: ask.payload.id, ok: true, value: "" });   // granted nothing

    if (b.outbound().length !== 1) {
      fail('the target was dialled without a token: '
           + JSON.stringify(b.outbound().map((m) => m.payload.object)), b.heard);
    }
    b.send(CALL, { id: 2, authToken: "", object: 'web_rust_caller', method: 'last', args: [] });
    const refused = b.result(2);
    if (!refused || !String(refused.payload.value).startsWith('err:')) {
      fail('an ungranted call was not reported to the module as a failure: '
           + JSON.stringify(refused && refused.payload.value), b.heard);
    }
    if (!String(refused.payload.value).includes('stub_target')) {
      fail('the refusal does not name the target: ' + refused.payload.value);
    }
    console.log('PASS: a target this image holds no token for is refused, not forwarded');
  })().catch((e) => { console.error('FAIL: ' + ((e && e.stack) || e)); process.exit(1); });
  JS

  node drive-outbound.js

  mkdir -p $out
  cp "$variant/wasm-host.json" $out/
  echo "web-variant tests passed" > $out/result
''
