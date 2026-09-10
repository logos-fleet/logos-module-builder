# Builder for the **Bare module** artifact — the protocol-free shape of a module
# (see docs/nix-api.md, "The `bare` output").
#
# The build reuses the module's own `generate` output — the tree after every
# code generator has run, staged Rust/Go archives and external libs included —
# so a bare artifact is compiled from exactly the sources a plugin build
# compiles, minus the Qt ones. `LOGOS_MODULE_BARE=ON` makes `logos_module()`
# take the `logos_bare_module()` path in LogosModule.cmake and return before it
# looks for Qt at all, which is why neither Qt nor logos-qt-sdk appears below.
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
}:

let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  libExt = if isDarwin then "dylib" else "so";
  artifact = "${config.name}_bare.${libExt}";

  # The gate reads the symbol table and the load commands, so it needs the
  # platform's binary tools by name.
  binTools = if isDarwin then [ pkgs.darwin.cctools ] else [ pkgs.binutils ];

in pkgs.stdenv.mkDerivation {
  pname = "logos-${config.name}-bare";
  version = config.version;

  src = generatedSrc;

  nativeBuildInputs = [ pkgs.cmake pkgs.ninja pkgs.pkg-config ] ++ binTools ++ extraNativeBuildInputs;
  buildInputs = [ pkgs.nlohmann_json ] ++ extraBuildInputs;

  cmakeFlags = [
    "-GNinja"
    "-DLOGOS_MODULE_BARE=ON"
    "-DLOGOS_CPP_SDK_ROOT=${logosSdk}"
    "-DLOGOS_PROTOCOL_ROOT=${logosProtocol}"
  ]
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
  installPhase = ''
    runHook preInstall
    install -Dm755 bare/${artifact} $out/lib/${artifact}
    ${lib.optionalString isDarwin ''
      install_name_tool -id "@rpath/${artifact}" "$out/lib/${artifact}"
    ''}
    runHook postInstall
  '';

  # ── the gate ────────────────────────────────────────────────────────────
  # "Protocol-free" is only true if the linker agrees: run the gate over the
  # installed artifact and fail the derivation when it does not.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    echo "logos-module-builder: gating ${artifact}"
    LOGOS_MODULE_IMPL_EXPORTS=${moduleImplAbi}/exports.txt \
      bash ${gateScript} "$out/lib/${artifact}"
    runHook postInstallCheck
  '';

  meta = with lib; {
    description = "${config.description} (Bare module: protocol-free, no Qt)";
    platforms = platforms.unix;
  };
}
