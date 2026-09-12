# ui_qml module builder — QML view + optional C++ backend (process-isolated).
# Calls buildCppPlugin only when config.main is set; the resulting `combined`
# output bundles the plugin .so (when present) with the QML view directory.
{ nixpkgs, lib, common, parseMetadata, logos-cpp-sdk, logos-protocol ? null, logos-qt-sdk ? null, logos-plugin-qt ? null, logos-view-module, logos-view-module-runtime ? null, logos-module, uiBackend, coreBackend, builderRoot, buildWebViewModule, nix-bundle-lgx, nix-bundle-logos-module-install, logos-standalone-app }:

{
  # Required: Path to the module source
  src,

  # Required: Path to the metadata.json configuration file
  configFile,

  # Optional: all flake inputs — dependencies in metadata.json are resolved automatically
  flakeInputs ? {},

  # Optional: Additional flake inputs for external libraries
  externalLibInputs ? {},

  # Optional: Extra build inputs to add
  extraBuildInputs ? [],

  # Optional: Extra native build inputs to add
  extraNativeBuildInputs ? [],

  # Optional: Override any config values
  configOverrides ? {},

  # Optional: Custom preConfigure hook
  preConfigure ? "",

  # Optional: Custom postInstall hook
  postInstall ? "",

  # Optional: override the logos-standalone-app used for `nix run`.
  logosStandalone ? null,
}:

let
  metadataJson = builtins.readFile configFile;

  # Parse metadata first so we can decide whether to build a C++ backend at all.
  #
  # NO platform here, and this file is the one that most needs saying why. Three
  # of the reads below — `config.type`, `config.view`, `config.main` — happen
  # above forAllSystems and decide the flake's output SHAPE, not just its
  # contents: `hasBackend` gates whether `packages.<sys>` even has a `-lib`
  # attribute. A per-system answer for `main` would make the ATTRIBUTE NAMES
  # differ between systems, which is not something a flake can express.
  #
  # A module cannot platform-key `main` at all — resolvePlatforms refuses it in
  # `topDeferred`, on every target and with no target, so the throw arrives at
  # the overlay rather than here. That refusal replaced an earlier arrangement
  # in which `main` WAS overlay-able and this read was supposed to be the thing
  # that caught it, via resolvePlatforms.poisonField. It was not: mkLogosModule's
  # only read of `config.main` is modulePreConfigure.nix:200's legacy-interface
  # guard, which only ever throws — so a CORE module keying it sailed through
  # with no diagnostic anywhere and shipped a manifest naming a plugin that does
  # exist on the non-base targets. A guard that fires for one module type and
  # silently does not for the other is not a guard.
  #
  # The reasoning for parsing with no platform here is unaffected: `type` and
  # `view` still decide output shape, and the plugin's file EXTENSION is already
  # handled centrally by common.getPluginFilename, so there is no case a
  # per-platform `main` serves that is not better served there.
  rawConfig = parseMetadata.parseModuleConfig { json = metadataJson; platform = null; };
  config = common.recursiveMerge [ rawConfig configOverrides ];

  # The resolved config per target, rebound as `config` inside every per-system
  # closure below.
  configFor = system: common.recursiveMerge [
    (parseMetadata.parseModuleConfig {
      json = metadataJson;
      platform = parseMetadata.platformForSystem system;
    })
    configOverrides
  ];

  # ── The document the ARTIFACT carries ─────────────────────────────────────
  #
  # `configFile` is the SOURCE, overlays unapplied. Ship it and a platform-keyed
  # field is resolved for the BUILD and not for the artifact: the loader, lgpm
  # and the .lgx manifest all read the base answer. That gap is why
  # `dependencies` was a refused overlay key.
  #
  # Written from `_raw` — the RESOLVED tree, which keeps the object entry form
  # that carries an installer's version/signer constraints. The normalised
  # `config` would flatten those to names.
  #
  # Null for a module with no `platforms` anywhere: there is nothing to resolve,
  # and the source file goes on reaching the artifact byte-identically.
  hasPlatformOverlays =
    let j = builtins.fromJSON metadataJson;
    in (j ? platforms) || (builtins.isAttrs (j.nix or null) && (j.nix ? platforms));
  resolvedMetadataFileFor = pkgs: system:
    if !hasPlatformOverlays then null
    else pkgs.writeText "metadata.json" (builtins.toJSON (configFor system)._raw);

  # The same answer as a path that always exists — the source file is the
  # resolved document for a module with nothing to resolve.
  shippedMetadataFor = pkgs: system:
    let f = resolvedMetadataFileFor pkgs system;
    in if f == null then configFile else f;

  # Validate: view modules must be type "ui_qml" with a "view" field.
  # The "main" backend library is OPTIONAL — if absent, the module is QML-only and
  # is loaded directly in-process by basecamp/standalone (no ui-host process).
  _ = assert config.type == "ui_qml" || builtins.throw
    "mkLogosQmlModule: metadata.json type must be \"ui_qml\", got \"${config.type}\"";
  assert config.view != null || builtins.throw
    "mkLogosQmlModule: metadata.json must specify a \"view\" field (e.g. \"qml/Main.qml\")";
  null;

  # Whether this module has a backend C++ plugin. QML-only modules omit "main".
  hasBackend = config.main != null;

  # Delegate compilation to the shared build pipeline (only when there's a backend).
  buildCppPlugin = import ./buildCppPlugin.nix {
    inherit nixpkgs lib common parseMetadata logos-cpp-sdk logos-protocol logos-qt-sdk logos-plugin-qt logos-view-module logos-module uiBackend coreBackend builderRoot nix-bundle-lgx nix-bundle-logos-module-install;
  };

  # The iOS view framework — the same module, the same generated tree, a
  # different link. See buildViewFramework.nix.
  buildViewFramework = import ./buildViewFramework.nix { inherit lib; };

  # Imported here rather than taken as an argument: mkLogosQmlModule's caller
  # (lib/default.nix) builds mkExternalLib from the same two values.
  mkExternalLib = import ./mkExternalLib.nix { inherit lib common; };

  built =
    if hasBackend
    then buildCppPlugin {
      inherit src configFile flakeInputs externalLibInputs extraBuildInputs
              extraNativeBuildInputs configOverrides preConfigure postInstall;
    }
    else null;

  # The QML view directory is derived from the "view" field (e.g. "qml/Main.qml" -> "qml")
  viewDir = builtins.dirOf config.view;

  # The same directory as a path relative to the module's TREE. `view` is
  # relative to either the project root or src/ and both layouts are in use, so
  # this tries them in the order mkCombined does. `generate` snapshots the
  # module's own tree, so the relative answer is the same there as in src —
  # which is why the iOS view framework and the `web` variant, both of which
  # build out of the generate tree, resolve it here rather than in their
  # builders. null when neither layout has it: the two callers disagree about
  # what that means, so neither the throw nor the fallback belongs in here.
  qmlDirFor = view:
    let rel = builtins.dirOf view; in
    if view == null then null
    else if builtins.pathExists "${src}/src/${rel}" then "src/${rel}"
    else if builtins.pathExists "${src}/${rel}" then rel
    else null;

  mkStandaloneApp = import ./mkStandaloneApp.nix;

  forAllSystems = f: lib.genAttrs common.systems (system: f system);

  # pkgs accessor that works whether or not buildCppPlugin ran
  pkgsFor = system:
    if hasBackend
    then built.perSystem.${system}.pkgs
    else common.mkPkgs system;

  # Helper: create a combined derivation from a plugin lib + QML view from source.
  # Used for both default and portable variants. For QML-only modules, pluginLib is null.
  iconFiles = lib.optional (config.icon != null) (src + "/${config.icon}");

  mkCombined = system: pluginLib: suffix:
    let pkgs = pkgsFor system;
        iconInstall = pkgs.lib.concatStringsSep "\n" (map (icon: ''
          install -D -m644 ${icon} $out/lib/${config.icon}
        '') iconFiles);
    in (pkgs.runCommand "logos-${config.name}-module${suffix}" {} ''
      mkdir -p $out/lib

      ${lib.optionalString (pluginLib != null) ''
        # Copy library files (not symlinks)
        if [ -d "${pluginLib}/lib" ]; then
          cp -rL ${pluginLib}/lib/* $out/lib/
        fi
      ''}

      # Include metadata.json and icons in the output. The RESOLVED document
      # when the module has overlays — this file is what lgpm and the .lgx
      # manifest read, so shipping the source here is what made a platform-keyed
      # field resolve for the build and not for the artifact.
      cp ${shippedMetadataFor pkgs system} $out/lib/metadata.json
      ${iconInstall}

      # Copy QML view files from source.
      # C++ modules keep QML under src/ (e.g. src/qml/Main.qml);
      # QML-only modules may keep them at the project root (e.g. Main.qml or qml/Main.qml).
      # When viewDir is "." we only copy the single QML file to avoid pulling in
      # the entire project root (which would conflict with metadata.json above).
      if [ -d "${src}/src/${viewDir}" ] && [ "${viewDir}" != "." ]; then
        mkdir -p "$out/lib/${viewDir}"
        cp -r "${src}/src/${viewDir}/." "$out/lib/${viewDir}/"
        echo "Copied QML view directory from src/${viewDir}"
      elif [ -d "${src}/${viewDir}" ] && [ "${viewDir}" != "." ]; then
        mkdir -p "$out/lib/${viewDir}"
        cp -r "${src}/${viewDir}/." "$out/lib/${viewDir}/"
        echo "Copied QML view directory from ${viewDir}"
      elif [ -f "${src}/src/${config.view}" ]; then
        cp "${src}/src/${config.view}" "$out/lib/${config.view}"
        echo "Copied QML entry file from src/${config.view}"
      elif [ -f "${src}/${config.view}" ]; then
        cp "${src}/${config.view}" "$out/lib/${config.view}"
        echo "Copied QML entry file: ${config.view}"
      else
        echo "Warning: QML view '${config.view}' not found in source"
      fi

      # Auto-generate a qmldir at the entry directory declaring a unique
      # per-module URI. Qt reads this qmldir when the entry file's implicit
      # "." import loads, and uses its `module` line as the import's URI —
      # non-empty and per-module. Without this, Qt's process-global
      # composite-type name cache (keyed by (name, uri)) would let
      # same-basename types (e.g. two Card.qml files in two different
      # modules) cross-match across engines loaded in the same host process,
      # producing the "Invalid null URL" cascade
      #
      # Skipped if the author already shipped a qmldir at the entry dir.
      QMLDIR_TARGET="$out/lib/${viewDir}/qmldir"
      if [ ! -f "$QMLDIR_TARGET" ]; then
        mkdir -p "$(dirname "$QMLDIR_TARGET")"
        echo "module com.logos.module.${config.name}" > "$QMLDIR_TARGET"
        echo "Generated qmldir at ${viewDir}/qmldir (module com.logos.module.${config.name})"
      else
        echo "Author-provided qmldir at ${viewDir}/qmldir preserved"
      fi
    '') // { inherit src; version = config.version; };


  # ── the ui_qml module on iOS ──────────────────────────────────────────────
  # `nix build .#packages.aarch64-ios.view`: the SAME module as the desktop Qt
  # plugin, cross-compiled into one embedded framework that carries its Qt
  # backend and its QML and binds Qt upward into the app image. The Native
  # container loads it, the host instantiates the view object in-process (there
  # is no ui-host subprocess on a phone) and the QML renders in the host's own
  # engine.
  #
  # Only `view`, and only on the iOS keys. See buildViewFramework.nix for why
  # Android is not the same artifact, and mkLogosModule's mobileBareFor for why
  # the mobile keys carry one output rather than joining forAllSystems.
  #
  # THE GENERATED TREE COMES FROM THE BUILD PLATFORM, for the same reason the
  # mobile Bare artifact's does: `generate` is source plus everything the code
  # generators emitted, and a code generator is a host tool. The framework is a
  # cross COMPILE of the native `generate`, which also makes it byte-identical
  # in input to the desktop plugin.
  viewFrameworkFor = { androidBuildSystem }:
    common.forAllMobileSystems { inherit androidBuildSystem; }
      ({ system, pkgs, buildSystem }:
        let
          mobileConfig = configFor system;

          # A QML-only module has no .rep, no backend and no C++ at all, so
          # there is nothing to compile into a framework — it would be a QML
          # file in a Mach-O wrapper. Such a module ships its QML in the LGX
          # and the host loads it directly.
          refuseQmlOnly = throw ("logos-module-builder: module '"
            + mobileConfig.name + "' is QML-only (no `main` in metadata.json), "
            + "so it has no iOS `view` framework. A view framework IS the "
            + "module's compiled Qt backend; with no backend there is nothing "
            + "to bind Qt upward and the QML travels in the module's LGX.");

          # `view` is "qml/Main.qml" (a path relative to src/ or to the project
          # root); the framework's qrc is built from the DIRECTORY and entered
          # at the file. Resolved here rather than in CMake because this is
          # where the module's source tree is; qmlDirFor does the two-layout
          # search, and an absent directory is fatal for THIS output.
          viewDirRel = builtins.dirOf mobileConfig.view;
          viewEntry = builtins.baseNameOf mobileConfig.view;
          qmlDirRel =
            let resolved = qmlDirFor mobileConfig.view; in
            if resolved != null then resolved
            else throw ("logos-module-builder: module '" + mobileConfig.name
              + "' declares view \"" + mobileConfig.view + "\" but neither src/"
              + viewDirRel + " nor " + viewDirRel + " exists. The iOS framework "
              + "compiles that directory into its own qrc, so there is nothing "
              + "to put in it.");

          refuseExternalLibs = throw ("logos-module-builder: module '"
            + mobileConfig.name + "' cannot be built as an iOS view framework "
            + "yet: it declares nix.external_libraries ("
            + lib.concatStringsSep ", " (mkExternalLib.getExternalLibNames mobileConfig)
            + "). Those are staged into lib/ as BUILD-platform images by the "
            + "module's own `generate` step and nothing here can recompile "
            + "them — each comes from its own flake, which has to publish a "
            + "package for " + system + ".");
        in lib.optionalAttrs (pkgs.stdenv.hostPlatform.isiOS or false) {
          view =
            if !hasBackend then refuseQmlOnly
            else if mkExternalLib.hasExternalLibs mobileConfig then refuseExternalLibs
            else buildViewFramework {
              inherit pkgs builderRoot;
              config = mobileConfig;
              generatedSrc = built.perSystem.${buildSystem}.moduleGenerate;
              # Every one of these is compiled against and none is linked, so
              # the BUILD platform's prefix is the honest answer — there is
              # nothing in a header-only prefix to cross-compile.
              logosSdk = logos-cpp-sdk.packages.${buildSystem}.default;
              logosQtSdk = logos-qt-sdk.packages.${buildSystem}.default;
              logosQtHost = logos-plugin-qt.packages.${buildSystem}.logos-qt-host;
              logosProtocol = logos-protocol.packages.${buildSystem}.default;
              logosModule = logos-module.packages.${buildSystem}.default;
              viewTemplates = logos-view-module.packages.${buildSystem}.logos-view-templates;
              viewInclude = logos-view-module.packages.${buildSystem}.include;
              gateScript = builderRoot + "/scripts/logos-view-gate.sh";
              qmlDir = qmlDirRel;
              qmlEntry = viewEntry;
            };
        });

  viewFrameworkPackages = viewFrameworkFor {
    androidBuildSystem = common.defaultAndroidBuildSystem;
  };

  # ── the `web` variant ───────────────────────────────────────────────────────
  #
  # `nix build .#web` on a view module: its QML, plus a Qt-for-WebAssembly image
  # hosting its `.rep` backend over QtRO on a MessagePort, laid out as an LGX
  # `web` variant for the app's bundled QML runtime to load (ADR 0004, slice 27).
  # A ui_qml module's third artifact, beside the desktop plugin and the iOS view
  # framework, and cut from the same `generate` tree as both.
  #
  # The directory this variant ships, resolved against the source tree exactly
  # as the iOS view framework's is. null — no `view`, or neither layout has its
  # directory — is not fatal here: it is one of the six things below that turn
  # the `web` output off.
  webViewQmlDir = qmlDirFor config.view;

  # SIX THINGS HAVE TO BE TRUE, and each absence is a real state rather than an
  # error: the module has a C++ backend at all, it DECLARED one that is
  # separable from its plugin (`web.view_backend` — see parseMetadata for why it
  # cannot be derived), it has a `view` document whose directory is on disk, the
  # pinned logos-nix publishes a Qt for WebAssembly, the pinned
  # logos-view-module-runtime publishes the wasm half this image links, and the
  # pinned logos-protocol publishes the web transport behind it. Any missing
  # means no `web` output on this module, which is what a pin rollout looks like
  # from here.
  webViewFor = system:
    let
      pkgs = pkgsFor system;
      cfg = configFor system;
      qtWasm = common.qtWasmFor system;
      webRuntimeWasm =
        if logos-view-module-runtime == null then null
        else (logos-view-module-runtime.packages.${system} or {}).qml-runtime-wasm or null;
      logosProtocolWasm =
        if logos-protocol == null then null
        else (logos-protocol.packages.${system} or {}).logos-protocol-wasm or null;
    in
    if !hasBackend
       || cfg.web_view_backend == null
       || webViewQmlDir == null
       || qtWasm == null
       || webRuntimeWasm == null
       || logosProtocolWasm == null
    then null
    else buildWebViewModule {
      inherit pkgs builderRoot qtWasm webRuntimeWasm logosProtocolWasm;
      inherit extraNativeBuildInputs extraBuildInputs;
      config = cfg;
      generatedSrc = built.perSystem.${system}.moduleGenerate;
      qmlDir = webViewQmlDir;
      qmlEntry = builtins.baseNameOf cfg.view;
    };

  # Package outputs
  packages = forAllSystems (system:
    let
      config = configFor system;
      moduleLib =
        if hasBackend then built.perSystem.${system}.moduleLib else null;
      moduleLibPortable =
        if hasBackend then built.perSystem.${system}.moduleLibPortable else null;

      combined = mkCombined system moduleLib "";
      combinedPortable =
        if moduleLibPortable != null
        then mkCombined system moduleLibPortable "-portable"
        else null;

      webView = webViewFor system;

    in {
      # Default: lib/ layout for both backend and QML-only modules.
      default = combined;

      # Buildable launcher: same wrapper `nix run` uses (dependency modules and
      # all), but as a package so it lands in ./result/bin. Build it once, then
      # relaunch directly — with DEV_QML_PATH set, QML edits need no rebuild at
      # all, and the app hot-reloads them on save.
      #
      # DEV_QML_PATH is auto-detected from the working directory, so:
      #   nix build .#ui-dev
      #   ./result/bin/run-logos-standalone-ui
      ui-dev = mkStandaloneApp {
        pkgs         = pkgsFor system;
        standalone   = resolvedStandalone.packages.${system}.default;
        plugin       = combined;
        metadataFile = configFile;
        dirName      = "logos-${config.name}-plugin-dir";
        format       = if hasBackend then "qt-plugin" else "qml";
        moduleDeps   = common.collectAllModuleDeps system flakeInputs config.dependencies;
        asPackage    = true;
      };
    } // lib.optionalAttrs hasBackend {
      "${config.name}-lib" = moduleLib;
      lib = moduleLib;

      # Ready-to-build codebase: all code generators run, emitted as a source
      # tree (nix build .#generate). Only for modules with a C++ backend —
      # QML-only modules have no generators to run.
      generate = built.perSystem.${system}.moduleGenerate;
      "${config.name}-generate" = built.perSystem.${system}.moduleGenerate;
    } // lib.optionalAttrs (moduleLibPortable != null) {
      "${config.name}-lib-portable" = moduleLibPortable;
      lib-portable = moduleLibPortable;
    } // lib.optionalAttrs (webView != null) {
      # The same output NAME a headless module's Bare Wasm host gets from
      # mkLogosModule, and they can never collide: the two builders are chosen
      # by module type. One name because a container installing a `web` variant
      # does not care which kind it is — the manifest's `logos_web_runtime`
      # says.
      web = webView;
      "${config.name}-web" = webView;
    }
  );

  # LGX packages — bundle the combined output (plugin + QML), not just moduleLib.
  # This ensures the QML view directory is included in the .lgx package so that
  # lgpm install and mkStandaloneApp LGX extraction both have the QML files.
  lgxPackages = forAllSystems (system:
    let
      bundleLgx = nix-bundle-lgx.bundlers.${system}.default;
      bundleLgxPortable = nix-bundle-lgx.bundlers.${system}.portable;
      installDev = nix-bundle-logos-module-install.bundlers.${system}.dev;
      installPortable = nix-bundle-logos-module-install.bundlers.${system}.portable;

      moduleLib =
        if hasBackend then built.perSystem.${system}.moduleLib else null;
      moduleLibPortable =
        if hasBackend then built.perSystem.${system}.moduleLibPortable else null;

      combined = mkCombined system moduleLib "";
      # Use the portable-linked plugin + QML for portable bundles when available
      combinedForPortable =
        if moduleLibPortable != null
        then mkCombined system moduleLibPortable "-portable"
        else combined;
    in {
      lgx = bundleLgx combined;
      install = installDev combined;
      lgx-portable = bundleLgxPortable combinedForPortable;
      install-portable = installPortable combinedForPortable;
    }
  );

  # Resolve the standalone app: explicit override > built-in from module-builder
  resolvedStandalone =
    if logosStandalone != null then logosStandalone
    else logos-standalone-app;

  apps = forAllSystems (system:
    let
      pkgs = common.mkPkgs system;
      config = configFor system;
      # Collect all module dependencies (direct + transitive) for bundling
      allDeps = common.collectAllModuleDeps system flakeInputs config.dependencies;
    in {
      default = mkStandaloneApp {
        inherit pkgs;
        standalone   = resolvedStandalone.packages.${system}.default;
        plugin       = packages.${system}.default;
        metadataFile = configFile;
        dirName      = "logos-${config.name}-plugin-dir";
        format       = if hasBackend then "qt-plugin" else "qml";
        moduleDeps   = allDeps;
      };
    }
  );

  # Auto-detect UI integration tests: scan tests/ for .mjs files and produce
  # an integration-test package using logos-standalone-app's mkPluginTest.
  testsDir = src + "/tests";
  hasTestsDir = builtins.pathExists testsDir;
  testFiles =
    if hasTestsDir then
      let
        entries = builtins.attrNames (builtins.readDir testsDir);
        mjsFiles = builtins.filter (name: lib.hasSuffix ".mjs" name) entries;
      in map (name: testsDir + "/${name}") mjsFiles
    else [];
  hasUiTests = testFiles != [];

  integrationTestPackages = lib.optionalAttrs hasUiTests (forAllSystems (system:
    let
      mkPluginTest = resolvedStandalone.lib.${system}.mkPluginTest;
      pkgs = pkgsFor system;
      config = configFor system;
      allDeps = common.collectAllModuleDeps system flakeInputs config.dependencies;
    in {
      integration-test = mkPluginTest {
        inherit pkgs testFiles;
        pluginPkg = packages.${system}.default;
        moduleDeps = allDeps;
        name = "${config.name}-integration-test";
      };

      # Expose logos-qt-mcp so modules can build the test framework locally:
      #   nix build .#test-framework -o result-mcp
      test-framework = resolvedStandalone.packages.${system}.logos-qt-mcp;
    }
  ));

  # Merge view-module-specific LGX outputs and integration tests into packages
  mergedPackages = lib.mapAttrs (system: sysPkgs:
    sysPkgs // (lgxPackages.${system} or {}) // (integrationTestPackages.${system} or {})
  ) packages;

in {
  # The iOS keys are MERGED rather than folded into forAllSystems: they carry
  # `view` and nothing else. See viewFrameworkFor above.
  packages = mergedPackages // viewFrameworkPackages;
  checks = lib.mapAttrs (_: sysPkgs: {
    integration-test = sysPkgs.integration-test;
  }) integrationTestPackages;
  devShells =
    if hasBackend
    then built.devShells
    else lib.genAttrs common.systems (system:
      { default = (pkgsFor system).mkShell {}; });
  inherit apps config;
  # The RESOLVED config per target — see the `configFor` comment above.
  configFor = lib.genAttrs common.systems configFor;
  inherit metadataJson;
}
