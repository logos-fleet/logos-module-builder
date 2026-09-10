# The `bare` output CROSS-BUILT: the iOS embedded framework (device and
# simulator) and the Android shared object.
#
# Each of these derivations runs scripts/logos-bare-gate.sh over its own
# artifact — and, on Android, logos-nix's DT_NEEDED gate as well — so realising
# them is already most of the assertion: the whole module-impl C ABI is
# exported, lp_* is left undefined, no Qt or logos-protocol code came along and
# every DT_NEEDED soname is one the container ships or Android guarantees. What
# is asserted HERE is only what the gates have no opinion about — WHICH platform
# an artifact is for, and the shape that platform's loader demands:
#
#   iOS      a flat framework bundle: <name>.framework/{<name>,Info.plist},
#            an install_name of @rpath/<name>.framework/<name> (dyld cannot
#            find it in <App>.app/Frameworks/ otherwise), the right Mach-O
#            platform in LC_BUILD_VERSION, and no Versions/ tree (which iOS
#            refuses and codesign will not sign).
#   Android  an aarch64 ELF named lib*.so with a matching SONAME, because an
#            APK carries only files matching lib*.so and androiddeployqt drops
#            everything else.
#
# TWO SHAPES, because they take two different paths through the builder:
#   bare_counter      a leaf universal C++ module — `generate` is source and
#                     crosses untouched.
#   bare_rust_module  a codegen.rust module — the ONE part of `generate` that
#                     is not platform-neutral is lib/<crate>.a, so the crate is
#                     recompiled for the target and staged over it. An arm64
#                     artifact cannot come out of a whole-archive link of a
#                     build-platform .a at all, so the arch assertions below
#                     are what proves the Rust core crossed.
#
# aarch64-darwin only: iOS cannot be cross-compiled from anywhere else, and the
# Android leg is instantiated with androidBuildSystem = aarch64-darwin so all
# six derivations can be realised by one builder.
{ pkgs, mkLogosModule, fixturesRoot }:

let
  inherit (pkgs) lib;

  mkFixture = name: mkLogosModule {
    src = fixturesRoot + "/${name}";
    configFile = fixturesRoot + "/${name}/metadata.json";
  };

  mobileOf = m: m.legacyPackages.aarch64-darwin.mobile;

  counter = mkFixture "bare-counter";
  rustModule = mkFixture "bare-rust";

  # stem = what LogosModule.cmake names the artifact; the mobile decoration
  # around it is what the checks below are about.
  modules = [
    { stem = "bare_counter_bare"; mobile = mobileOf counter; }
    { stem = "bare_rust_module_bare"; mobile = mobileOf rustModule; }
  ];

  iosCases = lib.concatMapStrings (m: ''
    check_ios ${m.mobile.aarch64-ios-simulator.bare} 7 ${m.stem} "iOS simulator"
    check_ios ${m.mobile.aarch64-ios.bare} 2 ${m.stem} "iOS device"
  '') modules;

  androidCases = lib.concatMapStrings (m: ''
    check_android ${m.mobile.aarch64-android.bare} ${m.stem}
  '') modules;

  # A Qt plugin shape has no protocol-free form to extract, and that must stay
  # true on the mobile keys too — otherwise `nix build .#packages.aarch64-ios.bare`
  # would offer an artifact for a module that cannot have one. Pure evaluation.
  qmlHasNoMobileBare =
    if (mkFixture "qml-module").packages.aarch64-ios ? bare
    then builtins.throw "FAIL: a ui_qml view backend must not expose a mobile `bare` output"
    else true;

  # A module with `nix.external_libraries` has to be REFUSED at eval. Those
  # libraries are staged into lib/ as build-platform images by the module's own
  # `generate` step and nothing in the builder can recompile them — each comes
  # from its own flake. Left to the linker it surfaces forty lines into a link
  # command as "building for 'iOS-simulator', but linking in dylib ... built for
  # 'macOS'", naming neither the library's owner nor the fix.
  #
  # Only the FAILURE is asserted, not its wording: `builtins.tryEval` yields
  # `{ success, value }` and never the message, so there is no pure way to match
  # on it.
  extlibRefused =
    let
      attempt = builtins.tryEval
        (builtins.deepSeq (mkFixture "extlib-module").packages.aarch64-ios.bare "forced");
    in
    if attempt.success
    then builtins.throw
      "FAIL: a module declaring nix.external_libraries must not offer a mobile bare output"
    else true;

in
assert qmlHasNoMobileBare;
assert extlibRefused;
pkgs.runCommand "bare-modules-mobile-tests" {
  nativeBuildInputs = [
    pkgs.darwin.cctools
    pkgs.llvmPackages.bintools-unwrapped
  ];
} ''
  set -euo pipefail
  mkdir -p $out

  check_ios() {
    local root="$1" want_platform="$2" stem="$3" what="$4"
    local label="$stem $what"
    local fw="$root/Library/Frameworks/$stem.framework"
    local bin="$fw/$stem"

    test -f "$bin" || { echo "FAIL: $label has no framework binary at $bin"; exit 1; }
    test -f "$fw/Info.plist" || { echo "FAIL: $label framework carries no Info.plist"; exit 1; }
    # macOS frameworks are versioned (Versions/A/...); iOS refuses that layout
    # and so does codesign when the bundle is embedded in an app.
    test ! -e "$fw/Versions" || { echo "FAIL: $label framework has a Versions/ tree"; exit 1; }
    grep -q "<string>$stem</string>" "$fw/Info.plist"
    grep -q "<string>FMWK</string>" "$fw/Info.plist"

    local id
    id=$(otool -D "$bin" | tail -1)
    [ "$id" = "@rpath/$stem.framework/$stem" ] \
      || { echo "FAIL: $label install_name is '$id', not @rpath/<bundle>/<binary>"; exit 1; }

    # LC_BUILD_VERSION platform: 2 = iOS device, 7 = iOS simulator. A framework
    # built for the wrong one links and installs and fails at dlopen.
    local platform
    platform=$(otool -l "$bin" | awk '/LC_BUILD_VERSION/{f=1} f && $1=="platform"{print $2; exit}')
    [ "$platform" = "$want_platform" ] \
      || { echo "FAIL: $label Mach-O platform is $platform, expected $want_platform"; exit 1; }

    file "$bin" | grep -q arm64

    # The Bare shape restated on the bytes the gate just cleared: the host
    # image supplies lp_*. Captured whole rather than piped into `grep -q` —
    # pipefail is on and grep closes the pipe the moment it is satisfied, so
    # the producer dies of SIGPIPE and the assertion reads backwards.
    local syms
    syms=$(nm -g "$bin")
    case "$syms" in
      *" U _lp_"*) ;;
      *) echo "FAIL: $label has no undefined lp_* — it is not resolving upward"; exit 1 ;;
    esac
    echo "PASS: $label — flat framework, @rpath install_name, Mach-O platform $platform, lp_* undefined"
  }

  check_android() {
    local root="$1" stem="$2"
    local so="$root/lib/lib$stem.so"

    test -f "$so" || { echo "FAIL: no lib$stem.so"; exit 1; }
    file "$so" | grep -q 'ELF 64-bit.*aarch64'
    local soname
    soname=$(llvm-readelf -d "$so" | awk -F'[][]' '/SONAME/ {print $2}')
    [ "$soname" = "lib$stem.so" ] \
      || { echo "FAIL: Android SONAME is '$soname', not lib$stem.so"; exit 1; }
    # The whole reason the Android name is decorated at all.
    case "$(basename "$so")" in lib*.so) ;; *) echo "FAIL: not lib*.so"; exit 1 ;; esac

    # WHERE ITS lp_* COME FROM. On Android a DT_NEEDED on the host's protocol
    # soname is the only mechanism bionic offers a dlopen'd library for reaching
    # an app library's symbols, so its absence is not a missing nicety -- the
    # module loads nowhere. It is recorded by linking an EMPTY .so carrying that
    # soname, so the gate's "every lp_* stays UNDEFINED" still holds and is
    # re-asserted here against the shipped bytes.
    local needed
    needed=$(llvm-readelf -d "$so" | awk -F'[][]' '/NEEDED/ {print $2}')
    grep -qx liblogos_protocol.so <<< "$needed" \
      || { echo "FAIL: $stem does not name liblogos_protocol.so in DT_NEEDED."
           echo "      NEEDED was:"; printf '        %s\n' $needed; exit 1; }
    if llvm-nm -D --defined-only "$so" | grep -q ' lp_'; then
      echo "FAIL: the DT_NEEDED brought protocol CODE along; lp_* must stay undefined"
      exit 1
    fi
    echo "PASS: $stem aarch64-android — ELF lib*.so, SONAME matches, NEEDED liblogos_protocol.so with no lp_* defined"
  }

  ${iosCases}
  ${androidCases}

  echo "PASS: a ui_qml view backend exposes no mobile bare output"
  echo "PASS: a module with nix.external_libraries is refused a mobile bare output"
  touch $out/ok
''
