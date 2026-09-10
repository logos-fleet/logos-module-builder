# Integration test for the `bare` output — the Bare module artifact.
#
# Builds it for the three authoring shapes that must produce one:
#
#   bare_counter            leaf universal C++ module (the counter)
#   bare_relay              universal C++ module with a dependency — its
#                           modules().bare_counter calls leave `lp_invoke`
#                           UNDEFINED, which is the Bare shape's defining property
#   rust_native_dep_module  a codegen.rust module — the same ABI, exported out
#                           of the Rust core rather than a C++ impl
#
# Every one of these derivations ran scripts/logos-bare-gate.sh as its
# installCheck, which already proves the whole module-impl C ABI is exported
# and no Qt or logos-protocol code is carried. Realising them is therefore
# most of the assertion; only the claims the gate does not make are checked
# here, and the Qt plugin shapes are checked to expose no `bare` output at all.
{ pkgs, mkLogosModule, fixturesRoot }:

let
  counter = mkLogosModule {
    src = fixturesRoot + "/bare-counter";
    configFile = fixturesRoot + "/bare-counter/metadata.json";
  };

  # `bare_counter` is resolved from its published LIDL contract, so the relay's
  # bare build never builds the counter's plugin.
  relay = mkLogosModule {
    src = fixturesRoot + "/bare-relay";
    configFile = fixturesRoot + "/bare-relay/metadata.json";
    flakeInputs = { bare_counter = counter; };
  };

  rustModule = mkLogosModule {
    src = fixturesRoot + "/rust-native-dep";
    configFile = fixturesRoot + "/rust-native-dep/metadata.json";
  };

  system = pkgs.stdenv.hostPlatform.system;
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  libExt = if isDarwin then "dylib" else "so";
  # Mach-O keeps every global in the regular table; ELF's dynamic table is
  # the one that matters for a shared object.
  nmTable = if isDarwin then "-g" else "-D";

  counterBare = counter.packages.${system}.bare;
  relayBare = relay.packages.${system}.bare;
  rustBare = rustModule.packages.${system}.bare;

  # A Qt plugin object holding a LogosAPI has no protocol-free form to extract,
  # so it must not advertise a `bare` output at all. Both fixtures below are
  # `interface: legacy` (the key is absent) — one a hand-written Qt core module,
  # one a ui_qml view backend. Pure evaluation — nothing is built.
  noBare = label: fixture:
    let m = mkLogosModule {
          src = fixturesRoot + "/${fixture}";
          configFile = fixturesRoot + "/${fixture}/metadata.json";
        };
    in if m.packages.${system} ? bare
       then builtins.throw "FAIL: ${label} (${fixture}) must not expose a `bare` output"
       else true;

  qtPluginsHaveNoBare =
    noBare "a hand-written Qt core module" "test-framework-module"
    && noBare "a ui_qml view backend" "qml-module";

in assert qtPluginsHaveNoBare; pkgs.runCommand "bare-modules-tests" {
  nativeBuildInputs = [ pkgs.stdenv.cc.bintools.bintools ];
} ''
  set -euo pipefail

  counter_lib=${counterBare}/lib/bare_counter_bare.${libExt}
  relay_lib=${relayBare}/lib/bare_relay_bare.${libExt}
  rust_lib=${rustBare}/lib/rust_native_dep_module_bare.${libExt}
  test -f "$counter_lib" && test -f "$relay_lib" && test -f "$rust_lib"
  echo "PASS: bare artifacts built and gated for universal C++ (leaf + dependent) and Rust"

  # The relay's dependency calls reach the host's lp_* at load time, so
  # lp_invoke has to be an UNDEFINED symbol here (Mach-O's leading underscore
  # stripped).
  undefined=$(nm ${nmTable} "$relay_lib" \
    | awk '$(NF-1) == "U" || $(NF-1) == "u" { n = $NF; sub(/^_/, "", n); print n }')
  grep -qx lp_invoke <<< "$undefined" \
    || { echo "FAIL: bare_relay does not reference lp_invoke as an UNDEFINED symbol"; \
         echo "undefined symbols were:"; echo "$undefined"; exit 1; }
  echo "PASS: the relay leaves lp_invoke undefined for the host image"

  mkdir -p $out
  for f in "$counter_lib" "$relay_lib" "$rust_lib"; do
    echo "== $f" >> $out/symbols.txt
    nm ${nmTable} "$f" >> $out/symbols.txt
  done
  echo "bare outputs verified for universal C++ (leaf + dependent) and Rust" > $out/results.txt
''
