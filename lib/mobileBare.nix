# The **Bare module**, cross-built for the mobile pseudo-systems
# (`aarch64-ios`, `aarch64-ios-simulator`, `aarch64-android`).
#
# Why this is a separate file rather than three more entries in
# `common.systems`: every OTHER output a module publishes is a Qt plugin or
# packages one (lgx, install, unit-tests, the ui_qml view), and none of those
# has a mobile shape at all -- an iOS app loads an embedded framework, not a
# Qt plugin. The Bare module is the one artifact that DOES cross, precisely
# because it carries no Qt. Folding the mobile targets into `systems` would
# ask for the other twenty outputs too and fail on the first of them.
#
# What crosses and what does not:
#   * `generate` -- the tree after every code generator has run -- is SOURCE,
#     and is taken from the build platform unchanged. Its one target-specific
#     corner is lib/, where the generate step staged a build-platform Rust
#     archive; the cross archive replaces it (see `stagedArchives`).
#   * logos-cpp-sdk and logos-protocol are consumed as HEADERS by a bare build
#     (LogosModule.cmake adds include directories and links neither), so the
#     build-platform packages are correct and nothing has to be cross-built.
#   * The toolchain, the sysroot and the gates come from logos-nix's cross
#     overlay for the target, through the four attribute names both mobile
#     overlays contribute.
{
  lib,
  common,
  buildBareModule,
  moduleImplAbiFor,
  builderRoot,
  logos-cpp-sdk,
  logos-protocol,
  rust-overlay ? null,
}:

{
  # The module.
  src,
  configFor,
  # `packages` for a given system, as mkLogosModule assembled it: this reads
  # `generate` (and `rust-crate-src`, for a codegen.rust module) out of the
  # BUILD platform's set.
  packagesFor,
  # Dotted-path package resolver, shared with mkLogosModule.
  getPkg,
  # The Android derivations' `system` is their BUILD platform, so an
  # x86_64-linux one cannot be realised on a Mac even though aarch64-darwin
  # builds the identical closure. Verifying Android from a Mac is
  # `{ androidBuildSystem = "aarch64-darwin"; }`. The iOS sets only
  # aarch64-darwin can build at all, so they take no parameter.
  androidBuildSystem ? "x86_64-linux",
}:

let
  # ── one target ────────────────────────────────────────────────────────
  bareFor = { system, pkgs, buildSystem }:
    let
      config = configFor buildSystem;
      buildPackages = packagesFor buildSystem;
      buildPkgs = common.mkPkgs buildSystem;

      isAndroid = system == "aarch64-android";

      # ── what does not cross yet ───────────────────────────────────────
      # `nix.external_libraries` are staged into lib/ by the generate step as
      # BUILD-PLATFORM images, and unlike a Rust core there is nothing here
      # that could rebuild them: each comes from its own flake, which would
      # have to publish a package for this target. Refused by name, at eval,
      # rather than left to the linker -- which reports it as
      #     ld: building for 'iOS-simulator', but linking in dylib
      #         (.../libfoo.dylib) built for 'macOS'
      # forty lines into a link command, saying nothing about whose library it
      # is or what would fix it. (Measured on package_manager_module, whose
      # external `lgx` is exactly this case.)
      externalLibNames = map (e: e.name or (toString e)) config.external_libraries;
      assertNoExternalLibs =
        if config.external_libraries == [ ] then null
        else throw ''
          logos-module-builder: module '${config.name}' cannot be built as a Bare
          module for ${system} yet: it declares nix.external_libraries
          (${lib.concatStringsSep ", " externalLibNames}).

          Those are staged into lib/ as build-platform images by the module's own
          `generate` step, and nothing here can recompile them -- each one comes
          from its own flake. For a mobile Bare module the external library has to
          be built for the target and staged in its place, which means the flake
          providing it publishing a package for ${system}.

          Until then this module has a native `bare` output and no mobile one.
          A codegen.rust core is different and DOES cross: the crate is rebuilt
          for the target here.
        '';

      # ── the Rust core, for the target ─────────────────────────────────
      # `generate` staged a build-platform archive into lib/; a Bare module
      # links it whole, so on mobile it has to be the target's.
      isRustModule = (config.codegen or { }) ? rust;
      rustCfg = (config.codegen or { }).rust or { };
      rustCrateDir = "${src}/${rustCfg.crate}";
      rustCargoToml = builtins.fromTOML (builtins.readFile "${rustCrateDir}/Cargo.toml");
      rustStaticName =
        rustCfg.staticlib
          or (rustCargoToml.lib.name
              or (lib.replaceStrings [ "-" ] [ "_" ] rustCargoToml.package.name));

      rustTriple = common.mobileRustTargets.${system}
        or (throw "logos-module-builder: no cargo target known for ${system}");

      # The toolchain must RUN on the builder and merely TARGET `system`. Taken
      # from rust-overlay rather than from nixpkgs' rustc because only
      # rust-overlay can add a target's std to an existing toolchain; nixpkgs'
      # cross rustPlatform would have to come from the TARGET set, which for
      # iOS does not have a working stdenv at all.
      rustBuildPkgs =
        if rust-overlay == null
        then throw ("logos-module-builder: module '" + config.name + "' is a "
          + "codegen.rust module and mobile targets need a cross Rust toolchain, "
          + "but this builder was built without a rust-overlay input.")
        else common.mkPkgsWith [ (import rust-overlay) ] buildSystem;
      rustToolchain =
        (if config.nix_rust.toolchain != null
         then rustBuildPkgs.rust-bin.stable.${config.nix_rust.toolchain}.default
         else rustBuildPkgs.rust-bin.stable.latest.default
        ).override { targets = [ rustTriple ]; };
      rustPlatform = rustBuildPkgs.makeRustPlatform {
        cargo = rustToolchain;
        rustc = rustToolchain;
      };

      # The crate's own system libraries, for the TARGET. A build script that
      # probes one does so with the build platform's pkg-config, which knows
      # nothing about cross: it refuses outright ("pkg-config has not been
      # configured to support cross-compilation") rather than answering wrongly.
      # Pointing it at the target .pc files and allowing cross is what turns
      # that refusal into the right answer. Both pkgconfig directories:
      # nixpkgs puts a .pc under share/ whenever it is architecture-independent
      # (zlib's is), and naming only lib/ finds nothing for those.
      rustTargetLibs =
        map (getPkg pkgs) (lib.filter builtins.isString config.nix_rust.packages.runtime);
      rustPkgConfigSetup = lib.optionalString (rustTargetLibs != [ ]) ''
        export PKG_CONFIG_ALLOW_CROSS=1
        export PKG_CONFIG_PATH=${
          lib.concatMapStringsSep ":"
            (p: "${lib.getDev p}/lib/pkgconfig:${lib.getDev p}/share/pkgconfig")
            rustTargetLibs
        }
      '';

      rustArchive = rustPlatform.buildRustPackage {
        pname = "${rustStaticName}-${system}";
        version = config.version;
        # The crate laid out for the build (scaffold injected, SDK source
        # alongside), published by the build platform's package set so the
        # generator runs exactly once for all three targets.
        src = buildPackages."rust-crate-src";
        sourceRoot = "logos-${config.name}-rust-src/rust-lib";
        cargoLock = {
          lockFile = "${rustCrateDir}/Cargo.lock";
          allowBuiltinFetchGit = true;
        };
        # No xcodeWrapper here: it would put Xcode's clang/ar/ranlib/nm in
        # front of nixpkgs' on PATH for the BUILD-platform half of the same
        # cargo run (build scripts, proc macros). logosRustCrossSetup reaches
        # Xcode by absolute path instead.
        nativeBuildInputs =
          map (getPkg buildPkgs) (lib.filter builtins.isString config.nix_rust.packages.build);
        buildInputs = rustTargetLibs;
        env = config.nix_rust.env;
        doCheck = false;
        # fixupPhase would otherwise run the BUILD platform's strip over the
        # installed archive, and this derivation runs in the build platform's
        # stdenv (so the toolchain is runnable) while producing a TARGET
        # archive. Measured on aarch64-darwin: Darwin's strip rewrote the
        # aarch64-android archive's index into BSD's `__.SYMDEF SORTED`, and
        # ld.lld then rejected it with "not an ELF file" naming the `/` member
        # -- a message about the archive index that reads like a message about
        # the objects. Nothing here should be stripped anyway; the module-impl
        # exports are the point.
        dontStrip = true;
        # iOS reaches Xcode through /Applications (ADR 0002).
        __noChroot = !isAndroid;
        # cargoBuildHook derives `--target` from the stdenv's HOST platform, and
        # this derivation deliberately runs in the BUILD platform's stdenv so the
        # toolchain is runnable. Left alone it builds for the BUILDER -- silently,
        # producing a perfectly good archive that then fails to link.
        buildPhase = ''
          runHook preBuild
          ${pkgs.logosRustCrossSetup}
          ${rustPkgConfigSetup}
          export CARGO_HOME=$TMPDIR/cargo
          cargo build --release --offline --target ${rustTriple}
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          mkdir -p $out/lib
          cp target/${rustTriple}/release/lib${rustStaticName}.a $out/lib/
          runHook postInstall
        '';
      };

      # ── the platform ──────────────────────────────────────────────────
      platform =
        if isAndroid then {
          mkDerivation = pkgs.stdenv.mkDerivation;
          isMachO = false;
          cmakeDir = null;
          targetCmakeFlags = pkgs.logosAndroidCmakeTargetFlags;
          toolchainNativeBuildInputs = [
            buildPkgs.cmake
            buildPkgs.ninja
            buildPkgs.pkg-config
          ];
          # The NDK's llvm-nm/llvm-readelf: the artifact is ELF and the builder
          # may well be a Mac, so neither tool can be the one on PATH.
          gateEnv = {
            NM = "${pkgs.androidPkgs.ndkToolchainBin}/llvm-nm";
            READELF = "${pkgs.androidPkgs.ndkToolchainBin}/llvm-readelf";
          };
          # The second gate: a Bare module may only name sonames the app ships
          # or Android guarantees. This is where `openssl_runtime` and friends
          # are caught -- at the artifact, not at the phone.
          #
          # libc++_shared.so is the one soname the module cannot ship and
          # Android does not guarantee: Qt's Android platform refuses any STL
          # but c++_shared (QtPlatformAndroid.cmake), so the Native container's
          # APK packages it and every image in the process shares that one copy.
          # Named here rather than waved through inside the gate, so the
          # allowance is visible where the decision belongs.
          extraInstallCheck = ''
            ${pkgs.logosAndroidDtNeededGate}/bin/logos-android-dt-needed-gate \
              --allow libc++_shared.so \
              "$out/lib/${config.name}_bare.so"
          '';
        } else {
          # nixpkgs' own iOS cross stdenv does not build at this pin; every iOS
          # target compiles through Xcode's clang (logos-nix ADR 0002).
          mkDerivation = pkgs.xcodeClang.mkDerivation;
          isMachO = true;
          # xcodeClang.mkDerivation configures cmake from a build/ subdirectory.
          cmakeDir = "..";
          targetCmakeFlags = pkgs.logosIosCmakeTargetFlags;
          # xcodeClang already supplies xcodeWrapper (nm, otool,
          # install_name_tool), cmake and ninja.
          toolchainNativeBuildInputs = [ ];
          gateEnv = { };
          extraInstallCheck = "";
        };

      bare = buildBareModule ({
        inherit pkgs config builderRoot;
        generatedSrc = buildPackages.generate;
        # Headers, both of them: a bare build adds include directories and
        # links neither, so the build platform's packages are the right ones.
        logosSdk = logos-cpp-sdk.packages.${buildSystem}.default;
        logosProtocol = logos-protocol.packages.${buildSystem}.default;
        gateScript = builderRoot + "/scripts/logos-bare-gate.sh";
        moduleImplAbi = moduleImplAbiFor buildSystem;
        rustStaticNames = lib.optional isRustModule rustStaticName;
        goStaticNames = config.go_static_lib_names;
        stagedArchives = lib.optional isRustModule
          "${rustArchive}/lib/lib${rustStaticName}.a";
        extraNativeBuildInputs =
          map (getPkg pkgs) (lib.filter builtins.isString config.nix_packages.build);
        extraBuildInputs =
          map (getPkg pkgs) (lib.filter builtins.isString config.nix_packages.runtime);
        strictDeps = true;
      } // platform);
    in
    builtins.seq assertNoExternalLibs {
      inherit bare;
      "${config.name}-bare" = bare;
      default = bare;
    };
in
common.forAllMobileTargets { inherit androidBuildSystem; } bareFor
