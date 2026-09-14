#!/usr/bin/env bash
# logos-view-gate.sh — the view-image gate.
#
# A view image is a `type: ui_qml` module built as ONE library: its Qt backend,
# the typed source and replica of its .rep, and its QML in the image's own qrc.
# Unlike a Bare module it is FULL of Qt calls — the point is that it CARRIES
# none of Qt. Every Qt symbol, every logos-qt-host symbol and every lp_* is
# left undefined for the app to supply at dlopen. An image that linked a Qt
# ARCHIVE would be a second QtCore in the process: it builds, it loads, and it
# fails at the first QObject that crosses between the two.
#
# TWO FORMATS, ONE RULE, and the artifact's own magic bytes say which:
#
#   Mach-O   the iOS embedded framework. Nothing is linked at all and the load
#            commands must name nothing but the system — dyld resolves Qt,
#            logos-qt-host and lp_* against the app's flat namespace
#            (ADR 0006; spike ios-dlopen-bare-module, Level 2).
#   ELF      the Android lib<stem>_view.so. The SAME symbols are undefined, and
#            here the load commands must NAME where they come from: bionic
#            resolves a dlopen'd library only against its own DT_NEEDED closure
#            and the global group, and an app's libraries are never global. So
#            on this side a missing DT_NEEDED is the failure, and "no linked
#            libraries" would be the bug.
#
#   usage: logos-view-gate.sh <framework-bundle|dylib|so>
#
# Exit 0: a valid view image. Exit 1: every offending symbol / library is
# named on stderr. Exit 2: usage error.
#
# Like logos-bare-gate.sh this reads what the LINKER recorded — the symbol
# table and the load commands — never what the build intended.
#
#   env:  NM / OTOOL         the Mach-O readers   (default nm / otool)
#         READELF            the ELF reader       (default readelf)
set -uo pipefail

ARTIFACT="${1:-}"
if [ -z "$ARTIFACT" ]; then
    echo "logos-view-gate: usage: logos-view-gate.sh <artifact>" >&2
    exit 2
fi
# The shipped artifact is a flat framework BUNDLE, so a caller has a directory.
if [ -d "$ARTIFACT" ]; then
    case "$ARTIFACT" in
        *.framework | *.framework/)
            bundle="${ARTIFACT%/}"
            ARTIFACT="$bundle/$(basename "$bundle" .framework)"
            ;;
        *)
            echo "logos-view-gate: $ARTIFACT is a directory and not a .framework bundle" >&2
            exit 2
            ;;
    esac
fi
if [ ! -f "$ARTIFACT" ]; then
    echo "logos-view-gate: no such artifact: $ARTIFACT" >&2
    exit 2
fi

NM="${NM:-nm}"
OTOOL="${OTOOL:-otool}"
READELF="${READELF:-readelf}"

# WHICH FORMAT, off the file's own first four bytes rather than off a flag.
# The gate runs inside the module's cross build, where the only thing that can
# be trusted to know the answer is the artifact.
magic=$(od -An -tx1 -N4 "$ARTIFACT" 2>/dev/null | tr -d ' \n')
case "$magic" in
    cffaedfe|cefaedfe|feedfacf|feedface|cafebabe|bebafeca) FORMAT=macho ;;
    7f454c46) FORMAT=elf ;;
    *)
        echo "logos-view-gate: FAIL -- $ARTIFACT is neither a Mach-O nor an ELF" \
             "image (magic $magic). A view image is one or the other." >&2
        exit 1
        ;;
esac

# ── the symbol table, split four ways ───────────────────────────────────────
# `nm -m` rather than `nm -g`, because the distinctions that matter here are
# ones `nm -g` cannot make:
#
#   undefined     resolved at load time — the shape this gate is about.
#   weak          a coalesced definition: a C++ inline or template
#                 instantiation. Every Qt consumer emits these and they are
#                 not evidence of anything.
#   local         `non-external`, usually `(was a private external)` — an
#                 instantiation the image does not export. Part of the bytes,
#                 not part of the linkage surface.
#   strong        `external` and defined: what this image OFFERS.
#
# The trailing clause an undefined line carries — `(from libSystem)`,
# `(dynamically looked up)` — is dropped FIRST. Taking the last field without
# doing so reads `up)` as the symbol name, and every clause below then
# quietly examines nothing.
#
# ON ELF THE SAME FOUR WORDS COME FROM `nm -D`: the DYNAMIC table, which is the
# only one that describes linkage — a `.so` may also carry a full .symtab whose
# local entries say nothing about what the loader can see. The type letter is
# the whole classification (U undefined, V/W weak, lowercase local, the rest
# strong), and an ELF name carries no leading underscore to strip.
if [ "$FORMAT" = macho ]; then
    raw=$("$NM" -m "$ARTIFACT" 2>/dev/null)
else
    raw=$("$NM" -D "$ARTIFACT" 2>/dev/null)
fi
if [ -z "$raw" ]; then
    echo "logos-view-gate: FAIL — could not read a symbol table from $ARTIFACT" >&2
    exit 1
fi

if [ "$FORMAT" = macho ]; then
SYMS=$(printf '%s\n' "$raw" | awk '
    {
        line = $0
        sub(/[ \t]*\((from [^)]*|dynamically looked up)\)[ \t]*$/, "", line)
        n = split(line, f, /[ \t]+/)
        name = f[n]
        sub(/^_/, "", name)
        if (line ~ /\(undefined\)/)     { print "undefined", name }
        else if (line ~ /[ \t]weak /)   { print "weak", name }
        else if (line ~ /non-external/) { print "local", name }
        else                            { print "strong", name }
    }')
else
SYMS=$(printf '%s\n' "$raw" | awk '
    NF >= 2 {
        type = $(NF - 1)
        name = $NF
        # THE VERSION SUFFIX GOES FIRST. Qt for Android is built with a symbol
        # version script, so every Qt reference in here is recorded as
        # `_ZN7QObject16staticMetaObjectE@Qt_6`. Matching the marker names
        # below without dropping it finds nothing at all — which reads as "this
        # image references no Qt", the exact opposite of the truth.
        sub(/@.*$/, "", name)
        if (type == "U")                       { print "undefined", name }
        else if (type ~ /^[VWvw]$/)            { print "weak", name }
        else if (type ~ /^[a-z]$/)             { print "local", name }
        else                                   { print "strong", name }
    }')
fi
undefined_syms=$(printf '%s\n' "$SYMS" | awk '$1 == "undefined" { print $2 }' | sort -u)
strong_syms=$(printf '%s\n' "$SYMS" | awk '$1 == "strong" { print $2 }' | sort -u)
defined_syms=$(printf '%s\n' "$SYMS" | awk '$1 != "undefined" { print $2 }' | sort -u)

failures=0
fail() { echo "logos-view-gate: FAIL — $*" >&2; failures=$((failures + 1)); }

fail_each() {
    local hit
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        fail "$1: $hit${4:+ $4}"
    done < <(printf '%s\n' "$3" | grep -E "$2" | head -20)
}

# ── 1. the C edge the host dlsym's ──────────────────────────────────────────
# Restated here rather than read from a published list, unlike the Bare gate's
# module-impl ABI: this ABI is DECLARED BY THIS REPO, in
# cmake/LogosViewFrameworkAbi.cpp.in, and the gate and the template are one
# file apart. `qt_plugin_instance` is Qt's, emitted by moc from the plugin
# class's Q_PLUGIN_METADATA, and is how the host constructs the plugin.
VIEW_ABI=(
    logos_view_module_abi_version
    logos_view_module_name
    logos_view_module_version
    logos_view_module_qml_url
    logos_view_module_create
    logos_view_module_acquire_replica
    qt_plugin_instance
)
missing=$(comm -23 <(printf '%s\n' "${VIEW_ABI[@]}" | sort -u) \
                   <(printf '%s\n' "$defined_syms"))
fail_each "missing view-framework ABI export" '.' "$missing" \
    "(the host reaches this image through dlsym and nothing else)"

# ── 2. Qt is bound UPWARD, not carried ──────────────────────────────────────
# Four symbols only QtCore's compiled objects define, that any Qt consumer
# references: if they are undefined here, Qt is being resolved against the app
# image. If any is DEFINED, a Qt archive is inside — which is a second QtCore
# in the process, and the failure it produces is at the first QObject that
# crosses the boundary, not at load.
QT_CORE_MARKERS=(
    _ZN7QObject16staticMetaObjectE
    _ZN11QMetaObject8activateEP7QObjectPKS_iPPv
    _ZN10QArrayData8allocateEPS_lll6QFlagsINS_16AllocationOptionEE
    _ZN7QObjectC2EP15QObjectPrivateS0_
)
found_undefined=0
for m in "${QT_CORE_MARKERS[@]}"; do
    if grep -qxF "$m" <<< "$undefined_syms"; then found_undefined=1; fi
    if grep -qxF "$m" <<< "$defined_syms"; then
        fail "QtCore is INSIDE the view image: $m is defined here" \
             "(a Qt archive was linked; Qt must come from the app's own copy)"
    fi
done
if [ "$found_undefined" -eq 0 ]; then
    fail "not one QtCore symbol is undefined in $ARTIFACT" \
         "— a view image that references no Qt is not a Qt backend at all"
fi

# A broader sweep over the same question, one step weaker on purpose: a
# symbol owned by a Qt class that this image EXPORTS. The four markers above
# are the real check — an archive's symbols would be LOCAL here, because the
# iOS Qt is compiled -fvisibility=hidden. This clause catches the other
# direction: a framework that re-publishes Qt's API, which is how a second
# QtCore reaches a third image in the same process.
#
# Over what the image exports BEYOND its own declared edge. `qt_plugin_*` is
# that edge: moc emits it from Q_PLUGIN_METADATA and clause 1 above REQUIRES
# it, so a sweep that did not subtract it would refuse every artifact this
# function can produce.
QT_OWNED_RE='^_Z(TV|TT|TI|TS|N|NK)?[0-9]+Q[A-Z]|^_ZN[0-9]+QtPrivate|^qt_[a-z]'
beyond_abi=$(comm -23 <(printf '%s\n' "$strong_syms") \
                      <(printf '%s\n' "${VIEW_ABI[@]}" | grep -v '^qt_plugin' | sort -u) \
             | grep -v '^qt_plugin_')
fail_each "Qt symbol EXPORTED by the framework" "$QT_OWNED_RE" "$beyond_abi" \
    "(a view framework publishes its own C ABI and nothing else)"

# ── 3. the Logos host runtime comes from the app too ─────────────────────────
# LogosAPI, the provider glue and the lp_* C ABI are in the app image for the
# same reason Qt is: one core, one transport, one token store. A framework
# that carried its own would answer a different registry than the app.
fail_each "logos-protocol symbol DEFINED in a view framework" '^lp_' "$strong_syms" \
    "(the logos-protocol archive was linked in; lp_* must stay undefined)"
LOGOS_HOST_RE='^_ZN8LogosAPI|^_ZN19LogosAPIClient|^_ZN12TokenManager|^_ZN19LogosProviderObject'
fail_each "logos-qt-host object code linked into the framework" "$LOGOS_HOST_RE" "$strong_syms" \
    "(the host runtime is the app's; the framework binds to it upward)"

# ── 4. the load commands, which the two platforms read OPPOSITELY ───────────
#
# Mach-O: nothing but the system. `<App>.app/Frameworks/` is flat, so a
# dependent library named here is one dyld would have to find beside the app,
# and none of these ever is — Qt and the Logos host runtime arrive through the
# app's flat namespace with no load command at all.
#
# ELF: the opposite, and for a platform reason rather than a taste. Bionic
# resolves a dlopen'd library's undefined symbols against its own DT_NEEDED
# closure and the linker namespace's GLOBAL group only, and an app's own
# libraries are never global (everything an Android app loads goes through
# System.load(), a LOCAL dlopen into the classloader namespace — measured on an
# SM-G990B for the Bare module). So here the DT_NEEDED entries ARE the binding,
# and their ABSENCE is the defect: an image with none loads nowhere and says so
# only on the device, naming one mangled symbol.
if [ "$FORMAT" = macho ]; then
    LIB_RE='libQt|Qt[A-Z][A-Za-z]*\.framework|logos_protocol|logos-protocol|logos_qt_sdk|logos_qt_host'
    linked=$("$OTOOL" -L "$ARTIFACT" 2>/dev/null | tail -n +2 | awk '{print $1}')
    fail_each "view image links a forbidden library" "$LIB_RE" "$linked"
else
    needed=$("$READELF" -d "$ARTIFACT" 2>/dev/null |
        sed -n 's/.*(NEEDED).*Shared library: \[\(.*\)\]/\1/p' | sort -u)
    # Each is a soname the APK carries: Qt's from androiddeployqt, the two
    # Logos ones from the app's own library set. What is checked is that this
    # image NAMES them — whether the app ships them is the DT_NEEDED gate's
    # question, and it runs over the same bytes a moment later.
    for want in 'libQt6Core' 'liblogos_protocol\.so' 'liblogos_qt_host\.so'; do
        grep -qE "^$want" <<< "$needed" || {
            fail "no DT_NEEDED matching $want in $ARTIFACT" \
                 "(bionic resolves a dlopen'\''d image only against its own DT_NEEDED closure; unnamed is unreachable)"
        }
    done
fi

# ── 5. the view is actually in the image ────────────────────────────────────
# qrc registers through a static initializer, so the QML's presence is not a
# symbol — it is bytes. The entry URL the ABI reports must name a resource
# root that this image's own resource blob carries.
# `tr` rather than `strings`: the gate runs inside the module's own build
# environment, which has cmake, ninja and Xcode's compiler drivers and no
# binutils — `strings` is simply not there, and its absence would read as a
# framework carrying no QML.
qml_marker=$(tr -c '[:print:]' '\n' < "$ARTIFACT" | grep -m1 '^qrc:/logos/')
if [ -z "$qml_marker" ]; then
    fail "no qrc:/logos/... entry URL in $ARTIFACT" \
         "— logos_view_module_qml_url() would hand the host a view it does not carry"
fi

if [ "$failures" -gt 0 ]; then
    echo "logos-view-gate: $ARTIFACT does NOT reach the app's Qt ($failures problem(s) above)." >&2
    exit 1
fi

if [ "$FORMAT" = macho ]; then
    binding="binds Qt, logos-qt-host and lp_* upward into the app image"
else
    binding="names the app's Qt and Logos host images in DT_NEEDED and defines none of them"
fi
echo "logos-view-gate: PASS — $(basename "$ARTIFACT") exports the view ABI, carries its QML" \
     "($qml_marker), and $binding."
