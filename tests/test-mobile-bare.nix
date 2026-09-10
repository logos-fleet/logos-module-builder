# Integration test for the mobile Bare module outputs —
# `packages.aarch64-ios{,-simulator}.bare` and `packages.aarch64-android.bare`.
#
# Every one of these derivations ran scripts/logos-bare-gate.sh over its
# artifact (and, on Android, logos-nix's DT_NEEDED gate), so realising them is
# already most of the assertion: the module-impl C ABI is exported, `lp_*` is
# undefined, no Qt and no logos-protocol code is carried, and every DT_NEEDED
# soname resolves on device. What the gates CANNOT say is which platform the
# artifact is for — a build that quietly produced the builder's own object
# would pass all of them — so that is what is checked here, off the load
# commands and the ELF header.
#
# Three shapes, because they take three different paths through the builder:
#   bare_counter       leaf universal C++ module
#   bare_relay         universal C++ module with a dependency (its
#                      modules().bare_counter calls are what leave lp_invoke
#                      undefined)
#   bare_rust_module   a codegen.rust module — the crate is cross-compiled for
#                      the target and whole-archived in, which is the only part
#                      of `generate` that is not platform-neutral
{ pkgs, mkLogosModule, fixturesRoot }:

let
  inherit (pkgs) lib;

  counter = mkLogosModule {
    src = fixturesRoot + "/bare-counter";
    configFile = fixturesRoot + "/bare-counter/metadata.json";
  };
  relay = mkLogosModule {
    src = fixturesRoot + "/bare-relay";
    configFile = fixturesRoot + "/bare-relay/metadata.json";
    flakeInputs = { bare_counter = counter; };
  };
  rustModule = mkLogosModule {
    src = fixturesRoot + "/bare-rust";
    configFile = fixturesRoot + "/bare-rust/metadata.json";
  };

  modules = [
    { m = counter; name = "bare_counter"; }
    { m = relay; name = "bare_relay"; }
    { m = rustModule; name = "bare_rust_module"; }
  ];

  # An Android derivation's `system` is its BUILD platform, so the flake's
  # default (x86_64-linux) cannot be realised here; ask for this one.
  buildSystem = pkgs.stdenv.hostPlatform.system;
  mobileOf = entry: entry.m.mobileBarePackagesFor { androidBuildSystem = buildSystem; };

  # Only aarch64-darwin can build the iOS sets at all (Xcode, ADR 0002).
  iosTargets = lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
    # target, the Mach-O LC_BUILD_VERSION platform number Apple assigns it
    { system = "aarch64-ios"; platform = "2"; }
    { system = "aarch64-ios-simulator"; platform = "7"; }
  ];

  iosChecks = lib.concatMapStrings
    (t: lib.concatMapStrings (entry: ''
      lib=${(mobileOf entry).${t.system}.bare}/lib/${entry.name}_bare.dylib
      test -f "$lib" || { echo "FAIL: ${entry.name} produced no ${t.system} artifact"; exit 1; }

      # Every reader's output is captured whole and matched with `case`, never
      # piped into `grep -q`. `set -o pipefail` is on, and `grep -q` closes the
      # pipe the moment it is satisfied, so the producer dies of SIGPIPE and
      # the pipeline reports 141 -- on SUCCESS. The assertion then reads
      # exactly backwards, which is how this test first "failed".
      header=$(otool -hv "$lib")
      loadcmds=$(otool -l "$lib")
      syms=$(nm -g "$lib")

      # Mach-O, arm64, and the right Apple platform. `platform ${t.platform}`
      # is the whole point: an iphoneos image and an iphonesimulator image are
      # both "Mach-O 64-bit arm64" and neither loads where the other belongs.
      case "$header" in
        *ARM64*DYLIB*) ;;
        *) echo "FAIL: ${entry.name} ${t.system} is not an arm64 Mach-O dylib"; echo "$header"; exit 1 ;;
      esac
      platform=$(printf '%s\n' "$loadcmds" \
        | awk '/LC_BUILD_VERSION/ { f=1 } f && $1 == "platform" { print $2; exit }')
      [ "$platform" = "${t.platform}" ] \
        || { echo "FAIL: ${entry.name} ${t.system} is built for Apple platform '$platform', not ${t.platform}"; exit 1; }

      # The Bare shape, restated on the artifact the gate just cleared: the
      # host image supplies lp_*.
      case "$syms" in
        *" U _lp_"*) ;;
        *) echo "FAIL: ${entry.name} ${t.system} defines no undefined lp_* — it is not resolving upward"; exit 1 ;;
      esac
      echo "PASS: ${entry.name} ${t.system} — arm64 Mach-O, Apple platform ${t.platform}, lp_* undefined"
    '') modules)
    iosTargets;

  androidChecks = lib.concatMapStrings (entry: ''
    lib=${(mobileOf entry).aarch64-android.bare}/lib/${entry.name}_bare.so
    test -f "$lib" || { echo "FAIL: ${entry.name} produced no aarch64-android artifact"; exit 1; }

    # Captured, not piped -- see the iOS half for why.
    header=$(readelf -h "$lib")
    syms=$(readelf -sW --dyn-syms "$lib")

    case "$header" in
      *AArch64*) ;;
      *) echo "FAIL: ${entry.name} android artifact is not AArch64 ELF"; echo "$header"; exit 1 ;;
    esac
    case "$header" in
      *"DYN (Shared object file)"*) ;;
      *) echo "FAIL: ${entry.name} android artifact is not a shared object"; echo "$header"; exit 1 ;;
    esac
    case "$syms" in
      *" UND lp_"*) ;;
      *) echo "FAIL: ${entry.name} android defines no undefined lp_* — it is not resolving upward"; exit 1 ;;
    esac
    echo "PASS: ${entry.name} aarch64-android — AArch64 ELF shared object, lp_* undefined"
  '') modules;

  # A Qt plugin object holding a LogosAPI has no protocol-free form to
  # extract, on any platform — so it must not advertise a mobile bare either.
  # Pure evaluation; nothing is built.
  noMobileBare = label: fixture:
    let
      m = mkLogosModule {
        src = fixturesRoot + "/${fixture}";
        configFile = fixturesRoot + "/${fixture}/metadata.json";
      };
      mobile = m.mobileBarePackagesFor { androidBuildSystem = buildSystem; };
    in
    if mobile != { }
    then builtins.throw "FAIL: ${label} (${fixture}) must not expose a mobile `bare` output"
    else true;

  qtPluginsHaveNoMobileBare =
    noMobileBare "a hand-written Qt core module" "test-framework-module"
    && noMobileBare "a ui_qml view backend" "qml-module";

  # A module with `nix.external_libraries` has to be REFUSED, by name, at
  # eval. Those libraries are staged into lib/ as build-platform images and
  # nothing here can recompile them; left to the linker it surfaces forty lines
  # into a link command as "building for 'iOS-simulator', but linking in dylib
  # ... built for 'macOS'", which names neither the library's owner nor the
  # fix. Asserted BY MESSAGE: a test that only checked for failure would pass
  # on a typo in this file.
  extlibModule = mkLogosModule {
    src = fixturesRoot + "/extlib-module";
    configFile = fixturesRoot + "/extlib-module/metadata.json";
  };
  extlibRefused =
    let
      attempt = builtins.tryEval
        (builtins.deepSeq
          (extlibModule.mobileBarePackagesFor { androidBuildSystem = buildSystem; })
          "built");
    in
    if attempt.success
    then builtins.throw
      "FAIL: a module declaring nix.external_libraries must not offer a mobile bare output"
    else true;

in
assert qtPluginsHaveNoMobileBare;
assert extlibRefused;
pkgs.runCommand "mobile-bare-tests"
{
  nativeBuildInputs = [ pkgs.binutils ]
    ++ lib.optional pkgs.stdenv.hostPlatform.isDarwin pkgs.darwin.cctools;
} ''
  set -euo pipefail
  ${iosChecks}
  ${androidChecks}
  echo "PASS: Qt plugin shapes expose no mobile bare output"
  echo "PASS: a module with nix.external_libraries is refused a mobile bare output"
  touch $out
''
