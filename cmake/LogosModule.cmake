# LogosModule.cmake
# Reusable CMake module for building Logos plugins
# This handles all the boilerplate configuration for Logos modules
#
# THIS IS THE ONLY COPY. Do not fork it into a backend repo.
#
# logos-plugin-qt used to ship a second copy, and because
# buildCppPlugin.nix set LOGOS_MODULE_BUILDER_ROOT only when the MODULE's own
# repo carried a cmake/LogosModule.cmake (no module does), the two were
# selected by module type: every ui_qml plugin configured with the backend's
# copy while every core module configured with this one. Both compiled, so the
# divergence was invisible — it is how a stale generator, a stale host-runtime
# repoint, and a missing source file each shipped green. Both nix entry points
# (mkLogosModule and buildCppPlugin) now point LOGOS_MODULE_BUILDER_ROOT here
# unconditionally; `logos_module()` echoes the file it came from so a future
# fork shows up in any configure log.

cmake_minimum_required(VERSION 3.14)

include(GNUInstallDirs)

# Enable CMake automoc for Qt
set(CMAKE_AUTOMOC ON)

#[=======================================================================[.rst:
logos_find_dependencies
-----------------------

Find and configure Logos SDK and logos-module dependencies.
This function sets up include directories and library paths.

Usage:
  logos_find_dependencies()

Sets:
  LOGOS_MODULE_ROOT - Path to logos-module
  LOGOS_CPP_SDK_ROOT - Path to logos-cpp-sdk
  LOGOS_MODULE_IS_SOURCE - TRUE if using source layout
  LOGOS_CPP_SDK_IS_SOURCE - TRUE if using source layout
  LOGOS_QT_HOST_ROOT - Path the Qt HOST RUNTIME is taken from
  LOGOS_QT_HOST_IS_SOURCE - TRUE if that root is a repo checkout
  LOGOS_QT_HOST_PACKAGE - CMake package name for the host runtime
  LOGOS_QT_HOST_TARGET - Imported target for the host runtime
#]=======================================================================]
function(logos_find_dependencies)
    # Allow override from environment or command line
    if(NOT DEFINED LOGOS_MODULE_ROOT)
        set(_parent_module "${CMAKE_SOURCE_DIR}/../logos-module")
        if(DEFINED ENV{LOGOS_MODULE_ROOT})
            set(LOGOS_MODULE_ROOT "$ENV{LOGOS_MODULE_ROOT}" PARENT_SCOPE)
            set(LOGOS_MODULE_ROOT "$ENV{LOGOS_MODULE_ROOT}")
        elseif(EXISTS "${_parent_module}/src/interface.h")
            set(LOGOS_MODULE_ROOT "${_parent_module}" PARENT_SCOPE)
            set(LOGOS_MODULE_ROOT "${_parent_module}")
        else()
            set(LOGOS_MODULE_ROOT "${CMAKE_SOURCE_DIR}/vendor/logos-module" PARENT_SCOPE)
            set(LOGOS_MODULE_ROOT "${CMAKE_SOURCE_DIR}/vendor/logos-module")
        endif()
    endif()

    if(NOT DEFINED LOGOS_CPP_SDK_ROOT)
        set(_parent_cpp_sdk "${CMAKE_SOURCE_DIR}/../logos-cpp-sdk")
        if(DEFINED ENV{LOGOS_CPP_SDK_ROOT})
            set(LOGOS_CPP_SDK_ROOT "$ENV{LOGOS_CPP_SDK_ROOT}" PARENT_SCOPE)
            set(LOGOS_CPP_SDK_ROOT "$ENV{LOGOS_CPP_SDK_ROOT}")
        elseif(EXISTS "${_parent_cpp_sdk}/cpp/logos_module_context.h")
            set(LOGOS_CPP_SDK_ROOT "${_parent_cpp_sdk}" PARENT_SCOPE)
            set(LOGOS_CPP_SDK_ROOT "${_parent_cpp_sdk}")
        else()
            set(LOGOS_CPP_SDK_ROOT "${CMAKE_SOURCE_DIR}/vendor/logos-cpp-sdk" PARENT_SCOPE)
            set(LOGOS_CPP_SDK_ROOT "${CMAKE_SOURCE_DIR}/vendor/logos-cpp-sdk")
        endif()
    endif()

    # Check if dependencies are available (support both source and installed layouts)
    set(_module_found FALSE)
    if(EXISTS "${LOGOS_MODULE_ROOT}/src/interface.h")
        set(_module_found TRUE)
        set(LOGOS_MODULE_IS_SOURCE TRUE PARENT_SCOPE)
    elseif(EXISTS "${LOGOS_MODULE_ROOT}/include/module_lib/interface.h")
        set(_module_found TRUE)
        set(LOGOS_MODULE_IS_SOURCE FALSE PARENT_SCOPE)
    endif()

    set(_cpp_sdk_found FALSE)
    # The base SDK is Qt-free/header-only since the qt split — detect it by
    # logos_module_context.h (logos_api.h lives in logos-qt-host).
    if(EXISTS "${LOGOS_CPP_SDK_ROOT}/cpp/logos_module_context.h")
        set(_cpp_sdk_found TRUE)
        set(LOGOS_CPP_SDK_IS_SOURCE TRUE PARENT_SCOPE)
    elseif(EXISTS "${LOGOS_CPP_SDK_ROOT}/include/cpp/logos_module_context.h")
        set(_cpp_sdk_found TRUE)
        set(LOGOS_CPP_SDK_IS_SOURCE FALSE PARENT_SCOPE)
    endif()

    # logos-qt-sdk — the Qt developer layer. Since the Qt host runtime moved to
    # logos-plugin-qt (see LOGOS_QT_HOST_ROOT below) what this root is still
    # REQUIRED for is the Qt-typed headers that were never part of the host
    # runtime: logos_qt_lp_bridge.h and logos_qt_wire.h (emitted by name into
    # every generated Qt consumer wrapper) and logos_ui_plugin_context.h.
    #
    # Probed by logos_qt_wire.h, deliberately. logos_api.h used to be the
    # discriminator here and is not there any more in EITHER layout: the host
    # split moved it out of cpp/, and the forwarder that kept it in
    # include/cpp/ went away when the consumers were repointed. Probing a name
    # this SDK does not own is how a correct root gets reported as "not found".
    if(NOT DEFINED LOGOS_QT_SDK_ROOT)
        set(_parent_qt_sdk "${CMAKE_SOURCE_DIR}/../logos-qt-sdk")
        if(DEFINED ENV{LOGOS_QT_SDK_ROOT})
            set(LOGOS_QT_SDK_ROOT "$ENV{LOGOS_QT_SDK_ROOT}" PARENT_SCOPE)
            set(LOGOS_QT_SDK_ROOT "$ENV{LOGOS_QT_SDK_ROOT}")
        elseif(EXISTS "${_parent_qt_sdk}/cpp/logos_qt_wire.h")
            set(LOGOS_QT_SDK_ROOT "${_parent_qt_sdk}" PARENT_SCOPE)
            set(LOGOS_QT_SDK_ROOT "${_parent_qt_sdk}")
        else()
            set(LOGOS_QT_SDK_ROOT "${CMAKE_SOURCE_DIR}/vendor/logos-qt-sdk" PARENT_SCOPE)
            set(LOGOS_QT_SDK_ROOT "${CMAKE_SOURCE_DIR}/vendor/logos-qt-sdk")
        endif()
    endif()
    set(_qt_sdk_found FALSE)
    if(EXISTS "${LOGOS_QT_SDK_ROOT}/cpp/logos_qt_wire.h")
        set(_qt_sdk_found TRUE)
        set(LOGOS_QT_SDK_IS_SOURCE TRUE PARENT_SCOPE)
        set(LOGOS_QT_SDK_IS_SOURCE TRUE)
    elseif(EXISTS "${LOGOS_QT_SDK_ROOT}/include/cpp/logos_qt_wire.h")
        set(_qt_sdk_found TRUE)
        set(LOGOS_QT_SDK_IS_SOURCE FALSE PARENT_SCOPE)
        set(LOGOS_QT_SDK_IS_SOURCE FALSE)
    endif()

    # logos-qt-host — the Qt HOST RUNTIME a plugin links: LogosAPI (the object
    # handed to initLogos), LogosAPIProvider, LogosProviderBase + the
    # LOGOS_PROVIDER/LOGOS_METHOD macros, the legacy QMetaObject adapter and
    # core/interface.h. It moved out of logos-qt-sdk into logos-plugin-qt and
    # ships as the `logos-qt-host` CMake package. LOGOS_QT_HOST_ROOT is the ONE
    # place it comes from; logos-qt-sdk forwarded the same headers during the
    # migration and no longer does, so there is no qt-sdk fallback to take.
    #
    # There is deliberately no silent branch: a build that cannot name a host
    # runtime stops with FATAL_ERROR rather than quietly producing a plugin
    # with no LogosAPI in it.
    if(NOT DEFINED LOGOS_QT_HOST_ROOT)
        set(_parent_qt_host "${CMAKE_SOURCE_DIR}/../logos-plugin-qt")
        if(DEFINED ENV{LOGOS_QT_HOST_ROOT})
            set(LOGOS_QT_HOST_ROOT "$ENV{LOGOS_QT_HOST_ROOT}")
        elseif(EXISTS "${_parent_qt_host}/cpp/logos_api.h")
            set(LOGOS_QT_HOST_ROOT "${_parent_qt_host}")
        endif()
    endif()
    set(_qt_host_found FALSE)
    if(DEFINED LOGOS_QT_HOST_ROOT)
        if(EXISTS "${LOGOS_QT_HOST_ROOT}/cpp/logos_api.h")
            set(_qt_host_found TRUE)
            set(_qt_host_is_source TRUE)
        elseif(EXISTS "${LOGOS_QT_HOST_ROOT}/include/cpp/logos_api.h")
            set(_qt_host_found TRUE)
            set(_qt_host_is_source FALSE)
        else()
            message(FATAL_ERROR
                "LOGOS_QT_HOST_ROOT is set to ${LOGOS_QT_HOST_ROOT} but no Qt host "
                "runtime is there (expected cpp/logos_api.h in a logos-plugin-qt "
                "checkout, or include/cpp/logos_api.h in an installed logos-qt-host "
                "prefix).")
        endif()
    endif()
    if(_qt_host_found)
        set(LOGOS_QT_HOST_ROOT "${LOGOS_QT_HOST_ROOT}" PARENT_SCOPE)
        set(LOGOS_QT_HOST_IS_SOURCE ${_qt_host_is_source} PARENT_SCOPE)
        set(LOGOS_QT_HOST_PACKAGE "logos-qt-host" PARENT_SCOPE)
        set(LOGOS_QT_HOST_TARGET "logos-qt-host::logos_qt_host" PARENT_SCOPE)
    endif()

    # logos-protocol — transports + lp_* C ABI (linked by the Qt host runtime;
    # needed directly for its headers and, in source layouts, its library).
    if(NOT DEFINED LOGOS_PROTOCOL_ROOT)
        set(_parent_protocol "${CMAKE_SOURCE_DIR}/../logos-protocol")
        if(DEFINED ENV{LOGOS_PROTOCOL_ROOT})
            set(LOGOS_PROTOCOL_ROOT "$ENV{LOGOS_PROTOCOL_ROOT}" PARENT_SCOPE)
            set(LOGOS_PROTOCOL_ROOT "$ENV{LOGOS_PROTOCOL_ROOT}")
        elseif(EXISTS "${_parent_protocol}/cpp/logos_protocol.h")
            set(LOGOS_PROTOCOL_ROOT "${_parent_protocol}" PARENT_SCOPE)
            set(LOGOS_PROTOCOL_ROOT "${_parent_protocol}")
        else()
            set(LOGOS_PROTOCOL_ROOT "${CMAKE_SOURCE_DIR}/vendor/logos-protocol" PARENT_SCOPE)
            set(LOGOS_PROTOCOL_ROOT "${CMAKE_SOURCE_DIR}/vendor/logos-protocol")
        endif()
    endif()
    set(_protocol_found FALSE)
    # Three layouts, and the third is not a variant of the first two. A source
    # checkout keeps headers under cpp/; the desktop package installs them under
    # include/cpp/; the WASM package (logos-protocol nix/wasm.nix) installs the
    # subset FLAT under include/, because it ships no CMake package config for a
    # Config file to resolve include paths against and a nested cpp/ would be
    # decoration.
    if(EXISTS "${LOGOS_PROTOCOL_ROOT}/cpp/logos_protocol.h"
       OR EXISTS "${LOGOS_PROTOCOL_ROOT}/include/cpp/logos_protocol.h"
       OR EXISTS "${LOGOS_PROTOCOL_ROOT}/include/logos_protocol.h")
        set(_protocol_found TRUE)
    endif()

    if(NOT _cpp_sdk_found)
        message(FATAL_ERROR "logos-cpp-sdk not found at ${LOGOS_CPP_SDK_ROOT}. "
                            "Set LOGOS_CPP_SDK_ROOT environment variable or CMake variable.")
    endif()
    if(NOT _protocol_found)
        message(FATAL_ERROR "logos-protocol not found at ${LOGOS_PROTOCOL_ROOT}. "
                            "Set LOGOS_PROTOCOL_ROOT environment variable or CMake variable.")
    endif()
    message(STATUS "Found logos-cpp-sdk at: ${LOGOS_CPP_SDK_ROOT}")
    message(STATUS "Found logos-protocol at: ${LOGOS_PROTOCOL_ROOT}")

    # logos-module (the Qt PluginInterface), logos-qt-sdk (the Qt developer
    # layer) and logos-qt-host (the Qt host runtime) are the Qt half of a module
    # build. Neither protocol-free artifact -- the Bare module
    # (LOGOS_MODULE_BARE) nor the Wasm host (LOGOS_MODULE_WEB) -- compiles or
    # links any of them, so neither is required to have them: that absence is
    # the point, and under emscripten none of the three exists to be found.
    if(LOGOS_MODULE_BARE OR LOGOS_MODULE_WEB)
        return()
    endif()
    if(NOT _module_found)
        message(FATAL_ERROR "logos-module not found at ${LOGOS_MODULE_ROOT}. "
                            "Set LOGOS_MODULE_ROOT environment variable or CMake variable.")
    endif()
    if(NOT _qt_sdk_found)
        message(FATAL_ERROR "logos-qt-sdk not found at ${LOGOS_QT_SDK_ROOT}. "
                            "Set LOGOS_QT_SDK_ROOT environment variable or CMake variable.")
    endif()
    if(NOT _qt_host_found)
        message(FATAL_ERROR "No Qt host runtime found. Set LOGOS_QT_HOST_ROOT to an "
                            "installed logos-qt-host prefix (or a logos-plugin-qt "
                            "checkout) via environment or CMake variable. "
                            "LOGOS_QT_SDK_ROOT is not a substitute: logos-qt-sdk no "
                            "longer carries the host runtime's headers.")
    endif()
    message(STATUS "Found logos-module at: ${LOGOS_MODULE_ROOT}")
    message(STATUS "Found logos-qt-sdk at: ${LOGOS_QT_SDK_ROOT}")
    message(STATUS "Qt host runtime: logos-qt-host::logos_qt_host at ${LOGOS_QT_HOST_ROOT}")
endfunction()

#[=======================================================================[.rst:
logos_find_qt
-------------

Find Qt6 (or Qt5 as fallback) with required components.

Usage:
  logos_find_qt()

Sets:
  QT_VERSION_MAJOR - The major Qt version found (5 or 6)
#]=======================================================================]
# NOTE: this MUST be a macro, not a function. Qt's mingw
# Qt6EntryPointMinGW32Target.cmake guards itself with a bare include_guard()
# (variable-scoped) while creating a DIRECTORY-scoped imported target. If the
# first find_package(Qt6) runs inside a function scope, the guard variable and
# every <pkg>_FOUND marker die at endfunction() while the EntryPointMinGW32
# target survives, so the next find_package(Qt6) (via logos-protocol's /
# logos-qt-sdk's find_dependency) re-enters and hits
# "add_library cannot create imported target EntryPointMinGW32".
macro(logos_find_qt)
    if(NOT DEFINED QT_VERSION_MAJOR)
        find_package(QT NAMES Qt6 Qt5 REQUIRED COMPONENTS Core RemoteObjects)
        if(Qt6_FOUND)
            set(QT_VERSION_MAJOR 6)
        else()
            set(QT_VERSION_MAJOR 5)
        endif()
    endif()
    find_package(Qt${QT_VERSION_MAJOR} REQUIRED COMPONENTS Core RemoteObjects)
endmacro()

# _logos_find_external_lib(<name> <out_lib> <out_include> <out_lib_dir>)
#
# Resolve one EXTERNAL_LIBS entry. LOGOS_EXT_ROOT_<NAME> (exported by the nix
# dev shell, or any caller) points at a package root laid out as lib/ +
# include/, e.g. a Nix store path; otherwise the module's flat ./lib/ staging
# directory holds both the library and its headers. Shared is preferred over
# static. <out_lib> is empty when nothing was found; <out_lib_dir> names where
# the search happened, for the caller's error message.
function(_logos_find_external_lib ext_lib out_lib out_include out_lib_dir)
    string(TOUPPER "${ext_lib}" _ext_lib_upper)
    set(_ext_root_var "LOGOS_EXT_ROOT_${_ext_lib_upper}")
    if(DEFINED ENV{${_ext_root_var}})
        set(_lib_dir "$ENV{${_ext_root_var}}/lib")
        set(_include_dir "$ENV{${_ext_root_var}}/include")
    else()
        set(_lib_dir "${CMAKE_CURRENT_SOURCE_DIR}/lib")
        set(_include_dir "${CMAKE_CURRENT_SOURCE_DIR}/lib")
    endif()

    # On Windows a shared library is TWO files: you LINK against the import
    # library (lib<x>.dll.a under mingw) and SHIP the .dll.
    if(WIN32)
        set(_names lib${ext_lib}.dll.a ${ext_lib}.dll.a lib${ext_lib}.lib ${ext_lib}.lib lib${ext_lib}.dll ${ext_lib}.dll lib${ext_lib}.a ${ext_lib}.a)
    elseif(APPLE)
        set(_names lib${ext_lib}.dylib lib${ext_lib}.so ${ext_lib}.dylib ${ext_lib}.so lib${ext_lib}.a ${ext_lib}.a)
    else()
        set(_names lib${ext_lib}.so lib${ext_lib}.dylib ${ext_lib}.so ${ext_lib}.dylib lib${ext_lib}.a ${ext_lib}.a)
    endif()
    # Find the library (prefer shared, fall back to static).
    #
    # NO_CMAKE_FIND_ROOT_PATH: the staging directory is in the SOURCE TREE, not
    # in a sysroot. Under a cross build CMake re-roots find_library at
    # CMAKE_FIND_ROOT_PATH -- an iOS toolchain sets that to the SDK -- so the
    # absolute path named in PATHS is silently rewritten to <sdk>/nix/store/...
    # and nothing is found. NO_DEFAULT_PATH does not turn re-rooting off; only
    # this does. Same trap, and the same fix, as the Rust/Go archive lookup in
    # logos_bare_module().
    find_library(${ext_lib}_PATH NAMES ${_names}
        PATHS ${_lib_dir} NO_DEFAULT_PATH NO_CMAKE_FIND_ROOT_PATH)

    set(${out_lib} "${${ext_lib}_PATH}" PARENT_SCOPE)
    set(${out_include} "${_include_dir}" PARENT_SCOPE)
    set(${out_lib_dir} "${_lib_dir}" PARENT_SCOPE)
endfunction()

# _logos_link_sdk_headers(<target>)
#
# The Qt-free base SDK headers (logos_module_context.h / logos_json.h /
# logos_result.h → nlohmann_json include path): logos-cpp-sdk::logos_headers
# from an installed SDK, or nlohmann_json directly from a source checkout.
function(_logos_link_sdk_headers target)
    if(EXISTS "${LOGOS_CPP_SDK_ROOT}/lib/cmake/logos-cpp-sdk")
        find_package(logos-cpp-sdk REQUIRED CONFIG
            PATHS ${LOGOS_CPP_SDK_ROOT}/lib/cmake/logos-cpp-sdk
            NO_DEFAULT_PATH)
        target_link_libraries(${target} PRIVATE logos-cpp-sdk::logos_headers)
    else()
        find_package(nlohmann_json REQUIRED)
        target_link_libraries(${target} PRIVATE nlohmann_json::nlohmann_json)
    endif()
endfunction()

#[=======================================================================[.rst:
_logos_module_sdk_includes
--------------------------

Put the Logos SDK header roots on ``TARGET``'s include path.

``GEN_DIR`` is the module's ``generated_code`` directory (the plugin build and
the iOS view framework disagree about where that is, which is the only reason
it is a parameter).

Extracted from ``logos_module()`` so ``logos_view_framework()`` can compile the
SAME translation units against the SAME headers. Two copies of this list is how
a module would compile one way for the desktop and another way for a phone.
#]=======================================================================]
function(_logos_module_sdk_includes TARGET GEN_DIR)
    # Include directories
    target_include_directories(${TARGET} PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}
        ${CMAKE_CURRENT_SOURCE_DIR}/src
        ${CMAKE_CURRENT_BINARY_DIR}
        ${GEN_DIR}
    )

    # Add include directories based on layout type
    if(LOGOS_MODULE_IS_SOURCE)
        target_include_directories(${TARGET} PRIVATE ${LOGOS_MODULE_ROOT}/src)
    else()
        target_include_directories(${TARGET} PRIVATE ${LOGOS_MODULE_ROOT}/include/module_lib)
    endif()

    if(LOGOS_CPP_SDK_IS_SOURCE)
        target_include_directories(${TARGET} PRIVATE
            ${LOGOS_CPP_SDK_ROOT}/cpp
            ${LOGOS_CPP_SDK_ROOT}/cpp/generated
        )
    else()
        target_include_directories(${TARGET} PRIVATE
            ${LOGOS_CPP_SDK_ROOT}/include
            ${LOGOS_CPP_SDK_ROOT}/include/cpp
            ${GEN_DIR}/include
        )
    endif()
    # Qt HOST RUNTIME headers (LogosAPI, provider glue, legacy PluginInterface
    # at core/interface.h). Both roots have the same two shapes — a repo
    # checkout (cpp/, core/) and an installed prefix (include/cpp,
    # include/core) — so only the root changes with the repoint.
    if(LOGOS_QT_HOST_IS_SOURCE)
        target_include_directories(${TARGET} PRIVATE
            ${LOGOS_QT_HOST_ROOT}/cpp
            ${LOGOS_QT_HOST_ROOT}/core
        )
    else()
        target_include_directories(${TARGET} PRIVATE
            ${LOGOS_QT_HOST_ROOT}/include
            ${LOGOS_QT_HOST_ROOT}/include/cpp
            ${LOGOS_QT_HOST_ROOT}/include/core
        )
    endif()
    # logos_ui_plugin_context.h, from logos-view-module — and FIRST, ahead of
    # the logos-qt-sdk root below.
    #
    # This header and the view glue emitter are one MATCHED PAIR: the emitted
    # `<name>_ui_glue.cpp` calls
    # `_logos_codegen_::maybeUiPluginAboutToUnload(...)`, which only this header
    # declares. Both ship from logos-view-module under ONE pin, so they cannot
    # disagree — but logos-qt-sdk's copy is pinned SEPARATELY by this repo's
    # flake.lock and drifts independently, and resolving to it is how a build
    # gets an emitter from one revision and a context header from another. The
    # symptom is a compile error inside generated code, far from the pin that
    # caused it.
    #
    # As of the qt-sdk pin above, logos-view-module is the ONLY repo that ships
    # the header, so ordering is not currently what decides which copy wins. It
    # stays BEFORE anyway: an older qt-sdk pin — a rollback, a branch, a
    # consumer overriding the input — brings the duplicate straight back.
    #
    # Passed as a cache variable by every nix build (LOGOS_VIEW_INCLUDE_DIR) and
    # as an env var for a hand-run cmake in a dev shell, the same two channels
    # LOGOS_VIEW_TEMPLATE_DIR uses.
    if(NOT LOGOS_VIEW_INCLUDE_DIR AND DEFINED ENV{LOGOS_VIEW_INCLUDE_DIR})
        set(LOGOS_VIEW_INCLUDE_DIR "$ENV{LOGOS_VIEW_INCLUDE_DIR}")
    endif()
    if(LOGOS_VIEW_INCLUDE_DIR)
        # BEFORE, not the default append: a stale logos_ui_plugin_context.h on
        # the qt-sdk root must lose, not win by accident of ordering.
        target_include_directories(${TARGET} BEFORE PRIVATE
            ${LOGOS_VIEW_INCLUDE_DIR}/include
        )
    endif()
    # The Qt-typed headers logos-qt-sdk owns — logos_qt_lp_bridge.h /
    # logos_qt_wire.h (emitted by name into generated Qt consumer wrappers).
    # It no longer ships logos_ui_plugin_context.h; logos-view-module is its sole
    # owner, and the block above stays ordered ahead of this one so an older
    # qt-sdk pin that still carries a copy cannot win.
    if(NOT "${LOGOS_QT_SDK_ROOT}" STREQUAL "${LOGOS_QT_HOST_ROOT}")
        if(LOGOS_QT_SDK_IS_SOURCE)
            target_include_directories(${TARGET} PRIVATE
                ${LOGOS_QT_SDK_ROOT}/cpp
            )
        else()
            target_include_directories(${TARGET} PRIVATE
                ${LOGOS_QT_SDK_ROOT}/include
                ${LOGOS_QT_SDK_ROOT}/include/cpp
            )
        endif()
    endif()
    # Protocol layer headers (transports, consumer core, lp_* C ABI)
    if(EXISTS "${LOGOS_PROTOCOL_ROOT}/cpp/logos_protocol.h")
        target_include_directories(${TARGET} PRIVATE
            ${LOGOS_PROTOCOL_ROOT}/cpp
        )
    else()
        target_include_directories(${TARGET} PRIVATE
            ${LOGOS_PROTOCOL_ROOT}/include
            ${LOGOS_PROTOCOL_ROOT}/include/cpp
        )
    endif()
endfunction()

# THE QT-FREE HALF OF THE GENERATED TREE, selected once.
#
# Both protocol-free artifacts compile exactly this set -- the Bare module (a
# shared object a native host dlopens) and the Wasm host (an executable that IS
# the module) -- and they must not be able to drift apart: two globs would be two
# opinions about which generated file is Qt-bearing, and the one that is wrong
# fails at LINK, naming a Qt symbol, three steps from the filter that let it in.
#
# Kept:
#   <name>_module_impl.cpp    the module-impl C ABI exports
#   <name>_events_cdylib.cpp  typed event emitters (Qt-free flavour)
#   logos_sdk.cpp             the lp_*-backed modules().<dep> surface
# Dropped: the uniform Qt-plugin glue (<name>_cdylib_glue.cpp), the Qt provider
# dispatch (<name>_dispatch.cpp, logos_provider_dispatch.cpp), the Qt event
# sidecar (<name>_events.cpp) and the ui glue. <name>_api.cpp is #include'd by
# logos_sdk.cpp, never compiled on its own.
function(_logos_protocol_free_sources name caller module_sources out_var)
    set(_gen_dir "${CMAKE_CURRENT_SOURCE_DIR}/generated_code")
    file(GLOB _gen_cpps CONFIGURE_DEPENDS "${_gen_dir}/*.cpp")
    list(FILTER _gen_cpps EXCLUDE REGEX
        "/([^/]*_api|[^/]*_dispatch|[^/]*_events|[^/]*_cdylib_glue|[^/]*_qt_glue|[^/]*_ui_glue)\\.cpp$")

    if(NOT _gen_cpps AND NOT module_sources)
        message(FATAL_ERROR
            "${caller}(${name}): nothing to compile. Expected the "
            "Qt-free generated sources in ${_gen_dir} (run the module's "
            "code generators first) or module SOURCES.")
    endif()
    set(${out_var} "${_gen_cpps}" PARENT_SCOPE)
endfunction()

#[=======================================================================[.rst:
logos_bare_module
-----------------

Build the **Bare module** artifact: the protocol-free shape of a module.

A Bare module is the module implementation (a Qt-free C++ impl class, or a
Rust core) plus the generated Qt-free C-ABI wrapper, linked so that

  * the common module-impl C ABI (logos-protocol/cpp/logos_module_impl.h) is
    EXPORTED — that is the whole surface a no-Qt host drives it through;
  * the logos-protocol consumer ABI (``lp_*``) is left UNDEFINED, for the host
    image to supply at load time;
  * no Qt, no generated Qt-plugin glue and no logos-protocol archive is linked.

It is the build shape shared by the iOS embedded framework and the Wasm host.
``logos_module()`` routes here when ``LOGOS_MODULE_BARE`` is ON and then
returns, so a bare build never calls ``logos_find_qt()`` and needs neither Qt
nor logos-qt-sdk present.

The nix wrapper (mkLogosModule's ``bare`` output) runs
``scripts/logos-bare-gate.sh`` over the result; this function only has to
produce the artifact, the gate decides whether it is honest.
#]=======================================================================]
function(logos_bare_module)
    cmake_parse_arguments(
        BARE
        ""
        "NAME"
        "SOURCES;EXTERNAL_LIBS;FIND_PACKAGES;LINK_LIBRARIES;LINK_TARGETS;INCLUDE_DIRS"
        ${ARGN}
    )

    set(_BARE_TARGET ${BARE_NAME}_bare)
    set(_BARE_GEN_DIR "${CMAKE_CURRENT_SOURCE_DIR}/generated_code")

    foreach(pkg ${BARE_FIND_PACKAGES})
        find_package(${pkg} REQUIRED)
    endforeach()

    _logos_protocol_free_sources(${BARE_NAME} "logos_bare_module" "${BARE_SOURCES}" _BARE_GEN_CPPS)

    add_library(${_BARE_TARGET} SHARED ${BARE_SOURCES} ${_BARE_GEN_CPPS})

    # A Bare module has no QObject in it — AUTOMOC is on directory-wide for the
    # plugin build, so turn it off here or cmake would demand Qt's moc.
    set_target_properties(${_BARE_TARGET} PROPERTIES
        AUTOMOC OFF
        AUTOUIC OFF
        AUTORCC OFF
        PREFIX ""
        OUTPUT_NAME "${BARE_NAME}_bare"
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bare"
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bare"
    )

    # The SDK and protocol headers this compiles against are C++17
    # (std::optional, std::is_floating_point_v). Native clang and gcc default
    # to gnu++17 and made that invisible; Xcode's clang targeting iOS does not,
    # and the first cross build failed inside logos_codec.h. State the
    # requirement rather than inherit a default.
    target_compile_features(${_BARE_TARGET} PRIVATE cxx_std_17)

    target_include_directories(${_BARE_TARGET} PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}
        ${CMAKE_CURRENT_SOURCE_DIR}/src
        ${CMAKE_CURRENT_BINARY_DIR}
        ${_BARE_GEN_DIR}
        ${_BARE_GEN_DIR}/include
    )

    # Qt-free SDK headers only: logos-cpp-sdk (LogosModuleContext, StdLogosResult,
    # LpClient) and logos-protocol's header surface (logos_protocol.h's lp_* C
    # ABI, logos_module_impl.h, logos_codec.h). Headers only — the protocol
    # LIBRARY is deliberately not linked.
    if(LOGOS_CPP_SDK_IS_SOURCE)
        target_include_directories(${_BARE_TARGET} PRIVATE
            ${LOGOS_CPP_SDK_ROOT}/cpp
            ${LOGOS_CPP_SDK_ROOT}/cpp/generated
        )
    else()
        target_include_directories(${_BARE_TARGET} PRIVATE
            ${LOGOS_CPP_SDK_ROOT}/include
            ${LOGOS_CPP_SDK_ROOT}/include/cpp
        )
    endif()
    if(EXISTS "${LOGOS_PROTOCOL_ROOT}/cpp/logos_protocol.h")
        target_include_directories(${_BARE_TARGET} PRIVATE ${LOGOS_PROTOCOL_ROOT}/cpp)
    else()
        target_include_directories(${_BARE_TARGET} PRIVATE
            ${LOGOS_PROTOCOL_ROOT}/include
            ${LOGOS_PROTOCOL_ROOT}/include/cpp
        )
    endif()

    foreach(dir ${BARE_INCLUDE_DIRS})
        target_include_directories(${_BARE_TARGET} PRIVATE ${dir})
    endforeach()

    _logos_link_sdk_headers(${_BARE_TARGET})

    foreach(target ${BARE_LINK_TARGETS})
        if(TARGET ${target})
            target_link_libraries(${_BARE_TARGET} PRIVATE ${target})
        else()
            message(FATAL_ERROR
                "LINK_TARGETS target '${target}' was not defined before "
                "logos_module(). Refusing to silently drop a configured link target.")
        endif()
    endforeach()

    foreach(ext_lib ${BARE_EXTERNAL_LIBS})
        _logos_find_external_lib(${ext_lib} _ext_path _ext_include _ext_lib_dir)
        if(NOT _ext_path)
            message(FATAL_ERROR
                "External library '${ext_lib}' was not found in ${_ext_lib_dir}. "
                "Refusing to build a Bare module with a missing dependency.")
        endif()
        target_link_libraries(${_BARE_TARGET} PRIVATE ${_ext_path})
        target_include_directories(${_BARE_TARGET} PRIVATE ${_ext_include})
    endforeach()

    # Go and Rust static archives, staged in lib/ by the builder. Unlike the
    # plugin, the Bare artifact has no Qt glue referencing the module-impl
    # exports, so nothing would pull the archive members in: link them whole so
    # the C ABI actually lands in the artifact (and the gate can see it).
    set(_BARE_STATIC_LIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/lib")
    set(_BARE_WHOLE_ARCHIVES "")
    foreach(_lang IN ITEMS GO RUST)
        foreach(_archive_name IN LISTS LOGOS_MODULE_${_lang}_STATIC_LIBS)
            # NO_CMAKE_FIND_ROOT_PATH: this archive lives in the SOURCE TREE,
            # not in a sysroot. Under a cross build CMake re-roots find_library
            # at CMAKE_FIND_ROOT_PATH -- an iOS toolchain sets that to the SDK
            # -- so the absolute path named in PATHS is silently rewritten to
            # <sdk>/nix/var/nix/builds/.../lib and nothing is found. NO_DEFAULT_PATH
            # does not turn re-rooting off; only this does. (Measured on the
            # aarch64-ios leg of a codegen.rust module: "RUST static library
            # 'x' was not found in <the exact directory holding it>".)
            find_library(_LOGOS_BARE_${_lang}_${_archive_name}
                NAMES lib${_archive_name}.a lib${_archive_name}.lib ${_archive_name}.a ${_archive_name}.lib ${_archive_name}
                PATHS ${_BARE_STATIC_LIB_DIR} NO_DEFAULT_PATH NO_CMAKE_FIND_ROOT_PATH)
            if(NOT _LOGOS_BARE_${_lang}_${_archive_name})
                message(FATAL_ERROR
                    "${_lang} static library '${_archive_name}' was not found in "
                    "${_BARE_STATIC_LIB_DIR}. The builder stages compiled archives there "
                    "before the link; this usually means the external build or staging "
                    "step did not run.")
            endif()
            list(APPEND _BARE_WHOLE_ARCHIVES ${_LOGOS_BARE_${_lang}_${_archive_name}})
        endforeach()
    endforeach()

    foreach(_archive IN LISTS _BARE_WHOLE_ARCHIVES)
        if(APPLE)
            target_link_options(${_BARE_TARGET} PRIVATE -Wl,-force_load,${_archive})
        else()
            target_link_options(${_BARE_TARGET} PRIVATE
                -Wl,--whole-archive ${_archive} -Wl,--no-whole-archive)
        endif()
    endforeach()
    if(_BARE_WHOLE_ARCHIVES)
        if(APPLE)
            target_link_libraries(${_BARE_TARGET} PRIVATE
                "-framework CoreFoundation" "-framework Security")
        else()
            # NOT `pthread dl`: bionic has both inside libc and ships neither
            # as a library, so a literal -lpthread fails the Android link with
            # "unable to find library -lpthread". Threads::Threads and
            # CMAKE_DL_LIBS are the portable spellings -- they expand to
            # -lpthread / -ldl exactly where those files exist, and to nothing
            # where the platform folds them into libc. Reachable on Android
            # since a codegen.rust module crosses (lib/mobileBare.nix).
            find_package(Threads REQUIRED)
            target_link_libraries(${_BARE_TARGET} PRIVATE Threads::Threads ${CMAKE_DL_LIBS})
        endif()
    endif()

    foreach(lib ${BARE_LINK_LIBRARIES})
        target_link_libraries(${_BARE_TARGET} PRIVATE ${lib})
    endforeach()

    # Where the host's `lp_*` come from, on the one platform that needs telling.
    #
    # LOGOS_MODULE_BARE_LINK_HOST_ABI names an EMPTY shared object whose SONAME
    # is the host's logos-protocol image. `--no-as-needed` makes the linker
    # record it as a DT_NEEDED even though no symbol is taken from it, so the
    # artifact says where its undefined `lp_*` resolve without carrying a byte
    # of protocol code. Android's loader has no other mechanism -- see
    # lib/buildBareModule.nix for the measurement. Empty everywhere else.
    if(LOGOS_MODULE_BARE_LINK_HOST_ABI)
        if(NOT EXISTS "${LOGOS_MODULE_BARE_LINK_HOST_ABI}")
            message(FATAL_ERROR
                "LOGOS_MODULE_BARE_LINK_HOST_ABI does not exist: ${LOGOS_MODULE_BARE_LINK_HOST_ABI}")
        endif()
        target_link_options(${_BARE_TARGET} PRIVATE
            -Wl,--no-as-needed ${LOGOS_MODULE_BARE_LINK_HOST_ABI} -Wl,--as-needed)
    endif()

    # lp_* stays undefined: that IS the Bare shape. Both linkers have to be
    # told so -- ELF permits undefined symbols in a shared object by default,
    # but a cross toolchain may have turned that default off. The NDK's
    # android.toolchain.cmake does exactly that (`-Wl,--no-undefined` in
    # CMAKE_SHARED_LINKER_FLAGS), and the link then fails on lp_token_save,
    # lp_token_save_inbound and lp_grant_host_services -- the three the host
    # image exists to supply. `-z undefs` is the ELF twin of Mach-O's
    # `-undefined dynamic_lookup`: it cancels `-z defs` / `--no-undefined`
    # whether or not anything set it, so this is stated rather than assumed.
    if(APPLE)
        target_link_options(${_BARE_TARGET} PRIVATE -undefined dynamic_lookup)
        set_target_properties(${_BARE_TARGET} PROPERTIES
            INSTALL_RPATH "@loader_path"
            INSTALL_NAME_DIR "@rpath"
            BUILD_WITH_INSTALL_NAME_DIR TRUE
        )
    else()
        target_link_options(${_BARE_TARGET} PRIVATE "LINKER:-z,undefs")
        set_target_properties(${_BARE_TARGET} PROPERTIES
            INSTALL_RPATH "$ORIGIN"
            INSTALL_RPATH_USE_LINK_PATH FALSE
        )
    endif()

    install(TARGETS ${_BARE_TARGET}
        LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}/logos/bare
        RUNTIME DESTINATION ${CMAKE_INSTALL_LIBDIR}/logos/bare
    )

    message(STATUS "Logos Bare module ${BARE_NAME} configured (protocol-free, no Qt)")
endfunction()

#[=======================================================================[.rst:
logos_wasm_module
-----------------

Build the **Wasm host**: the module, logos-protocol's web transport and a small
relay, compiled to WebAssembly as ONE executable that runs in a Web Worker.

The same sources as :cmake:command:`logos_bare_module` -- the module impl plus
the Qt-free half of the generated tree -- with two differences that are the
whole of what makes it a host rather than an artifact to be loaded:

  * it LINKS logos-protocol's wasm subset (``liblogos_protocol_wasm.a``), where
    a Bare module deliberately leaves ``lp_*`` undefined for its host to supply.
    A wasm image has no dlopen and nothing to resolve against, so the image is
    the host: the module and the protocol are one link;
  * ``wasm/logos_wasm_host.cpp`` from this repo comes with it, supplying
    ``main()``, the Worker's message port as an ``IMessageChannel``, and the
    provider that answers Call/Methods/Subscribe/Token by driving the module's
    module-impl C ABI.

``logos_module()`` routes here when ``LOGOS_MODULE_WEB`` is ON and then returns,
so a web build never calls ``logos_find_qt()``.

ONE EXECUTABLE, built with ``-sSINGLE_FILE=1`` so the glue carries the image
base64-embedded. That is not a size preference: a ``file://`` page cannot
``fetch()`` a sibling ``.wasm``, and a webview loading a local entry document is
exactly where this runs. The nix wrapper extracts the embedded image back out as
``<name>_wasm_image.wasm`` -- the same bytes, for weighing and inspection --
rather than linking a second time, which would produce a DIFFERENT image:
wasm-opt minifies export names per link, so a separately-linked ``.wasm`` does
not match the shipped glue and could not be run with it.
#]=======================================================================]
function(logos_wasm_module)
    cmake_parse_arguments(
        WASM
        ""
        "NAME"
        "SOURCES;EXTERNAL_LIBS;FIND_PACKAGES;LINK_LIBRARIES;LINK_TARGETS;INCLUDE_DIRS"
        ${ARGN}
    )

    if(NOT EMSCRIPTEN)
        message(FATAL_ERROR
            "logos_wasm_module(${WASM_NAME}): this output only exists under the "
            "Emscripten toolchain. Configure with logos-nix's "
            "pkgs.logosWasmCmakeFlags.")
    endif()
    if(NOT LOGOS_PROTOCOL_WASM_ROOT)
        message(FATAL_ERROR
            "logos_wasm_module(${WASM_NAME}): LOGOS_PROTOCOL_WASM_ROOT is not "
            "set. It must name logos-protocol's wasm build "
            "(packages.<system>.logos-protocol-wasm), which supplies both the "
            "web transport and the lp_* doors this image links.")
    endif()
    # The host main lives in THIS repo, and a module's CMakeLists.txt reaches
    # this file through the same variable -- which arrives in the ENVIRONMENT
    # (nix sets env.LOGOS_MODULE_BUILDER_ROOT), not as a cmake -D. Read both, so
    # a developer configuring by hand can pass either.
    set(_wasm_builder_root "${LOGOS_MODULE_BUILDER_ROOT}")
    if(NOT _wasm_builder_root)
        set(_wasm_builder_root "$ENV{LOGOS_MODULE_BUILDER_ROOT}")
    endif()
    if(NOT _wasm_builder_root OR NOT EXISTS "${_wasm_builder_root}/wasm/logos_wasm_host.cpp")
        message(FATAL_ERROR
            "logos_wasm_module(${WASM_NAME}): wasm/logos_wasm_host.cpp was not "
            "found. LOGOS_MODULE_BUILDER_ROOT must name this repo's root; it "
            "resolved to '${_wasm_builder_root}'.")
    endif()

    foreach(pkg ${WASM_FIND_PACKAGES})
        find_package(${pkg} REQUIRED)
    endforeach()

    _logos_protocol_free_sources(${WASM_NAME} "logos_wasm_module" "${WASM_SOURCES}" _WASM_GEN_CPPS)

    set(_WASM_OBJS ${WASM_NAME}_wasm_objs)
    add_library(${_WASM_OBJS} OBJECT
        ${WASM_SOURCES}
        ${_WASM_GEN_CPPS}
        "${_wasm_builder_root}/wasm/logos_wasm_host.cpp"
    )

    # No QObject anywhere in this image; AUTOMOC is on directory-wide for the
    # plugin build and would demand Qt's moc.
    set_target_properties(${_WASM_OBJS} PROPERTIES
        AUTOMOC OFF AUTOUIC OFF AUTORCC OFF
        POSITION_INDEPENDENT_CODE ON
    )
    target_compile_features(${_WASM_OBJS} PRIVATE cxx_std_17)

    # Which module this image serves. A file-scope constant rather than a
    # runtime lookup: one image is one module, and there is nothing in a Worker
    # to discover it from.
    target_compile_definitions(${_WASM_OBJS} PRIVATE
        LOGOS_WASM_MODULE_NAME="${WASM_NAME}")

    target_include_directories(${_WASM_OBJS} PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}
        ${CMAKE_CURRENT_SOURCE_DIR}/src
        ${CMAKE_CURRENT_BINARY_DIR}
        "${CMAKE_CURRENT_SOURCE_DIR}/generated_code"
        "${CMAKE_CURRENT_SOURCE_DIR}/generated_code/include"
        # The wasm protocol's headers: logos_module_impl.h and the web
        # transport's own (message_channel.h, web_rpc_connection.h,
        # incoming_call_handler.h, json_mapping.h). Flat, as nix/wasm.nix
        # installs them.
        "${LOGOS_PROTOCOL_WASM_ROOT}/include"
    )

    if(LOGOS_CPP_SDK_IS_SOURCE)
        target_include_directories(${_WASM_OBJS} PRIVATE
            ${LOGOS_CPP_SDK_ROOT}/cpp
            ${LOGOS_CPP_SDK_ROOT}/cpp/generated
        )
    else()
        target_include_directories(${_WASM_OBJS} PRIVATE
            ${LOGOS_CPP_SDK_ROOT}/include
            ${LOGOS_CPP_SDK_ROOT}/include/cpp
        )
    endif()

    foreach(dir ${WASM_INCLUDE_DIRS})
        target_include_directories(${_WASM_OBJS} PRIVATE ${dir})
    endforeach()

    # NOT _logos_link_sdk_headers(), and the reason is a cmake rule rather than
    # a preference. That helper does find_package(logos-cpp-sdk CONFIG), and an
    # installed SDK's generated ConfigVersion.cmake refuses a consumer whose
    # CMAKE_SIZEOF_VOID_P differs from the one it was written on:
    #
    #   Could not find a configuration file for package "logos-cpp-sdk" that is
    #   compatible with requested version ""
    #     ... logos-cpp-sdkConfig.cmake, version: 0.2.0 (64bit)
    #
    # wasm32 is a 32-bit pointer target, so every 64-bit-built package config in
    # the store is rejected for it -- a rejection whose message says "version",
    # which is why it is worth naming here.
    #
    # Nothing is lost. What that target carries is an include path for the
    # Qt-free SDK headers, which this function already puts on the line
    # explicitly above, plus nlohmann_json. nlohmann_json's own config is
    # ARCH_INDEPENDENT (it is header-only) and resolves for wasm32 unchanged.
    find_package(nlohmann_json REQUIRED)
    target_link_libraries(${_WASM_OBJS} PRIVATE nlohmann_json::nlohmann_json)

    find_library(_LOGOS_PROTOCOL_WASM_LIB
        NAMES logos_protocol_wasm
        PATHS "${LOGOS_PROTOCOL_WASM_ROOT}/lib"
        NO_DEFAULT_PATH NO_CMAKE_FIND_ROOT_PATH)
    if(NOT _LOGOS_PROTOCOL_WASM_LIB)
        message(FATAL_ERROR
            "liblogos_protocol_wasm.a was not found in "
            "${LOGOS_PROTOCOL_WASM_ROOT}/lib. Refusing to link a Wasm host with "
            "no protocol in it: every lp_* the generated glue calls would be "
            "undefined and the link error would name the symbols, not the cause.")
    endif()

    # THE LINK, once. `-sSINGLE_FILE=1` embeds the image in the glue, which is
    # what makes a file:// page able to load it, and the nix wrapper extracts
    # the image back out rather than linking a second time (wasm-opt minifies
    # export names per link, so a second link is a DIFFERENT image).
    #
    # `_EXPORTED_FUNCTIONS` names what JS reaches by ccall; without it the
    # optimiser removes them, since nothing in the image calls them. `_main` is
    # on the list because -sMODULARIZE defers it to the factory call rather than
    # running it at load.
    set(_WASM_LINK_FLAGS
        "-sMODULARIZE=1"
        "-sEXPORT_NAME=LogosWasmModule"
        # worker is the shipping environment; node is what lets a test drive
        # the image without a browser (see logos_wasm_post's fallback in
        # wasm/logos_wasm_host.cpp), and web costs nothing and makes the same
        # glue usable from a page during debugging.
        "-sENVIRONMENT=web,worker,node"
        "-sALLOW_MEMORY_GROWTH=1"
        "-sEXPORTED_FUNCTIONS=['_main','_logos_wasm_deliver','_logos_wasm_ready_ms']"
        "-sEXPORTED_RUNTIME_METHODS=['ccall','cwrap']"
        # A trap must kill the Worker, which the loader page reports as a module
        # failure. Without this emscripten's abort() throws a JS exception that
        # an unlucky catch could swallow, leaving a module that answers nothing
        # and never says why.
        "-sEXIT_RUNTIME=0"
        "-sASSERTIONS=0"
        "-sSINGLE_FILE=1"
    )

    add_executable(${WASM_NAME}_wasm $<TARGET_OBJECTS:${_WASM_OBJS}>)
    target_link_libraries(${WASM_NAME}_wasm PRIVATE ${_LOGOS_PROTOCOL_WASM_LIB} ${WASM_LINK_LIBRARIES})
    target_link_options(${WASM_NAME}_wasm PRIVATE ${_WASM_LINK_FLAGS})
    set_target_properties(${WASM_NAME}_wasm PROPERTIES
        SUFFIX ".js"
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/web"
    )

    foreach(target ${WASM_LINK_TARGETS})
        if(TARGET ${target})
            target_link_libraries(${WASM_NAME}_wasm PRIVATE ${target})
        else()
            message(FATAL_ERROR
                "LINK_TARGETS target '${target}' was not defined before "
                "logos_module(). Refusing to silently drop a configured link target.")
        endif()
    endforeach()

    foreach(ext_lib ${WASM_EXTERNAL_LIBS})
        _logos_find_external_lib(${ext_lib} _ext_path _ext_include _ext_lib_dir)
        if(NOT _ext_path)
            message(FATAL_ERROR
                "External library '${ext_lib}' was not found in ${_ext_lib_dir}. "
                "Refusing to build a Wasm host with a missing dependency.")
        endif()
        target_link_libraries(${WASM_NAME}_wasm PRIVATE ${_ext_path})
        target_include_directories(${_WASM_OBJS} PRIVATE ${_ext_include})
    endforeach()

    message(STATUS "Logos Wasm host ${WASM_NAME} configured (web transport only, no Qt)")
endfunction()

#[=======================================================================[.rst:
logos_view_framework
--------------------

Build the **iOS view framework**: a ``type: ui_qml`` module as one embedded
framework that carries its Qt backend and its QML, and binds Qt UPWARD into
the app image.

It is the same module, from the same generated tree, as the desktop Qt
plugin — the ONE difference is the link. Nothing is linked at all:

  * Qt is compiled against and never linked, so every Qt symbol the backend
    calls stays UNDEFINED and dyld resolves it against the app's own static
    Qt at load time. A Qt archive in here would be a second QtCore in the
    process (ADR 0006 is what this implements).
  * logos-qt-host (``LogosAPI``, the provider glue) and logos-protocol are
    left undefined for exactly the same reason and by exactly the same
    mechanism — the app image has them.
  * ``-undefined dynamic_lookup`` is what says so to the linker
    (spike ``ios-dlopen-bare-module``, Level 2).

Three things are in the framework that are NOT in the desktop plugin:

  * the QML, compiled into the image's own qrc — ``<App>.app/Frameworks/`` is
    flat and read-only and there is nowhere beside the binary to put a view;
  * the repc REPLICA, because on a phone there is no ``<name>_replica_factory``
    plugin file to load separately;
  * ``LogosViewFrameworkAbi.cpp.in``'s six C entry points, the whole surface
    the host dlsym's.

``logos_module()`` routes here when ``LOGOS_MODULE_VIEW_FRAMEWORK`` is ON and
then returns. The nix wrapper (mkLogosQmlModule's ``view`` output) runs
``scripts/logos-view-gate.sh`` over the result; this function only produces
the artifact, the gate decides whether the link was honest.
#]=======================================================================]
function(logos_view_framework)
    cmake_parse_arguments(VIEW "" "NAME;REP_FILE;QML_URI;QML_TYPE_NAME"
        "SOURCES;FIND_PACKAGES;INCLUDE_DIRS" ${ARGN})

    if(NOT VIEW_REP_FILE)
        message(FATAL_ERROR
            "logos_view_framework: ${VIEW_NAME} has no REP_FILE. A view framework "
            "IS the typed source and the typed replica of one .rep — without it "
            "there is no backend to bind the QML to and the module should ship "
            "as QML alone.")
    endif()
    if(NOT LOGOS_VIEW_QML_DIR)
        message(FATAL_ERROR
            "logos_view_framework: LOGOS_VIEW_QML_DIR is not set. It names the "
            "directory whose contents are compiled into the framework's qrc; "
            "mkLogosQmlModule derives it from metadata.json's `view` field and "
            "passes it in.")
    endif()
    if(NOT LOGOS_VIEW_QML_ENTRY)
        message(FATAL_ERROR "logos_view_framework: LOGOS_VIEW_QML_ENTRY is not set.")
    endif()

    set(_TARGET ${VIEW_NAME}_view)
    set(_GEN_DIR "${CMAKE_CURRENT_SOURCE_DIR}/generated_code")

    # Qt is FOUND but never linked; see the header. Quick and Gui are in the
    # list because a view backend's headers reach them transitively even when
    # its own code does not.
    set(_QT_COMPONENTS Core Gui Qml Quick RemoteObjects)
    find_package(Qt6 REQUIRED COMPONENTS ${_QT_COMPONENTS})
    set(QT_VERSION_MAJOR 6)
    foreach(pkg ${VIEW_FIND_PACKAGES})
        find_package(${pkg} REQUIRED)
    endforeach()

    # Q_PLUGIN_METADATA(... FILE "metadata.json") is resolved by moc against
    # the include path, so the document has to be beside the build.
    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/metadata.json")
        configure_file(
            "${CMAKE_CURRENT_SOURCE_DIR}/metadata.json"
            "${CMAKE_CURRENT_BINARY_DIR}/metadata.json"
            COPYONLY
        )
    endif()

    # ── the sources ─────────────────────────────────────────────────────────
    # The module's own, plus every generated translation unit — the same set
    # the desktop plugin compiles. `logos_sdk.cpp` and the per-dependency
    # `*_api.cpp` are #include'd by their siblings, never compiled twice.
    set(_SRCS ${VIEW_SOURCES})
    if(EXISTS "${_GEN_DIR}/logos_sdk.cpp")
        list(APPEND _SRCS "${_GEN_DIR}/logos_sdk.cpp")
    endif()
    file(GLOB _GEN_CPPS CONFIGURE_DEPENDS "${_GEN_DIR}/*.cpp")
    file(GLOB _GEN_HS CONFIGURE_DEPENDS "${_GEN_DIR}/*.h")
    list(FILTER _GEN_CPPS EXCLUDE REGEX ".*/(logos_sdk|.*_api)\\.cpp$")
    list(APPEND _SRCS ${_GEN_CPPS} ${_GEN_HS})

    add_library(${_TARGET} SHARED ${_SRCS})
    set_target_properties(${_TARGET} PROPERTIES
        AUTOMOC ON
        # QT_MAJOR_VERSION is NOT decoration. CMake decides whether to create
        # an autogen target by asking the target which Qt it uses, and it asks
        # by looking at the Qt libraries the target LINKS. This one links none,
        # so the answer is "no Qt" and AUTOMOC is skipped — SILENTLY, with no
        # diagnostic anywhere. What comes out is a framework whose plugin class
        # has no moc: the link succeeds (`-undefined dynamic_lookup` swallows
        # the missing vtable), the image loads, and it has no
        # qt_plugin_instance for the host to call. This property is the
        # documented way to answer that question directly.
        QT_MAJOR_VERSION 6
        PREFIX ""
        OUTPUT_NAME "${VIEW_NAME}_view"
        SUFFIX ".dylib"
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/view"
    )

    # ── Qt, compiled against and not linked ─────────────────────────────────
    # TRANSITIVELY, and that is the whole difficulty. A Qt module's usage
    # requirements are spread over the Qt6::* targets it links: Qt6::Qml names
    # its own Headers directory and gets QtQmlIntegration's from Qt6::QmlIntegration,
    # and Qt6::Platform is where the C++ standard lives. A target that LINKS
    # Qt6::Qml collects all of it for free; this one must not link, so it walks
    # the same graph by hand. Taking only the named components' direct
    # properties fails as `'QtQmlIntegration/qqmlintegration.h' file not found`
    # — a missing header from a Qt module nobody named.
    #
    # Read at configure time rather than through $<TARGET_PROPERTY:...> so
    # AUTOMOC sees a plain list: moc is handed the target's include
    # directories, and a generator expression there fails as a missing
    # Q_OBJECT at link time.
    set(_qt_seen "")
    set(_qt_queue "")
    foreach(_c IN LISTS _QT_COMPONENTS)
        list(APPEND _qt_queue "Qt6::${_c}")
    endforeach()
    while(_qt_queue)
        list(POP_FRONT _qt_queue _qt_t)
        if(NOT TARGET ${_qt_t})
            continue()
        endif()
        if(${_qt_t} IN_LIST _qt_seen)
            continue()
        endif()
        list(APPEND _qt_seen ${_qt_t})

        get_target_property(_inc ${_qt_t} INTERFACE_INCLUDE_DIRECTORIES)
        if(_inc)
            target_include_directories(${_TARGET} SYSTEM PRIVATE ${_inc})
        endif()
        get_target_property(_def ${_qt_t} INTERFACE_COMPILE_DEFINITIONS)
        if(_def)
            target_compile_definitions(${_TARGET} PRIVATE ${_def})
        endif()
        get_target_property(_opt ${_qt_t} INTERFACE_COMPILE_OPTIONS)
        if(_opt)
            target_compile_options(${_TARGET} PRIVATE ${_opt})
        endif()
        # THE LANGUAGE LEVEL, which is part of "compiled against Qt" and is
        # not optional. Qt carries it as a compile FEATURE (cxx_std_17, on
        # Qt6::Platform), inherited by LINKING. The diagnostic when it is
        # missing is `no template named 'is_integral_v' in namespace 'std'`
        # from inside qtypeinfo.h — twenty errors deep in a Qt header, naming
        # nothing about this build.
        get_target_property(_feat ${_qt_t} INTERFACE_COMPILE_FEATURES)
        if(_feat)
            target_compile_features(${_TARGET} PRIVATE ${_feat})
        endif()

        get_target_property(_deps ${_qt_t} INTERFACE_LINK_LIBRARIES)
        if(_deps)
            foreach(_d IN LISTS _deps)
                # $<LINK_ONLY:...> is SKIPPED, and it is the whole reason this
                # loop can be trusted. Qt6::Core names Qt6::PlatformModuleInternal
                # that way: those are Qt's own build settings — -fno-exceptions,
                # -Werror, QT_NO_FOREACH, QT_NO_EXCEPTIONS — and CMake never gives
                # them to a consumer, precisely because LINK_ONLY means "link,
                # do not compile with". Following it anyway compiles the module
                # under settings no Qt consumer has ever been built with; the
                # first diagnostic is `cannot use 'throw' with exceptions
                # disabled` inside logos_types.h.
                if(_d MATCHES "LINK_ONLY")
                    continue()
                endif()
                string(REGEX MATCHALL "Qt6::[A-Za-z0-9_]+" _qt_names "${_d}")
                list(APPEND _qt_queue ${_qt_names})
            endforeach()
        endif()
    endwhile()

    # ...and a floor under the standard, because WHICH Qt target carries that
    # feature has moved between Qt minor versions. C++17 is qtbase 6's own
    # minimum.
    set_target_properties(${_TARGET} PROPERTIES
        CXX_STANDARD_REQUIRED ON
        CXX_EXTENSIONS OFF)
    get_target_property(_std ${_TARGET} CXX_STANDARD)
    if(NOT _std OR _std LESS 17)
        set_target_properties(${_TARGET} PROPERTIES CXX_STANDARD 17)
    endif()

    _logos_module_sdk_includes(${_TARGET} "${_GEN_DIR}")
    # Header roots the plugin path reaches by LINKING a CMake target it must
    # not link here — nlohmann_json, which arrives through
    # logos-cpp-sdk::logos_headers on the desktop. Passed as a plain list of
    # directories by mkLogosQmlModule.
    if(LOGOS_VIEW_EXTRA_INCLUDE_DIRS)
        target_include_directories(${_TARGET} SYSTEM PRIVATE ${LOGOS_VIEW_EXTRA_INCLUDE_DIRS})
    endif()
    foreach(dir ${VIEW_INCLUDE_DIRS})
        target_include_directories(${_TARGET} PRIVATE ${dir})
    endforeach()

    # ── the .rep, both sides of it ──────────────────────────────────────────
    qt6_add_repc_sources(${_TARGET} ${VIEW_REP_FILE})
    qt6_add_repc_replicas(${_TARGET} ${VIEW_REP_FILE})

    set(_REP_ABS "${VIEW_REP_FILE}")
    if(NOT IS_ABSOLUTE "${_REP_ABS}")
        set(_REP_ABS "${CMAKE_CURRENT_SOURCE_DIR}/${VIEW_REP_FILE}")
    endif()
    file(READ "${_REP_ABS}" _REP_CONTENTS)
    string(REGEX MATCH "class[ \t]+([A-Za-z_][A-Za-z0-9_]*)" _ "${_REP_CONTENTS}")
    set(LOGOS_REP_CLASS "${CMAKE_MATCH_1}")
    if(NOT LOGOS_REP_CLASS)
        message(FATAL_ERROR "logos_view_framework: could not parse a class name from ${VIEW_REP_FILE}")
    endif()
    get_filename_component(LOGOS_REP_BASE "${VIEW_REP_FILE}" NAME_WE)

    if(NOT VIEW_QML_URI)
        set(VIEW_QML_URI "Logos.${LOGOS_REP_CLASS}")
    endif()
    if(NOT VIEW_QML_TYPE_NAME)
        set(VIEW_QML_TYPE_NAME "${LOGOS_REP_CLASS}")
    endif()
    set(LOGOS_QML_URI "${VIEW_QML_URI}")
    set(LOGOS_QML_TYPE_NAME "${VIEW_QML_TYPE_NAME}")

    # The per-module LogosViewPlugin base the plugin class inherits — the same
    # two templates, from the same LOGOS_VIEW_TEMPLATE_DIR, that the desktop
    # plugin gets. A local copy here is how the phone and the desktop would
    # come to disagree about what a view plugin is.
    if(NOT LOGOS_VIEW_TEMPLATE_DIR AND DEFINED ENV{LOGOS_VIEW_TEMPLATE_DIR})
        set(LOGOS_VIEW_TEMPLATE_DIR "$ENV{LOGOS_VIEW_TEMPLATE_DIR}")
    endif()
    if(NOT LOGOS_VIEW_TEMPLATE_DIR)
        message(FATAL_ERROR
            "logos_view_framework: LOGOS_VIEW_TEMPLATE_DIR is not set. The "
            "LogosView*.in templates are owned by logos-view-module; there is "
            "no local copy to fall back to.")
    endif()
    set(_VIEW_GEN "${CMAKE_CURRENT_BINARY_DIR}/view_plugin_base_${VIEW_NAME}")
    file(MAKE_DIRECTORY "${_VIEW_GEN}")
    configure_file("${LOGOS_VIEW_TEMPLATE_DIR}/LogosViewPluginBase.h.in"
                   "${_VIEW_GEN}/LogosViewPluginBase.h" @ONLY)
    configure_file("${LOGOS_VIEW_TEMPLATE_DIR}/LogosViewPluginBase.cpp.in"
                   "${_VIEW_GEN}/LogosViewPluginBase.cpp" @ONLY)
    target_sources(${_TARGET} PRIVATE
        "${_VIEW_GEN}/LogosViewPluginBase.h"
        "${_VIEW_GEN}/LogosViewPluginBase.cpp")
    target_include_directories(${_TARGET} PRIVATE "${_VIEW_GEN}")

    # ── the QML, inside the image ───────────────────────────────────────────
    set(_QML_PREFIX "/logos/${VIEW_NAME}")
    set(LOGOS_VIEW_QML_URL "qrc:${_QML_PREFIX}/${LOGOS_VIEW_QML_ENTRY}")
    file(GLOB_RECURSE _QML_FILES RELATIVE "${LOGOS_VIEW_QML_DIR}"
         CONFIGURE_DEPENDS "${LOGOS_VIEW_QML_DIR}/*")
    if(NOT _QML_FILES)
        message(FATAL_ERROR
            "logos_view_framework: no QML under ${LOGOS_VIEW_QML_DIR}. A view "
            "framework with no view is an artifact the host would load and then "
            "have nothing to show.")
    endif()
    list(FIND _QML_FILES "${LOGOS_VIEW_QML_ENTRY}" _entry_idx)
    if(_entry_idx EQUAL -1)
        message(FATAL_ERROR
            "logos_view_framework: the entry ${LOGOS_VIEW_QML_ENTRY} is not in "
            "${LOGOS_VIEW_QML_DIR}. The host loads ${LOGOS_VIEW_QML_URL} and "
            "there would be nothing at that URL.")
    endif()

    # The same per-module URI the desktop's generated qmldir declares, for the
    # same reason: Qt's composite-type cache is keyed on (name, uri), so two
    # modules with a Card.qml each cross-match in one host process when the
    # uri is empty. Skipped when the author shipped one.
    set(_QRC_FILES ${_QML_FILES})
    if(NOT EXISTS "${LOGOS_VIEW_QML_DIR}/qmldir")
        file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/view_qmldir_${VIEW_NAME}/qmldir"
             "module com.logos.module.${VIEW_NAME}\n")
        qt6_add_resources(${_TARGET} "${VIEW_NAME}_qmldir"
            PREFIX "${_QML_PREFIX}"
            BASE "${CMAKE_CURRENT_BINARY_DIR}/view_qmldir_${VIEW_NAME}"
            FILES "${CMAKE_CURRENT_BINARY_DIR}/view_qmldir_${VIEW_NAME}/qmldir")
    endif()
    list(TRANSFORM _QRC_FILES PREPEND "${LOGOS_VIEW_QML_DIR}/")
    qt6_add_resources(${_TARGET} "${VIEW_NAME}_qml"
        PREFIX "${_QML_PREFIX}"
        BASE "${LOGOS_VIEW_QML_DIR}"
        FILES ${_QRC_FILES})

    # ── the C edge ──────────────────────────────────────────────────────────
    set(LOGOS_VIEW_NAME "${VIEW_NAME}")
    if(NOT LOGOS_VIEW_VERSION)
        set(LOGOS_VIEW_VERSION "0.0.0")
    endif()
    # CMAKE_CURRENT_FUNCTION_LIST_DIR, not LOGOS_MODULE_BUILDER_ROOT: that one
    # reaches a module build as an ENV var (the CMakeLists include line), not as
    # a cmake variable, and an empty prefix here would configure_file from "/".
    # The template is this file's sibling and belongs to the same repo.
    configure_file("${CMAKE_CURRENT_FUNCTION_LIST_DIR}/LogosViewFrameworkAbi.cpp.in"
                   "${CMAKE_CURRENT_BINARY_DIR}/logos_view_abi_${VIEW_NAME}.cpp" @ONLY)
    target_sources(${_TARGET} PRIVATE
        "${CMAKE_CURRENT_BINARY_DIR}/logos_view_abi_${VIEW_NAME}.cpp")

    # ── the link that is not a link ─────────────────────────────────────────
    # `-fixup_chains` is the spike's variant B: a modern fixup format and no
    # dependency on the app being linked first. The deprecation warning on
    # `-undefined dynamic_lookup` is Apple's and is expected.
    target_link_options(${_TARGET} PRIVATE
        "-Wl,-undefined,dynamic_lookup"
        "-Wl,-fixup_chains"
        "-Wl,-headerpad_max_install_names")
    set_target_properties(${_TARGET} PROPERTIES
        INSTALL_NAME_DIR "@rpath"
        BUILD_WITH_INSTALL_NAME_DIR TRUE)

    install(TARGETS ${_TARGET}
        LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}/logos/view
        RUNTIME DESTINATION ${CMAKE_INSTALL_LIBDIR}/logos/view
    )

    message(STATUS "Logos view framework ${_TARGET}: ${LOGOS_REP_CLASS} from "
                   "${VIEW_REP_FILE}, QML at ${LOGOS_VIEW_QML_URL}, Qt bound upward")
endfunction()

#[=======================================================================[.rst:
logos_module
------------

Main function to define a Logos module plugin.

Usage:
  logos_module(
    NAME <module_name>
    SOURCES <source_files...>
    [EXTERNAL_LIBS <lib_names...>]
    [FIND_PACKAGES <package_names...>]
    [LINK_LIBRARIES <library_names...>]
    [LINK_TARGETS <target_names...>]
    [AUTOGEN_DEPENDS <target_names...>]
    [INCLUDE_DIRS <directories...>]
    [REP_FILE <path_to_rep_file>]
    [QML_URI <uri>]
    [QML_TYPE_NAME <type_name>]
  )

Parameters:
  NAME            - (required) Module name
  SOURCES         - (required) Source files for the plugin
  REP_FILE        - Qt .rep file; builds a typed ``<name>_replica_factory`` plugin
                    and adds repc source/replica targets automatically
  QML_URI         - QML import URI for the replica factory (default: Logos.<ClassName>)
  QML_TYPE_NAME   - QML type name for the replica (default: <ClassName> from .rep)

Example:
  logos_module(
    NAME my_module
    SOURCES
      my_module_plugin.cpp
      my_module_plugin.h
      my_module_interface.h
    EXTERNAL_LIBS
      libfoo
    LINK_TARGETS
      my_custom_lib
    AUTOGEN_DEPENDS
      my_custom_lib
    INCLUDE_DIRS
      ${CMAKE_CURRENT_BINARY_DIR}/generated
    REP_FILE
      my_module.rep
  )
#]=======================================================================]
function(logos_module)
    cmake_parse_arguments(
        MODULE
        ""
        "NAME;REP_FILE;QML_URI;QML_TYPE_NAME"
        "SOURCES;EXTERNAL_LIBS;FIND_PACKAGES;LINK_LIBRARIES;LINK_TARGETS;AUTOGEN_DEPENDS;INCLUDE_DIRS"
        ${ARGN}
    )

    if(NOT MODULE_NAME)
        message(FATAL_ERROR "logos_module: NAME is required")
    endif()

    # Which LogosModule.cmake configured this module. There is exactly one, and
    # this line is how that stays true: a second copy anywhere in the tree names
    # itself here instead of being silently selected.
    message(STATUS "LogosModule.cmake: ${CMAKE_CURRENT_FUNCTION_LIST_FILE}")

    # Find dependencies
    logos_find_dependencies()

    # LOGOS_MODULE_BARE switches this call to the Bare module output (the
    # protocol-free artifact) INSTEAD of the Qt plugin, and returns. Nothing
    # below this point runs: no logos_find_qt(), no plugin target, no Qt on the
    # link line. mkLogosModule's `bare` output is what sets it.
    if(LOGOS_MODULE_BARE)
        logos_bare_module(
            NAME ${MODULE_NAME}
            SOURCES ${MODULE_SOURCES}
            EXTERNAL_LIBS ${MODULE_EXTERNAL_LIBS}
            FIND_PACKAGES ${MODULE_FIND_PACKAGES}
            LINK_LIBRARIES ${MODULE_LINK_LIBRARIES}
            LINK_TARGETS ${MODULE_LINK_TARGETS}
            INCLUDE_DIRS ${MODULE_INCLUDE_DIRS}
        )
        return()
    endif()

    # LOGOS_MODULE_WEB switches this call to the Wasm host: the same
    # protocol-free sources as the Bare artifact, plus logos-protocol's wasm
    # subset and this repo's host main, linked into one wasm executable. Same
    # place and same reason as the branch above -- nothing below runs, so no Qt
    # is looked for in an image that cannot have any.
    if(LOGOS_MODULE_WEB)
        logos_wasm_module(
            NAME ${MODULE_NAME}
            SOURCES ${MODULE_SOURCES}
            EXTERNAL_LIBS ${MODULE_EXTERNAL_LIBS}
            FIND_PACKAGES ${MODULE_FIND_PACKAGES}
            LINK_LIBRARIES ${MODULE_LINK_LIBRARIES}
            LINK_TARGETS ${MODULE_LINK_TARGETS}
            INCLUDE_DIRS ${MODULE_INCLUDE_DIRS}
        )
        return()
    endif()

    # LOGOS_MODULE_VIEW_FRAMEWORK switches a `type: ui_qml` module to its iOS
    # framework shape and returns, for the same reason and in the same place:
    # the artifact is the same sources with a different link, so it cannot be
    # produced by patching the plugin target after the fact.
    if(LOGOS_MODULE_VIEW_FRAMEWORK)
        logos_view_framework(
            NAME ${MODULE_NAME}
            REP_FILE ${MODULE_REP_FILE}
            QML_URI ${MODULE_QML_URI}
            QML_TYPE_NAME ${MODULE_QML_TYPE_NAME}
            SOURCES ${MODULE_SOURCES}
            FIND_PACKAGES ${MODULE_FIND_PACKAGES}
            INCLUDE_DIRS ${MODULE_INCLUDE_DIRS}
        )
        return()
    endif()

    logos_find_qt()

    # Embed metadata next to plugin sources (AUTOMOC / Q_PLUGIN_METADATA)
    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/metadata.json")
        configure_file(
            "${CMAKE_CURRENT_SOURCE_DIR}/metadata.json"
            "${CMAKE_CURRENT_BINARY_DIR}/metadata.json"
            COPYONLY
        )
    endif()

    # Root for dependencies
    get_filename_component(LOGOS_DEPS_ROOT "${LOGOS_CPP_SDK_ROOT}" DIRECTORY)

    # Set up generated code directory
    if(LOGOS_CPP_SDK_IS_SOURCE)
        set(PLUGINS_OUTPUT_DIR "${CMAKE_BINARY_DIR}/generated_code")
    else()
        # For nix builds, generated files are in source tree
        set(PLUGINS_OUTPUT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/generated_code")
    endif()

    # Locate metadata.json - check build directory first, then source
    set(METADATA_FILE "${CMAKE_CURRENT_SOURCE_DIR}/metadata.json")
    if(NOT EXISTS "${METADATA_FILE}" AND EXISTS "${CMAKE_CURRENT_BINARY_DIR}/metadata.json")
        set(METADATA_FILE "${CMAKE_CURRENT_BINARY_DIR}/metadata.json")
    endif()

    # Find additional packages
    foreach(pkg ${MODULE_FIND_PACKAGES})
        find_package(${pkg} REQUIRED)
    endforeach()

    # Collect sources
    set(PLUGIN_SOURCES ${MODULE_SOURCES})

    # Add logos-module interface header
    if(LOGOS_MODULE_IS_SOURCE)
        list(APPEND PLUGIN_SOURCES ${LOGOS_MODULE_ROOT}/src/interface.h)
    else()
        list(APPEND PLUGIN_SOURCES ${LOGOS_MODULE_ROOT}/include/module_lib/interface.h)
    endif()

    # Add Qt HOST RUNTIME sources (only if that root is a repo checkout — an
    # installed prefix ships them as a static library, linked below). The
    # transport/consumer core (token_manager, module_proxy, api_client/consumer)
    # lives in the logos-protocol LIBRARY and is linked, never compiled in.
    # LOGOS_QT_HOST_ROOT is a logos-plugin-qt checkout since the host-runtime
    # split; it carries these files at exactly the paths logos-qt-sdk's did.
    if(LOGOS_QT_HOST_IS_SOURCE)
        list(APPEND PLUGIN_SOURCES
            ${LOGOS_QT_HOST_ROOT}/cpp/logos_api.cpp
            ${LOGOS_QT_HOST_ROOT}/cpp/logos_api.h
            ${LOGOS_QT_HOST_ROOT}/cpp/logos_api_provider.cpp
            ${LOGOS_QT_HOST_ROOT}/cpp/logos_api_provider.h
            ${LOGOS_QT_HOST_ROOT}/cpp/logos_provider_object.cpp
            ${LOGOS_QT_HOST_ROOT}/cpp/logos_provider_object.h
            ${LOGOS_QT_HOST_ROOT}/cpp/qt_provider_object.cpp
            ${LOGOS_QT_HOST_ROOT}/cpp/qt_provider_object.h
            # qt_provider_object.cpp's dispatch calls into this; omitting it is
            # an undefined symbol at link time, not a configure error.
            ${LOGOS_QT_HOST_ROOT}/cpp/logos_qt_arg_decode.cpp
            ${LOGOS_QT_HOST_ROOT}/cpp/logos_qt_arg_decode.h
        )
    endif()
    if(LOGOS_CPP_SDK_IS_SOURCE)
        # Add generated logos_sdk.cpp
        list(APPEND PLUGIN_SOURCES ${PLUGINS_OUTPUT_DIR}/logos_sdk.cpp)
        set_source_files_properties(
            ${PLUGINS_OUTPUT_DIR}/logos_sdk.cpp
            PROPERTIES GENERATED TRUE
        )
        
        # Set up code generator
        set(CPP_GENERATOR_BUILD_DIR "${LOGOS_DEPS_ROOT}/build/cpp-generator")
        set(CPP_GENERATOR "${CPP_GENERATOR_BUILD_DIR}/bin/logos-cpp-generator")
        
        if(NOT TARGET cpp_generator_build)
            add_custom_target(cpp_generator_build
                COMMAND bash "${LOGOS_CPP_SDK_ROOT}/cpp-generator/compile.sh"
                WORKING_DIRECTORY "${LOGOS_DEPS_ROOT}"
                COMMENT "Building logos-cpp-generator"
                VERBATIM
            )
        endif()
        
        # LOGOS_API_STYLE selects between Qt-typed and lp (Qt-free,
        # logos-protocol C ABI) wrapper signatures on the generated
        # `<Module>` client class. Defaults to "qt" — every existing
        # handcrafted module keeps its Qt-typed LogosModules. Core
        # universal modules (those declaring `interface: "universal"`
        # in metadata.json, minus `type: ui_qml` view backends) get this
        # set to "lp" automatically by mkLogosModule.nix.
        if(NOT DEFINED LOGOS_API_STYLE OR LOGOS_API_STYLE STREQUAL "")
            set(LOGOS_API_STYLE "qt")
        endif()
        add_custom_target(run_cpp_generator_${MODULE_NAME}
            COMMAND "${CPP_GENERATOR}" --metadata "${METADATA_FILE}"
                    --general-only --api-style "${LOGOS_API_STYLE}"
                    --output-dir "${PLUGINS_OUTPUT_DIR}"
            WORKING_DIRECTORY "${LOGOS_DEPS_ROOT}"
            COMMENT "Running logos-cpp-generator for ${MODULE_NAME} (api-style=${LOGOS_API_STYLE})"
            VERBATIM
        )
        add_dependencies(run_cpp_generator_${MODULE_NAME} cpp_generator_build)
    else()
        # For nix builds, logos_sdk.cpp is already generated
        if(EXISTS "${PLUGINS_OUTPUT_DIR}/logos_sdk.cpp")
            list(APPEND PLUGIN_SOURCES ${PLUGINS_OUTPUT_DIR}/logos_sdk.cpp)
        elseif(EXISTS "${PLUGINS_OUTPUT_DIR}/include/logos_sdk.cpp")
            list(APPEND PLUGIN_SOURCES ${PLUGINS_OUTPUT_DIR}/include/logos_sdk.cpp)
        endif()
    endif()

    # Universal UI backends (type: ui_qml + interface: universal): the
    # generated glue plugin — derived from the impl class by
    # logos-qt-generator, carrying Q_PLUGIN_METADATA and the initLogos
    # wiring — must be compiled into the target (the .h rides along so
    # AUTOMOC picks up the plugin metadata).
    if(EXISTS "${PLUGINS_OUTPUT_DIR}/${MODULE_NAME}_ui_glue.cpp")
        list(APPEND PLUGIN_SOURCES
            ${PLUGINS_OUTPUT_DIR}/${MODULE_NAME}_ui_glue.cpp
            ${PLUGINS_OUTPUT_DIR}/${MODULE_NAME}_ui_glue.h)
    endif()


    # Create the plugin library
    add_library(${MODULE_NAME}_module_plugin SHARED ${PLUGIN_SOURCES})

    # Pre-generated sources from logos-cpp-generator (Nix preConfigure, universal/provider modules)
    set(_LOGOS_GEN_DIR "${CMAKE_CURRENT_SOURCE_DIR}/generated_code")
    if(IS_DIRECTORY "${_LOGOS_GEN_DIR}")
        file(GLOB _LOGOS_GEN_CPPS CONFIGURE_DEPENDS "${_LOGOS_GEN_DIR}/*.cpp")
        file(GLOB _LOGOS_GEN_HS CONFIGURE_DEPENDS "${_LOGOS_GEN_DIR}/*.h")
        # Exclude files that are #include'd by logos_sdk.cpp (not compiled separately):
        # logos_sdk.cpp and per-dependency *_api.cpp files. core_manager
        # is no longer generated (universal modules expose only their
        # declared dependencies; apps that need to manage the core use
        # liblogos' C API directly).
        list(FILTER _LOGOS_GEN_CPPS EXCLUDE REGEX ".*/(logos_sdk|.*_api)\\.cpp$")
        if(_LOGOS_GEN_CPPS OR _LOGOS_GEN_HS)
            target_sources(${MODULE_NAME}_module_plugin PRIVATE ${_LOGOS_GEN_CPPS} ${_LOGOS_GEN_HS})
            target_include_directories(${MODULE_NAME}_module_plugin PRIVATE "${_LOGOS_GEN_DIR}")
        endif()
    endif()

    # Set output name without lib prefix
    set_target_properties(${MODULE_NAME}_module_plugin PROPERTIES
        PREFIX ""
        OUTPUT_NAME "${MODULE_NAME}_plugin"
    )

    # Add dependency on code generator for source layout
    if(LOGOS_CPP_SDK_IS_SOURCE)
        add_dependencies(${MODULE_NAME}_module_plugin run_cpp_generator_${MODULE_NAME})
    endif()

    # Link additional targets (e.g., protobuf libs defined by module)
    foreach(target ${MODULE_LINK_TARGETS})
        if(TARGET ${target})
            target_link_libraries(${MODULE_NAME}_module_plugin PRIVATE ${target})
        else()
            message(FATAL_ERROR
                "LINK_TARGETS target '${target}' was not defined before "
                "logos_module(). Define it (e.g. add_library(${target} ...)) or "
                "remove it from LINK_TARGETS. Refusing to silently drop a "
                "configured link target.")
        endif()
    endforeach()

    # Set AUTOGEN dependencies if specified (ensures AUTOMOC waits for these targets)
    if(MODULE_AUTOGEN_DEPENDS)
        set_target_properties(${MODULE_NAME}_module_plugin PROPERTIES
            AUTOGEN_TARGET_DEPENDS "${MODULE_AUTOGEN_DEPENDS}"
        )
    endif()

    _logos_module_sdk_includes(${MODULE_NAME}_module_plugin "${PLUGINS_OUTPUT_DIR}")

    # Add custom include directories
    foreach(dir ${MODULE_INCLUDE_DIRS})
        target_include_directories(${MODULE_NAME}_module_plugin PRIVATE ${dir})
    endforeach()

    # Link Qt libraries
    target_link_libraries(${MODULE_NAME}_module_plugin PRIVATE 
        Qt${QT_VERSION_MAJOR}::Core 
        Qt${QT_VERSION_MAJOR}::RemoteObjects
    )

    # Link the Qt HOST RUNTIME via its exported CMake target so the consumer
    # inherits the full transitive link interface (logos-protocol, and through
    # it OpenSSL, Boost::system, nlohmann_json). The protocol layer must come
    # from an exported target — a bare archive on the link line would leave
    # every Boost.Asio TLS symbol undefined.
    if(NOT LOGOS_QT_HOST_IS_SOURCE)
        find_package(logos-protocol REQUIRED CONFIG
            PATHS ${LOGOS_PROTOCOL_ROOT}/lib/cmake/logos-protocol
            NO_DEFAULT_PATH)
        find_package(${LOGOS_QT_HOST_PACKAGE} REQUIRED CONFIG
            PATHS ${LOGOS_QT_HOST_ROOT}/lib/cmake/${LOGOS_QT_HOST_PACKAGE}
            NO_DEFAULT_PATH)
        # find_package(... REQUIRED) already stops on a missing package, but a
        # package that resolves without defining its target would leave the
        # plugin with no host runtime and no diagnostic. Refuse that too.
        if(NOT TARGET ${LOGOS_QT_HOST_TARGET})
            message(FATAL_ERROR
                "${LOGOS_QT_HOST_PACKAGE} was found at ${LOGOS_QT_HOST_ROOT} but did not "
                "define ${LOGOS_QT_HOST_TARGET}. The Qt host runtime is not optional — "
                "refusing to link ${MODULE_NAME}_module_plugin without it.")
        endif()
        target_link_libraries(${MODULE_NAME}_module_plugin PRIVATE ${LOGOS_QT_HOST_TARGET})
    else()
        # Source-layout host runtime: its sources are compiled into the plugin
        # above; the protocol layer is linked installed-or-source here.
        if(EXISTS "${LOGOS_PROTOCOL_ROOT}/lib/cmake/logos-protocol")
            find_package(logos-protocol REQUIRED CONFIG
                PATHS ${LOGOS_PROTOCOL_ROOT}/lib/cmake/logos-protocol
                NO_DEFAULT_PATH)
            target_link_libraries(${MODULE_NAME}_module_plugin PRIVATE logos-protocol::logos_protocol)
        elseif(EXISTS "${LOGOS_PROTOCOL_ROOT}/cpp/CMakeLists.txt")
            if(NOT TARGET logos_protocol)
                add_subdirectory("${LOGOS_PROTOCOL_ROOT}/cpp"
                                 "${CMAKE_BINARY_DIR}/logos-protocol-build")
            endif()
            target_link_libraries(${MODULE_NAME}_module_plugin PRIVATE logos_protocol)
        else()
            message(FATAL_ERROR "logos-protocol not usable at ${LOGOS_PROTOCOL_ROOT} "
                                "(need an installed prefix or a source checkout).")
        endif()
    endif()

    _logos_link_sdk_headers(${MODULE_NAME}_module_plugin)

    # Handle external libraries
    foreach(ext_lib ${MODULE_EXTERNAL_LIBS})
        _logos_find_external_lib(${ext_lib} ${ext_lib}_PATH EXT_INCLUDE_DIR EXT_LIB_DIR)

        if(${ext_lib}_PATH)
            target_link_libraries(${MODULE_NAME}_module_plugin PRIVATE ${${ext_lib}_PATH})
            target_include_directories(${MODULE_NAME}_module_plugin PRIVATE ${EXT_INCLUDE_DIR})

            # Copy shared libraries to output directory (static archives are
            # linked in, no runtime copy needed).
            #
            # Windows needs care: what we just linked is usually the IMPORT
            # library lib<x>.dll.a, whose name ends in ".a" and would therefore
            # be mistaken for a static archive and skipped -- shipping a plugin
            # with no runtime DLL beside it. Resolve the companion .dll and copy
            # THAT instead.
            get_filename_component(EXT_LIB_FILENAME "${${ext_lib}_PATH}" NAME)
            set(EXT_RUNTIME_LIB "")
            if(EXT_LIB_FILENAME MATCHES "\\.dll\\.a$" OR EXT_LIB_FILENAME MATCHES "\\.lib$")
                get_filename_component(_ext_dir "${${ext_lib}_PATH}" DIRECTORY)
                foreach(_dll_name lib${ext_lib}.dll ${ext_lib}.dll)
                    if(EXISTS "${_ext_dir}/${_dll_name}")
                        set(EXT_RUNTIME_LIB "${_ext_dir}/${_dll_name}")
                        set(EXT_LIB_FILENAME "${_dll_name}")
                        break()
                    endif()
                endforeach()
                if(NOT EXT_RUNTIME_LIB)
                    message(FATAL_ERROR
                        "External library '${ext_lib}': linked ${EXT_LIB_FILENAME} but found no "
                        "companion DLL in ${_ext_dir}. The plugin would build and then fail to "
                        "load at runtime, so refusing to continue.")
                endif()
            elseif(NOT EXT_LIB_FILENAME MATCHES "\\.a$")
                set(EXT_RUNTIME_LIB "${${ext_lib}_PATH}")
            endif()
            if(EXT_RUNTIME_LIB)
                add_custom_command(TARGET ${MODULE_NAME}_module_plugin PRE_LINK
                    COMMAND ${CMAKE_COMMAND} -E copy_if_different
                        ${EXT_RUNTIME_LIB}
                        ${CMAKE_BINARY_DIR}/modules/${EXT_LIB_FILENAME}
                    COMMENT "Copying ${EXT_LIB_FILENAME} to modules directory"
                )
            endif()
        else()
            message(FATAL_ERROR
                "External library '${ext_lib}' (declared in EXTERNAL_LIBS / "
                "metadata.json nix.external_libraries) was not found in "
                "${EXT_LIB_DIR}. A configured external library must be present at "
                "build time — check its vendor_path, externalLibInputs, or "
                "build_command/output_pattern. Refusing to build a plugin with a "
                "missing dependency.")
        endif()
    endforeach()

    # Go/cgo static archives (whole-archive link). Set by mkLogosModule when metadata lists go_build externals.
    if(DEFINED LOGOS_MODULE_GO_STATIC_LIBS AND NOT LOGOS_MODULE_GO_STATIC_LIBS STREQUAL "")
        set(EXT_LIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/lib")
        foreach(_golib IN LISTS LOGOS_MODULE_GO_STATIC_LIBS)
            if(_golib STREQUAL "")
                continue()
            endif()
            find_library(_LOGOS_GO_${_golib}
                NAMES lib${_golib}.a lib${_golib}.lib ${_golib}.a ${_golib}.lib
                PATHS ${EXT_LIB_DIR} NO_DEFAULT_PATH)
            if(_LOGOS_GO_${_golib})
                target_link_libraries(${MODULE_NAME}_module_plugin PRIVATE ${_LOGOS_GO_${_golib}})
                if(APPLE)
                    target_link_options(${MODULE_NAME}_module_plugin PRIVATE -Wl,-force_load ${_LOGOS_GO_${_golib}})
                    target_link_libraries(${MODULE_NAME}_module_plugin PUBLIC "-framework CoreFoundation" "-framework Security")
                else()
                    target_link_options(${MODULE_NAME}_module_plugin PRIVATE
                        -Wl,--whole-archive ${_LOGOS_GO_${_golib}} -Wl,--no-whole-archive)
                endif()
            else()
                message(FATAL_ERROR
                    "Go static library '${_golib}' (a go_build external library) "
                    "was not found in ${EXT_LIB_DIR}. Check the external build "
                    "produced lib${_golib}.a. Refusing to build a plugin with a "
                    "missing dependency.")
            endif()
        endforeach()
    endif()

    # Rust static archives. Set by mkLogosModule when a cdylib module is authored
    # in Rust (metadata codegen.rust): the builder compiles the crate to a
    # staticlib and stages it in lib/. The archive provides the logos_module_*
    # exports the generated Qt glue calls; its own lp_* undefineds resolve against
    # the logos-protocol archive already linked above (via logos-qt-sdk). Plain
    # link (NOT whole-archive: the Rust install hook is pulled in lazily by a
    # symbol reference), with the protocol target re-mentioned AFTER the archive
    # so single-pass linkers (GNU ld) see it later on the line — one protocol
    # stack shared by the glue and the Rust code.
    if(DEFINED LOGOS_MODULE_RUST_STATIC_LIBS AND NOT LOGOS_MODULE_RUST_STATIC_LIBS STREQUAL "")
        set(_LOGOS_RUST_LIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/lib")
        foreach(_rustlib IN LISTS LOGOS_MODULE_RUST_STATIC_LIBS)
            if(_rustlib STREQUAL "")
                continue()
            endif()
            find_library(_LOGOS_RUST_${_rustlib}
                NAMES lib${_rustlib}.a ${_rustlib}
                PATHS ${_LOGOS_RUST_LIB_DIR} NO_DEFAULT_PATH)
            if(_LOGOS_RUST_${_rustlib})
                target_link_libraries(${MODULE_NAME}_module_plugin PRIVATE ${_LOGOS_RUST_${_rustlib}})
                if(TARGET logos-protocol::logos_protocol)
                    target_link_libraries(${MODULE_NAME}_module_plugin PRIVATE logos-protocol::logos_protocol)
                elseif(TARGET logos_protocol)
                    target_link_libraries(${MODULE_NAME}_module_plugin PRIVATE logos_protocol)
                endif()
                # Native libraries Rust's `std` leaves undefined in a staticlib.
                # These are per-platform and NOT interchangeable: the old
                # two-way APPLE/else split silently meant "else == Linux" and
                # put `pthread dl` on the Windows link line, where `dl` does not
                # exist at all and `pthread` lives in a separate
                # mingw_w64-pthreads package that is not on the sysroot search
                # path -- so a Rust module could never link for Windows.
                if(APPLE)
                    target_link_libraries(${MODULE_NAME}_module_plugin PRIVATE
                        "-framework CoreFoundation" "-framework Security")
                elseif(WIN32)
                    # Derived from the archive's own undefined symbols, not
                    # guessed: BCryptGenRandom -> bcrypt; Nt*/Rtl* (file I/O and
                    # the unwinder) -> ntdll; GetUserProfileDirectoryW ->
                    # userenv; WaitOnAddress/WakeByAddress* -> synchronization
                    # (kernel32's mingw import lib does not carry them); the
                    # WSA*/socket set -> ws2_32. `ProcessPrng` needs nothing
                    # here -- std bundles its own bcryptprimitives import stubs
                    # inside the archive. Qt happens to drag several of these in
                    # already, but naming them keeps the Rust link independent
                    # of Qt's link interface.
                    # `pthread` is winpthreads, which mkLogosModule adds as a
                    # build input for a cross Rust module (see the note there).
                    # It is NOT part of the mingw sysroot -- nixpkgs builds mingw
                    # against mcfgthread -- but a crate's vendored C can still
                    # want it: aws-lc-sys compiles aws-lc's thread_pthread.c.
                    # ld pulls archive members on demand, so naming it costs
                    # nothing for a module that references no pthread symbol.
                    target_link_libraries(${MODULE_NAME}_module_plugin PRIVATE
                        ws2_32 bcrypt ntdll userenv synchronization advapi32 pthread)
                else()
                    target_link_libraries(${MODULE_NAME}_module_plugin PRIVATE pthread dl)
                endif()
            else()
                message(FATAL_ERROR
                    "Rust static library '${_rustlib}' (a codegen.rust module) was not "
                    "found in ${_LOGOS_RUST_LIB_DIR}. The builder stages the compiled "
                    "staticlib there before the plugin link; this usually means the "
                    "crate build or staging step did not run.")
            endif()
        endforeach()
    endif()

    # Nim static archives. Set by mkLogosModule when a cdylib module is authored
    # in Nim (metadata codegen.nim): the builder compiles the Nim sources to a
    # staticlib and stages it in lib/. The archive provides the logos_module_*
    # exports the generated glue calls; its lp_*/protocol undefineds resolve
    # against logos-protocol (re-mentioned after the archive for single-pass
    # linkers). Plain link — the Nim runtime is initialised by a load-time
    # constructor in the archive, not whole-archive inclusion. Nim's stdlib
    # leaves pthread/dl/m undefined in a staticlib.
    if(DEFINED LOGOS_MODULE_NIM_STATIC_LIBS AND NOT LOGOS_MODULE_NIM_STATIC_LIBS STREQUAL "")
        set(_LOGOS_NIM_LIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/lib")
        foreach(_nimlib IN LISTS LOGOS_MODULE_NIM_STATIC_LIBS)
            if(_nimlib STREQUAL "")
                continue()
            endif()
            find_library(_LOGOS_NIM_${_nimlib}
                NAMES lib${_nimlib}.a ${_nimlib}
                PATHS ${_LOGOS_NIM_LIB_DIR} NO_DEFAULT_PATH)
            if(_LOGOS_NIM_${_nimlib})
                target_link_libraries(${MODULE_NAME}_module_plugin PRIVATE ${_LOGOS_NIM_${_nimlib}})
                if(TARGET logos-protocol::logos_protocol)
                    target_link_libraries(${MODULE_NAME}_module_plugin PRIVATE logos-protocol::logos_protocol)
                elseif(TARGET logos_protocol)
                    target_link_libraries(${MODULE_NAME}_module_plugin PRIVATE logos_protocol)
                endif()
                if(APPLE)
                    target_link_libraries(${MODULE_NAME}_module_plugin PRIVATE pthread)
                else()
                    target_link_libraries(${MODULE_NAME}_module_plugin PRIVATE pthread dl m)
                endif()
                # External libraries the Nim staticlib's FFI references (metadata
                # codegen.nim.link) — e.g. secp256k1 — linked AFTER the archive so
                # its undefined symbols resolve. Their lib dirs come from
                # nix.packages.runtime (plugin buildInputs → NIX_LDFLAGS).
                if(DEFINED LOGOS_MODULE_NIM_LINK_LIBS AND NOT LOGOS_MODULE_NIM_LINK_LIBS STREQUAL "")
                    foreach(_nl IN LISTS LOGOS_MODULE_NIM_LINK_LIBS)
                        if(NOT _nl STREQUAL "")
                            target_link_libraries(${MODULE_NAME}_module_plugin PRIVATE ${_nl})
                        endif()
                    endforeach()
                endif()
            else()
                message(FATAL_ERROR
                    "Nim static library '${_nimlib}' (a codegen.nim module) was not "
                    "found in ${_LOGOS_NIM_LIB_DIR}. The builder stages the compiled "
                    "staticlib there before the plugin link; this usually means the "
                    "Nim build or staging step did not run.")
            endif()
        endforeach()
    endif()

    # Link additional libraries
    foreach(lib ${MODULE_LINK_LIBRARIES})
        target_link_libraries(${MODULE_NAME}_module_plugin PRIVATE ${lib})
    endforeach()

    # Output directory and RPATH settings
    set_target_properties(${MODULE_NAME}_module_plugin PROPERTIES
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/modules"
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/modules"
        BUILD_WITH_INSTALL_RPATH TRUE
        SKIP_BUILD_RPATH FALSE
    )

    if(APPLE)
        # Allow unresolved symbols at link time for external libs
        target_link_options(${MODULE_NAME}_module_plugin PRIVATE -undefined dynamic_lookup)
        
        set_target_properties(${MODULE_NAME}_module_plugin PROPERTIES
            INSTALL_RPATH "@loader_path"
            INSTALL_NAME_DIR "@rpath"
            BUILD_WITH_INSTALL_NAME_DIR TRUE
        )

        add_custom_command(TARGET ${MODULE_NAME}_module_plugin POST_BUILD
            COMMAND install_name_tool -id "@rpath/${MODULE_NAME}_plugin.dylib" 
                    $<TARGET_FILE:${MODULE_NAME}_module_plugin>
            COMMENT "Updating library paths for macOS"
        )
    else()
        set_target_properties(${MODULE_NAME}_module_plugin PROPERTIES
            INSTALL_RPATH "$ORIGIN"
            INSTALL_RPATH_USE_LINK_PATH FALSE
        )
    endif()

    # Install targets
    install(TARGETS ${MODULE_NAME}_module_plugin
        LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}/logos/modules
        RUNTIME DESTINATION ${CMAKE_INSTALL_LIBDIR}/logos/modules
        ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}/logos/modules
    )

    install(DIRECTORY "${PLUGINS_OUTPUT_DIR}/"
        DESTINATION ${CMAKE_INSTALL_DATADIR}/logos-${MODULE_NAME}-module/generated
        OPTIONAL
    )

    # ── Optional: typed replica factory plugin from a .rep file ─────────────
    if(MODULE_REP_FILE)
        _logos_module_add_replica_factory(${MODULE_NAME} "${MODULE_REP_FILE}"
            "${MODULE_QML_URI}" "${MODULE_QML_TYPE_NAME}")
    endif()

    message(STATUS "Logos module ${MODULE_NAME} configured successfully")
endfunction()

# ── Internal: build a <name>_replica_factory Qt plugin from a .rep file ─────
function(_logos_module_add_replica_factory MODULE_NAME REP_FILE QML_URI QML_TYPE_NAME)
    # Need repc replica generation + Qml for qmlRegisterUncreatableMetaObject
    find_package(Qt${QT_VERSION_MAJOR} REQUIRED COMPONENTS Core RemoteObjects Qml)

    # Also attach the source-side repc to the plugin target so the backend has
    # the generated SimpleSource base class available.
    if(QT_VERSION_MAJOR EQUAL 6)
        qt6_add_repc_sources(${MODULE_NAME}_module_plugin ${REP_FILE})
    else()
        qt5_add_repc_sources(${MODULE_NAME}_module_plugin ${REP_FILE})
    endif()

    # Parse class name out of the .rep (first `class Foo` line).
    set(_REP_FILE_ABS "${REP_FILE}")
    if(NOT IS_ABSOLUTE "${_REP_FILE_ABS}")
        set(_REP_FILE_ABS "${CMAKE_CURRENT_SOURCE_DIR}/${REP_FILE}")
    endif()
    file(READ "${_REP_FILE_ABS}" _REP_CONTENTS)
    string(REGEX MATCH "class[ \t]+([A-Za-z_][A-Za-z0-9_]*)" _ "${_REP_CONTENTS}")
    set(LOGOS_REP_CLASS "${CMAKE_MATCH_1}")
    if(NOT LOGOS_REP_CLASS)
        message(FATAL_ERROR "logos_module: could not parse class name from ${REP_FILE}")
    endif()

    get_filename_component(LOGOS_REP_BASE "${REP_FILE}" NAME_WE)
    set(LOGOS_FACTORY_CLASS "${LOGOS_REP_CLASS}ReplicaFactoryPlugin")

    if(NOT QML_URI)
        set(QML_URI "Logos.${LOGOS_REP_CLASS}")
    endif()
    if(NOT QML_TYPE_NAME)
        set(QML_TYPE_NAME "${LOGOS_REP_CLASS}")
    endif()
    set(LOGOS_QML_URI "${QML_URI}")
    set(LOGOS_QML_TYPE_NAME "${QML_TYPE_NAME}")

    # WHERE the LogosView*.in templates come from: logos-view-module's cmake/,
    # handed in as LOGOS_VIEW_TEMPLATE_DIR (a cmake flag and an env var, both
    # set by logos-module-builder — i.e. by THIS repo, the one shipping this
    # file: lib/mkLogosModule.nix and lib/buildCppPlugin.nix set them on every
    # plugin build and export the env var in every module dev shell).
    #
    # This used to be "sibling of this .cmake file", with a pathExists probe
    # falling through to CMAKE_CURRENT_LIST_DIR. The templates therefore lived
    # next to this file, in logos-module-builder — but a second consumer
    # instantiates them too (the rep-file-plugin fixture that proves a built
    # plugin still loads and casts), and it cannot depend on
    # logos-module-builder, so it kept its own byte-identical copy and nothing
    # compared the two. Ownership went first to logos-plugin-qt, and then on to
    # logos-view-module, which owns the whole ui_qml authoring flavour — the
    # fixture included — and is a LEAF, so every consumer can reach it. See
    # logos-view-module/cmake/README.md.
    #
    # There is no fallback. A sibling-directory fallback is what let a second
    # copy be picked silently, and the whole point of naming the directory is
    # that a wrong or absent answer is loud.
    if(NOT LOGOS_VIEW_TEMPLATE_DIR AND DEFINED ENV{LOGOS_VIEW_TEMPLATE_DIR})
        set(LOGOS_VIEW_TEMPLATE_DIR "$ENV{LOGOS_VIEW_TEMPLATE_DIR}")
    endif()
    if(NOT LOGOS_VIEW_TEMPLATE_DIR)
        message(FATAL_ERROR
            "logos_module(REP_FILE ...): LOGOS_VIEW_TEMPLATE_DIR is not set. "
            "The LogosView*.in templates are owned by logos-view-module "
            "(cmake/), and logos-module-builder — the repo shipping this "
            "LogosModule.cmake — passes this in for every plugin build and "
            "exports it in every module dev shell. Set it to that directory; "
            "there is no local copy to fall back to.")
    endif()
    set(_TEMPLATE_DIR "${LOGOS_VIEW_TEMPLATE_DIR}")
    foreach(_tpl LogosViewReplicaFactory.h.in LogosViewReplicaFactory.cpp.in
                 LogosViewPluginBase.h.in LogosViewPluginBase.cpp.in)
        if(NOT EXISTS "${_TEMPLATE_DIR}/${_tpl}")
            message(FATAL_ERROR
                "logos_module(REP_FILE ...): ${_tpl} is missing from "
                "LOGOS_VIEW_TEMPLATE_DIR (${_TEMPLATE_DIR}).")
        endif()
    endforeach()

    set(_GEN_DIR "${CMAKE_CURRENT_BINARY_DIR}/replica_factory_${MODULE_NAME}")
    file(MAKE_DIRECTORY "${_GEN_DIR}")
    configure_file("${_TEMPLATE_DIR}/LogosViewReplicaFactory.h.in"
                   "${_GEN_DIR}/LogosViewReplicaFactory.h" @ONLY)
    configure_file("${_TEMPLATE_DIR}/LogosViewReplicaFactory.cpp.in"
                   "${_GEN_DIR}/LogosViewReplicaFactory.cpp" @ONLY)

    # Generate the per-module LogosViewPlugin base that plugins inherit
    # from. It implements viewObject() + enableRemoting() so ui-host can
    # drive the plugin via a plain qobject_cast<LogosViewPlugin*> instead
    # of QMetaObject::invokeMethod reflection.
    set(_VIEW_PLUGIN_GEN_DIR "${CMAKE_CURRENT_BINARY_DIR}/view_plugin_base_${MODULE_NAME}")
    file(MAKE_DIRECTORY "${_VIEW_PLUGIN_GEN_DIR}")
    configure_file("${_TEMPLATE_DIR}/LogosViewPluginBase.h.in"
                   "${_VIEW_PLUGIN_GEN_DIR}/LogosViewPluginBase.h" @ONLY)
    configure_file("${_TEMPLATE_DIR}/LogosViewPluginBase.cpp.in"
                   "${_VIEW_PLUGIN_GEN_DIR}/LogosViewPluginBase.cpp" @ONLY)
    target_sources(${MODULE_NAME}_module_plugin PRIVATE
        "${_VIEW_PLUGIN_GEN_DIR}/LogosViewPluginBase.h"
        "${_VIEW_PLUGIN_GEN_DIR}/LogosViewPluginBase.cpp"
    )
    target_include_directories(${MODULE_NAME}_module_plugin PRIVATE
        "${_VIEW_PLUGIN_GEN_DIR}"
    )
    target_link_libraries(${MODULE_NAME}_module_plugin PRIVATE
        Qt${QT_VERSION_MAJOR}::RemoteObjects
    )

    set(_FACTORY_TARGET ${MODULE_NAME}_replica_factory)
    add_library(${_FACTORY_TARGET} SHARED
        "${_GEN_DIR}/LogosViewReplicaFactory.h"
        "${_GEN_DIR}/LogosViewReplicaFactory.cpp"
    )

    set_target_properties(${_FACTORY_TARGET} PROPERTIES
        AUTOMOC ON
        PREFIX ""
        OUTPUT_NAME "${MODULE_NAME}_replica_factory"
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/modules"
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/modules"
        BUILD_WITH_INSTALL_RPATH TRUE
        SKIP_BUILD_RPATH FALSE
        INSTALL_NAME_DIR "@rpath"
    )
    if(APPLE)
        target_link_options(${_FACTORY_TARGET} PRIVATE "-Wl,-headerpad_max_install_names")
    endif()

    target_include_directories(${_FACTORY_TARGET} PRIVATE
        "${_GEN_DIR}"
        "${CMAKE_CURRENT_BINARY_DIR}"
    )
    if(QT_VERSION_MAJOR EQUAL 6)
        qt6_add_repc_replicas(${_FACTORY_TARGET} ${REP_FILE})
    else()
        qt5_add_repc_replicas(${_FACTORY_TARGET} ${REP_FILE})
    endif()

    target_link_libraries(${_FACTORY_TARGET} PRIVATE
        Qt${QT_VERSION_MAJOR}::Core
        Qt${QT_VERSION_MAJOR}::RemoteObjects
        Qt${QT_VERSION_MAJOR}::Qml
    )

    if(APPLE)
        set_target_properties(${_FACTORY_TARGET} PROPERTIES
            INSTALL_RPATH "@loader_path"
            INSTALL_NAME_DIR "@rpath"
            BUILD_WITH_INSTALL_NAME_DIR TRUE
        )
        add_custom_command(TARGET ${_FACTORY_TARGET} POST_BUILD
            COMMAND install_name_tool -id "@rpath/${MODULE_NAME}_replica_factory.dylib"
                    $<TARGET_FILE:${_FACTORY_TARGET}>
            COMMENT "Updating library paths for macOS"
        )
    else()
        set_target_properties(${_FACTORY_TARGET} PROPERTIES
            INSTALL_RPATH "$ORIGIN"
            INSTALL_RPATH_USE_LINK_PATH FALSE
        )
    endif()

    install(TARGETS ${_FACTORY_TARGET}
        LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}/logos/modules
        RUNTIME DESTINATION ${CMAKE_INSTALL_LIBDIR}/logos/modules
        ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}/logos/modules
    )

    message(STATUS "Logos module ${MODULE_NAME}: replica factory plugin from ${REP_FILE} "
                   "(class ${LOGOS_REP_CLASS}, QML ${LOGOS_QML_URI}.${LOGOS_QML_TYPE_NAME})")
endfunction()
