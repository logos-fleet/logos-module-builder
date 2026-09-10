# Builder for the **Bare module** artifact — the protocol-free shape of a module
# (see docs/nix-api.md, "The `bare` output").
#
# The build reuses the module's own `generate` output — the tree after every
# code generator has run, staged Rust/Go archives and external libs included —
# so a bare artifact is compiled from exactly the sources a plugin build
# compiles, minus the Qt ones. `LOGOS_MODULE_BARE=ON` makes `logos_module()`
# take the `logos_bare_module()` path in LogosModule.cmake and return before it
# looks for Qt at all, which is why neither Qt nor logos-qt-sdk appears below.
#
# ONE FUNCTION, FOUR HOST SHAPES. The same call produces the native .so/.dylib,
# the iOS embedded FRAMEWORK BUNDLE and the Android .so; which one comes out is
# read off `pkgs.stdenv.hostPlatform`, never passed in, so a caller cannot ask
# for an iOS framework from a Linux package set. The mobile shapes differ from
# the native one in exactly three ways and no more:
#
#   * iOS compiles through Xcode's clang (pkgs.xcodeClang, a `__noChroot`
#     derivation — ADR 0002) because nix's cc-wrapper cannot target iOS;
#   * the artifact is wrapped in a flat `<name>_bare.framework` with an
#     Info.plist, and its install_name points into that bundle, because
#     `<App>.app/Frameworks/` is the only place an iOS app may carry a dylib;
#   * Android installs as `lib<name>_bare.so`, because an APK carries only
#     files matching `lib*.so` and androiddeployqt drops anything else.
#
# The gate runs over all four, unchanged.
{ lib }:

{
  pkgs,
  config,
  # The module's `generate` output: source + fully-populated generated_code/.
  # Platform-independent by construction (it is source), which is why the
  # mobile builds take the BUILD platform's copy rather than re-running every
  # code generator under a cross package set that has no Qt in it.
  generatedSrc,
  builderRoot,
  logosSdk,
  logosProtocol,
  gateScript,
  # logos-protocol's published module-impl export list
  # (packages.<sys>.module-impl-abi); the gate reads the ABI from it.
  moduleImplAbi,
  # Basenames of the Rust/Go archives staged in lib/ by the generate step;
  # LogosModule.cmake links them whole into the artifact.
  rustStaticNames ? [],
  goStaticNames ? [],
  extraNativeBuildInputs ? [],
  extraBuildInputs ? [],
}:

let
  host = pkgs.stdenv.hostPlatform;
  isIos = host.isiOS or false;
  isAndroid = host.isAndroid or false;
  isDarwin = host.isDarwin;

  # What CMake writes into <build>/bare/. PREFIX is cleared and OUTPUT_NAME is
  # "<name>_bare" (LogosModule.cmake), so this is the same on every host.
  stem = "${config.name}_bare";
  builtName = "${stem}.${if isDarwin then "dylib" else "so"}";

  # ...and what leaves the derivation. `_bare` has to survive into the INSTALLED
  # filename whatever the platform decoration around it: liblogos identifies a
  # Bare module by that stem suffix (module_registry.cpp, looksLikeBareModule),
  # so `libbare_counter_bare.so` and `bare_counter_bare.framework/bare_counter_bare`
  # both still answer yes.
  installedName = if isAndroid then "lib${stem}.so" else builtName;

  appleSdk =
    if !isIos then null
    else if host.darwinPlatform == "ios-simulator" then "iphonesimulator"
    else "iphoneos";
  iosPlatformName = if appleSdk == "iphonesimulator" then "iPhoneSimulator" else "iPhoneOS";
  # Matches nix/ios/cross-overlay.nix's iosDeploymentTarget: the floor every
  # hand-rolled iOS artifact in this stack targets.
  iosDeploymentTarget = "17.0";

  # CFBundleIdentifier is an RFC 1034 name: letters, digits and HYPHENS. A
  # module name is snake_case, and an underscore here makes codesign refuse the
  # bundle at app-signing time, which is a failure three steps away from its
  # cause.
  bundleId = "co.logos.module." + lib.replaceStrings [ "_" ] [ "-" ] config.name;

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

  # The gate reads the symbol table and the load commands, so it needs binary
  # tools that can read the ARTIFACT's format — which, under cross, is not the
  # builder's own. It picks the reader off the file's magic bytes and honours
  # NM / OTOOL / READELF, so the whole platform question is answered here.
  #
  #   iOS      Xcode's nm/otool, already on PATH from xcodeWrapper.
  #   Android  the NDK's LLVM bintools, which read aarch64 ELF from a Mac.
  #            `nm`/`readelf` by those names do not exist on Darwin at all.
  #   native   the platform's own.
  binTools =
    if isIos then [ ]
    else if isAndroid then [ pkgs.pkgsBuildBuild.llvmPackages.bintools-unwrapped ]
    else if isDarwin then [ pkgs.darwin.cctools ]
    else [ pkgs.binutils ];

  gateEnv = lib.optionalString isAndroid ''
    export NM=llvm-nm
    export READELF=llvm-readelf
  '';

  mkDerivation = if isIos then pkgs.xcodeClang.mkDerivation else pkgs.stdenv.mkDerivation;

  # ── how an Android Bare module reaches the host's lp_* ─────────────────────
  # THE SONAME OF THE HOST'S logos-protocol IMAGE, recorded as a DT_NEEDED.
  #
  # On every other platform "the host image supplies lp_*" needs no spelling:
  # a Mach-O says it with `-undefined dynamic_lookup`, and on Linux the host is
  # an executable, which the loader always searches. Android has neither.
  # Bionic resolves a dlopen'd library's undefined symbols against its own
  # DT_NEEDED closure and the linker namespace's GLOBAL group -- and an app's
  # own libraries are never in the global group, because everything an Android
  # app loads goes through System.load(), a LOCAL dlopen into the classloader
  # namespace. Re-opening the protocol image with RTLD_GLOBAL does not promote
  # it. Measured on an SM-G990B, both with and without RTLD_NOLOAD: the promote
  # call succeeds and the module still fails with
  #   dlopen failed: cannot locate symbol "lp_token_save"
  #
  # So DT_NEEDED is not one option among several here, it is the only mechanism
  # the platform has.
  #
  # HOW, without linking any protocol code: the module is linked against an
  # EMPTY shared object carrying this soname. `--no-as-needed` makes the linker
  # record the dependency even though not one symbol is taken from it, which is
  # the whole trick -- every `lp_*` stays UNDEFINED in the artifact, so the gate
  # is as strict as it ever was, and the ELF simply names where they come from.
  androidHostAbiSoname = "liblogos_protocol.so";

  # find_package(logos-cpp-sdk) does find_dependency(nlohmann_json), and under
  # cross neither prefix is on a path CMake searches by default: an iOS
  # toolchain re-roots find_package at the SDK sysroot. Name both explicitly
  # rather than rely on the setup hook, which differs between the two stdenvs
  # this function may be running under.
  # Mobile only: on a native build the cmake setup hook already puts every
  # buildInput on CMAKE_PREFIX_PATH, and passing -DCMAKE_PREFIX_PATH there
  # would REPLACE that list rather than add to it.
  findRootFlags = lib.optionals (isIos || isAndroid)
    (let roots = lib.concatStringsSep ";" [ "${pkgs.nlohmann_json}" "${logosSdk}" ]; in [
      "-DCMAKE_PREFIX_PATH=${roots}"
      "-DCMAKE_FIND_ROOT_PATH=${roots}"
    ]);

  # iOS: no nix cc-wrapper, so the sysroot and the architecture have to be
  # named. Deliberately NOT pkgs.logosQtCrossCmakeFlags — that carries
  # QT_HOST_PATH and the iOS Qt prefix paths, and a Bare module must not so
  # much as evaluate Qt.
  iosCmakeFlags = lib.optionals isIos [
    "-DCMAKE_OSX_SYSROOT=${appleSdk}"
    "-DCMAKE_OSX_ARCHITECTURES=${host.darwinArch}"
    "-DCMAKE_OSX_DEPLOYMENT_TARGET=${iosDeploymentTarget}"
  ];

  # Built in the derivation rather than as a separate one: it has to be
  # produced by the SAME cross toolchain that links the module, and it holds no
  # bytes worth caching -- an empty .so is 8 KB of ELF header.
  androidHostAbiStub = lib.optionalString isAndroid ''
    : > logos_host_abi_stub.c
    $CC -shared -fPIC -nostdlib -o logos_host_abi_stub.so logos_host_abi_stub.c \
      -Wl,-soname,${androidHostAbiSoname}
    cmakeFlagsArray+=("-DLOGOS_MODULE_BARE_LINK_HOST_ABI=$PWD/logos_host_abi_stub.so")
  '';

  installPhase =
    if isIos then ''
      runHook preInstall
      fw=$out/Library/Frameworks/${stem}.framework
      # FLAT, not versioned: iOS refuses a framework with a Versions/ tree, and
      # codesign refuses to sign one inside an app.
      mkdir -p "$fw"
      install -m755 bare/${builtName} "$fw/${stem}"
      install -m644 ${infoPlist} "$fw/Info.plist"
      # What dyld will look for once Xcode has copied the bundle into
      # <App>.app/Frameworks/ and the app carries @executable_path/Frameworks
      # on its rpath.
      install_name_tool -id "@rpath/${stem}.framework/${stem}" "$fw/${stem}"
      # A convenience path so a consumer can name the image without knowing the
      # bundle layout; the framework is the artifact, this is a pointer into it.
      mkdir -p $out/lib
      ln -s "$fw/${stem}" "$out/lib/${installedName}"
      runHook postInstall
    '' else ''
      runHook preInstall
      install -Dm755 bare/${builtName} $out/lib/${installedName}
      ${lib.optionalString isAndroid ''
        # The APK carries the file under this name, and a DT_NEEDED or a
        # dlopen("lib..._bare.so") has to find the SONAME it was built with.
        patchelf --set-soname "${installedName}" "$out/lib/${installedName}"
      ''}
      ${lib.optionalString (isDarwin && !isIos) ''
        install_name_tool -id "@rpath/${installedName}" "$out/lib/${installedName}"
      ''}
      runHook postInstall
    '';

  # What the gate is pointed at. For iOS that is the bundle: the gate resolves a
  # `.framework` directory to the Mach-O inside it, so the thing checked is the
  # thing shipped.
  gateTarget =
    if isIos then "$out/Library/Frameworks/${stem}.framework"
    else "$out/lib/${installedName}";

in mkDerivation ({
  pname = "logos-${config.name}-bare";
  version = config.version;

  src = generatedSrc;

  nativeBuildInputs = [ pkgs.cmake pkgs.ninja pkgs.pkg-config ]
    ++ binTools
    ++ lib.optional isAndroid pkgs.pkgsBuildBuild.patchelf
    ++ extraNativeBuildInputs;
  buildInputs = [ pkgs.nlohmann_json ] ++ extraBuildInputs;

  cmakeFlags = [
    "-GNinja"
    "-DLOGOS_MODULE_BARE=ON"
    "-DLOGOS_CPP_SDK_ROOT=${logosSdk}"
    "-DLOGOS_PROTOCOL_ROOT=${logosProtocol}"
  ]
  ++ findRootFlags
  ++ iosCmakeFlags
  ++ lib.optionals (rustStaticNames != []) [
    "-DLOGOS_MODULE_RUST_STATIC_LIBS=${lib.concatStringsSep ";" rustStaticNames}"
  ]
  ++ lib.optionals (goStaticNames != []) [
    "-DLOGOS_MODULE_GO_STATIC_LIBS=${lib.concatStringsSep ";" goStaticNames}"
  ];

  # The module-impl ABI exports are the artifact's entire reason to exist;
  # never let fixup strip them.
  dontStrip = true;

  env.LOGOS_MODULE_BUILDER_ROOT = "${builderRoot}";

  # logos_bare_module() writes the artifact to <build>/bare/.
  inherit installPhase;

  # ── the gate ────────────────────────────────────────────────────────────
  # "Protocol-free" is only true if the linker agrees: run the gate over the
  # installed artifact and fail the derivation when it does not.
  #
  # postFixup, NOT installCheckPhase, and the reason is not style. nixpkgs
  # computes `doInstallCheck = doInstallCheck && buildPlatform.canExecute
  # hostPlatform`, so under cross the phase is switched OFF -- silently. The
  # first iOS build here produced a framework and skipped the gate entirely,
  # which is the exact failure the gate exists to prevent, one level up.
  #
  # It belongs here on its own merits anyway: the gate RUNS ON THE BUILDER and
  # only READS the artifact, so it is not "run the tests" in any sense
  # canExecute has an opinion about -- and fixupPhase is the last thing that
  # rewrites the binary (install_name, strip), so this is the first moment the
  # bytes are the shipped bytes.
  postFixup = ''
    echo "logos-module-builder: gating ${installedName}"
    ${gateEnv}
    LOGOS_MODULE_IMPL_EXPORTS=${moduleImplAbi}/exports.txt \
      bash ${gateScript} "${gateTarget}"
  '';

  meta = with lib; {
    description = "${config.description} (Bare module: protocol-free, no Qt)";
    platforms = platforms.unix;
  };
}
# CONDITIONAL, and INSIDE the argument set. `preConfigure = androidHostAbiStub`
# unconditionally would replace pkgs.xcodeClang.mkDerivation's own preConfigure,
# which exports CC/CXX/AR from xcrun because nix's cc-wrapper cannot target iOS
# — measured as "CMAKE_CXX_COMPILER not set" on the iOS leg. And `//` applied to
# mkDerivation's RESULT instead of its argument silently adds an attribute to
# the derivation that no build phase ever reads, which is how this first shipped
# with no DT_NEEDED and no diagnostic anywhere.
// lib.optionalAttrs isAndroid {
  preConfigure = androidHostAbiStub;
})
