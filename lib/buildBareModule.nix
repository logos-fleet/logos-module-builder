# Builder for the **Bare module** artifact — the protocol-free shape of a module.
#
# A Bare module (workspace glossary) is the module impl plus its core, exporting
# the common module-impl C ABI, with the logos-protocol consumer ABI (`lp_*`)
# left undefined for the host image to supply, and with no Qt, no generated Qt
# glue and no logos-protocol archive anywhere in it. It is what an iOS embedded
# framework and the Wasm host are both cut from.
#
# The build reuses the module's own `generate` output — the snapshot of the tree
# after every code generator has run, staged Rust staticlib and external libs
# included — so a bare artifact is compiled from exactly the sources a plugin
# build compiles, minus the Qt ones. Nothing is generated twice and nothing is
# generated differently.
#
# `LOGOS_MODULE_BARE=ON` makes LogosModule.cmake's `logos_module()` take the
# `logos_bare_module()` path and return before it looks for Qt at all — which
# is why neither Qt nor logos-qt-sdk appears below.
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
  # Compiled Rust/Go archives are staged in lib/ by the generate step; these are
  # the basenames LogosModule.cmake links whole into the artifact.
  rustStaticNames ? [],
  goStaticNames ? [],
  extraNativeBuildInputs ? [],
  extraBuildInputs ? [],
  extraCmakeFlags ? [],
  extraEnv ? {},
}:

let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  libExt = if isDarwin then "dylib" else "so";
  artifact = "${config.name}_bare.${libExt}";

  # The gate reads the symbol table and the load commands, so it needs the
  # platform's binary tools by name.
  binTools = if isDarwin then [ pkgs.darwin.cctools ] else [ pkgs.binutils ];

in pkgs.stdenv.mkDerivation ({
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
  ]
  ++ extraCmakeFlags;

  # The generators already ran in the `generate` derivation this unpacks; a
  # second run would only risk diverging from the tree that was snapshotted.
  preConfigure = ''
    echo "logos-module-builder: bare build of ${config.name} (no Qt, no logos-protocol archive)"
  '';

  # Qt embeds nothing here, but the module-impl ABI exports are the artifact's
  # entire reason to exist — never let fixup strip them.
  dontStrip = true;

  env = {
    LOGOS_CPP_SDK_ROOT = "${logosSdk}";
    LOGOS_PROTOCOL_ROOT = "${logosProtocol}";
    LOGOS_MODULE_BUILDER_ROOT = "${builderRoot}";
  } // extraEnv;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib
    if [ -f bare/${artifact} ]; then
      cp bare/${artifact} $out/lib/
    elif [ -f ${artifact} ]; then
      cp ${artifact} $out/lib/
    else
      echo "Error: the bare artifact ${artifact} was not produced" >&2
      find . -name '*_bare.*' -type f 2>/dev/null || true
      exit 1
    fi

    ${lib.optionalString isDarwin ''
      ${pkgs.darwin.cctools}/bin/install_name_tool -id "@rpath/${artifact}" "$out/lib/${artifact}"
    ''}

    runHook postInstall
  '';

  # ── the gate ────────────────────────────────────────────────────────────
  # "Protocol-free" is only true if the linker agrees. Run the gate over the
  # installed artifact and fail the derivation when it does not: a Bare module
  # that quietly picked up Qt or linked the logos-protocol archive must never
  # reach a consumer.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    echo "logos-module-builder: gating ${artifact}"
    bash ${gateScript} "$out/lib/${artifact}"
    runHook postInstallCheck
  '';

  meta = with lib; {
    description = "${config.description} (Bare module: protocol-free, no Qt)";
    platforms = platforms.unix;
  };
})
