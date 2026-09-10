# Integration test for the `bare` output — the Bare module artifact.
#
# Builds it for the three authoring shapes that must produce one and inspects
# the result with nm, rather than trusting the build log:
#
#   bare_counter          leaf universal C++ module (the counter) — the whole
#                         module-impl C ABI is exported and no Qt is present
#   bare_relay            universal C++ module with a dependency — its
#                         modules().bare_counter calls leave `lp_invoke`
#                         UNDEFINED, which is the Bare shape's defining property
#   rust_native_dep_module  a codegen.rust module — the same ABI, exported out
#                         of the Rust core rather than a C++ impl
#
# Every one of these derivations already ran scripts/logos-bare-gate.sh as its
# installCheck, so realising them at all is most of the assertion; the checks
# below pin the specific claims the acceptance criteria name.
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
  libExt = if pkgs.stdenv.hostPlatform.isDarwin then "dylib" else "so";

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
  nativeBuildInputs =
    if pkgs.stdenv.hostPlatform.isDarwin then [ pkgs.darwin.cctools ] else [ pkgs.binutils ];
} ''
  set -euo pipefail

  # Normalised "<type> <name>" symbol lines; Mach-O's leading underscore gone.
  syms() {
    case "$(uname -s)" in
      Darwin) nm -g "$1" ;;
      *)      nm -D "$1" ;;
    esac | awk 'NF >= 2 { n = $NF; sub(/^_/, "", n); print $(NF-1), n }'
  }
  defined() { syms "$1" | awk '$1 != "U" && $1 != "u" { print $2 }'; }
  undefined() { syms "$1" | awk '$1 == "U" || $1 == "u" { print $2 }'; }

  ABI="logos_module_dispatch logos_module_get_methods logos_module_set_context \
       logos_module_set_emit_callback logos_module_accept_token \
       logos_module_get_protocol_version logos_module_string_free"

  echo "=== bare_counter (universal C++, the counter) ==="
  counter_lib=${counterBare}/lib/bare_counter_bare.${libExt}
  test -f "$counter_lib"
  for sym in $ABI; do
    defined "$counter_lib" | grep -qx "$sym" \
      || { echo "FAIL: bare_counter does not export $sym"; exit 1; }
  done
  echo "PASS: the counter's bare artifact exports the whole module-impl C ABI"
  if defined "$counter_lib" | grep -qE '^lp_'; then
    echo "FAIL: bare_counter DEFINES an lp_* symbol (protocol archive linked)"; exit 1
  fi
  echo "PASS: no lp_* is defined in the counter"

  echo "=== bare_relay (universal C++ with a dependency) ==="
  relay_lib=${relayBare}/lib/bare_relay_bare.${libExt}
  test -f "$relay_lib"
  for sym in $ABI; do
    defined "$relay_lib" | grep -qx "$sym" \
      || { echo "FAIL: bare_relay does not export $sym"; exit 1; }
  done
  # The point of the shape: the dependency call reaches the host's lp_* at load
  # time, so it has to be undefined here.
  undefined "$relay_lib" | grep -qx "lp_invoke" \
    || { echo "FAIL: bare_relay does not reference lp_invoke as an UNDEFINED symbol"; \
         echo "undefined symbols were:"; undefined "$relay_lib"; exit 1; }
  echo "PASS: the relay leaves lp_invoke undefined for the host image"

  echo "=== rust_native_dep_module (codegen.rust) ==="
  rust_lib=${rustBare}/lib/rust_native_dep_module_bare.${libExt}
  test -f "$rust_lib"
  for sym in $ABI; do
    defined "$rust_lib" | grep -qx "$sym" \
      || { echo "FAIL: the Rust module's bare artifact does not export $sym"; exit 1; }
  done
  echo "PASS: a Rust-core module exports the same module-impl C ABI"

  mkdir -p $out
  for f in "$counter_lib" "$relay_lib" "$rust_lib"; do
    echo "== $f" >> $out/symbols.txt
    syms "$f" >> $out/symbols.txt
  done
  echo "bare outputs verified for universal C++ (leaf + dependent) and Rust" > $out/results.txt
''
