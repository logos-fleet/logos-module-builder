#!/usr/bin/env bash
# logos-bare-gate.sh — the Bare-module gate.
#
# A Bare module is the protocol-free module artifact: it exports the common
# module-impl C ABI (logos-protocol/cpp/logos_module_impl.h), leaves the
# logos-protocol consumer ABI (lp_*) UNDEFINED for the host image to supply,
# and contains no Qt. mkLogosModule runs this over every `bare` artifact it
# produces, so a module that quietly picked up Qt or linked the logos-protocol
# archive never leaves its derivation. Like the Android DT_NEEDED gate in
# logos-nix, it reads what the linker actually recorded (symbol table + load
# commands), never what the build intended.
#
#   usage: logos-bare-gate.sh <artifact.dylib|artifact.so>
#   env:   LOGOS_MODULE_IMPL_EXPORTS=<exports.txt>   (required)
#
# The export list is READ from logos-protocol's published
# packages.<sys>.module-impl-abi/exports.txt, never restated here, so the gate
# cannot go stale as the ABI grows.
#
# Exit 0: a valid Bare module. Exit 1: every offending symbol / library is
# named on stderr. Exit 2: usage error, or no usable export list to gate on.
set -uo pipefail

ARTIFACT="${1:-}"
if [ -z "$ARTIFACT" ]; then
    echo "logos-bare-gate: usage: logos-bare-gate.sh <artifact>" >&2
    exit 2
fi
# An iOS Bare module is a FRAMEWORK BUNDLE, so the thing a caller has a path to
# is a directory. Resolve it to the Mach-O inside rather than making every
# caller know the layout; a flat iOS framework names its binary after the
# bundle.
if [ -d "$ARTIFACT" ]; then
    case "$ARTIFACT" in
        *.framework | *.framework/)
            bundle="${ARTIFACT%/}"
            ARTIFACT="$bundle/$(basename "$bundle" .framework)"
            ;;
        *)
            echo "logos-bare-gate: $ARTIFACT is a directory and not a .framework bundle" >&2
            exit 2
            ;;
    esac
fi
if [ ! -f "$ARTIFACT" ]; then
    echo "logos-bare-gate: no such artifact: $ARTIFACT" >&2
    exit 2
fi

NM="${NM:-nm}"
OTOOL="${OTOOL:-otool}"
READELF="${READELF:-readelf}"

# ── which object format the ARTIFACT is ─────────────────────────────────────
# Read from the file's magic bytes, never from `uname`. The gate now runs over
# CROSS-BUILT artifacts -- an Android .so produced on a Mac, an iOS framework
# produced on the same Mac -- and on that machine `uname -s` says Darwin for
# both. Keying the toolchain off the builder would run `otool -L` on an ELF and
# `readelf -d` on a Mach-O; the first reads nothing (a false FAIL) and the
# second reads nothing (a false PASS on clause 4, the load-command check).
#
# od rather than `file`: it is in coreutils, which every one of these build
# environments already has, and the answer is four bytes.
magic=$(od -An -tx1 -N4 "$ARTIFACT" 2>/dev/null | tr -d ' \n')
case "$magic" in
    7f454c46)                     FORMAT=elf ;;   # \x7fELF
    cffaedfe|cefaedfe)            FORMAT=macho ;; # MH_MAGIC_64 / MH_MAGIC, LE
    feedfacf|feedface)            FORMAT=macho ;; # ...BE, and fat headers below
    cafebabe|bebafeca)            FORMAT=macho ;; # universal binary
    4d5a*)                        FORMAT=pe ;;    # MZ
    *)
        echo "logos-bare-gate: FAIL -- $ARTIFACT is not an object file this gate" \
             "can read (magic $magic)" >&2
        exit 1
        ;;
esac

# ── the declared module-impl ABI ────────────────────────────────────────────
# Every export declared in logos_module_impl.h must be DEFINED, whatever
# language the impl is in. The check is one-directional (DECLARED ⊆ DEFINED):
# an impl may export more of its own, e.g. the Rust scaffold's
# `logos_module_install`.
EXPORTS_FILE="${LOGOS_MODULE_IMPL_EXPORTS:-}"
if [ -z "$EXPORTS_FILE" ]; then
    echo "logos-bare-gate: LOGOS_MODULE_IMPL_EXPORTS is unset. Point it at" \
         "logos-protocol's module-impl-abi/exports.txt — the gate does not" \
         "carry its own copy of the ABI on purpose." >&2
    exit 2
fi
if [ ! -r "$EXPORTS_FILE" ]; then
    echo "logos-bare-gate: cannot read LOGOS_MODULE_IMPL_EXPORTS=$EXPORTS_FILE" >&2
    exit 2
fi
# Comments and whitespace dropped. An empty list would make clause 1 pass
# every artifact silently, so refuse to gate against one.
MODULE_IMPL_ABI=()
while IFS= read -r sym; do
    MODULE_IMPL_ABI+=("$sym")
done < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$EXPORTS_FILE")
if [ ${#MODULE_IMPL_ABI[@]} -eq 0 ]; then
    echo "logos-bare-gate: $EXPORTS_FILE declares no exports; refusing to gate" \
         "against an unexamined ABI." >&2
    exit 2
fi

# ── read the symbol table ───────────────────────────────────────────────────
# Normalised to "<type> <name>" lines, with Mach-O's leading underscore and
# ELF's @version suffix stripped so the rest of the script speaks one spelling.
case "$FORMAT" in
    macho) raw_syms=$("$NM" -g "$ARTIFACT" 2>/dev/null) ;;
    *)     raw_syms=$("$NM" -D "$ARTIFACT" 2>/dev/null) ;;
esac
if [ -z "$raw_syms" ]; then
    echo "logos-bare-gate: FAIL — could not read a symbol table from $ARTIFACT" >&2
    exit 1
fi

SYMS=$(printf '%s\n' "$raw_syms" | awk '
    NF >= 2 {
        name = $NF
        sub(/^_/, "", name)
        sub(/@.*$/, "", name)
        print $(NF-1), name
    }')
defined_syms=$(printf '%s\n' "$SYMS" | awk '$1 != "U" && $1 != "u" { print $2 }' | sort -u)
undefined_syms=$(printf '%s\n' "$SYMS" | awk '$1 == "U" || $1 == "u" { print $2 }' | sort -u)
all_syms=$(printf '%s\n' "$SYMS" | awk '{ print $2 }' | sort -u)

failures=0
fail() { echo "logos-bare-gate: FAIL — $*" >&2; failures=$((failures + 1)); }

# fail_each <message> <regex> <newline-separated list> [<hint>]
# One FAIL per line of <list> matching <regex> (the first 20), naming the
# line. Runs in this shell so the failure count is kept.
fail_each() {
    local hit
    while IFS= read -r hit; do
        fail "$1: $hit${4:+ $4}"
    done < <(printf '%s\n' "$3" | grep -E "$2" | head -20)
}

# ── 1. every module-impl ABI export is present ──────────────────────────────
missing=$(comm -23 <(printf '%s\n' "${MODULE_IMPL_ABI[@]}" | sort -u) \
                   <(printf '%s\n' "$defined_syms"))
fail_each "missing module-impl ABI export" '.' "$missing" \
    "(a Bare module must export the whole of logos_module_impl.h)"

# ── 2. no Qt, defined or undefined ──────────────────────────────────────────
# Itanium-mangled Qt types always spell "<len>Q<Uppercase>" (7QString,
# 11QMetaObject, 7QObject); the moc-generated and C-ish entry points are named
# outright. Matching the mangled name catches a Qt reference even when no Qt
# library ends up in the load commands (static Qt, inlined-away calls).
QT_SYMBOL_RE='[0-9]Q[A-Z]|^_?qt_[a-z]|QMetaObject|qRegisterMetaType|^_?ZN2Qt|qFatal|qWarning'
fail_each "Qt symbol in a Bare module" "$QT_SYMBOL_RE" "$all_syms"

# ── 3. the logos-protocol ABI is referenced, never carried ──────────────────
# lp_* undefined is the whole point of a Bare module: the host image supplies
# them. lp_* DEFINED means the logos-protocol archive was linked in, which
# drags Qt and the transports along with it.
fail_each "logos_protocol symbol DEFINED in a Bare module" '^lp_' "$defined_syms" \
    "(the logos-protocol archive was linked in; lp_* must stay undefined)"

# Protocol internals (the C++ classes inside the archive) must not appear at
# all, defined or undefined. Only the lp_* C ABI may be referenced.
PROTOCOL_INTERNAL_RE='LogosProviderObject|LogosApiClient|LogosApiConsumer|ModuleProxy|TokenManager|LogosTransport|LogosRegistry'
fail_each "logos_protocol internal symbol in a Bare module" "$PROTOCOL_INTERNAL_RE" "$all_syms" \
    "(only the lp_* C ABI may cross a Bare module's edge)"

# ── 4. no Qt / logos-protocol shared library in the load commands ───────────
LIB_RE='libQt|Qt[A-Z][A-Za-z]*\.framework|libQt[0-9]|logos_protocol|logos-protocol|logos_qt_sdk|logos-qt-sdk'

# THE ONE PERMITTED NAME, and only on ELF.
#
# "The host image supplies lp_*" needs no spelling on Mach-O (`-undefined
# dynamic_lookup`) or on Linux (the host is an executable, always searched).
# Android has neither: bionic resolves a dlopen'd library against its own
# DT_NEEDED closure and the namespace's GLOBAL group, and an app's libraries
# are never in the global group. A DT_NEEDED on the host's protocol soname is
# the only mechanism the platform offers, and it carries NO CODE -- clause 3
# above still requires every lp_* to be UNDEFINED, which is what "protocol-free"
# actually means. A Qt library, a logos-qt-sdk, or a DEFINED lp_* is refused
# exactly as before.
HOST_ABI_SONAME='liblogos_protocol.so'
case "$FORMAT" in
    macho) linked=$("$OTOOL" -L "$ARTIFACT" 2>/dev/null | tail -n +2 | awk '{print $1}') ;;
    *)     linked=$("$READELF" -d "$ARTIFACT" 2>/dev/null \
                     | awk '/NEEDED/ { gsub(/[][]/, "", $NF); print $NF }' \
                     | grep -vFx "$HOST_ABI_SONAME") ;;
esac
fail_each "Bare module links a forbidden library" "$LIB_RE" "$linked"

if [ "$failures" -gt 0 ]; then
    echo "logos-bare-gate: $ARTIFACT is NOT protocol-free ($failures problem(s) above)." >&2
    exit 1
fi

echo "logos-bare-gate: PASS — $(basename "$ARTIFACT") ($FORMAT) exports the module-impl ABI, references no Qt, and carries no logos-protocol code."
