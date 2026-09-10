# The `bare` output CROSS-BUILT: the iOS embedded framework (device and
# simulator) and the Android shared object.
#
# Each of the three derivations runs scripts/logos-bare-gate.sh over its own
# artifact, so realising them already proves the whole module-impl C ABI is
# exported, lp_* is left undefined and no Qt or logos-protocol code came along.
# What is asserted HERE is only what the gate has no opinion about — the shape
# the platform's loader demands:
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
# aarch64-darwin only: iOS cannot be cross-compiled from anywhere else, and the
# Android leg is instantiated with androidBuildSystem = aarch64-darwin so all
# three derivations can be realised by one builder.
{ pkgs, mkLogosModule, fixturesRoot }:

let
  inherit (pkgs) lib;

  counter = mkLogosModule {
    src = fixturesRoot + "/bare-counter";
    configFile = fixturesRoot + "/bare-counter/metadata.json";
  };

  mobile = counter.legacyPackages.aarch64-darwin.mobile;
  iosSim = mobile.aarch64-ios-simulator.bare;
  iosDevice = mobile.aarch64-ios.bare;
  android = mobile.aarch64-android.bare;

  # A Qt plugin shape has no protocol-free form to extract, and that must stay
  # true on the mobile keys too — otherwise `nix build .#packages.aarch64-ios.bare`
  # would offer an artifact for a module that cannot have one. Pure evaluation.
  qmlHasNoMobileBare =
    let m = mkLogosModule {
          src = fixturesRoot + "/qml-module";
          configFile = fixturesRoot + "/qml-module/metadata.json";
        };
    in if m.packages.aarch64-ios ? bare
       then builtins.throw "FAIL: a ui_qml view backend must not expose a mobile `bare` output"
       else true;

in assert qmlHasNoMobileBare; pkgs.runCommand "bare-modules-mobile-tests" {
  nativeBuildInputs = [
    pkgs.darwin.cctools
    pkgs.llvmPackages.bintools-unwrapped
  ];
} ''
  set -euo pipefail
  mkdir -p $out

  check_ios() {
    local root="$1" want_platform="$2" label="$3"
    local fw="$root/Library/Frameworks/bare_counter_bare.framework"
    local bin="$fw/bare_counter_bare"

    test -f "$bin" || { echo "FAIL: $label has no framework binary at $bin"; exit 1; }
    test -f "$fw/Info.plist" || { echo "FAIL: $label framework carries no Info.plist"; exit 1; }
    # macOS frameworks are versioned (Versions/A/...); iOS refuses that layout
    # and so does codesign when the bundle is embedded in an app.
    test ! -e "$fw/Versions" || { echo "FAIL: $label framework has a Versions/ tree"; exit 1; }
    grep -q "<string>bare_counter_bare</string>" "$fw/Info.plist"
    grep -q "<string>FMWK</string>" "$fw/Info.plist"

    local id
    id=$(otool -D "$bin" | tail -1)
    [ "$id" = "@rpath/bare_counter_bare.framework/bare_counter_bare" ] \
      || { echo "FAIL: $label install_name is '$id', not @rpath/<bundle>/<binary>"; exit 1; }

    # LC_BUILD_VERSION platform: 2 = iOS device, 7 = iOS simulator. A framework
    # built for the wrong one links and installs and fails at dlopen.
    local platform
    platform=$(otool -l "$bin" | awk '/LC_BUILD_VERSION/{f=1} f && $1=="platform"{print $2; exit}')
    [ "$platform" = "$want_platform" ] \
      || { echo "FAIL: $label Mach-O platform is $platform, expected $want_platform"; exit 1; }

    file "$bin" | grep -q arm64
    echo "PASS: $label — flat framework, @rpath install_name, Mach-O platform $platform"
  }

  check_ios ${iosSim} 7 "iOS simulator"
  check_ios ${iosDevice} 2 "iOS device"

  and_so=${android}/lib/libbare_counter_bare.so
  test -f "$and_so" || { echo "FAIL: no libbare_counter_bare.so"; exit 1; }
  file "$and_so" | grep -q 'ELF 64-bit.*aarch64'
  soname=$(llvm-readelf -d "$and_so" | awk -F'[][]' '/SONAME/ {print $2}')
  [ "$soname" = "libbare_counter_bare.so" ] \
    || { echo "FAIL: Android SONAME is '$soname', not libbare_counter_bare.so"; exit 1; }
  # The whole reason the Android name is decorated at all.
  case "$(basename "$and_so")" in lib*.so) ;; *) echo "FAIL: not lib*.so"; exit 1 ;; esac
  echo "PASS: Android — aarch64 ELF, lib*.so, SONAME matches"

  {
    echo "ios-sim:     ${iosSim}"
    echo "ios-device:  ${iosDevice}"
    echo "android:     ${android}"
  } > $out/artifacts.txt
''
