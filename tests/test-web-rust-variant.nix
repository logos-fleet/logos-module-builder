# Integration test for a **Rust module's `web` variant** — the leg that did not
# exist.
#
# `logos_wasm_module()` linked C++ objects and logos-protocol's wasm archive, so
# a `codegen.rust` module — whose entire module-impl C ABI lives inside its
# crate — had no `web` output it could BE, however correct its storage was. The
# builder now compiles the crate for `wasm32-unknown-emscripten` and links the
# archive into the host image, which is the mobile Bare path aimed at a
# different triple.
#
# WHAT THIS ADDS OVER test-web-variant.nix, which drives the same host with a
# C++ core:
#
#   * THE RUST IS IN THE IMAGE AND IT ANSWERS. `ping()` comes back through the
#     web transport from code rustc compiled, which is the one fact a build
#     cannot establish about itself: an image that linked the archive and an
#     image that quietly did not are both valid wasm and both load.
#   * THE SDK'S STORE WORKS ON EMSCRIPTEN, FROM RUST. `logos_rust_sdk::storage`
#     is one type natively and on wasm32 with one difference — `commit()` is an
#     fsync there and a call into the host's `logos_storage_commit` here — and
#     that emscripten arm has, until now, never been executed by anything. It is
#     also the whole reason the keystore's vaults were moved onto it. Driven
#     across two images, which is what a page reload is to a module's store.
#   * AND IT IS HONEST WHEN THERE IS NOTHING DURABLE. With no host directory the
#     image still has a filesystem and the write still succeeds at the language
#     level; `remember` answers false because the barrier reported that nothing
#     durable is mounted. That refusal is the difference between a module that
#     knows it lost the data and one that does not — and on the Rust side it is
#     `StorageError::NotAvailable` coming back out of the FFI, not a C++
#     branch.
#
# NODEFS stands in for IndexedDB, for the reason test-web-variant.nix states at
# length: the mount, the populate-before-main, the persistence path on the
# module context and the `logos_storage_commit` the Rust core calls are one code
# path with the backend chosen at the bottom of it. What a browser would add
# here is a test of IndexedDB.
{ pkgs, mkLogosModule, fixturesRoot }:

let
  rustModule = mkLogosModule {
    src = fixturesRoot + "/bare-rust";
    configFile = fixturesRoot + "/bare-rust/metadata.json";
  };

  system = pkgs.stdenv.hostPlatform.system;
  rustWeb = rustModule.packages.${system}.web;

in pkgs.runCommand "web-rust-variant-tests" {
  nativeBuildInputs = [ pkgs.nodejs ];
} ''
  set -euo pipefail

  variant=${rustWeb}/bare_rust_module_web
  test -d "$variant" || { echo "FAIL: no bare_rust_module_web/ directory in the output"; exit 1; }
  for f in index.html manifest.json logos-wasm-worker.js bare_rust_module_wasm.js \
           bare_rust_module_wasm_image.wasm wasm-host.json; do
    test -s "$variant/$f" || { echo "FAIL: $f missing from the web variant"; exit 1; }
  done
  echo "PASS: a codegen.rust module has a web variant, laid out like any other"

  cp "$variant/bare_rust_module_wasm.js" ./host.js
  cat > drive.js <<'JS'
  // The Worker's job, done in node: hand the image a frame, collect what comes
  // back. Every frame is exactly what the Web container puts on the wire.
  const factory = require('./host.js');
  const fs = require('fs');
  const os = require('os');
  const path = require('path');

  const CALL = 1, RESULT = 2;

  const fail = (why, transcript) => {
    console.error('FAIL: ' + why);
    if (transcript) console.error(JSON.stringify(transcript, null, 2));
    process.exit(1);
  };

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
    // ── THE RUST IS IN THE IMAGE ────────────────────────────────────────────
    const a = await spawn();
    const hello = a.hello();
    if (!hello || hello.logosWasmHost !== 'bare_rust_module') {
      fail('the image did not announce itself: ' + JSON.stringify(hello));
    }
    a.send(CALL, { id: 1, authToken: "", object: 'bare_rust_module', method: 'ping', args: [] });
    const ping = a.result(1);
    if (!ping || !ping.payload.ok || ping.payload.value !== 'ok') {
      fail('ping() did not answer from the Rust core', a.heard);
    }
    console.log('PASS: a Rust core answers the web transport, in wasm');

    // ── THE SDK'S STORE, FROM RUST, ACROSS TWO IMAGES ───────────────────────
    const store = fs.mkdtempSync(path.join(os.tmpdir(), 'logos-web-rust-store-'));

    const writer = await spawn({ logosStorageHostDir: store });
    const writerHello = writer.hello();
    if (!writerHello || writerHello.storage !== 'nodefs') {
      fail('the image did not mount the store it was given: ' + JSON.stringify(writerHello));
    }
    writer.send(CALL, { id: 10, authToken: "", object: 'bare_rust_module',
                        method: 'remember', args: ['a Rust core kept this'] });
    const wrote = writer.result(10);
    if (!wrote || !wrote.payload.ok || wrote.payload.value !== true) {
      fail('remember() did not report a durable write', writer.heard);
    }

    // It reached the HOST filesystem, not just the image's view of one.
    const onDisk = fs.readdirSync(store);
    if (!onDisk.includes('note.txt')) {
      fail('nothing reached the durable store: ' + JSON.stringify(onDisk));
    }

    const reader = await spawn({ logosStorageHostDir: store });
    reader.send(CALL, { id: 11, authToken: "", object: 'bare_rust_module', method: 'recall', args: [] });
    const recalled = reader.result(11);
    if (!recalled || !recalled.payload.ok || recalled.payload.value !== 'a Rust core kept this') {
      fail('a second image did not recall what the first one committed', reader.heard);
    }
    console.log('PASS: logos_rust_sdk::storage commits from wasm and the next image reads it back');

    // ── ...AND IS HONEST WHEN THERE IS NOTHING DURABLE ──────────────────────
    const noStore = await spawn();
    if (noStore.hello().storage !== 'memfs') {
      fail('an image with no durable store did not say so: ' + JSON.stringify(noStore.hello()));
    }
    noStore.send(CALL, { id: 20, authToken: "", object: 'bare_rust_module',
                         method: 'remember', args: ['this cannot last'] });
    const ephemeral = noStore.result(20);
    if (!ephemeral || !ephemeral.payload.ok || ephemeral.payload.value !== false) {
      fail('a write with no durable store was reported as durable', noStore.heard);
    }
    console.log('PASS: with no durable store the Rust core refuses to claim durability');
  })().catch((e) => fail('the harness threw: ' + (e && e.stack || e)));
JS

  node drive.js
  mkdir -p $out
  echo ok > $out/result
''
