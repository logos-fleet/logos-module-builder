# Integration test for the `web` output of a **`type: ui_qml`** module — the
# module's QML plus its Qt-wasm view backend, laid out as an LGX `web` variant
# (ADR 0004, slice 27).
#
# The derivation under test already gated itself (buildWebViewModule's
# installCheckPhase: the image is wasm, every page-facing embind export survived
# the link, no QML engine came along for the ride, no template placeholder
# survived). Realising it here is therefore most of the assertion. What this file
# adds is what that gate cannot see from inside its own build:
#
#   * THE FOUR FILES NAME EACH OTHER. The page, the loader module, the backend
#     glue and the manifest are substituted independently; a mismatch between
#     the -sEXPORT_NAME the link produced and the entry the page calls is a
#     module that never starts, with no build error anywhere.
#   * THE BACKEND IMAGE IS A REAL, SEPARATE .wasm. Unlike the Bare variant's,
#     it is NOT embedded in its glue — this page cannot be a file:// page in the
#     first place, and a 4 MB image base64'd into JS costs a third again.
#   * THE MODULE'S QML SHIPPED, at the path the manifest and the page agree on.
#   * ADMISSION. A ui_qml module that declares no separable backend has no `web`
#     output rather than a broken one, and a NON-ui_qml module that declares one
#     is a metadata error rather than a silently ignored key.
#
# WHAT NEEDS A BROWSER AND IS THEREFORE NOT HERE: that the two images actually
# talk. `wasm/browser-e2e/run.mjs` boots this exact variant against the bundled
# runtime in headless Chrome and clicks the button. It cannot be a nix check —
# there is no browser in the sandbox and no chromium in darwin nixpkgs — which is
# the same boundary logos-view-module-runtime's own browser smoke sits on.
{ pkgs, mkLogosQmlModule, fixturesRoot }:

let
  counter = mkLogosQmlModule {
    src = fixturesRoot + "/web-view-counter";
    configFile = fixturesRoot + "/web-view-counter/metadata.json";
  };

  system = pkgs.stdenv.hostPlatform.system;
  counterWeb = counter.packages.${system}.web;

  # A ui_qml module with no `web.view_backend` gets no `web` output. Pure
  # evaluation — nothing is built. This is the fixture the OTHER web test uses
  # to assert the same absence from the Bare side, and it is the common case:
  # every ui_qml module written before this key existed.
  qmlOnlyHasNoWeb =
    let m = mkLogosQmlModule {
          src = fixturesRoot + "/qml-module";
          configFile = fixturesRoot + "/qml-module/metadata.json";
        };
    in if m.packages.${system} ? web
       then builtins.throw ("FAIL: a ui_qml module that declares no "
                            + "web.view_backend must not expose a `web` output")
       else true;

in assert qmlOnlyHasNoWeb; pkgs.runCommand "web-view-variant-tests" { } ''
  set -euo pipefail

  variant=${counterWeb}/web_counter_web
  test -d "$variant" || { echo "FAIL: no web_counter_web/ directory in the output"; exit 1; }

  for f in index.html manifest.json logos-view-loader.js web-view.json \
           web_counter_view_backend.js web_counter_view_backend.wasm \
           view/Counter.qml; do
    test -s "$variant/$f" || { echo "FAIL: $f missing from the web variant"; exit 1; }
  done
  echo "PASS: the variant carries the page, the loader, the backend image and the module's QML"

  # ── the four files agree ──────────────────────────────────────────────────
  grep -q "from './logos-view-loader.js'" "$variant/index.html" \
    || { echo "FAIL: the page does not import the shipped loader"; exit 1; }
  grep -q "backendGlue: 'web_counter_view_backend.js'" "$variant/index.html" \
    || { echo "FAIL: the page does not name the backend glue the build emitted"; exit 1; }
  grep -q "backendEntry: 'web_counter_view_backend_entry'" "$variant/index.html" \
    || { echo "FAIL: the page does not name the glue's -sEXPORT_NAME"; exit 1; }
  grep -q "viewEntry: 'view/Counter.qml'" "$variant/index.html" \
    || { echo "FAIL: the page does not name the module's QML document"; exit 1; }

  # ...and the entry point the page calls is really in the glue. This is the one
  # that has no build error: Qt derives -sEXPORT_NAME from the target name, and
  # the page derives it from the module name, so they agree only as long as the
  # builder's stem and the cmake target's stay in step.
  grep -q 'web_counter_view_backend_entry' "$variant/web_counter_view_backend.js" \
    || { echo "FAIL: the glue does not define web_counter_view_backend_entry"; exit 1; }
  echo "PASS: the page, the loader, the glue and the QML name each other correctly"

  # ── a real, separate image ────────────────────────────────────────────────
  #
  # The Bare variant embeds its image in its glue (-sSINGLE_FILE) so a file://
  # page can load it. This one must NOT: the page fetches its own QML and the
  # bundled runtime from another directory, so it is served either way, and a
  # base64 literal would cost a third of a 4 MB image for nothing.
  if grep -q 'base64Decode("AGFzbQ' "$variant/web_counter_view_backend.js"; then
    echo "FAIL: the backend glue carries the image base64-embedded."
    echo "      A ui_qml variant is served, never opened as a file, so"
    echo "      -sSINGLE_FILE only inflates it."
    exit 1
  fi

  measured=$(sed -n 's/.*"wasmBytes":\([0-9]*\).*/\1/p' "$variant/web-view.json")
  actual=$(wc -c < "$variant/web_counter_view_backend.wasm" | tr -d ' ')
  test "$measured" = "$actual" \
    || { echo "FAIL: web-view.json says $measured bytes, the image is $actual"; exit 1; }
  grep -q "const BACKEND_WASM_BYTES = $actual;" "$variant/index.html" \
    || { echo "FAIL: the page does not carry the measured image size"; exit 1; }
  brotli=$(sed -n 's/.*"brotliBytes":\([0-9]*\).*/\1/p' "$variant/web-view.json")
  echo "PASS: backend image $actual bytes raw, $brotli brotli, recorded in web-view.json and in the page"

  # ── the variant declares what kind of `web` it is ─────────────────────────
  grep -q '"logos_web_runtime": *"qml"' "$variant/manifest.json" \
    || { echo "FAIL: the manifest does not declare the qml web runtime"; exit 1; }
  grep -q '"main": *"index.html"' "$variant/manifest.json" \
    || { echo "FAIL: the manifest does not name index.html as its entry"; exit 1; }
  grep -q '"qml": *"view/Counter.qml"' "$variant/manifest.json" \
    || { echo "FAIL: the manifest does not name the module's QML document"; exit 1; }
  echo "PASS: the manifest says this is a qml web variant and names its parts"

  # ── the runtime is NOT in here ────────────────────────────────────────────
  #
  # Slice 27's fourth criterion, as a property of the package rather than of a
  # page: a module's variant must not carry a copy of the ~26 MB bundled
  # runtime, or "one runtime download" is a claim about one module only. The
  # margin is generous on purpose — this catches a runtime accidentally copied
  # in, not a backend that grew a megabyte.
  total=$(du -sk "$variant" | cut -f1)
  if [ "$total" -gt 15000 ]; then
    echo "FAIL: the variant is ''${total} KB. That is runtime-sized: a module's"
    echo "      web variant carries its own backend only, and the QML runtime is"
    echo "      the app's, downloaded once for every module."
    exit 1
  fi
  echo "PASS: the variant is ''${total} KB — its backend and its QML, not a runtime"

  mkdir -p $out
  cp "$variant/web-view.json" $out/
  # A pointer to the variant this check realised, so the browser end-to-end can
  # be run against the same bytes without anyone having to find them:
  #
  #   nix build .#checks.<system>.web-view-variant
  #   node wasm/browser-e2e/run.mjs result/variant <runtime www>
  ln -s "$variant" $out/variant
  echo "web-view-variant tests passed" > $out/result
''
