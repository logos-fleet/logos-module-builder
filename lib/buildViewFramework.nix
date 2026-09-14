# Builder for the **mobile view image** — a `type: ui_qml` module as ONE
# library carrying its Qt backend and its QML (docs/nix-api.md, "The `view`
# output").
#
# Same relationship to the desktop Qt plugin that `bare` has to it: both are cut
# from the module's own `generate` output — the tree after every code generator
# has run — so the view image and the plugin compile the SAME sources. What
# differs is the link, and only the link.
#
# TWO HOST SHAPES, and the package set decides which — never an argument, for
# the same reason buildBareModule reads its four shapes off the host platform.
#
#   iOS      an embedded framework with NOTHING linked. Qt, logos-qt-host and
#            the lp_* C ABI are left undefined for the app image to supply at
#            dlopen (ADR 0006). Only iOS can do this: Apple's dyld resolves a
#            flat namespace, and logos-nix builds the iOS Qt with
#            `reduce_exports` off so the app's export trie actually carries Qt
#            (spike ios-dlopen-bare-module, the precondition for Level 2).
#
#   Android  a plain `lib<name>_view.so`, and this is the EASIER platform for
#            it, not the harder one. Qt there is a set of shared objects that
#            androiddeployqt already packages, so the module simply names
#            libQt6Core_<abi>.so and friends in DT_NEEDED and the app's own Qt
#            answers. The Logos host runtime is named the same way a Bare
#            module names it — an empty stub carrying the host image's SONAME,
#            because bionic resolves a dlopen'd library only against its own
#            DT_NEEDED closure and the global group, and an app's libraries are
#            never in the global group. Everything stays UNDEFINED in the
#            artifact; the ELF only says where to look.
#
# A caller that hands this function neither package set gets told so.
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
  isAndroid = host.isAndroid or false;

  stem = "${config.name}_view";

  # What CMake writes into <build>/view/, and what leaves the derivation.
  # They differ only in that an iOS framework's binary is bare `<stem>` inside
  # the bundle, while on Android `lib<stem>.so` is the shipped name — an APK
  # carries only files matching lib*.so and androiddeployqt drops anything
  # else, exactly as for a Bare module.
  builtName = if isAndroid then "lib${stem}.so" else "${stem}.dylib";

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

  # The Qt modules this image finds, compiles against, and — on Android only —
  # links. ONE list for both platforms, because "which Qt a view backend uses"
  # is a property of the module and not of the phone.
  qtModules = with pkgs.qt6; [
    qtbase
    qtdeclarative
    qtshadertools
    qtsvg
    qtremoteobjects
  ];

  # ── how an Android view image reaches the app's Logos runtime ─────────────
  # THE SONAMES OF THE HOST'S IMAGES, recorded as DT_NEEDED. Same mechanism and
  # same reasoning as buildBareModule's `androidHostAbiSoname` — bionic resolves
  # a dlopen'd library's undefined symbols against its own DT_NEEDED closure and
  # the linker namespace's GLOBAL group, and an app's own libraries are never
  # global, because everything an Android app loads goes through System.load().
  # TWO here rather than one: a view image is a Qt backend, so it uses LogosAPI
  # and the provider glue (liblogos_qt_host.so) as well as the lp_* C ABI
  # (liblogos_protocol.so). Both are in every Logos APK — logos-liblogos's
  # Android chain installs them beside liblogos_core.
  androidHostAbiSonames = [ "liblogos_protocol.so" "liblogos_qt_host.so" ];

  # Built in the derivation rather than as separate ones: each has to be
  # produced by the SAME cross toolchain that links the image, and holds no
  # bytes worth caching — an empty .so is 8 KB of ELF header.
  androidHostAbiStubs = ''
    : > logos_host_abi_stub.c
    stubs=""
    for soname in ${lib.escapeShellArgs androidHostAbiSonames}; do
      $CC -shared -fPIC -nostdlib -o "$PWD/$soname" logos_host_abi_stub.c \
        -Wl,-soname,"$soname"
      stubs="''${stubs:+$stubs;}$PWD/$soname"
    done
    # A `;`-list, which is how CMake spells a list — and the only spelling that
    # survives: nixpkgs' cmake hook expands cmakeFlags UNQUOTED, so a flag
    # carrying a space would arrive as two arguments.
    cmakeFlagsArray+=("-DLOGOS_VIEW_LINK_HOST_ABI=$stubs")
  '';

  # The gate reads the symbol table and the load commands, so it needs binary
  # tools that can read the ARTIFACT's format — which, under cross, is not the
  # builder's own. Same three-way answer buildBareModule gives, minus the
  # native case this function never sees.
  #
  #   iOS      Xcode's nm/otool, already on PATH from xcodeWrapper.
  #   Android  the NDK's LLVM bintools, which read aarch64 ELF from a Mac.
  #            `nm`/`readelf` by those names do not exist on Darwin at all.
  binTools = lib.optionals isAndroid [
    pkgs.pkgsBuildBuild.llvmPackages.bintools-unwrapped
  ];

  gateEnv = lib.optionalString isAndroid ''
    export NM=llvm-nm
    export READELF=llvm-readelf
  '';

  # ── the second gate, on Android ──────────────────────────────────────────
  # A view image may only name sonames the app ships or Android guarantees.
  # Qt's are admitted by DIRECTORY — androiddeployqt packages exactly the
  # modules a target links, so naming the prefixes it linked is the honest
  # statement of "the app carries these", and it cannot drift as Qt's
  # per-ABI file naming changes. The three by name are the ones the CONTAINER
  # promises rather than the linker:
  #   libc++_shared.so      Qt's Android platform refuses any other STL
  #                         (QtPlatformAndroid.cmake), so every Logos APK
  #                         packages it and every image shares that one copy.
  #   liblogos_protocol.so  the empty host-ABI stubs' sonames; the app's own
  #   liblogos_qt_host.so   images supply them. See androidHostAbiSonames.
  androidDtNeededFlags = lib.escapeShellArgs (
    lib.concatMap (s: [ "--allow" s ]) ([ "libc++_shared.so" ] ++ androidHostAbiSonames)
    ++ lib.concatMap (m: [ "--allow-dir" "${lib.getLib m}/lib" ]) qtModules);

  androidDtNeededGate = lib.optionalString isAndroid ''
    ${pkgs.logosAndroidDtNeededGate}/bin/logos-android-dt-needed-gate \
      ${androidDtNeededFlags} "$out/lib/${builtName}"
  '';

  installPhase =
    if isAndroid then ''
      runHook preInstall
      install -Dm755 view/${builtName} $out/lib/${builtName}
      # The APK carries the file under this name, and a DT_NEEDED or a
      # dlopen("lib..._view.so") has to find the SONAME it was built with.
      patchelf --set-soname "${builtName}" "$out/lib/${builtName}"
      # The manifest the host has to carry for this module, for the same reason
      # as on iOS: the app's native library directory is flat and there is
      # nowhere beside the image to put one.
      install -Dm644 metadata.json $out/share/logos/${config.name}/metadata.json
      runHook postInstall
    '' else ''
      runHook preInstall
      fw=$out/Library/Frameworks/${stem}.framework
      # FLAT, not versioned: iOS refuses a framework with a Versions/ tree and
      # codesign refuses to sign one inside an app.
      mkdir -p "$fw"
      install -m755 view/${builtName} "$fw/${stem}"
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

  # What the gate is pointed at. For iOS that is the bundle: the gate resolves a
  # `.framework` directory to the Mach-O inside it, so the thing checked is the
  # thing shipped.
  gateTarget =
    if isAndroid then "$out/lib/${builtName}"
    else "$out/Library/Frameworks/${stem}.framework";

in
if !isIos && !isAndroid then
  throw ("logos-module-builder: the `view` output (a ui_qml module as one "
    + "image carrying its Qt backend and its QML) exists for the iOS and "
    + "Android package sets, and this one is " + host.system + ".")
else
(if isIos then pkgs.xcodeClang.mkDerivation else pkgs.stdenv.mkDerivation) {
  pname = "logos-${config.name}-view";
  version = config.version;

  src = generatedSrc;

  nativeBuildInputs = [ pkgs.cmake pkgs.ninja ]
    ++ binTools
    ++ lib.optional isAndroid pkgs.pkgsBuildBuild.patchelf
    ++ extraNativeBuildInputs;
  # Qt for the TARGET. On iOS it is found, compiled against and never linked;
  # on Android it is found, compiled against and LINKED by soname. It is a
  # buildInput rather than a bare prefix path so the cmake setup hook puts it
  # where find_package(Qt6) looks, exactly as mkIosCmakeStage does.
  buildInputs = qtModules ++ extraBuildInputs;

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
    # Relative to LOGOS_VIEW_QML_DIR, which preConfigure makes absolute below —
    # the entry stays relative, because it is also the name the qrc path is
    # built from.
    "-DLOGOS_VIEW_QML_ENTRY=${qmlEntry}"
  ] ++ pkgs.logosQtCrossCmakeFlags
  # Qt6Config only looks for EXTRA modules (Quick, RemoteObjects) under the
  # prefixes named here, and the Android overlay's own flags list none on the
  # target side. Same line, same reason, as logos-liblogos's Android chain.
  ++ lib.optional isAndroid
    "-DQT_ADDITIONAL_PACKAGES_PREFIX_PATH=${lib.concatMapStringsSep ";" toString qtModules}";

  # QML_DIR has to be an ABSOLUTE path (file(GLOB_RECURSE) and qt6_add_resources
  # BASE both take one), and the only moment its absolute form is known is
  # after unpackPhase. On iOS, xcodeClang.mkDerivation's own preConfigure is
  # composed in rather than replaced — it exports CC/CXX from xcrun, without
  # which cmake reports "CMAKE_CXX_COMPILER not set".
  preConfigure = lib.optionalString isIos ''
    export CC=$(xcrun --sdk ${appleSdk} --find clang)
    export CXX=$(xcrun --sdk ${appleSdk} --find clang++)
    export AR=$(xcrun --sdk ${appleSdk} --find ar)
    export RANLIB=$(xcrun --sdk ${appleSdk} --find ranlib)
    export STRIP=$(xcrun --sdk ${appleSdk} --find strip)
    cmakeFlagsArray+=(-DCMAKE_SYSTEM_NAME=iOS)
  '' + lib.optionalString isAndroid androidHostAbiStubs + ''
    qmldir="$PWD/${qmlDir}"
    [ -d "$qmldir" ] || { echo "no QML directory at $qmldir -- the generate tree has no ${qmlDir}, and the image's qrc is built from it" >&2; exit 1; }
    cmakeFlagsArray+=("-DLOGOS_VIEW_QML_DIR=$qmldir")
  '';

  env.LOGOS_MODULE_BUILDER_ROOT = "${builderRoot}";

  # The view ABI and qt_plugin_instance are the artifact's entire reason to
  # exist; never let fixup strip them.
  dontStrip = true;

  # A LIBRARY, on both legs. nixpkgs' Qt setup hook refuses to proceed until a
  # derivation with qtbase in its inputs says which it is, and there is no app
  # here to wrap -- the image is dlopen'd by a host that is itself the app.
  dontWrapQtApps = true;

  # logos_view_framework() writes the image to <build>/view/.
  inherit installPhase;

  # postFixup, NOT installCheckPhase: nixpkgs computes `doInstallCheck &&
  # buildPlatform.canExecute hostPlatform`, which is off under cross — a mobile
  # artifact gated in installCheckPhase is an artifact that is never gated.
  # (Measured on the Bare module; see buildBareModule.nix.) fixupPhase is also
  # the last thing that rewrites the binary, so this is the first moment the
  # bytes are the shipped bytes.
  postFixup = ''
    echo "logos-module-builder: gating ${builtName}"
    ${gateEnv}
    bash ${gateScript} "${gateTarget}"
    ${androidDtNeededGate}
  '';

  meta = with lib; {
    description = "${config.description} ("
      + (if isAndroid then "Android view image: Qt by soname"
                      else "iOS view framework: Qt bound upward") + ")";
    platforms = if isAndroid then platforms.aarch64 else [ "aarch64-darwin" ];
  };
}
