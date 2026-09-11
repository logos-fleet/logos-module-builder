# Builder for the **`web` variant** — a Bare module and logos-protocol's web
# transport compiled to WebAssembly, plus the loader page that runs the image in
# a Web Worker (slice 26).
#
# WHAT COMES OUT is an LGX `web` variant DIRECTORY, which is a package format
# rather than a library: `main` names an entry document, everything the page may
# load lives beside it, and the directory IS the package (lgx::resolveMain
# enforces that at install time). The Web container opens `main` in a webview and
# relays the web transport across its bridge; nothing in the container is
# wasm-aware, which is why the same variant runs behind a WKWebView on a phone.
#
#   <name>_web/
#     manifest.json          the module's own metadata, main = index.html
#     index.html             the loader page: spawns the Worker and relays
#     logos-wasm-worker.js   the Worker: emscripten glue in, port relay out
#     <name>_wasm.js         THE WASM HOST, wasm base64-embedded (-sSINGLE_FILE)
#     <name>_wasm_image.wasm the same image emitted plainly
#     wasm-host.json         what the build measured: sizes, module, protocol
#
# WHY THE IMAGE SHIPS TWICE. A `file://` page cannot `fetch()` a sibling `.wasm`
# — Chromium refuses the scheme, and a webview loading a local entry document is
# exactly where this runs — so the glue the Worker imports has to carry the image
# inside it. The plain `.wasm` beside it is the same bytes: it is what this build
# WEIGHS for the size the loader page logs (slice 26's criterion 5), it is
# inspectable with the ordinary wasm tools, and it is what a host serving the
# variant over http or a custom URL scheme loads directly. Two shapes, one image,
# one compile — see logos_wasm_module() in cmake/LogosModule.cmake.
{ lib }:

{
  pkgs,
  config,
  # The module's `generate` output, exactly as the Bare build takes it: source
  # plus a fully-populated generated_code/. Platform-independent by
  # construction, which is why the wasm build compiles the BUILD platform's copy
  # rather than re-running every code generator under a package set that has no
  # Qt in it.
  generatedSrc,
  builderRoot,
  logosSdk,
  # logos-protocol's wasm subset: packages.<system>.logos-protocol-wasm. Both
  # the headers this compiles against and the archive it links.
  logosProtocolWasm,
  extraNativeBuildInputs ? [],
  extraBuildInputs ? [],
}:

let
  stem = "${config.name}_wasm";

  # The manifest the package manager and the Web container read. `main` is the
  # loader page, never the wasm: a `web` variant's entry point is a document,
  # and that is what makes the container's job identical for a page written in
  # JavaScript (slice 24) and one that is a compiled module.
  manifestFile = builtins.toFile "${config.name}-web-manifest.json" (builtins.toJSON {
    inherit (config) name version description category;
    author = config.author or "";
    type = config.type;
    main = "index.html";
    dependencies = config.dependencies or [];
    # THE VARIANT SAYS WHAT IT IS. A `web` variant may be hand-written
    # JavaScript or a compiled wasm host, and a host that wants to know (to log
    # it, to decide a memory budget, to refuse one on a device without wasm)
    # should not have to sniff the files. Additive: nothing reads it today.
    logos_web_runtime = "wasm";
  });

in pkgs.stdenv.mkDerivation {
  pname = "logos-${config.name}-web";
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

    mkdir -p build-web
    cd build-web

    # CMAKE_FIND_ROOT_PATH as well as CMAKE_PREFIX_PATH. The Emscripten
    # toolchain sets CMAKE_FIND_ROOT_PATH_MODE_{INCLUDE,LIBRARY,PACKAGE} to
    # ONLY, so a store path named only in the prefix path is not searched at
    # all — the same trap the iOS Bare build documents, with the same fix.
    #
    # LOGOS_PROTOCOL_ROOT points at the WASM package deliberately: the wasm host
    # compiles against the subset's headers, and pointing it at the desktop
    # package would put Qt-bearing headers on the include path of an image that
    # cannot have Qt.
    cmake .. -GNinja ${lib.escapeShellArgs pkgs.logosWasmCmakeFlags} \
      -DLOGOS_MODULE_WEB=ON \
      -DCMAKE_BUILD_TYPE=Release \
      -DLOGOS_CPP_SDK_ROOT=${logosSdk} \
      -DLOGOS_PROTOCOL_ROOT=${logosProtocolWasm} \
      -DLOGOS_PROTOCOL_WASM_ROOT=${logosProtocolWasm} \
      -DCMAKE_PREFIX_PATH="${pkgs.nlohmann_json};${logosSdk};${logosProtocolWasm}" \
      -DCMAKE_FIND_ROOT_PATH="${pkgs.nlohmann_json};${logosSdk};${logosProtocolWasm}"
    ninja
    cd ..

    runHook postBuild
  '';

  env.LOGOS_MODULE_BUILDER_ROOT = "${builderRoot}";

  installPhase = ''
    runHook preInstall

    out_dir=$out/${config.name}_web
    mkdir -p "$out_dir"

    cp build-web/web/${stem}.js "$out_dir/${stem}.js"

    # THE IMAGE, TAKEN BACK OUT OF THE GLUE. -sSINGLE_FILE embeds the wasm as a
    # base64 literal and deletes the file, so this is where the shipped image
    # comes from. Extracting rather than linking a second time is deliberate:
    # wasm-opt minifies export names per link, so a separately-linked .wasm
    # would be a DIFFERENT image that the shipped glue could not run — a decoy
    # that weighs about the right amount.
    #
    # `AGFzbQ` is base64 for the \0asm magic, which pins the match to the wasm
    # payload rather than to any other base64 literal emscripten may embed.
    payload=$(grep -o 'base64Decode("AGFzbQ[A-Za-z0-9+/=]*")' "$out_dir/${stem}.js" \
              | head -1 | sed 's/^base64Decode("//; s/")$//')
    if [ -z "$payload" ]; then
      echo "could not find the embedded wasm image in ${stem}.js;" >&2
      echo "  emscripten's -sSINGLE_FILE embedding changed shape." >&2
      exit 1
    fi
    printf '%s' "$payload" | base64 -d > "$out_dir/${stem}_image.wasm"

    # The Worker, with the two names the build decided substituted in. A
    # template rather than a generated file so the JS stays readable and
    # reviewable in the repo; the substitutions are a filename and an
    # -sEXPORT_NAME, both of which the build owns.
    substitute ${builderRoot}/wasm/logos-wasm-worker.js "$out_dir/logos-wasm-worker.js" \
      --replace-fail LOGOS_WASM_GLUE_JS ${stem}.js \
      --replace-fail LOGOS_WASM_FACTORY LogosWasmModule

    wasm_bytes=$(wc -c < "$out_dir/${stem}_image.wasm" | tr -d ' ')

    substitute ${builderRoot}/wasm/loader.html "$out_dir/index.html" \
      --replace-fail '@MODULE@' '${config.name}' \
      --replace-fail '@WORKER_JS@' 'logos-wasm-worker.js' \
      --replace-fail '@WASM_BYTES@' "$wasm_bytes"

    cp ${manifestFile} "$out_dir/manifest.json"

    # WHAT THE BUILD MEASURED. Slice 26 asks for the wasm size and the cold
    # instantiate time to be logged; the second is a runtime fact the image
    # measures for itself and the page prints, and this is the first — a build
    # fact, recorded where a CI job or a size-regression gate can read it without
    # running a browser.
    glue_bytes=$(wc -c < "$out_dir/${stem}.js" | tr -d ' ')
    printf '{"module":"%s","version":"%s","wasmBytes":%s,"glueBytes":%s,"entry":"index.html","worker":"logos-wasm-worker.js","glue":"%s","image":"%s"}\n' \
      '${config.name}' '${config.version}' "$wasm_bytes" "$glue_bytes" \
      '${stem}.js' '${stem}_image.wasm' > "$out_dir/wasm-host.json"

    echo "logos-module-builder: ${config.name} web variant — wasm $wasm_bytes bytes"

    runHook postInstall
  '';

  # ── the gate ───────────────────────────────────────────────────────────────
  #
  # A `web` variant that installs is not yet a `web` variant that LOADS. Three
  # things have to be true of the bytes, and each has failed in a way the build
  # could not see:
  #
  #   1. THE IMAGE IS WASM. A toolchain file that did not take produces a
  #      perfectly good native executable and a .js beside it.
  #   2. THE GLUE CARRIES THE IMAGE. Without -sSINGLE_FILE the glue fetches a
  #      sibling .wasm, and a file:// page cannot — which fails in a webview, at
  #      load, with nothing but a 30-second timeout to show for it.
  #   3. THE ENTRY DOCUMENT IS COMPLETE. The manifest names index.html; a
  #      substitution that silently did not fire leaves an @PLACEHOLDER@ in the
  #      page, which is valid HTML and a dead module.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    out_dir=$out/${config.name}_web

    head -c 4 "$out_dir/${stem}_image.wasm" | od -An -c | grep -q '\\0   a   s   m' \
      || { echo "${stem}_image.wasm is not a wasm image"; exit 1; }

    grep -q 'base64' "$out_dir/${stem}.js" \
      || { echo "${stem}.js does not carry the image: -sSINGLE_FILE did not take"; exit 1; }

    for f in index.html manifest.json logos-wasm-worker.js wasm-host.json; do
      test -s "$out_dir/$f" || { echo "$f is missing or empty"; exit 1; }
    done

    if grep -q '@[A-Z_]\+@\|LOGOS_WASM_GLUE_JS\|LOGOS_WASM_FACTORY' \
         "$out_dir/index.html" "$out_dir/logos-wasm-worker.js"; then
      echo "a template placeholder survived into the shipped variant:"
      grep -n '@[A-Z_]\+@\|LOGOS_WASM_GLUE_JS\|LOGOS_WASM_FACTORY' \
        "$out_dir/index.html" "$out_dir/logos-wasm-worker.js"
      exit 1
    fi

    grep -q '"main": *"index.html"' "$out_dir/manifest.json" \
      || { echo "the manifest does not name index.html as its entry"; exit 1; }

    runHook postInstallCheck
  '';

  meta = with lib; {
    description = "${config.description} (web variant: Wasm host + loader page)";
    platforms = platforms.unix;
  };
}
