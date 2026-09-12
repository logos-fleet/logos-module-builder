# Builder for the **`web` variant of a `type: ui_qml` module** — the module's
# QML, its Qt-wasm view backend, and the loader page that joins them to the
# app's bundled QML runtime (ADR 0004, slice 27).
#
# THE OTHER `web` VARIANT. buildWebModule.nix next door builds the one a
# headless module gets: a Bare module and logos-protocol's web transport in one
# Qt-free image, answering Call/Methods/Subscribe/Token from a Worker. This one
# builds what a module with a UI gets, and the two share only the LGX shape:
#
#            Bare module's `web`              ui_qml module's `web`
#   image    one, Qt-free, in a Worker        one, Qt-wasm, on the page thread
#   API      the web transport                a QtRO source (the .rep) + a router
#   UI       none                             a QML document, loaded by the
#                                             app's bundled runtime
#   file://  works (image embedded in glue)   NO: the page fetches its own QML
#                                             and the runtime from another dir
#
# WHAT COMES OUT is an LGX `web` variant DIRECTORY, exactly as the Bare one is:
# `main` names an entry document, everything the page may load lives beside it,
# and the directory IS the package.
#
#   <name>_web/
#     manifest.json              main = index.html, logos_web_runtime = "qml"
#     index.html                 the loader page (wasm/view-loader.html)
#     logos-view-loader.js       what it runs (wasm/logos-view-loader.js)
#     view/<entry>.qml           the module's QML, as the page fetches it
#     <name>_view_backend.js     the backend image's emscripten glue
#     <name>_view_backend.wasm   the backend image
#     web-view.json              what the build measured
#
# WHY THE BACKEND IMAGE IS NOT EMBEDDED IN ITS GLUE, where the Bare host's is:
# -sSINGLE_FILE exists there to survive a `file://` page, and this page cannot
# be a file:// page anyway (it fetches its own QML document and loads the ~26 MB
# runtime out of a directory the app serves). Keeping the image a real `.wasm`
# means the browser streams and caches it, which for a 4 MB image on a phone is
# the difference the base64 inflation would otherwise cost twice over.
{ lib }:

{
  pkgs,
  config,
  # The module's `generate` output: source plus a fully-populated
  # generated_code/. The same tree the desktop plugin and the iOS view framework
  # compile, so a `web` variant is the same module by construction.
  generatedSrc,
  builderRoot,
  # logos-nix' Qt for WebAssembly: `cmakeFlags` and `version`.
  qtWasm,
  # logos-view-module-runtime's web half, built for wasm: liblogos_messageport.a
  # (the `messageport:` QtRO scheme) and liblogos_web_runtime.a (whose
  # LogosWebCallRouter object is the only one this image pulls out). Its `www/`
  # is the bundled runtime the loader page loads at run time; nothing here
  # ships it, because one runtime serves every module.
  webRuntimeWasm,
  # logos-protocol's wasm subset: the web transport the call router's far end
  # uses to reach a native module through the container.
  logosProtocolWasm,
  # The module's QML: the directory whose contents ship, relative to the
  # generate tree, and the entry document relative to THAT. Resolved by the
  # caller for the same reason the iOS view framework's is — `view` in metadata
  # is relative to either the project root or src/, and where the two-layout
  # search already lives is mkLogosModule, which has the source tree.
  qmlDir,
  qmlEntry,
  extraNativeBuildInputs ? [],
  extraBuildInputs ? [],
}:

let
  backend = config.web_view_backend;
  stem = "${config.name}_view_backend";
  entryFunction = "${stem}_entry";

  # The module's QML, as the package lays it out. Everything in the declared
  # directory ships, and the entry is what the loader fetches. One directory
  # rather than one file because a module's document may sit next to assets it
  # references — what it may not do yet is import a SIBLING document, since the
  # runtime compiles one string (see the note in LogosWebRuntime).
  #
  # Shipped under view/ rather than at the package root so that a module's QML
  # can never collide with the five names this builder owns.
  viewEntry = "view/${qmlEntry}";

  manifestFile = builtins.toFile "${config.name}-web-view-manifest.json" (builtins.toJSON {
    inherit (config) name version description category;
    author = config.author or "";
    type = config.type;
    main = "index.html";
    dependencies = config.dependencies or [];
    # THE VARIANT SAYS WHAT IT IS, same key and same reason as the Bare variant's
    # manifest: a `web` variant may be hand-written JavaScript, a Wasm host, or
    # this — and a host deciding a memory budget should not have to sniff files.
    # "qml" is the one that costs the bundled runtime.
    logos_web_runtime = "qml";
    logos_web_view = {
      qml = viewEntry;
      backend_glue = "${stem}.js";
      backend_entry = entryFunction;
    };
  });

in pkgs.stdenv.mkDerivation {
  pname = "logos-${config.name}-web-view";
  version = config.version;

  src = generatedSrc;

  nativeBuildInputs = [ pkgs.cmake pkgs.ninja ] ++ extraNativeBuildInputs;
  buildInputs = [ pkgs.nlohmann_json ] ++ extraBuildInputs;

  dontUseCmakeConfigure = true;
  dontWrapQtApps = true;
  # There is nothing in a wasm artifact for the Darwin/Linux fixup phases to
  # rewrite, and `strip` cannot read one.
  dontStrip = true;
  dontFixup = true;

  buildPhase = ''
    runHook preBuild

    ${pkgs.logosEmscriptenSetup}

    # The last two -D lines RESTATE the search paths qtWasm.cmakeFlags already
    # sets (a repeated -D wins), because this consumer needs nlohmann_json's
    # prefix alongside Qt's. Both variables, not just CMAKE_PREFIX_PATH: the
    # Emscripten toolchain sets CMAKE_FIND_ROOT_PATH_MODE_PACKAGE to ONLY, so a
    # prefix named only in CMAKE_PREFIX_PATH is never searched.
    cmake -S . -B build-web-view -GNinja ${lib.escapeShellArgs qtWasm.cmakeFlags} \
      -DCMAKE_BUILD_TYPE=Release \
      -DLOGOS_MODULE_WEB_VIEW=ON \
      -DLOGOS_WEB_RUNTIME_ROOT=${webRuntimeWasm} \
      -DLOGOS_PROTOCOL_WASM_ROOT=${logosProtocolWasm} \
      -DLOGOS_WEB_VIEW_BACKEND_CLASS=${lib.escapeShellArg backend.class} \
      -DLOGOS_WEB_VIEW_BACKEND_HEADER=${lib.escapeShellArg backend.header} \
      -DLOGOS_WEB_VIEW_BACKEND_SOURCES=${lib.escapeShellArg (lib.concatStringsSep ";" backend.sources)} \
      -DCMAKE_PREFIX_PATH="${qtWasm.prefix};${pkgs.nlohmann_json}" \
      -DCMAKE_FIND_ROOT_PATH="${qtWasm.prefix};${pkgs.nlohmann_json}"
    cmake --build build-web-view --parallel $NIX_BUILD_CORES

    runHook postBuild
  '';

  env.LOGOS_MODULE_BUILDER_ROOT = "${builderRoot}";

  installPhase = ''
    runHook preInstall

    out_dir=$out/${config.name}_web
    mkdir -p "$out_dir/view"

    built=build-web-view/web-view
    for f in ${stem}.js ${stem}.wasm; do
      [ -f "$built/$f" ] || { echo "the wasm link produced no $f" >&2; ls -la "$built" >&2; exit 1; }
      cp "$built/$f" "$out_dir/$f"
    done

    # The module's QML directory, contents and all.
    cp -R ${lib.escapeShellArg qmlDir}/. "$out_dir/view/"
    test -s "$out_dir/${viewEntry}" \
      || { echo "${qmlEntry} is not in ${qmlDir} in the generate tree" >&2; exit 1; }

    wasm_bytes=$(wc -c < "$out_dir/${stem}.wasm" | tr -d ' ')

    cp ${builderRoot}/wasm/logos-view-loader.js "$out_dir/logos-view-loader.js"
    substitute ${builderRoot}/wasm/view-loader.html "$out_dir/index.html" \
      --replace-fail '@MODULE@' '${config.name}' \
      --replace-fail '@VIEW_ENTRY@' '${viewEntry}' \
      --replace-fail '@BACKEND_JS@' '${stem}.js' \
      --replace-fail '@BACKEND_ENTRY@' '${entryFunction}' \
      --replace-fail '@BACKEND_WASM_BYTES@' "$wasm_bytes"

    cp ${manifestFile} "$out_dir/manifest.json"

    glue_bytes=$(wc -c < "$out_dir/${stem}.js" | tr -d ' ')
    ${pkgs.brotli}/bin/brotli -q 11 -c "$out_dir/${stem}.wasm" > "$TMPDIR/backend.br"
    br_bytes=$(wc -c < "$TMPDIR/backend.br" | tr -d ' ')

    # WHAT THE BUILD MEASURED, where a CI job or a size gate can read it without
    # running a browser. The brotli figure is the one that matters on a phone:
    # it is what the container actually transfers.
    printf '{"module":"%s","version":"%s","kind":"qml","wasmBytes":%s,"brotliBytes":%s,"glueBytes":%s,"entry":"index.html","qml":"%s","backend":"%s","backendEntry":"%s","qt":"%s"}\n' \
      '${config.name}' '${config.version}' "$wasm_bytes" "$br_bytes" "$glue_bytes" \
      '${viewEntry}' '${stem}.wasm' '${entryFunction}' '${qtWasm.version}' \
      > "$out_dir/web-view.json"

    echo "logos-module-builder: ${config.name} ui_qml web variant"
    echo "  view backend image: raw $wasm_bytes B, brotli $br_bytes B (Qt ${qtWasm.version})"
    echo "  the ~26 MB QML runtime is NOT in here: it is the app's, downloaded once"

    runHook postInstall
  '';

  # ── the gate ───────────────────────────────────────────────────────────────
  #
  # Four claims, none of them implied by a successful link.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    out_dir=$out/${config.name}_web
    image="$out_dir/${stem}.wasm"

    # 1. THE IMAGE IS WASM. A toolchain file that did not take produces a
    #    perfectly good native executable and a .js beside it.
    head -c 4 "$image" | od -An -c | grep -q '\\0   a   s   m' \
      || { echo "${stem}.wasm is not a wasm image"; exit 1; }

    # 2. EVERY CALL THAT CROSSES THE LANGUAGE BOUNDARY IS STILL IN IT. These are
    #    embind exports, so NOTHING in C++ references them and a linker is free
    #    to drop the translation unit that registers them — leaving an image
    #    that builds, boots, and can never be handed a port or a frame. The
    #    first two come from the transport, the rest from this repo's host.
    for symbol in logosAdoptMessagePort logosMessagePortDeliver \
                  logosViewHostSetSink logosViewHostDeliver \
                  logosViewHostModule logosViewHostServing logosViewHostReadyMs \
                  logosViewHostBackendJson; do
      grep -a -q "$symbol" "$out_dir/${stem}.js" "$image" || {
        echo "the backend image does not export $symbol: the object registering" >&2
        echo "  it was dropped from the link (nothing in C++ names an embind" >&2
        echo "  binding, so a static archive is free to leave it out)." >&2
        exit 1
      }
    done

    # 3. NO QML ENGINE IN HERE. liblogos_web_runtime.a carries LogosWebRuntime
    #    and LogosWebBridge as well as the router, and both want Qt Qml; only
    #    the router's object should be pulled out. If that ever stops being
    #    true the image silently gains a second QML engine per module, which is
    #    precisely the cost ADR 0004's split exists to avoid — and it would show
    #    up as size, months later, with nothing pointing at the cause.
    if grep -a -q 'QQmlEngine' "$image"; then
      echo "the view backend image carries a QML engine. Something in it now" >&2
      echo "  references LogosWebRuntime or LogosWebBridge, so the whole of Qt" >&2
      echo "  Qml came with it. The scene belongs to the bundled runtime." >&2
      exit 1
    fi

    # 4. THE PACKAGE IS COMPLETE AND THE PAGE IS FILLED IN. A substitution that
    #    silently did not fire leaves an @PLACEHOLDER@ in valid HTML, which is a
    #    dead module with no error anywhere.
    for f in index.html manifest.json logos-view-loader.js web-view.json \
             ${stem}.js ${viewEntry}; do
      test -s "$out_dir/$f" || { echo "$f is missing or empty"; exit 1; }
    done

    if grep -q '@[A-Z_]\+@' "$out_dir/index.html"; then
      echo "a template placeholder survived into the shipped page:"
      grep -n '@[A-Z_]\+@' "$out_dir/index.html"
      exit 1
    fi

    grep -q '"main": *"index.html"' "$out_dir/manifest.json" \
      || { echo "the manifest does not name index.html as its entry"; exit 1; }
    grep -q '"logos_web_runtime": *"qml"' "$out_dir/manifest.json" \
      || { echo "the manifest does not declare the qml web runtime"; exit 1; }

    runHook postInstallCheck
  '';

  meta = with lib; {
    description = "${config.description} (web variant: QML for the bundled runtime + a Qt-wasm view backend)";
    platforms = platforms.unix;
  };
}
