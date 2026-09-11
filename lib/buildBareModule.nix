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
# ONE FUNCTION, FOUR HOST SHAPES: the native .so, the native .dylib, the iOS
# embedded FRAMEWORK BUNDLE and the Android .so. Which one comes out is read off
# `pkgs.stdenv.hostPlatform`, never passed in, so a caller cannot ask for an iOS
# framework from a Linux package set. The mobile shapes differ from the native
# one in exactly three ways and no more:
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
  # Archives to drop into lib/ before cmake, REPLACING whatever the generate
  # step staged there. `generate` is a source tree and is therefore right for
  # every target -- except in lib/, where it snapshotted a BUILD-platform
  # Rust/Go archive. A mobile caller passes the target's archive here; a native
  # one passes nothing and keeps what generate staged.
  stagedArchives ? [],
  # `nix.external_libraries`, built FOR this target. Same problem as
  # stagedArchives and a different shape of answer: `generate` staged a
  # build-platform image of each one into lib/, and no amount of re-running the
  # generators would change that -- an external library comes from its OWN
  # flake. A mobile caller resolves the target's build of it (the module's
  # flake publishes one, see mkLogosModule's `mobilePackages`) and passes
  # `{ name; drv; }` here; the build-platform image is DELETED before the
  # target's lands, because _logos_find_external_lib prefers a shared library
  # over a static one and would otherwise keep linking the one for the Mac.
  stagedExternalLibs ? [],
  extraNativeBuildInputs ? [],
  extraBuildInputs ? [],
  # Gating that runs after the Bare gate, over the same artifact. Android
  # passes logos-nix's DT_NEEDED gate here: "no unbundled system libs" is a
  # different rule from "no Qt and no protocol code", judged on the same bytes
  # at the same moment.
  extraGateChecks ? "",
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

  # The device and the simulator share a triple; `darwinPlatform` is what
  # separates them, and it is the only thing either name below depends on.
  isIosSimulator = isIos && host.darwinPlatform == "ios-simulator";
  appleSdk = if isIosSimulator then "iphonesimulator" else "iphoneos";
  iosPlatformName = if isIosSimulator then "iPhoneSimulator" else "iPhoneOS";
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

  # The module's OWN declared dependencies — `nix.packages.build` and
  # `nix.packages.runtime` from metadata.json, already resolved out of THIS
  # target's package set by the caller. They are named here for the same reason
  # the SDK is: under cross, nothing puts them anywhere CMake or the compiler
  # looks.
  #
  # A native build never needed this. nix's cc-wrapper turns every buildInput
  # into -isystem <prefix>/include through NIX_CFLAGS_COMPILE, so a header-only
  # dependency is found whether or not the module's CMakeLists ever mentions
  # it. The iOS stdenv is stdenvNoCC driving Xcode's clang (logos-nix's
  # xcodeClang) and has no such wrapper, so the SAME metadata that builds
  # natively used to fail the cross compile at the first #include. Measured on
  # capability_module, whose only Boost use is boost/uuid (header-only):
  #     fatal error: 'boost/uuid/uuid.hpp' file not found
  # with pkgs.boost sitting in buildInputs the whole time.
  modulePrefixes =
    lib.unique (map toString (extraBuildInputs ++ extraNativeBuildInputs));

  # find_package(logos-cpp-sdk) does find_dependency(nlohmann_json), and under
  # cross neither prefix is on a path CMake searches by default: an iOS
  # toolchain re-roots find_package at the SDK sysroot. Name both explicitly
  # rather than rely on the setup hook, which differs between the two stdenvs
  # this function may be running under.
  # Mobile only: on a native build the cmake setup hook already puts every
  # buildInput on CMAKE_PREFIX_PATH, and passing -DCMAKE_PREFIX_PATH there
  # would REPLACE that list rather than add to it.
  #
  # `modulePrefixes` joins them so `cmake.find_packages` in metadata.json
  # (logos_bare_module runs find_package(<pkg> REQUIRED) over that list)
  # resolves against the TARGET's build of the package rather than failing --
  # or, worse, finding the build platform's.
  findRootFlags = lib.optionals (isIos || isAndroid)
    (let roots = lib.concatStringsSep ";"
      ([ "${pkgs.nlohmann_json}" "${logosSdk}" ] ++ modulePrefixes); in [
      "-DCMAKE_PREFIX_PATH=${roots}"
      "-DCMAKE_FIND_ROOT_PATH=${roots}"
    ]);

  # ...and the compile line, which CMAKE_PREFIX_PATH does not touch. Only iOS:
  # the Android package set is an ordinary nixpkgs cross stdenv and its
  # cc-wrapper already does this.
  #
  # CMAKE_CXX_STANDARD_INCLUDE_DIRECTORIES, not -DCMAKE_CXX_FLAGS=-isystem ...,
  # for a mechanical reason: nixpkgs' cmake hook expands `cmakeFlags` UNQUOTED
  # (`cmake $cmakeDir $cmakeFlags "''${cmakeFlagsArray[@]}"`), so any flag
  # containing a space is split into two arguments and cmake answers "Unknown
  # argument -isystem". This variable takes a SEMICOLON-separated list of
  # directories -- exactly what a toolchain file uses it for -- and adds each as
  # a SYSTEM include on every target, which is also what nix's cc-wrapper does
  # natively (so a dependency's headers stay exempt from the module's own
  # warning flags).
  iosIncludeFlags =
    let dirs = lib.optionals isIos (map (p: "${p}/include") modulePrefixes); in
    lib.optional (dirs != [])
      "-DCMAKE_CXX_STANDARD_INCLUDE_DIRECTORIES=${lib.concatStringsSep ";" dirs}";

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
  # Reached only through the `lib.optionalAttrs isAndroid` at the bottom.
  androidHostAbiStub = ''
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

  # Before cmake, and by overwrite rather than by flag: LogosModule.cmake
  # resolves each rustStaticNames entry to lib/lib<name>.a inside the source
  # tree, so the cross archive has to arrive under the name generate used.
  postPatch = lib.optionalString (stagedArchives != [] || stagedExternalLibs != []) ''
    mkdir -p lib
    ${lib.concatMapStringsSep "\n" (a: ''cp -f "${a}" lib/'') stagedArchives}
    ${lib.concatMapStringsSep "\n" (e: ''
      # Only the LIBRARY images go; the headers `generate` staged beside them
      # are source and are right for every target.
      for _ext in so dylib dll a lib; do
        rm -f "lib/lib${e.name}.$_ext" "lib/${e.name}.$_ext"
      done
      cp -fL ${e.drv}/lib/* lib/
      # -R: an include/ tree may have subdirectories (libp2p_module's staged
      # TinyCBOR is reached as <tinycbor/cbor.h>), and a flat copy fails on the
      # first one.
      if [ -d ${e.drv}/include ]; then cp -RfL ${e.drv}/include/* lib/; fi
      chmod -R u+w lib
    '') stagedExternalLibs}
  '';

  cmakeFlags = [
    "-GNinja"
    "-DLOGOS_MODULE_BARE=ON"
    "-DLOGOS_CPP_SDK_ROOT=${logosSdk}"
    "-DLOGOS_PROTOCOL_ROOT=${logosProtocol}"
  ]
  ++ findRootFlags
  ++ iosIncludeFlags
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
    # Named once, so extraGateChecks below does not have to restate the
    # per-platform artifact naming rule (framework bundle / lib<stem>.so).
    gateTarget="${gateTarget}"
    LOGOS_MODULE_IMPL_EXPORTS=${moduleImplAbi}/exports.txt \
      bash ${gateScript} "$gateTarget"
    ${extraGateChecks}
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
