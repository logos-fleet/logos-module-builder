# The `view` output on ANDROID: a `type: ui_qml` module cross-built into one
# `lib<name>_view.so` that carries its Qt backend and its QML and reaches the
# app's Qt by soname.
#
# The derivation runs scripts/logos-view-gate.sh and logos-nix's DT_NEEDED gate
# over its own artifact, so realising it is already most of the assertion: the
# view C ABI is exported, QtCore is referenced and not carried, no logos-qt-host
# or logos-protocol code came along, the QML is in the image, and every
# DT_NEEDED soname is one the app ships or Android guarantees. What is asserted
# HERE is what the gates have no opinion about — the shape Android's loader and
# an APK demand, and the ONE fact that separates this artifact from the iOS one:
#
#   an aarch64 ELF named lib<stem>.so with a matching SONAME, because an APK
#   carries only files matching lib*.so and androiddeployqt drops the rest;
#   DT_NEEDED naming the app's Qt and the two Logos host images, with NOTHING
#   from either defined here — on iOS those same symbols arrive with no load
#   command at all, and an artifact that got the two the wrong way round loads
#   on neither phone.
#
# ...plus the refusal that keeps the output honest, at EVAL: a QML-only ui_qml
# module has no backend to compile, so no view image on this platform either.
#
# aarch64-darwin only, for the same reason as the other two mobile checks: the
# Android leg is instantiated with androidBuildSystem = aarch64-darwin so this
# builder can realise it.
{ pkgs, mkLogosQmlModule, fixturesRoot }:

let
  inherit (pkgs) lib;

  mkFixture = name: mkLogosQmlModule {
    src = fixturesRoot + "/${name}";
    configFile = fixturesRoot + "/${name}/metadata.json";
  };

  counter = mkFixture "view-counter-module";
  stem = "view_counter_view";

  # `legacyPackages.<buildSystem>.mobile`, not `packages.aarch64-android`: a
  # cross derivation's `system` is its BUILD platform, and the canonical key is
  # x86_64-linux, which this builder cannot realise. Same spelling
  # mkLogosModule's mobile `bare` uses.
  view = counter.legacyPackages.aarch64-darwin.mobile.aarch64-android.view;

  # A QML-only module (no `main`) has nothing to compile into an image. The
  # output must be a REFUSAL, not an artifact — otherwise `nix build
  # .#packages.aarch64-android.view` offers one for a module that cannot have
  # one.
  #
  # Only the failure is asserted, not its wording: builtins.tryEval yields
  # { success, value } and never the message.
  qmlOnlyRefused =
    let
      attempt = builtins.tryEval
        (builtins.deepSeq (mkFixture "qml-module").packages.aarch64-android.view "forced");
    in
    if attempt.success
    then builtins.throw "FAIL: a QML-only ui_qml module must not offer an Android view image"
    else true;

in
assert qmlOnlyRefused;
pkgs.runCommand "view-module-android-tests" {
  nativeBuildInputs = [ pkgs.llvmPackages.bintools-unwrapped ];
} ''
  set -euo pipefail
  mkdir -p $out

  so=${view}/lib/lib${stem}.so
  test -f "$so" || { echo "FAIL: no lib${stem}.so in ${view}"; ls -R ${view}; exit 1; }
  file "$so" | grep -q 'ELF 64-bit.*aarch64' \
    || { echo "FAIL: $so is not an aarch64 ELF"; file "$so"; exit 1; }

  soname=$(llvm-readelf -d "$so" | awk -F'[][]' '/SONAME/ {print $2}')
  [ "$soname" = "lib${stem}.so" ] \
    || { echo "FAIL: SONAME is '$soname', not lib${stem}.so"; exit 1; }
  # The whole reason the Android name is decorated at all.
  case "$(basename "$so")" in lib*.so) ;; *) echo "FAIL: not lib*.so"; exit 1 ;; esac

  # ── where its Qt and its host runtime come from ─────────────────────────
  # Named, not carried. On Android a DT_NEEDED is the only mechanism bionic
  # offers a dlopen'd library for reaching an app library's symbols, so each
  # of these absent is not a missing nicety — the image loads nowhere.
  needed=$(llvm-readelf -d "$so" | awk -F'[][]' '/NEEDED/ {print $2}')
  for want in libQt6Core liblogos_protocol.so liblogos_qt_host.so; do
    grep -q "^$want" <<< "$needed" \
      || { echo "FAIL: no DT_NEEDED matching $want."
           echo "      NEEDED was:"; printf '        %s\n' $needed; exit 1; }
  done

  dyn=$(llvm-nm -D "$so")
  # ...and NONE of it is inside. The same two facts the iOS framework is held
  # to, restated on the shipped ELF: a second QtCore in the process fails at
  # the first QObject that crosses between the two, and a view image carrying
  # the protocol would answer a different registry than the app.
  grep -q ' U .*_ZN7QObject16staticMetaObjectE' <<< "$dyn" \
    || { echo "FAIL: QObject::staticMetaObject is not undefined — Qt was carried in"; exit 1; }
  if llvm-nm -D --defined-only "$so" | grep -q ' lp_'; then
    echo "FAIL: the image DEFINES lp_* — the logos-protocol code came along"; exit 1
  fi
  if llvm-nm -D --defined-only "$so" | grep -q '_ZN8LogosAPI'; then
    echo "FAIL: the image DEFINES LogosAPI — the Qt host runtime came along"; exit 1
  fi

  # The C edge the host reaches this image through, and nothing else.
  for sym in logos_view_module_abi_version logos_view_module_name \
             logos_view_module_version logos_view_module_qml_url \
             logos_view_module_create logos_view_module_acquire_replica \
             qt_plugin_instance; do
    llvm-nm -D --defined-only "$so" | grep -qw "$sym" \
      || { echo "FAIL: the image does not export $sym"; exit 1; }
  done

  # The QML is IN the image (a qrc registers through a static initializer, so
  # its presence is bytes rather than a symbol) — the same thing the gate
  # checks, restated here against the shipped file.
  # CAPTURED WHOLE, then matched: pipefail is on and `grep -q` closes the pipe
  # the moment it is satisfied, so `tr` dies of SIGPIPE and the assertion reads
  # backwards — a FAIL on an image that carries exactly what was asked for.
  printable=$(tr -c '[:print:]' '\n' < "$so")
  case "$printable" in
    *"qrc:/logos/view_counter/"*) ;;
    *) echo "FAIL: no qrc:/logos/view_counter/... entry URL in the image"; exit 1 ;;
  esac

  # The manifest travels beside the image because an app's native library
  # directory is flat and has no room for one.
  test -f ${view}/share/logos/view_counter/metadata.json \
    || { echo "FAIL: the Android view image ships no metadata.json"; exit 1; }

  echo "PASS: view_counter aarch64-android — ELF lib*.so, SONAME matches, Qt and the"
  echo "      Logos host images named in DT_NEEDED and defined nowhere, QML in the qrc"
  echo "PASS: a QML-only ui_qml module is refused an Android view image"
  touch $out/ok
''
