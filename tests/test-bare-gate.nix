# Integration test for the Bare-module gate (scripts/logos-bare-gate.sh).
#
# The gate is what makes "protocol-free" a build failure rather than a comment,
# so it gets tested the only way that means anything: build artifacts that are
# deliberately wrong and assert the gate rejects them, naming the symbol.
#
#   1. a well-formed Bare artifact (every declared module-impl ABI export
#      defined, lp_* undefined)                            -> PASS
#   2. the same artifact built against Qt6::Core            -> FAIL, names a Qt symbol
#   3. an artifact missing one module-impl ABI export       -> FAIL, names the export
#   4. an artifact that DEFINES lp_invoke (as linking the
#      logos-protocol archive would)                        -> FAIL, names lp_invoke
#   5. the gate run against an empty/absent export list     -> REFUSE (exit 2)
#   6. a nim type-descriptor name that CONTAINS "<digit>Q<Upper>"
#      but is not a mangled C++ name at all                 -> PASS
#
# The ABI stubs are GENERATED from logos-protocol's published exports.txt, not
# hand-copied: the gate reads that same list, and a test carrying its own copy
# could agree with a stale gate while both drifted from the protocol.
{ pkgs, gateScript, moduleImplAbi }:

let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  # Undefined symbols in a shared object are the norm on ELF and must be asked
  # for on Mach-O — the same flag mkLogosModule's bare build uses.
  undefinedFlags = if isDarwin then "-Wl,-undefined,dynamic_lookup" else "";
  soExt = if isDarwin then "dylib" else "so";

in pkgs.runCommandCC "bare-gate-tests" {
  nativeBuildInputs = [ pkgs.cmake pkgs.qt6.qtbase ] ++ pkgs.lib.optional isDarwin pkgs.darwin.cctools;
  # The gate is a pure shell/nm/otool script; cmake is only here to link the
  # deliberately-Qt-linked case the way a real Qt build would.
} ''
  set -uo pipefail
  export HOME=$TMPDIR
  gate=${gateScript}
  exports=${moduleImplAbi}/exports.txt
  export LOGOS_MODULE_IMPL_EXPORTS="$exports"
  # cc-wrapper puts c++ on PATH; CXX is not always exported into a runCommand.
  CXXBIN="''${CXX:-c++}"

  echo "=== gating against the module-impl ABI declared by logos-protocol ==="
  cat "$exports"

  # Emit a C++ translation unit defining every DECLARED module-impl export.
  # Only the NAMES matter here — the gate reads nm, not signatures — so each
  # export becomes a trivial no-arg stub.
  gen_abi() {
    echo '#define EXPORT extern "C" __attribute__((visibility("default")))'
    echo '// The consumer ABI a Bare module leaves UNDEFINED for the host image.'
    echo 'extern "C" int lp_invoke(const char*, const char*, const char*, char**, char**);'
    sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$exports" \
      | while read -r sym; do echo "EXPORT void $sym(void) {}"; done
    # One export beyond the declared list (clause 1 is subset-only) that calls
    # lp_invoke, so a well-formed artifact carries it as an UNDEFINED symbol —
    # the Bare shape's defining property.
    echo 'EXPORT void bare_gate_probe(void) { lp_invoke("p", "m", "a", nullptr, nullptr); }'
  }
  gen_abi > abi.cpp

  echo "=== case 1: a well-formed Bare artifact must PASS ==="
  "$CXXBIN" -std=c++17 -fPIC -shared -o clean.${soExt} abi.cpp ${undefinedFlags}
  if ! bash "$gate" clean.${soExt} > case1.log 2>&1; then
    echo "FAIL: the gate rejected a well-formed Bare artifact:"; cat case1.log; exit 1
  fi
  grep -q "PASS" case1.log
  echo "PASS: clean artifact accepted"

  echo "=== case 2: a deliberately Qt-linked build must FAIL naming the Qt symbol ==="
  mkdir -p qtcase
  { gen_abi
    cat <<'CPP'
#include <string>
#include <QString>
// Deliberate Qt reference: this is what the gate exists to catch.
extern "C" __attribute__((visibility("default"))) const char* qt_leak() {
    static QString s = QStringLiteral("qt");
    static std::string b = s.toStdString();
    return b.c_str();
}
CPP
  } > qtcase/qt_bare.cpp
  cd qtcase
  cat > CMakeLists.txt <<'CMAKE'
cmake_minimum_required(VERSION 3.14)
project(QtLinkedBare LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
find_package(Qt6 REQUIRED COMPONENTS Core)
add_library(qt_linked_bare SHARED qt_bare.cpp)
target_link_libraries(qt_linked_bare PRIVATE Qt6::Core)
if(APPLE)
    # Same undefined-symbol policy the real bare build uses, so the only
    # difference between this artifact and a legitimate one is the Qt link.
    target_link_options(qt_linked_bare PRIVATE -undefined dynamic_lookup)
endif()
CMAKE
  cmake -S . -B build -DCMAKE_BUILD_TYPE=Release > /dev/null
  cmake --build build > /dev/null
  qtlib=$(find build -name 'libqt_linked_bare.*' -type f | head -1)
  test -n "$qtlib" || { echo "FAIL: the Qt-linked fixture did not build"; exit 1; }
  cd ..

  if bash "$gate" "qtcase/$qtlib" > case2.log 2>&1; then
    echo "FAIL: the gate ACCEPTED a Qt-linked artifact:"; cat case2.log; exit 1
  fi
  cat case2.log
  grep -q "Qt symbol in a Bare module" case2.log \
    || { echo "FAIL: the gate rejected the Qt build without naming a Qt symbol"; exit 1; }
  # The message must name the offending symbol, not just say "Qt".
  grep -Eq "Qt symbol in a Bare module: [A-Za-z_][A-Za-z0-9_]+" case2.log \
    || { echo "FAIL: no symbol name in the Qt failure message"; exit 1; }
  echo "PASS: Qt-linked artifact rejected, offending symbol named"

  echo "=== case 3: a missing module-impl ABI export must FAIL naming it ==="
  # Drop whichever export the protocol lists last, so this case keeps testing
  # a real declared symbol as the ABI grows.
  drop=$(grep -v '^[[:space:]]*$' "$exports" | tail -1 | tr -d '[:space:]')
  echo "dropping: $drop"
  grep -v "^EXPORT void $drop(" abi.cpp > partial.cpp
  cmp -s abi.cpp partial.cpp && { echo "FAIL: nothing was dropped from abi.cpp"; exit 1; }
  "$CXXBIN" -std=c++17 -fPIC -shared -o partial.${soExt} partial.cpp ${undefinedFlags}
  if bash "$gate" partial.${soExt} > case3.log 2>&1; then
    echo "FAIL: the gate ACCEPTED an artifact missing an ABI export"; exit 1
  fi
  grep -q "missing module-impl ABI export: $drop" case3.log \
    || { echo "FAIL: missing-export failure did not name the export:"; cat case3.log; exit 1; }
  echo "PASS: missing ABI export rejected by name"

  echo "=== case 4: a DEFINED lp_* (the protocol archive linked in) must FAIL ==="
  { gen_abi
    cat <<'CPP'
// What linking the logos-protocol archive would look like from the outside.
extern "C" __attribute__((visibility("default")))
int lp_invoke(const char*, const char*, const char*, char**, char**) { return 0; }
CPP
  } > carried.cpp
  "$CXXBIN" -std=c++17 -fPIC -shared -o carried.${soExt} carried.cpp ${undefinedFlags}
  if bash "$gate" carried.${soExt} > case4.log 2>&1; then
    echo "FAIL: the gate ACCEPTED an artifact carrying lp_invoke"; exit 1
  fi
  grep -q "logos_protocol symbol DEFINED in a Bare module: lp_invoke" case4.log \
    || { echo "FAIL: carried-protocol failure did not name lp_invoke:"; cat case4.log; exit 1; }
  echo "PASS: carried logos-protocol code rejected by name"

  echo "=== case 6: a nim type descriptor is not a Qt symbol ==="
  # The Qt clause looks for Itanium mangling's "<len>Q<Uppercase>" (7QString).
  # Unanchored, that is three characters of coincidence, and nim's type
  # descriptors hit it for real: this exact name comes off libp2p_module's
  # aarch64-ios Bare artifact, which links nim-libp2p's cbind and contains no
  # Qt at all. The whole gate failed on it.
  { gen_abi
    cat <<'CPP'
extern "C" __attribute__((visibility("default")))
void NimDT___xGPxh4QRav413fifxHuqCw_oResultPrivate(void) {}
CPP
  } > nimcase.cpp
  "$CXXBIN" -std=c++17 -fPIC -shared -o nimcase.${soExt} nimcase.cpp ${undefinedFlags}
  bash "$gate" nimcase.${soExt} > case6.log 2>&1 \
    || { echo "FAIL: the gate read a nim type descriptor as a Qt symbol:"; cat case6.log; exit 1; }
  echo "PASS: a nim type descriptor containing <digit>Q<Upper> is not a Qt symbol"

  echo "=== case 5: the gate must REFUSE to run against no ABI list ==="
  # Anti-vacuity. An unset or empty list would make clause 1 pass every
  # artifact silently, which is worse than no gate at all.
  : > empty.txt
  for bad in "" "$PWD/empty.txt" "$PWD/does-not-exist.txt"; do
    # `|| rc=$?` and not a bare call: stdenv's builder runs under `set -e`, so
    # an unguarded non-zero exit would kill the test instead of being asserted.
    rc=0
    LOGOS_MODULE_IMPL_EXPORTS="$bad" bash "$gate" clean.${soExt} > case5.log 2>&1 || rc=$?
    test "$rc" = 2 \
      || { echo "FAIL: expected refusal (exit 2) for LOGOS_MODULE_IMPL_EXPORTS='$bad', got $rc:"
           cat case5.log; exit 1; }
  done
  echo "PASS: the gate refuses to run against an unexamined ABI"

  mkdir -p $out
  cp case*.log $out/
  echo "all bare-gate cases passed" > $out/results.txt
''
