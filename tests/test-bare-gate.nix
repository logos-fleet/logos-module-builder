# Integration test for the Bare-module gate (scripts/logos-bare-gate.sh).
#
# The gate is what makes "protocol-free" a build failure rather than a comment,
# so it gets tested the only way that means anything: build artifacts that are
# deliberately wrong and assert the gate rejects them, naming the symbol.
#
#   1. a well-formed Bare artifact (all seven module-impl ABI exports, lp_*
#      undefined)                                          -> PASS
#   2. the same artifact built against Qt6::Core            -> FAIL, names a Qt symbol
#   3. an artifact missing one module-impl ABI export       -> FAIL, names the export
#   4. an artifact that DEFINES lp_invoke (as linking the
#      logos-protocol archive would)                        -> FAIL, names lp_invoke
{ pkgs, gateScript }:

let
  # The seven exports of logos-protocol/cpp/logos_module_impl.h, hand-written
  # here so the gate is tested against the ABI itself and not against whatever
  # the generator happened to emit.
  abiExports = ''
    #include <cstdlib>
    #include <cstring>
    #define EXPORT extern "C" __attribute__((visibility("default")))
    // The consumer ABI a Bare module leaves undefined for the host image.
    extern "C" int lp_invoke(const char*, const char*, const char*, char**, char**);
    EXPORT char* logos_module_dispatch(const char* m, const char* a) {
        char* out = nullptr; char* err = nullptr;
        lp_invoke("peer", m, a, &out, &err);
        return out;
    }
    EXPORT char* logos_module_get_methods(void) { return strdup("[]"); }
    EXPORT void logos_module_set_context(const char*, const char*, const char*) {}
    EXPORT void logos_module_set_emit_callback(void (*)(const char*, const char*, void*), void*) {}
    EXPORT int logos_module_accept_token(const char*, const char*) { return 0; }
    EXPORT const char* logos_module_get_protocol_version(void) { return "1.0.0"; }
    EXPORT void logos_module_string_free(char* s) { std::free(s); }
  '';

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
  # cc-wrapper puts c++ on PATH; CXX is not always exported into a runCommand.
  CXXBIN="''${CXX:-c++}"

  cat > abi.cpp <<'CPP'
  ${abiExports}
  CPP

  echo "=== case 1: a well-formed Bare artifact must PASS ==="
  "$CXXBIN" -std=c++17 -fPIC -shared -o clean.${soExt} abi.cpp ${undefinedFlags}
  if ! bash "$gate" clean.${soExt} > case1.log 2>&1; then
    echo "FAIL: the gate rejected a well-formed Bare artifact:"; cat case1.log; exit 1
  fi
  grep -q "PASS" case1.log
  echo "PASS: clean artifact accepted"

  echo "=== case 2: a deliberately Qt-linked build must FAIL naming the Qt symbol ==="
  mkdir -p qtcase && cd qtcase
  cat > qt_bare.cpp <<'CPP'
  #include <QString>
  ${abiExports}
  // Deliberate Qt reference: this is what the gate exists to catch.
  extern "C" __attribute__((visibility("default"))) const char* qt_leak() {
      static QString s = QStringLiteral("qt");
      static std::string b = s.toStdString();
      return b.c_str();
  }
  CPP
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
  sed '/logos_module_string_free/d' abi.cpp > partial.cpp
  "$CXXBIN" -std=c++17 -fPIC -shared -o partial.${soExt} partial.cpp ${undefinedFlags}
  if bash "$gate" partial.${soExt} > case3.log 2>&1; then
    echo "FAIL: the gate ACCEPTED an artifact missing an ABI export"; exit 1
  fi
  grep -q "missing module-impl ABI export: logos_module_string_free" case3.log \
    || { echo "FAIL: missing-export failure did not name the export:"; cat case3.log; exit 1; }
  echo "PASS: missing ABI export rejected by name"

  echo "=== case 4: a DEFINED lp_* (the protocol archive linked in) must FAIL ==="
  cat > carried.cpp <<'CPP'
  ${abiExports}
  // What linking the logos-protocol archive would look like from the outside.
  extern "C" __attribute__((visibility("default")))
  int lp_invoke(const char*, const char*, const char*, char**, char**) { return 0; }
  CPP
  "$CXXBIN" -std=c++17 -fPIC -shared -o carried.${soExt} carried.cpp ${undefinedFlags}
  if bash "$gate" carried.${soExt} > case4.log 2>&1; then
    echo "FAIL: the gate ACCEPTED an artifact carrying lp_invoke"; exit 1
  fi
  grep -q "logos_protocol symbol DEFINED in a Bare module: lp_invoke" case4.log \
    || { echo "FAIL: carried-protocol failure did not name lp_invoke:"; cat case4.log; exit 1; }
  echo "PASS: carried logos-protocol code rejected by name"

  mkdir -p $out
  cp case*.log $out/
  echo "all bare-gate cases passed" > $out/results.txt
''
