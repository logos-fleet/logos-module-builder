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
# The same function produces the NATIVE artifact and the mobile ones. A Bare
# module links no Qt by definition, so cross-compiling it needs only a
# toolchain and a sysroot — everything platform-specific arrives through the
# arguments under "the platform" below, which mkLogosModule fills from the
# logos-nix cross overlay for the target.
{ lib }:

{
  pkgs,
  config,
  # The module's `generate` output: source + fully-populated generated_code/.
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

  # ── the platform ───────────────────────────────────────────────────────
  # Everything a cross target changes, defaulted to the native build so a
  # native caller passes none of it.
  #
  # How to make a derivation. iOS is not `pkgs.stdenv.mkDerivation`: nixpkgs'
  # own iOS cross stdenv does not build at this pin, so logos-nix compiles
  # every iOS target through Xcode's clang in a `__noChroot` derivation
  # (ADR 0002), which is what `pkgs.xcodeClang.mkDerivation` is.
  mkDerivation ? pkgs.stdenv.mkDerivation,
  # Whether the artifact will be Mach-O. Decides the extension and whether the
  # install name has to be rewritten -- NOT `pkgs.stdenv.hostPlatform.isDarwin`
  # read here, because a Mac cross-building for Android must answer "no".
  isMachO ? pkgs.stdenv.hostPlatform.isDarwin,
  # -D flags that put the compiler on the target (sysroot, arch, toolchain
  # file). Empty natively.
  targetCmakeFlags ? [],
  # cmake + ninja + the binary tools the gate reads the artifact with. The
  # default is the native set; a cross caller passes build-platform ones.
  toolchainNativeBuildInputs ?
    [ pkgs.cmake pkgs.ninja pkgs.pkg-config ]
    ++ (if pkgs.stdenv.hostPlatform.isDarwin then [ pkgs.darwin.cctools ] else [ pkgs.binutils ]),
  # NM / OTOOL / READELF for the gate, when they are not the ones on PATH.
  gateEnv ? {},
  # Archives to drop into lib/ before cmake, replacing whatever the generate
  # step staged there. This is how a Rust or Go core built for the TARGET
  # replaces the build-platform one `generate` snapshotted: `generate` is a
  # source tree, so it is correct for every target except in lib/.
  stagedArchives ? [],
  # Extra gating, appended to installCheckPhase -- the Android DT_NEEDED gate.
  extraInstallCheck ? "",
  # Where CMakeLists.txt is, relative to the build directory. Only a cross
  # caller sets it: xcodeClang.mkDerivation drives cmake through its own
  # preConfigure and is told the source directory this way.
  cmakeDir ? null,
  # Reach for host tools by name rather than letting them be spliced onto the
  # target. Correct everywhere, but only turned on for the cross callers: the
  # native `bare` output predates it and a module's own nix.packages lists were
  # not written against it.
  strictDeps ? false,
}:

let
  libExt = if isMachO then "dylib" else "so";
  artifact = "${config.name}_bare.${libExt}";

in mkDerivation ({
  pname = "logos-${config.name}-bare";
  version = config.version;

  src = generatedSrc;

  nativeBuildInputs = toolchainNativeBuildInputs ++ extraNativeBuildInputs;
  buildInputs = [ pkgs.nlohmann_json ] ++ extraBuildInputs;

  inherit strictDeps;

  postPatch = lib.optionalString (stagedArchives != []) ''
    mkdir -p lib
    ${lib.concatMapStringsSep "\n" (a: ''cp -f "${a}" lib/'') stagedArchives}
  '';

  cmakeFlags = [
    "-GNinja"
    "-DLOGOS_MODULE_BARE=ON"
    "-DLOGOS_CPP_SDK_ROOT=${logosSdk}"
    "-DLOGOS_PROTOCOL_ROOT=${logosProtocol}"
  ]
  ++ targetCmakeFlags
  ++ lib.optionals (rustStaticNames != []) [
    "-DLOGOS_MODULE_RUST_STATIC_LIBS=${lib.concatStringsSep ";" rustStaticNames}"
  ]
  ++ lib.optionals (goStaticNames != []) [
    "-DLOGOS_MODULE_GO_STATIC_LIBS=${lib.concatStringsSep ";" goStaticNames}"
  ];

  # The module-impl ABI exports are the artifact's entire reason to exist;
  # never let fixup strip them.
  dontStrip = true;

  env = { LOGOS_MODULE_BUILDER_ROOT = "${builderRoot}"; } // gateEnv;

  # logos_bare_module() writes the artifact to <build>/bare/.
  installPhase = ''
    runHook preInstall
    install -Dm755 bare/${artifact} $out/lib/${artifact}
    ${lib.optionalString isMachO ''
      install_name_tool -id "@rpath/${artifact}" "$out/lib/${artifact}"
    ''}
    runHook postInstall
  '';

  # ── the gate ────────────────────────────────────────────────────────────
  # "Protocol-free" is only true if the linker agrees: run the gate over the
  # installed artifact and fail the derivation when it does not.
  #
  # postFixup, NOT installCheckPhase, and that is load-bearing: nixpkgs'
  # mkDerivation computes `doInstallCheck && buildPlatform.canExecute
  # hostPlatform`, so under ANY cross build it quietly resolves to false and
  # the phase is skipped. This gate reads a symbol table -- it never runs the
  # artifact -- so there is nothing for that rule to protect against here, and
  # the shape it produces is the worst one available: three mobile Bare modules
  # that report themselves gated and were not. (Measured: the aarch64-ios-
  # simulator artifact built with `doInstallCheck = true` and no
  # installCheckPhase in the log at all.)
  postFixup = ''
    echo "logos-module-builder: gating ${artifact}"
    LOGOS_MODULE_IMPL_EXPORTS=${moduleImplAbi}/exports.txt \
      bash ${gateScript} "$out/lib/${artifact}"
    ${extraInstallCheck}
  '';

  meta = with lib; {
    description = "${config.description} (Bare module: protocol-free, no Qt)";
    platforms = platforms.unix;
  };
}
// lib.optionalAttrs (cmakeDir != null) { inherit cmakeDir; })
