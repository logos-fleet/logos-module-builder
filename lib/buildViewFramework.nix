# Builder for the **iOS view framework** — a `type: ui_qml` module as one
# embedded framework carrying its Qt backend and its QML (docs/nix-api.md,
# "The `view` output").
#
# Same relationship to the desktop Qt plugin that `bare` has to it: both are cut
# from the module's own `generate` output — the tree after every code generator
# has run — so the framework and the plugin compile the SAME sources. What
# differs is the link, and only the link: `logos_view_framework()` in
# LogosModule.cmake links nothing at all, so Qt, logos-qt-host and the lp_* C
# ABI are left undefined for the app image to supply at dlopen (ADR 0006).
#
# ONE HOST SHAPE, deliberately. iOS is the only platform where a Qt-linking
# module image can bind Qt upward into the app: Apple's dyld resolves a flat
# namespace, and logos-nix builds the iOS Qt with `reduce_exports` off so the
# app's export trie actually carries Qt (spike ios-dlopen-bare-module, the
# precondition for Level 2). Android's Qt is a set of SHARED objects, so the
# same module there is a `.so` naming libQt6Core_arm64-v8a.so and friends in
# DT_NEEDED — a different artifact with a different gate, and not this one.
# A caller that hands this function a non-iOS package set gets told so.
{ lib }:

{
  pkgs,
  config,
  # The module's `generate` output: source + fully-populated generated_code/,
  # produced on the BUILD platform. Source, so it crosses untouched — same
  # reasoning as the mobile `bare` artifact.
  generatedSrc,
  builderRoot,
  # Header roots. All BUILD-platform prefixes, and that is not a shortcut: the
  # framework compiles against them and links none of them, so there is nothing
  # in any of these to cross-compile.
  logosSdk,
  logosQtSdk,
  logosQtHost,
  logosProtocol,
  logosModule,
  # logos-view-module's cmake/ (the LogosView*.in templates) and its include/.
  viewTemplates,
  viewInclude,
  gateScript,
  # The module's QML: the directory whose contents go into the framework's qrc,
  # relative to the generate tree, and the entry file relative to THAT.
  qmlDir,
  qmlEntry,
  extraNativeBuildInputs ? [],
  extraBuildInputs ? [],
}:

let
  host = pkgs.stdenv.hostPlatform;
  isIos = host.isiOS or false;

  stem = "${config.name}_view";

  # The device and the simulator share a triple; `darwinPlatform` is what
  # separates them. Derived here rather than read off `pkgs.logosIosAppleSdk`
  # for the same reason buildBareModule derives it: that attribute is newer
  # than some consumers' logos-nix pin, and this is one line of the same fact.
  isIosSimulator = isIos && host.darwinPlatform == "ios-simulator";
  appleSdk = if isIosSimulator then "iphonesimulator" else "iphoneos";
  iosPlatformName = if isIosSimulator then "iPhoneSimulator" else "iPhoneOS";
  # Matches logos-nix's iosDeploymentTarget, the floor every hand-rolled iOS
  # artifact in this stack targets.
  iosDeploymentTarget = "17.0";

  # CFBundleIdentifier is an RFC 1034 name: no underscores. A module name is
  # snake_case, and codesign refuses the bundle at APP-signing time, three
  # steps from here.
  bundleId = "co.logos.view." + lib.replaceStrings [ "_" ] [ "-" ] config.name;

  infoPlist = builtins.toFile "${stem}-Info.plist" ''
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleDevelopmentRegion</key><string>en</string>
      <key>CFBundleExecutable</key><string>${stem}</string>
      <key>CFBundleIdentifier</key><string>${bundleId}</string>
      <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
      <key>CFBundleName</key><string>${stem}</string>
      <key>CFBundlePackageType</key><string>FMWK</string>
      <key>CFBundleShortVersionString</key><string>${config.version}</string>
      <key>CFBundleVersion</key><string>${config.version}</string>
      <key>CFBundleSupportedPlatforms</key><array><string>${iosPlatformName}</string></array>
      <key>MinimumOSVersion</key><string>${iosDeploymentTarget}</string>
    </dict>
    </plist>
  '';

in
if !isIos then
  throw ("logos-module-builder: the `view` output (a ui_qml module as an "
    + "embedded framework with Qt bound upward) exists for iOS only, and this "
    + "package set is " + host.system + ". On Android Qt is a set of shared "
    + "objects, so the same module is a .so naming them in DT_NEEDED — a "
    + "different artifact with a different gate, not this one.")
else
pkgs.xcodeClang.mkDerivation {
  pname = "logos-${config.name}-view";
  version = config.version;

  src = generatedSrc;

  nativeBuildInputs = [ pkgs.cmake pkgs.ninja ] ++ extraNativeBuildInputs;
  # Qt for the TARGET: found, compiled against, never linked. It is a
  # buildInput rather than a bare prefix path so the cmake setup hook puts it
  # where find_package(Qt6) looks, exactly as mkIosCmakeStage does.
  buildInputs = [
    pkgs.qt6.qtbase
    pkgs.qt6.qtdeclarative
    pkgs.qt6.qtshadertools
    pkgs.qt6.qtsvg
    pkgs.qt6.qtremoteobjects
  ] ++ extraBuildInputs;

  cmakeFlags = [
    "-GNinja"
    "-DCMAKE_TOOLCHAIN_FILE=${pkgs.logosQtCrossToolchainFile}"
    "-DLOGOS_MODULE_VIEW_FRAMEWORK=ON"
    "-DLOGOS_CPP_SDK_ROOT=${logosSdk}"
    "-DLOGOS_QT_SDK_ROOT=${logosQtSdk}"
    "-DLOGOS_QT_HOST_ROOT=${logosQtHost}"
    "-DLOGOS_PROTOCOL_ROOT=${logosProtocol}"
    "-DLOGOS_MODULE_ROOT=${logosModule}"
    "-DLOGOS_VIEW_TEMPLATE_DIR=${viewTemplates}"
    "-DLOGOS_VIEW_INCLUDE_DIR=${viewInclude}"
    "-DLOGOS_VIEW_EXTRA_INCLUDE_DIRS=${pkgs.pkgsBuildBuild.nlohmann_json}/include"
    "-DLOGOS_VIEW_VERSION=${config.version}"
    # Resolved against the unpacked source root by cmake, which runs in
    # <src>/build — hence the absolute form via CMAKE_SOURCE_DIR is not
    # available here; both are passed relative to the source dir and made
    # absolute in preConfigure.
    "-DLOGOS_VIEW_QML_ENTRY=${qmlEntry}"
  ] ++ pkgs.logosQtCrossCmakeFlags;

  # QML_DIR has to be an ABSOLUTE path (file(GLOB_RECURSE) and qt6_add_resources
  # BASE both take one), and the only moment its absolute form is known is
  # after unpackPhase. xcodeClang.mkDerivation's own preConfigure is composed
  # in rather than replaced — it exports CC/CXX from xcrun, without which cmake
  # reports "CMAKE_CXX_COMPILER not set".
  preConfigure = ''
    export CC=$(xcrun --sdk ${appleSdk} --find clang)
    export CXX=$(xcrun --sdk ${appleSdk} --find clang++)
    export AR=$(xcrun --sdk ${appleSdk} --find ar)
    export RANLIB=$(xcrun --sdk ${appleSdk} --find ranlib)
    export STRIP=$(xcrun --sdk ${appleSdk} --find strip)
    cmakeFlagsArray+=(-DCMAKE_SYSTEM_NAME=iOS)
    qmldir="$PWD/${qmlDir}"
    [ -d "$qmldir" ] || { echo "no QML directory at $qmldir (metadata.json view: ${qmlEntry})" >&2; exit 1; }
    cmakeFlagsArray+=("-DLOGOS_VIEW_QML_DIR=$qmldir")
  '';

  env.LOGOS_MODULE_BUILDER_ROOT = "${builderRoot}";

  # The view ABI and qt_plugin_instance are the artifact's entire reason to
  # exist; never let fixup strip them.
  dontStrip = true;

  # logos_view_framework() writes the image to <build>/view/.
  installPhase = ''
    runHook preInstall
    fw=$out/Library/Frameworks/${stem}.framework
    # FLAT, not versioned: iOS refuses a framework with a Versions/ tree and
    # codesign refuses to sign one inside an app.
    mkdir -p "$fw"
    install -m755 view/${stem}.dylib "$fw/${stem}"
    install -m644 ${infoPlist} "$fw/Info.plist"
    install_name_tool -id "@rpath/${stem}.framework/${stem}" "$fw/${stem}"
    # The manifest the host has to carry for this module: there is nowhere in
    # <App>.app/Frameworks/ to put one beside the image, so it travels
    # separately and is compiled into the host (same arrangement the Bare
    # modules use).
    install -Dm644 metadata.json $out/share/logos/${config.name}/metadata.json
    # A pointer into the bundle so a consumer can name the image without
    # knowing the layout; the framework is the artifact.
    mkdir -p $out/lib
    ln -s "$fw/${stem}" "$out/lib/${stem}.dylib"
    runHook postInstall
  '';

  # postFixup, NOT installCheckPhase: nixpkgs computes `doInstallCheck &&
  # buildPlatform.canExecute hostPlatform`, which is off under cross — an iOS
  # artifact gated in installCheckPhase is an artifact that is never gated.
  # (Measured on the Bare module; see buildBareModule.nix.) fixupPhase is also
  # the last thing that rewrites the binary, so this is the first moment the
  # bytes are the shipped bytes.
  postFixup = ''
    echo "logos-module-builder: gating ${stem}"
    bash ${gateScript} "$out/Library/Frameworks/${stem}.framework"
  '';

  meta = with lib; {
    description = "${config.description} (iOS view framework: Qt bound upward)";
    platforms = [ "aarch64-darwin" ];
  };
}
