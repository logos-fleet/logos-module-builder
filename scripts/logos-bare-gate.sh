#!/usr/bin/env bash
# logos-bare-gate.sh — the Bare-module gate.
#
# A Bare module (see the workspace glossary) is the protocol-free module
# artifact: the module impl (C++ or Rust core) exporting the common module-impl
# C ABI, with the logos-protocol consumer ABI (lp_*) left UNDEFINED for the host
# image to supply, and with no Qt anywhere. This script is what turns that
# sentence into a build failure instead of a comment: mkLogosModule runs it over
# every `bare` artifact it produces, so a Bare module that quietly picked up Qt
# or linked the logos-protocol archive never leaves the derivation.
#
# Modelled on the Android DT_NEEDED gate in logos-nix: read what the linker
# actually recorded (symbol table + load commands), never what the build
# intended.
#
#   usage: logos-bare-gate.sh <artifact.dylib|artifact.so>
#
# Exits 0 when the artifact is a valid Bare module; exits 1 and names every
# offending symbol / library on stderr otherwise.
set -uo pipefail

ARTIFACT="${1:-}"
if [ -z "$ARTIFACT" ]; then
    echo "logos-bare-gate: usage: logos-bare-gate.sh <artifact>" >&2
    exit 2
fi
if [ ! -f "$ARTIFACT" ]; then
    echo "logos-bare-gate: no such artifact: $ARTIFACT" >&2
    exit 2
fi

NM="${NM:-nm}"
OTOOL="${OTOOL:-otool}"
READELF="${READELF:-readelf}"

# The common module-impl C ABI (logos-protocol/cpp/logos_module_impl.h). Every
# one of these must be DEFINED and exported, whatever language the impl is in —
# a no-Qt host drives a Bare module through exactly this set and nothing else.
MODULE_IMPL_ABI=(
    logos_module_dispatch
    logos_module_get_methods
    logos_module_set_context
    logos_module_set_emit_callback
    logos_module_accept_token
    logos_module_get_protocol_version
    logos_module_string_free
)

# ── read the symbol table ───────────────────────────────────────────────────
# Normalised to "<type> <name>" lines, with Mach-O's leading underscore
# stripped so the rest of the script speaks one spelling.
case "$(uname -s)" in
    Darwin) raw_syms=$("$NM" -g "$ARTIFACT" 2>/dev/null) ;;
    *)      raw_syms=$("$NM" -D --with-symbol-versions "$ARTIFACT" 2>/dev/null \
                       || "$NM" -D "$ARTIFACT" 2>/dev/null) ;;
esac

if [ -z "$raw_syms" ]; then
    echo "logos-bare-gate: FAIL — could not read a symbol table from $ARTIFACT" >&2
    exit 1
fi

SYMS=$(printf '%s\n' "$raw_syms" | awk '
    NF >= 2 {
        type = $(NF-1); name = $NF
        sub(/^_/, "", name)          # Mach-O underscore
        sub(/@.*$/, "", name)        # ELF symbol version suffix
        print type, name
    }')

defined_syms=$(printf '%s\n' "$SYMS" | awk '$1 != "U" && $1 != "u" { print $2 }' | sort -u)
undefined_syms=$(printf '%s\n' "$SYMS" | awk '$1 == "U" || $1 == "u" { print $2 }' | sort -u)
all_syms=$(printf '%s\n%s\n' "$defined_syms" "$undefined_syms" | sort -u)

failures=0
fail() { echo "logos-bare-gate: FAIL — $*" >&2; failures=$((failures + 1)); }

# ── 1. every module-impl ABI export is present ──────────────────────────────
for sym in "${MODULE_IMPL_ABI[@]}"; do
    if ! printf '%s\n' "$defined_syms" | grep -qx "$sym"; then
        fail "missing module-impl ABI export: $sym" \
             "(a Bare module must export the whole of logos_module_impl.h)"
    fi
done

# ── 2. no Qt, defined or undefined ──────────────────────────────────────────
# Itanium-mangled Qt types always spell "<len>Q<Uppercase>" (7QString,
# 11QMetaObject, 7QObject); the moc-generated and C-ish entry points are named
# outright. Matching the mangled name means a Qt reference is caught even when
# no Qt library ends up in the load commands (static Qt, inlined-away calls).
QT_SYMBOL_RE='[0-9]Q[A-Z]|^_?qt_[a-z]|QMetaObject|qRegisterMetaType|^_?ZN2Qt|qFatal|qWarning'
qt_hits=$(printf '%s\n' "$all_syms" | grep -E "$QT_SYMBOL_RE" | head -20)
if [ -n "$qt_hits" ]; then
    while IFS= read -r sym; do
        [ -n "$sym" ] && fail "Qt symbol in a Bare module: $sym"
    done <<< "$qt_hits"
fi

# ── 3. the logos-protocol ABI is referenced, never carried ──────────────────
# lp_* undefined is the whole point of a Bare module: the host image supplies
# them. lp_* DEFINED means the logos-protocol archive was linked in, which
# drags Qt and the transports along with it.
lp_defined=$(printf '%s\n' "$defined_syms" | grep -E '^lp_' | head -20)
if [ -n "$lp_defined" ]; then
    while IFS= read -r sym; do
        [ -n "$sym" ] && fail "logos_protocol symbol DEFINED in a Bare module: $sym" \
            "(the logos-protocol archive was linked in; lp_* must stay undefined)"
    done <<< "$lp_defined"
fi

# Protocol internals (the C++ classes inside the archive) must not appear at
# all — neither defined nor undefined. Only the lp_* C ABI may be referenced.
PROTOCOL_INTERNAL_RE='LogosProviderObject|LogosApiClient|LogosApiConsumer|ModuleProxy|TokenManager|LogosTransport|LogosRegistry'
proto_hits=$(printf '%s\n' "$all_syms" | grep -E "$PROTOCOL_INTERNAL_RE" | head -20)
if [ -n "$proto_hits" ]; then
    while IFS= read -r sym; do
        [ -n "$sym" ] && fail "logos_protocol internal symbol in a Bare module: $sym" \
            "(only the lp_* C ABI may cross a Bare module's edge)"
    done <<< "$proto_hits"
fi

# ── 4. no Qt / logos-protocol shared library in the load commands ───────────
LIB_RE='libQt|Qt[A-Z][A-Za-z]*\.framework|libQt[0-9]|logos_protocol|logos-protocol|logos_qt_sdk|logos-qt-sdk'
case "$(uname -s)" in
    Darwin) linked=$("$OTOOL" -L "$ARTIFACT" 2>/dev/null | tail -n +2 | awk '{print $1}') ;;
    *)      linked=$("$READELF" -d "$ARTIFACT" 2>/dev/null \
                     | awk '/NEEDED/ { gsub(/[][]/, "", $NF); print $NF }') ;;
esac
lib_hits=$(printf '%s\n' "$linked" | grep -E "$LIB_RE" | head -20)
if [ -n "$lib_hits" ]; then
    while IFS= read -r libname; do
        [ -n "$libname" ] && fail "Bare module links a forbidden library: $libname"
    done <<< "$lib_hits"
fi

if [ "$failures" -gt 0 ]; then
    echo "logos-bare-gate: $ARTIFACT is NOT protocol-free ($failures problem(s) above)." >&2
    exit 1
fi

echo "logos-bare-gate: PASS — $(basename "$ARTIFACT") exports the module-impl ABI, references no Qt, and carries no logos-protocol code."
