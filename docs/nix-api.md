# Nix API Reference

Complete reference for logos-module-builder Nix functions.

## Overview

The logos-module-builder exposes its API via `lib` attribute:

```nix
logos-module-builder.lib.mkLogosModule { ... }     # core + legacy UI widgets
logos-module-builder.lib.mkLogosQmlModule { ... }  # ui_qml (QML view + optional C++ backend)
```

## mkLogosModule

Builder for core C++ modules and legacy UI widget modules. For `ui_qml` modules (QML view with optional C++ backend), use `mkLogosQmlModule` instead.

### Syntax

```nix
mkLogosModule {
  src = ./.;
  configFile = ./metadata.json;

  # Optional
  flakeInputs = inputs;        # Pass all flake inputs — deps auto-resolved
  externalLibInputs = { };     # For external C libs fetched as flake inputs
  extraBuildInputs = [ ];
  extraNativeBuildInputs = [ ];
  configOverrides = { };
  preConfigure = "";           # String or function: { externalLibs }: "..."
  postInstall = "";
  logosStandalone = null;      # Override logos-standalone-app for `nix run`
}
```

### Parameters

#### src (required)
Path to the module source directory.

```nix
src = ./.;
```

#### configFile (required)
Path to the `metadata.json` configuration file.

```nix
configFile = ./metadata.json;
```

#### flakeInputs (optional)
All flake `inputs`. The builder automatically filters this by `dependencies` in `metadata.json` to resolve module dependencies — you don't need to pass them individually.

```nix
outputs = inputs@{ logos-module-builder, ... }:
  logos-module-builder.lib.mkLogosModule {
    src = ./.;
    configFile = ./metadata.json;
    flakeInputs = inputs;  # dependencies[] in metadata.json are resolved automatically from input names
  };
```

#### externalLibInputs (optional)
Flake inputs for external C/C++ libraries. Keys must match library names in `metadata.json`'s `nix.external_libraries`. For pre-built vendor libraries, use `vendor_path` in `metadata.json` instead — no `externalLibInputs` needed.

The builder auto-detects whether the resolved input is a Nix derivation (via `lib.isDerivation`). If it is, the derivation is used directly. If it's raw source, it's built with `make` / custom command. No flags needed in `metadata.json`.

**Simple format** — bare flake input, resolves to `packages.${system}.default`:

```nix
externalLibInputs = {
  gowalletsdk = inputs.go-wallet-sdk;
};
```

**Structured format** — per-variant package mappings. When any entry uses this format, the builder produces both `lib` and `lib-portable` outputs, each linked against the corresponding external lib variant. The `lgx` output bundles `lib` and `lgx-portable` bundles `lib-portable`.

```nix
externalLibInputs = {
  logos_pm = {
    input = inputs.logos-package-manager;
    packages = {
      default = "lib";           # → input.packages.${system}.lib
      portable = "lib-portable"; # → input.packages.${system}.lib-portable
    };
  };
};
```

#### extraBuildInputs (optional)
Additional Nix packages to add to `buildInputs`.

```nix
extraBuildInputs = with pkgs; [
  openssl
  libsodium
];
```

#### extraNativeBuildInputs (optional)
Additional Nix packages to add to `nativeBuildInputs` (build-time only).

```nix
extraNativeBuildInputs = with pkgs; [
  rustc
  cargo
];
```

#### configOverrides (optional)
Override values from `metadata.json`. Merged recursively.

```nix
configOverrides = {
  version = "2.0.0";
  nix_packages = {
    build = [ "extra-package" ];
  };
};
```

#### metadata.json: `interface`, `codegen`, and Go static libs (automatic)

The builder prepends steps before your `preConfigure`:

- **`"interface": "universal"`** — derives everything from `src/<name>_impl.h` (impl class derived from the module name, e.g. `accounts_module` → `AccountsModuleImpl`) in three steps:

  1. `logos-cpp-generator --header-to-lidl` → `generated_code/<name>.lidl`, the contract (also the events sidecar dependents' typed-event codegen reads)
  2. `logos-qt-host-generator --lidl … --backend cdylib` → `<name>_cdylib_glue.{h,cpp}`, the Qt plugin `logos_host` loads
  3. `logos-cpp-generator --lidl … --backend cdylib` → `<name>_module_impl.cpp`, `<name>_types.h` (and `<name>_events_cdylib.cpp` when the header declares `logos_events:`), the Qt-free C-ABI wrapper around the impl class

  (A single `logos-cpp-generator --from-header --backend qt` call used to do all
  of this; `--backend qt` no longer exists.)

  Optional overrides:

  ```json
  "interface": "universal",
  "codegen": {
    "impl_header": "src/custom_impl.h",
    "impl_class": "CustomImpl"
  }
  ```

  > **Method docs:** a comment directly above a method's declaration becomes that method's
  > `description`, carried in `getMethods()` and shown by `lm methods`, `logoscore module-info`,
  > and Basecamp's Methods list:
  > ```cpp
  > /// Processes the input and returns a result.
  > QString doSomething(const QString& input);
  > ```

- **`"interface": "universal"` + `"type": "ui_qml"`** (handled by `mkLogosQmlModule`) — for a C++ UI backend, `"codegen": { "rep": "src/<name>.rep" }` names the Qt Remote Objects view contract; `repc` runs on it and the `*Backend` class derives the generated `<RepClass>SimpleSource`. The `*Plugin`/`*Interface` glue is still generated.

- **External libraries** — `logos-plugin-qt` already copies flake-built externals into `lib/` before your hook; you usually do **not** need to `cp` them in `preConfigure`.

- **`go_build: true`** on an `nix.external_libraries` entry — passes `-DLOGOS_MODULE_GO_STATIC_LIBS=…` to CMake so `LogosModule.cmake` links the static archive with whole-archive / `-force_load` as needed.

`LOGOS_MODULE_BUILDER_ROOT` always points at **this** flake’s source — both entry points (`mkLogosModule` and `buildCppPlugin`) set it unconditionally, and evaluation throws if `cmake/LogosModule.cmake` is missing from it. That file is the only copy: `logos-plugin-qt` used to ship a second one, and because the override used to be conditional the two were selected by module *type* (every `ui_qml` plugin configured with the backend’s copy, every core module with this one). `logos_module()` echoes the file it was read from at configure time so a future fork is visible in the log.

#### preConfigure (optional)
Extra shell commands (or a function) appended **after** the automatic codegen / setup above.

**String form** — plain shell commands:

```nix
preConfigure = ''
  echo "Running custom preConfigure"
  ./scripts/generate-something.sh
'';
```

**Function form** — receives `{ externalLibs }` with resolved store paths keyed by library name:

```nix
preConfigure = { externalLibs }: ''
  # Only when you need something beyond the defaults
  echo "extra step using ${externalLibs.mylib}"
'';
```

#### postInstall (optional)
Shell commands to run after installation.

```nix
postInstall = ''
  # Custom post-install
  mkdir -p $out/share
  cp extra-files/* $out/share/
'';
```

#### logosStandalone (optional)
Override the `logos-standalone-app` used for `nix run`. By default, `logos-module-builder` bundles `logos-standalone-app` internally and automatically wires up `apps.default` for UI modules (`"type": "ui"` or QML modules). You only need this parameter if you want to use a custom build of `logos-standalone-app`.

```nix
logosStandalone = my-custom-standalone-app;
```

### Return Value

Returns an attribute set with:

```nix
{
  packages = {
    <system> = {
      default = <combined package>;
      <name>-lib = <library package>;
      <name>-include = <headers package>;
      lib = <library package>;
      include = <headers package>;
      lgx = <lgx package>;              # always included
      lgx-portable = <portable lgx>;    # always included
      install = <dev install package>;  # always included
      install-portable = <portable install package>;  # always included

      # Only for `interface: "cdylib"` and core `interface: "universal"` modules:
      bare = <Bare module artifact>;          # also under packages.aarch64-ios,
      <name>-bare = <Bare module artifact>;   # .aarch64-ios-simulator, .aarch64-android

      # Only when externalLibInputs uses structured format with variants:
      <name>-lib-portable = <portable library package>;
      lib-portable = <portable library package>;
    };
  };

  devShells = {
    <system> = {
      default = <dev shell>;
    };
  };

  apps = { ... };  # only for type="ui" (legacy widget modules)

  config = <parsed config>;
  metadataJson = <metadata.json content>;
}
```

### The `bare` output — the Bare module artifact

`nix build .#bare` produces the **Bare module**: the module implementation
(a Qt-free C++ impl class, or a Rust core) linked so that

- every module-impl C ABI export logos-protocol declares in
  `cpp/logos_module_impl.h` is **defined** — that is the entire surface a
  no-Qt host drives it through. The list is read from logos-protocol's
  published `packages.<sys>.module-impl-abi/exports.txt`, so it grows with the
  protocol instead of being restated here;
- the logos-protocol consumer ABI (`lp_*`) is left **undefined**, for the host
  image to supply at load time;
- **no Qt**, no generated Qt-plugin glue and no logos-protocol archive is
  linked in.

It is the build shape shared by the iOS embedded framework and the Wasm host.
Desktop targets: `<name>_bare.dylib` / `<name>_bare.so` under `lib/`; the
mobile targets are below.

Who gets one: exactly the modules `parseMetadata` marks
`packaged_as_cdylib` — `interface: "cdylib"` modules (C++ or `codegen.rust`)
and core `interface: "universal"` modules, i.e. those whose own image already
exports the module-impl C ABI. A `type: ui_qml` view backend derives a Qt
SimpleSource and an `interface: "legacy"` module is hand-written Qt; both are
Qt plugin objects holding a `LogosAPI`, so neither exposes a `bare` attribute
at all.

The artifact is cut from the module's own `generate` output — the tree after
every code generator has run — so `bare` and the plugin compile the same
sources; `bare` just leaves the Qt ones out. Building `bare` never builds the
plugin.

**The gate.** Every `bare` derivation runs `scripts/logos-bare-gate.sh` in its
`postFixup` and fails if the linker did not agree with the description above:
a missing module-impl ABI export, any Qt symbol (mangled or moc-generated), a
**defined** `lp_*` (meaning the logos-protocol archive was linked), a
logos-protocol internal symbol, or a Qt / logos-protocol library in the load
commands (`otool -L` on Mach-O, `DT_NEEDED` on ELF). Each failure names the
offending symbol or library. The gate is a plain script and can be run by hand:

```bash
nix build .#bare
LOGOS_MODULE_IMPL_EXPORTS=$(nix build --no-link --print-out-paths \
  'github:logos-co/logos-protocol#module-impl-abi')/exports.txt \
  ./scripts/logos-bare-gate.sh result/lib/my_module_bare.dylib
```

`LOGOS_MODULE_IMPL_EXPORTS` is required: the gate refuses to run without a
non-empty export list rather than pass an artifact against an ABI it never
checked.

The gate runs in `postFixup`, not in `installCheckPhase`, and that is
load-bearing rather than stylistic: nixpkgs computes `doInstallCheck &&
buildPlatform.canExecute hostPlatform`, so under any cross build the phase is
skipped without a word. This gate reads a symbol table and never runs the
artifact, so there is nothing for that rule to protect against here — and the
shape it would otherwise produce is the worst one available, a mobile Bare
module that reports itself gated and was not.

The gate picks its reader off the ARTIFACT's magic bytes, not off `uname`, so
it reads an Android `.so` correctly while running on a Mac; hand it a
`.framework` directory and it resolves the Mach-O inside.

#### The mobile keys

The same `bare` output, cross-compiled:

```bash
nix build .#packages.aarch64-ios.bare            # iPhone / iPad
nix build .#packages.aarch64-ios-simulator.bare  # the simulator
nix build .#packages.aarch64-android.bare        # arm64-v8a
```

These three keys are **pseudo-systems** (a cross derivation's `system` is its
BUILD platform) and they carry `bare` and nothing else — there is no Qt plugin
host on a phone, which is the reason the Bare module exists. They appear only
when the builder's `logos-nix` input has the mobile targets.

| target | artifact |
|---|---|
| `aarch64-ios`, `aarch64-ios-simulator` | `Library/Frameworks/<name>_bare.framework/` — a flat embedded framework with an `Info.plist`, install_name `@rpath/<name>_bare.framework/<name>_bare`. Copy it into `<App>.app/Frameworks/` with Code Sign On Copy. |
| `aarch64-android` | `lib/lib<name>_bare.so`, SONAME to match — an APK carries only `lib*.so`. |

`_bare` survives into the installed filename on every platform on purpose:
liblogos identifies a Bare module by that stem suffix.

The generated sources come from the BUILD platform's `generate` output: a code
generator is a host tool, so the mobile artifact is a cross COMPILE of exactly
the tree the native one compiles. Its one target-specific corner is `lib/`,
where the generate step staged a build-platform archive.

**A `codegen.rust` core crosses.** The crate is recompiled for the target and
staged over the build-platform archive `generate` left in `lib/`, so a Rust
module has the same three mobile artifacts a C++ one does. The toolchain is a
rust-overlay one that RUNS on the builder with the target's std added — nixpkgs'
cross `rustPlatform` would have to come from the target package set, which for
iOS has no working stdenv at all. `logos-nix`'s `lib.mobileRustTargets` names
the cargo triple, and the linker / `cc-rs` / SDK wiring arrives as
`pkgs.logosRustCrossSetup`, contributed by both mobile overlays under the same
name. `packages.<buildSystem>.rust-crate-src` is published for this: the
scaffold is generated once on the build platform and all four targets compile
that same crate.

**An external library crosses when its consumer says how.** `generate` staged
each `nix.external_libraries` entry into `lib/` as a build-platform image, and
nothing in the builder can recompile one — it comes from its own flake. So the
module's flake answers, per target, with `mobilePackages` on the
`externalLibInputs` entry:

```nix
externalLibInputs.libp2p = {
  input = inputs.libp2p;              # the native half, as before
  packages.default = "cbind";
  # { system, pkgs, buildSystem } -> a derivation laid out lib/ + include/,
  # built for that mobile system, or null to decline it.
  mobilePackages = { system, pkgs, buildSystem }:
    import ./nix/mobile-cbind.nix { inherit pkgs; target = system; /* … */ };
};
```

A function rather than an attrset keyed by system, and the reason is not style:
`pkgs` is the target package set the bare build is already using, and for
Android its BUILD platform is a parameter (`androidBuildSystem`) — an attrset
would have to pick one, and a Mac cannot realise a derivation whose build
platform is `x86_64-linux`. Handing `pkgs` over also means the module's flake
never instantiates a second copy of it.

The result is staged OVER the build-platform image, which is deleted first:
`_logos_find_external_lib` prefers a shared library to a static one, so a
surviving `.dylib` would win. A target build should be STATIC — a Bare module on
a phone carries every third-party library inside its own image, and on Android
an unbundled soname fails the `DT_NEEDED` gate outright. `logos-libp2p-module`'s
`nix/mobile-cbind.nix` is the worked example (nim cross-compile + two vendored C
libraries, merged into one archive).

**What still does not cross**, refused by name at eval rather than left to the
linker:

- an `nix.external_libraries` entry with no `mobilePackages` build for the
  target. Left to the linker it surfaces as `ld: building for 'iOS-simulator',
  but linking in dylib ... built for 'macOS'` forty lines into a link command,
  naming neither the library's owner nor the fix;
- a Go core, for the same reason with no cross toolchain wired in.

And one platform fact: `packages.aarch64-android` is built from logos-nix's
canonical Android build platform (`x86_64-linux`), which a Mac cannot realise.
For the other one use `legacyPackages.<buildSystem>.mobile.aarch64-android.bare`
— e.g. `legacyPackages.aarch64-darwin.mobile.aarch64-android.bare`.

**The Android gate.** On top of the Bare-module gate, every `aarch64-android`
artifact is run through logos-nix's `logos-android-dt-needed-gate`: a
`DT_NEEDED` soname that is neither shipped beside the artifact nor guaranteed
by Android at the app's API level fails the build rather than the phone (where
it surfaces as an `UnsatisfiedLinkError` naming one soname and none of the
reason). Two names are allowed explicitly — `libc++_shared.so`, because Qt's
Android platform refuses any other STL and the Native container's APK therefore
packages it, and `liblogos_protocol.so`, the empty host-ABI stub's soname the
host image supplies.

### The `view` output — a `ui_qml` module as an iOS framework

```bash
nix build .#packages.aarch64-ios.view            # iPhone / iPad
nix build .#packages.aarch64-ios-simulator.view  # the simulator
```

The same `type: ui_qml` module as the desktop Qt plugin — same sources, same
`generate` tree — built as ONE embedded framework carrying its Qt backend, the
typed source AND replica of its `.rep`, and its QML compiled into the image's
own `qrc`. Nothing is linked into it: Qt, logos-qt-host (`LogosAPI`) and the
`lp_*` C ABI are all left **undefined** and resolve upward into the app image
at `dlopen`, which is what ADR 0006 asks for and what the
`ios-dlopen-bare-module` spike measured (Level 2).

Layout: `Library/Frameworks/<name>_view.framework/{<name>_view,Info.plist}`,
install_name `@rpath/<name>_view.framework/<name>_view` — copy it into
`<App>.app/Frameworks/` with Code Sign On Copy. The module's `metadata.json`
travels beside it at `share/logos/<name>/metadata.json`, because that flat
directory has no room for a manifest and the host has to carry one.

**The C edge.** `<App>.app/Frameworks/` is flat and read-only, there is no
plugin directory to scan, and a Store app does not take the `QPluginLoader`
path. The host reaches the image with `dlopen` + `dlsym` and nothing else:

| symbol | answers |
|---|---|
| `logos_view_module_abi_version()` | `1` today; the host refuses a number it does not know |
| `logos_view_module_name()` / `_version()` | the module's identity |
| `logos_view_module_qml_url()` | `qrc:/logos/<name>/<entry>` — inside this image |
| `logos_view_module_create()` | the plugin object, which the host `qobject_cast`s to `LogosViewPlugin` |
| `logos_view_module_acquire_replica(node)` | the typed replica, from the host's `QRemoteObjectNode` |
| `qt_plugin_instance()` | Qt's own, emitted by moc from `Q_PLUGIN_METADATA` |

The replica entry point is in the framework because on a phone there is no
separate `<name>_replica_factory` plugin file to load; on the desktop that
second plugin is still exactly what it was.

**Who gets one.** A `ui_qml` module with a C++ backend (`main` in
`metadata.json`) and a `.rep`. A QML-only module is refused by name — a view
framework IS the compiled backend, and with no backend there is nothing to
bind Qt upward; its QML travels in the module's LGX. A module declaring
`nix.external_libraries` is refused for the same reason the mobile `bare`
output refuses it.

**iOS only.** `packages.aarch64-android` carries no `view` attribute. Android's
Qt is a set of shared objects, so the same module there is a `.so` naming
`libQt6Core_arm64-v8a.so` and friends in `DT_NEEDED` — a different artifact
with a different gate.

**The gate.** Every `view` derivation runs `scripts/logos-view-gate.sh` in its
`postFixup` (`postFixup` and not `installCheckPhase`, for the reason spelled
out under `bare` above). It fails on: a missing entry point from the table; a
QtCore marker symbol DEFINED in the image, or none of them undefined; a Qt
symbol EXPORTED beyond the module's own edge; a defined `lp_*` or
logos-qt-host symbol; a Qt / logos-protocol library in the load commands; or
no `qrc:/logos/...` URL in the bytes. It is a plain script:

```bash
nix build .#packages.aarch64-ios-simulator.view
./scripts/logos-view-gate.sh result/Library/Frameworks/my_view.framework
```

**Qt, compiled against and not linked**, is the whole trick and it has one
sharp edge in CMake. A target that does not link `Qt6::Core` gets none of Qt's
usage requirements: not the include directories (transitively — `Qt6::Qml`
alone does not name `QtQmlIntegration`'s), not `cxx_std_17`, and not an
AUTOMOC target at all, because CMake decides whether to run AUTOMOC by asking
which Qt the target LINKS. `logos_view_framework()` walks the `Qt6::*`
interface graph by hand, skipping `$<LINK_ONLY:...>` entries (those are Qt's
own build settings — `-fno-exceptions`, `-Werror` — which no consumer is
compiled with), and sets `QT_MAJOR_VERSION` on the target so AUTOMOC runs.
Without that last line the plugin class has no moc, the link still succeeds
(`-undefined dynamic_lookup` swallows the missing vtable) and the image has no
`qt_plugin_instance` — which is what the gate's first clause catches.

### Example

```nix
{
  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder";
    waku_module.url = "github:logos-co/logos-waku-module";  # input name must match dependency name
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
      preConfigure = ''
        echo "Building my module..."
      '';
    };
}
```

---

## mkLogosQmlModule

Builder for `ui_qml` modules — QML view with an optional C++ backend. Validates that `metadata.json` has `"type": "ui_qml"` and a non-null `"view"` field. When `"main"` is declared, compiles the C++ backend via `buildCppPlugin` and bundles it alongside the QML view. When `"main"` is absent, produces a QML-only output (no compilation). Always wires `apps.default`.

### Syntax

```nix
mkLogosQmlModule {
  src = ./.;
  configFile = ./metadata.json;

  # Optional — same parameters as mkLogosModule
  flakeInputs = inputs;
  externalLibInputs = { };
  extraBuildInputs = [ ];
  extraNativeBuildInputs = [ ];
  configOverrides = { };
  preConfigure = "";
  postInstall = "";
  logosStandalone = null;
}
```

### Return Value

```nix
{
  packages = {
    <system> = {
      default = <combined plugin (if backend) + QML view>;
      <name>-lib = <library package>;       # only when backend present
      lib = <library package>;              # only when backend present
      lgx = <lgx package>;
      lgx-portable = <portable lgx>;
      install = <dev install package>;
      install-portable = <portable install package>;
    };
  };

  devShells = {
    <system> = {
      default = <dev shell>;
    };
  };

  apps = {
    <system> = {
      default = <logos-standalone-app runner>;  # always present
    };
  };

  config = <parsed config>;
  metadataJson = <metadata.json content>;
}
```

### Example (with backend)

```nix
{
  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder";
    calc_module.url = "github:logos-co/logos-tutorial?dir=logos-calc-module";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosQmlModule {
      src = ./.;
      configFile = ./metadata.json;  # type: ui_qml, main: "calc_ui_cpp_plugin", view: "qml/Main.qml"
      flakeInputs = inputs;
    };
}
```

### Example (QML-only, no backend)

```nix
{
  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosQmlModule {
      src = ./.;
      configFile = ./metadata.json;  # type: ui_qml, view: "Main.qml" (no "main")
      flakeInputs = inputs;
    };
}
```

---

## parseMetadata

Parse a `metadata.json` file.

### parseModuleConfig

Parse JSON content and apply defaults, resolving any `platforms` overlays for
the given target.

```nix
let
  parseMetadata = logos-module-builder.lib.parseMetadata;
  config = parseMetadata.parseModuleConfig {
    json     = builtins.readFile ./metadata.json;
    platform = parseMetadata.platformForSystem system;   # inside forAllSystems
  };
in {
  inherit (config) name version type category description;
  inherit (config) dependencies nix_packages external_libraries cmake;
}
```

`platform` is **required**. It may be `null`, which means "no target known" —
the parse then succeeds, but any field a `platforms` overlay declares throws
when read instead of quietly returning the base value. That is the shape the
builders use above `forAllSystems`, where only platform-invariant fields
(`name`, `version`, `type`, `interface`) are needed.

### platformForSystem

Turn a nix system string into the `{ os, architecture, abi }` triple that
`when` selectors are matched against.

```nix
logos-module-builder.lib.parseMetadata.platformForSystem "x86_64-windows"
# { os = "windows"; architecture = "x86_64"; abi = "gnu"; }
```

Note the `abi`: the Windows target is mingw (`x86_64-w64-mingw32`). Do not
derive the triple with `lib.systems.elaborate` — it reads the pseudo-system
string alone and answers `msvc`.

### platformOf

The same triple, from a package set that is already in scope.

```nix
logos-module-builder.lib.parseMetadata.platformOf pkgs.stdenv.hostPlatform
```

---

## common

Utility functions.

### systems

List of supported systems.

```nix
logos-module-builder.lib.common.systems
# [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ]
# plus "x86_64-windows" when the logos-nix input is threaded into the builder
```

### getLibExtension

Get library extension for platform.

```nix
logos-module-builder.lib.common.getLibExtension pkgs
# "dylib" on macOS, "so" on Linux
```

### getPluginFilename

Get plugin filename for module.

```nix
logos-module-builder.lib.common.getPluginFilename pkgs "my_module"
# "my_module_plugin.dylib" or "my_module_plugin.so"
```

### collectAllModuleDeps

Recursively resolve all module dependencies (direct + transitive) from flake inputs. Returns a flat attrset mapping module names to their LGX derivations. Used internally by `mkStandaloneApp` to bundle dependencies.

```nix
logos-module-builder.lib.common.collectAllModuleDeps system flakeInputs depNames
# { waku_module = <lgx derivation>; chat = <lgx derivation>; ... }
```

### nameFormats

Convert module name to various formats.

```nix
logos-module-builder.lib.common.nameFormats "my_module"
# { snake = "my_module"; pascal = "MyModule"; camel = "myModule"; upper = "MY_MODULE"; }
```

## Lower-level Builders

For advanced use cases, you can use some lower-level builders directly. Plugin compilation has been delegated to backends — `mkModuleLib` and `mkModuleInclude` no longer exist.

### Plugin Backends

Plugin compilation is delegated to a backend (e.g. `logos-plugin-qt`). The active backends are exposed as `uiBackend` and `coreBackend`:

```nix
logos-module-builder.lib.uiBackend.buildPlugin { ... }
logos-module-builder.lib.uiBackend.buildHeaders { ... }
logos-module-builder.lib.coreBackend.buildPlugin { ... }
```

These are internal implementation details — most modules don't need to call them directly.

### mkExternalLib

Build/resolve external libraries from flake inputs. Returns an attrset mapping library names to derivations. If a resolved input is already a Nix derivation (`lib.isDerivation`), it is used directly; otherwise the source is built with `make` / custom command.

```nix
logos-module-builder.lib.mkExternalLib.buildExternalLibs {
  pkgs = ...;
  config = ...;
  externalInputs = { };
}
```

### mkStandaloneApp

Build the `apps.default` entry for `nix run`.

```nix
logos-module-builder.lib.mkStandaloneApp {
  pkgs = ...;
  standalone = logos-standalone-app.packages.${system}.default;
  plugin = self.packages.${system}.default;
  metadataFile = ./metadata.json;
  dirName = "logos-my-module-plugin-dir";  # optional
  format = "qt-plugin";                    # or "qml"
  moduleDeps = { };                        # resolved module deps (LGX packages)
}
```

## version

Library version string.

```nix
logos-module-builder.lib.version
# "0.2.0"
```
