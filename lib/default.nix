# Main entry point for logos-module-builder library
# This file exports all the builder functions.
# The actual plugin build logic is delegated to the pluginBackend (e.g. logos-plugin-qt).
#
# logos-cpp-sdk and logos-module are owned by this builder and injected into
# backends — backends never resolve these deps themselves.
{ nixpkgs, lib, logos-nix ? null, uiBackend, coreBackend, logos-plugin-qt ? null, logos-view-module, logos-view-module-runtime ? null, logos-cpp-sdk, logos-protocol ? null, logos-qt-sdk ? null, logos-module, logos-test-framework, logos-rust-sdk ? null, nix-bundle-lgx, nix-bundle-logos-module-install, logos-standalone-app, builderRoot, rust-overlay ? null }:

let
  # Import common utilities (backend-agnostic)
  common = import ./common.nix { inherit lib nix-bundle-lgx nixpkgs logos-nix; };

  # Import the metadata parser (reads metadata.json)
  parseMetadata = import ./parseMetadata.nix { inherit lib; };

  # Import the Bare module builder (the protocol-free artifact + its gate).
  # Backend-agnostic on purpose: a Bare module has no Qt plugin in it, so it is
  # built here rather than delegated to a plugin backend.
  buildBareModule = import ./buildBareModule.nix { inherit lib; };
  buildWebModule = import ./buildWebModule.nix { inherit lib; };
  # The OTHER `web` variant: a ui_qml module's QML plus its Qt-wasm view
  # backend, for the app's bundled QML runtime (ADR 0004). Its own file rather
  # than a branch in buildWebModule: the two share the LGX shape and nothing
  # else -- different toolchain, different image, different page.
  buildWebViewModule = import ./buildWebViewModule.nix { inherit lib; };

  # logos-protocol publishes the module-impl C ABI export list as
  # packages.<sys>.module-impl-abi. The Bare-module gate and the ABI tests read
  # it from there rather than keeping a copy that could go stale.
  moduleImplAbiFor = system:
    logos-protocol.packages.${system}.module-impl-abi
      or (throw ("logos-module-builder: the pinned logos-protocol predates "
        + "packages.<sys>.module-impl-abi, so the declared module-impl export "
        + "list cannot be read. Bump the logos-protocol input — the list is "
        + "published by the repo that owns the ABI precisely so no consumer "
        + "has to keep its own copy."));

  # Import the core module builder (routes to the right backend by type)
  mkLogosModule = import ./mkLogosModule.nix {
    inherit nixpkgs nix-bundle-lgx nix-bundle-logos-module-install logos-standalone-app lib;
    inherit common parseMetadata builderRoot uiBackend coreBackend buildBareModule buildWebModule moduleImplAbiFor;
    inherit logos-cpp-sdk logos-protocol logos-qt-sdk logos-module logos-test-framework logos-rust-sdk;
    inherit logos-plugin-qt;
    # The view (ui_qml) authoring flavour: source of the LogosView*.in
    # templates handed to every plugin build as LOGOS_VIEW_TEMPLATE_DIR.
    inherit logos-view-module;
    inherit rust-overlay;
  };

  # Import the shared C++ plugin build pipeline (used by mkLogosQmlModule for backend builds)
  buildCppPlugin = import ./buildCppPlugin.nix {
    inherit nixpkgs nix-bundle-lgx nix-bundle-logos-module-install lib;
    inherit common parseMetadata logos-cpp-sdk logos-protocol logos-qt-sdk logos-module uiBackend coreBackend builderRoot;
    inherit logos-plugin-qt logos-view-module;
  };

  # Import the ui_qml module builder (QML view + optional C++ backend)
  mkLogosQmlModule = import ./mkLogosQmlModule.nix {
    inherit nixpkgs nix-bundle-lgx nix-bundle-logos-module-install logos-standalone-app lib;
    inherit common parseMetadata logos-cpp-sdk logos-protocol logos-qt-sdk logos-module uiBackend coreBackend builderRoot;
    inherit logos-plugin-qt logos-view-module logos-view-module-runtime;
    inherit buildWebViewModule;
  };

  # Import sub-builders that remain backend-agnostic
  mkExternalLib = import ./mkExternalLib.nix { inherit lib common; };
  mkStandaloneApp = import ./mkStandaloneApp.nix;

  # Import the test builder
  mkLogosModuleTests = import ./mkLogosModuleTests.nix {
    inherit nixpkgs lib common parseMetadata;
    inherit logos-cpp-sdk logos-protocol logos-qt-sdk logos-plugin-qt logos-test-framework;
    # Source of logos-view-generator: a ui_qml module's unit tests run the same
    # autoCodegen the plugin build does.
    inherit logos-view-module;
  };

in {
  # Main builders
  inherit mkLogosModule;       # C++ Qt plugin modules (delegates to pluginBackend)
  inherit mkLogosQmlModule;    # ui_qml modules — QML view + optional C++ backend
  inherit mkLogosModuleTests;  # Unit tests for modules

  # Lower-level standalone app builder
  inherit mkStandaloneApp;

  # Lower-level builders for advanced use cases
  inherit mkExternalLib;
  inherit buildBareModule;     # the Bare module artifact (protocol-free)
  inherit buildWebModule;      # the `web` variant (Wasm host + loader page)
  inherit buildWebViewModule;  # the ui_qml `web` variant (QML + Qt-wasm view backend)
  inherit moduleImplAbiFor;    # logos-protocol's published module-impl ABI

  # Utilities
  inherit parseMetadata;
  inherit common;

  # The active plugin backends
  inherit uiBackend coreBackend;

  # Version info
  version = "0.2.0";
}
