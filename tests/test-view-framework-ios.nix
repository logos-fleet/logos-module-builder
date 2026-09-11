# The `view` output: a `type: ui_qml` module CROSS-BUILT into one iOS embedded
# framework that carries its Qt backend and its QML and binds Qt upward into
# the app image.
#
# Each of these derivations runs scripts/logos-view-gate.sh over its own
# artifact, so realising them is already most of the assertion: the view C ABI
# is exported, QtCore is referenced and not carried, no Qt or logos-protocol
# archive came along and the QML is in the image. What is asserted HERE is what
# the gate has no opinion about — WHICH platform the artifact is for and the
# shape iOS's loader demands:
#
#   a flat framework bundle <name>_view.framework/{<name>_view,Info.plist},
#   an install_name of @rpath/<bundle>/<binary> (dyld cannot find it in
#   <App>.app/Frameworks/ otherwise), the right Mach-O platform byte in
#   LC_BUILD_VERSION, and no Versions/ tree (which iOS refuses and codesign
#   will not sign).
#
# ...plus the two refusals that keep the output honest, both at EVAL:
#   a QML-only ui_qml module has no backend to compile, so no framework;
#   the aarch64-android key carries no `view` at all, because Android's Qt is
#   shared objects and the artifact there is a different one.
#
# aarch64-darwin only: iOS cannot be cross-compiled from anywhere else.
{ pkgs, mkLogosQmlModule, fixturesRoot }:

let
  inherit (pkgs) lib;

  mkFixture = name: mkLogosQmlModule {
    src = fixturesRoot + "/${name}";
    configFile = fixturesRoot + "/${name}/metadata.json";
  };

  counter = mkFixture "view-counter-module";
  stem = "view_counter_view";

  # A QML-only module (no `main`) has nothing to compile into a framework. The
  # output must be a REFUSAL, not an artifact — otherwise `nix build
  # .#packages.aarch64-ios.view` offers one for a module that cannot have one.
  #
  # Only the failure is asserted, not its wording: builtins.tryEval yields
  # { success, value } and never the message.
  qmlOnlyRefused =
    let
      attempt = builtins.tryEval
        (builtins.deepSeq (mkFixture "qml-module").packages.aarch64-ios.view "forced");
    in
    if attempt.success
    then builtins.throw "FAIL: a QML-only ui_qml module must not offer an iOS view framework"
    else true;

  androidHasNoView =
    if (mkFixture "view-counter-module").packages.aarch64-android ? view
    then builtins.throw ("FAIL: the aarch64-android key must carry no `view` — "
      + "Android's Qt is shared objects and the artifact there is a different one")
    else true;

in
assert qmlOnlyRefused;
assert androidHasNoView;
pkgs.runCommand "view-framework-ios-tests" {
  nativeBuildInputs = [ pkgs.darwin.cctools ];
} ''
  set -euo pipefail
  mkdir -p $out

  check_ios() {
    local root="$1" want_platform="$2" what="$3"
    local fw="$root/Library/Frameworks/${stem}.framework"
    local bin="$fw/${stem}"

    test -f "$bin" || { echo "FAIL: $what has no framework binary at $bin"; exit 1; }
    test -f "$fw/Info.plist" || { echo "FAIL: $what carries no Info.plist"; exit 1; }
    test ! -e "$fw/Versions" || { echo "FAIL: $what has a Versions/ tree"; exit 1; }
    grep -q "<string>${stem}</string>" "$fw/Info.plist"
    grep -q "<string>FMWK</string>" "$fw/Info.plist"

    local id
    id=$(otool -D "$bin" | tail -1)
    [ "$id" = "@rpath/${stem}.framework/${stem}" ] \
      || { echo "FAIL: $what install_name is '$id', not @rpath/<bundle>/<binary>"; exit 1; }

    # LC_BUILD_VERSION platform: 2 = iOS device, 7 = iOS simulator. A framework
    # built for the wrong one links and installs and fails at dlopen.
    local platform
    platform=$(otool -l "$bin" | awk '/LC_BUILD_VERSION/{f=1} f && $1=="platform"{print $2; exit}')
    [ "$platform" = "$want_platform" ] \
      || { echo "FAIL: $what Mach-O platform is $platform, expected $want_platform"; exit 1; }
    file "$bin" | grep -q arm64

    # The view shape restated on the bytes the gate just cleared. Captured
    # whole rather than piped into `grep -q`: pipefail is on and grep closes
    # the pipe the moment it is satisfied, so the producer dies of SIGPIPE and
    # the assertion reads backwards.
    local syms
    syms=$(nm -m "$bin")
    case "$syms" in
      *"_logos_view_module_create"*) ;;
      *) echo "FAIL: $what does not export logos_view_module_create"; exit 1 ;;
    esac
    case "$syms" in
      *"undefined"*"_ZN7QObject16staticMetaObjectE"*) ;;
      *) echo "FAIL: $what does not leave QObject::staticMetaObject undefined"; exit 1 ;;
    esac

    # The manifest travels beside the framework because <App>.app/Frameworks/
    # is flat and has no room for one.
    test -f "$root/share/logos/view_counter/metadata.json" \
      || { echo "FAIL: $what ships no metadata.json for the host to carry"; exit 1; }

    echo "PASS: $what — flat framework, @rpath install_name, Mach-O platform $platform, Qt undefined"
  }

  check_ios ${counter.packages.aarch64-ios-simulator.view} 7 "view_counter iOS simulator"
  check_ios ${counter.packages.aarch64-ios.view} 2 "view_counter iOS device"

  # AC: the desktop path is untouched. The SAME fixture still builds its Qt
  # plugin and still ships its QML beside it, from the same sources.
  desktop=${counter.packages.${pkgs.stdenv.hostPlatform.system}.default}
  test -f "$desktop/lib/view_counter_plugin.dylib" -o -f "$desktop/lib/view_counter_plugin.so" \
    || { echo "FAIL: the desktop ui_qml plugin is gone"; ls -R "$desktop"; exit 1; }
  test -f "$desktop/lib/qml/Main.qml" \
    || { echo "FAIL: the desktop combined output lost its QML"; exit 1; }
  echo "PASS: the desktop ui_qml plugin and its QML are unchanged"

  echo "PASS: a QML-only ui_qml module is refused an iOS view framework"
  echo "PASS: the aarch64-android key carries no view output"
  touch $out/ok
''
