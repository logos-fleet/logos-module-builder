# LogosModule.cmake
# Reusable CMake module for building Logos plugins
# This handles all the boilerplate configuration for Logos modules

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
    # logos_module_context.h (logos_api.h moved to logos-qt-sdk).
    if(EXISTS "${LOGOS_CPP_SDK_ROOT}/cpp/logos_module_context.h")
        set(_cpp_sdk_found TRUE)
        set(LOGOS_CPP_SDK_IS_SOURCE TRUE PARENT_SCOPE)
    elseif(EXISTS "${LOGOS_CPP_SDK_ROOT}/include/cpp/logos_module_context.h")
        set(_cpp_sdk_found TRUE)
        set(LOGOS_CPP_SDK_IS_SOURCE FALSE PARENT_SCOPE)
    endif()

    # logos-qt-sdk — the Qt developer layer (LogosAPI, provider glue) every
    # Qt plugin links.
    if(NOT DEFINED LOGOS_QT_SDK_ROOT)
        set(_parent_qt_sdk "${CMAKE_SOURCE_DIR}/../logos-qt-sdk")
        if(DEFINED ENV{LOGOS_QT_SDK_ROOT})
            set(LOGOS_QT_SDK_ROOT "$ENV{LOGOS_QT_SDK_ROOT}" PARENT_SCOPE)
            set(LOGOS_QT_SDK_ROOT "$ENV{LOGOS_QT_SDK_ROOT}")
        elseif(EXISTS "${_parent_qt_sdk}/cpp/logos_api.h")
            set(LOGOS_QT_SDK_ROOT "${_parent_qt_sdk}" PARENT_SCOPE)
            set(LOGOS_QT_SDK_ROOT "${_parent_qt_sdk}")
        else()
            set(LOGOS_QT_SDK_ROOT "${CMAKE_SOURCE_DIR}/vendor/logos-qt-sdk" PARENT_SCOPE)
            set(LOGOS_QT_SDK_ROOT "${CMAKE_SOURCE_DIR}/vendor/logos-qt-sdk")
        endif()
    endif()
    set(_qt_sdk_found FALSE)
    if(EXISTS "${LOGOS_QT_SDK_ROOT}/cpp/logos_api.h")
        set(_qt_sdk_found TRUE)
        set(LOGOS_QT_SDK_IS_SOURCE TRUE PARENT_SCOPE)
    elseif(EXISTS "${LOGOS_QT_SDK_ROOT}/include/cpp/logos_api.h")
        set(_qt_sdk_found TRUE)
        set(LOGOS_QT_SDK_IS_SOURCE FALSE PARENT_SCOPE)
    endif()

    # logos-protocol — transports + lp_* C ABI (linked by logos-qt-sdk; also
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
    if(EXISTS "${LOGOS_PROTOCOL_ROOT}/cpp/logos_protocol.h" OR EXISTS "${LOGOS_PROTOCOL_ROOT}/include/cpp/logos_protocol.h")
        set(_protocol_found TRUE)
    endif()

    # logos-module (the Qt PluginInterface) and logos-qt-sdk are the Qt half of
    # a module build. A Bare build (LOGOS_MODULE_BARE) produces the protocol-free
    # artifact and never compiles or links either, so it must not be forced to
    # have them present — that absence is half the point of the output.
    if(NOT _module_found AND NOT LOGOS_MODULE_BARE)
        message(FATAL_ERROR "logos-module not found at ${LOGOS_MODULE_ROOT}. "
                            "Set LOGOS_MODULE_ROOT environment variable or CMake variable.")
    endif()

    if(NOT _cpp_sdk_found)
        message(FATAL_ERROR "logos-cpp-sdk not found at ${LOGOS_CPP_SDK_ROOT}. "
                            "Set LOGOS_CPP_SDK_ROOT environment variable or CMake variable.")
    endif()
    if(NOT _qt_sdk_found AND NOT LOGOS_MODULE_BARE)
        message(FATAL_ERROR "logos-qt-sdk not found at ${LOGOS_QT_SDK_ROOT}. "
                            "Set LOGOS_QT_SDK_ROOT environment variable or CMake variable.")
    endif()
    if(NOT _protocol_found)
        message(FATAL_ERROR "logos-protocol not found at ${LOGOS_PROTOCOL_ROOT}. "
                            "Set LOGOS_PROTOCOL_ROOT environment variable or CMake variable.")
    endif()

    message(STATUS "Found logos-module at: ${LOGOS_MODULE_ROOT}")
    message(STATUS "Found logos-cpp-sdk at: ${LOGOS_CPP_SDK_ROOT}")
    message(STATUS "Found logos-qt-sdk at: ${LOGOS_QT_SDK_ROOT}")
    message(STATUS "Found logos-protocol at: ${LOGOS_PROTOCOL_ROOT}")
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
function(logos_find_qt)
    if(NOT DEFINED QT_VERSION_MAJOR)
        find_package(QT NAMES Qt6 Qt5 REQUIRED COMPONENTS Core RemoteObjects)
        if(Qt6_FOUND)
            set(QT_VERSION_MAJOR 6 PARENT_SCOPE)
        else()
            set(QT_VERSION_MAJOR 5 PARENT_SCOPE)
        endif()
    endif()
    find_package(Qt${QT_VERSION_MAJOR} REQUIRED COMPONENTS Core RemoteObjects)
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

    # The generated translation units, minus every Qt-bearing one. Kept:
    #   <name>_module_impl.cpp    the module-impl C ABI exports
    #   <name>_events_cdylib.cpp  typed event emitters (Qt-free flavour)
    #   logos_sdk.cpp             the lp_*-backed modules().<dep> surface
    # Dropped: the uniform Qt-plugin glue (<name>_cdylib_glue.cpp), the Qt
    # provider dispatch (<name>_dispatch.cpp, logos_provider_dispatch.cpp), the
    # Qt event sidecar (<name>_events.cpp) and the ui glue. <name>_api.cpp is
    # #include'd by logos_sdk.cpp, never compiled on its own.
    file(GLOB _BARE_GEN_CPPS CONFIGURE_DEPENDS "${_BARE_GEN_DIR}/*.cpp")
    list(FILTER _BARE_GEN_CPPS EXCLUDE REGEX
        "/([^/]*_api|[^/]*_dispatch|[^/]*_events|[^/]*_cdylib_glue|[^/]*_qt_glue|[^/]*_ui_glue)\\.cpp$")

    if(NOT _BARE_GEN_CPPS AND NOT BARE_SOURCES)
        message(FATAL_ERROR
            "logos_bare_module(${BARE_NAME}): nothing to compile. Expected the "
            "Qt-free generated sources in ${_BARE_GEN_DIR} (run the module's "
            "code generators first) or module SOURCES.")
    endif()

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

    # nlohmann_json is the only library a Bare C++ module needs (header-only).
    # logos-cpp-sdk::logos_headers is an INTERFACE target that carries it plus
    # the SDK include path; both are Qt-free.
    if(EXISTS "${LOGOS_CPP_SDK_ROOT}/lib/cmake/logos-cpp-sdk")
        find_package(logos-cpp-sdk REQUIRED CONFIG
            PATHS ${LOGOS_CPP_SDK_ROOT}/lib/cmake/logos-cpp-sdk
            NO_DEFAULT_PATH)
        target_link_libraries(${_BARE_TARGET} PRIVATE logos-cpp-sdk::logos_headers)
    else()
        find_package(nlohmann_json REQUIRED)
        target_link_libraries(${_BARE_TARGET} PRIVATE nlohmann_json::nlohmann_json)
    endif()

    foreach(target ${BARE_LINK_TARGETS})
        if(TARGET ${target})
            target_link_libraries(${_BARE_TARGET} PRIVATE ${target})
        else()
            message(FATAL_ERROR
                "LINK_TARGETS target '${target}' was not defined before "
                "logos_module(). Refusing to silently drop a configured link target.")
        endif()
    endforeach()

    # External libraries — same lookup as the plugin build (staged in lib/ by
    # the builder, or pointed at directly by LOGOS_EXT_ROOT_<NAME>).
    foreach(ext_lib ${BARE_EXTERNAL_LIBS})
        string(TOUPPER "${ext_lib}" _ext_lib_upper)
        set(_ext_root_var "LOGOS_EXT_ROOT_${_ext_lib_upper}")
        if(DEFINED ENV{${_ext_root_var}})
            set(EXT_LIB_DIR "$ENV{${_ext_root_var}}/lib")
            set(EXT_INCLUDE_DIR "$ENV{${_ext_root_var}}/include")
        else()
            set(EXT_LIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/lib")
            set(EXT_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/lib")
        endif()
        if(APPLE)
            set(EXT_LIB_NAMES lib${ext_lib}.dylib lib${ext_lib}.so ${ext_lib}.dylib ${ext_lib}.so lib${ext_lib}.a ${ext_lib}.a)
        else()
            set(EXT_LIB_NAMES lib${ext_lib}.so lib${ext_lib}.dylib ${ext_lib}.so ${ext_lib}.dylib lib${ext_lib}.a ${ext_lib}.a)
        endif()
        find_library(${ext_lib}_BARE_PATH NAMES ${EXT_LIB_NAMES} PATHS ${EXT_LIB_DIR} NO_DEFAULT_PATH)
        if(${ext_lib}_BARE_PATH)
            target_link_libraries(${_BARE_TARGET} PRIVATE ${${ext_lib}_BARE_PATH})
            target_include_directories(${_BARE_TARGET} PRIVATE ${EXT_INCLUDE_DIR})
        else()
            message(FATAL_ERROR
                "External library '${ext_lib}' was not found in ${EXT_LIB_DIR}. "
                "Refusing to build a Bare module with a missing dependency.")
        endif()
    endforeach()

    # Go and Rust static archives. Unlike the plugin, the Bare artifact has no
    # Qt glue referencing the module-impl exports, so nothing would pull the
    # archive members in: link them whole so the C ABI actually lands in the
    # artifact (and the gate can see it).
    set(_BARE_STATIC_LIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/lib")
    set(_BARE_WHOLE_ARCHIVES "")
    foreach(_golib IN LISTS LOGOS_MODULE_GO_STATIC_LIBS)
        if(NOT _golib STREQUAL "")
            find_library(_LOGOS_BARE_GO_${_golib}
                NAMES lib${_golib}.a lib${_golib}.lib ${_golib}.a ${_golib}.lib
                PATHS ${_BARE_STATIC_LIB_DIR} NO_DEFAULT_PATH)
            if(NOT _LOGOS_BARE_GO_${_golib})
                message(FATAL_ERROR "Go static library '${_golib}' was not found in ${_BARE_STATIC_LIB_DIR}.")
            endif()
            list(APPEND _BARE_WHOLE_ARCHIVES ${_LOGOS_BARE_GO_${_golib}})
        endif()
    endforeach()
    foreach(_rustlib IN LISTS LOGOS_MODULE_RUST_STATIC_LIBS)
        if(NOT _rustlib STREQUAL "")
            find_library(_LOGOS_BARE_RUST_${_rustlib}
                NAMES lib${_rustlib}.a ${_rustlib}
                PATHS ${_BARE_STATIC_LIB_DIR} NO_DEFAULT_PATH)
            if(NOT _LOGOS_BARE_RUST_${_rustlib})
                message(FATAL_ERROR
                    "Rust static library '${_rustlib}' (a codegen.rust module) was not "
                    "found in ${_BARE_STATIC_LIB_DIR}. The builder stages the compiled "
                    "staticlib there before the link; this usually means the crate build "
                    "or staging step did not run.")
            endif()
            list(APPEND _BARE_WHOLE_ARCHIVES ${_LOGOS_BARE_RUST_${_rustlib}})
        endif()
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
            target_link_libraries(${_BARE_TARGET} PRIVATE pthread dl)
        endif()
    endif()

    foreach(lib ${BARE_LINK_LIBRARIES})
        target_link_libraries(${_BARE_TARGET} PRIVATE ${lib})
    endforeach()

    # lp_* stays undefined: that IS the Bare shape. ELF allows undefined symbols
    # in a shared object by default; Mach-O has to be told.
    if(APPLE)
        target_link_options(${_BARE_TARGET} PRIVATE -undefined dynamic_lookup)
        set_target_properties(${_BARE_TARGET} PROPERTIES
            INSTALL_RPATH "@loader_path"
            INSTALL_NAME_DIR "@rpath"
            BUILD_WITH_INSTALL_NAME_DIR TRUE
        )
    else()
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
  )

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
  )
#]=======================================================================]
function(logos_module)
    cmake_parse_arguments(
        MODULE
        ""
        "NAME;PROVIDER_HEADER"
        "SOURCES;EXTERNAL_LIBS;FIND_PACKAGES;LINK_LIBRARIES;LINK_TARGETS;AUTOGEN_DEPENDS;INCLUDE_DIRS"
        ${ARGN}
    )

    if(NOT MODULE_NAME)
        message(FATAL_ERROR "logos_module: NAME is required")
    endif()

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

    # Add Qt-SDK sources (only if source layout). The Qt developer layer
    # lives in logos-qt-sdk since the qt split; the transport/consumer core
    # (token_manager, module_proxy, api_client/consumer) moved into the
    # logos-protocol LIBRARY and is linked below instead of compiled in.
    if(LOGOS_QT_SDK_IS_SOURCE)
        list(APPEND PLUGIN_SOURCES
            ${LOGOS_QT_SDK_ROOT}/cpp/logos_api.cpp
            ${LOGOS_QT_SDK_ROOT}/cpp/logos_api.h
            ${LOGOS_QT_SDK_ROOT}/cpp/logos_api_provider.cpp
            ${LOGOS_QT_SDK_ROOT}/cpp/logos_api_provider.h
            ${LOGOS_QT_SDK_ROOT}/cpp/logos_provider_object.cpp
            ${LOGOS_QT_SDK_ROOT}/cpp/logos_provider_object.h
            ${LOGOS_QT_SDK_ROOT}/cpp/qt_provider_object.cpp
            ${LOGOS_QT_SDK_ROOT}/cpp/qt_provider_object.h
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

    # Provider-header code generation (new LogosProviderBase API)
    if(MODULE_PROVIDER_HEADER)
        set(_PROVIDER_HEADER_ABS "${CMAKE_CURRENT_SOURCE_DIR}/${MODULE_PROVIDER_HEADER}")
        set(_PROVIDER_DISPATCH "${PLUGINS_OUTPUT_DIR}/logos_provider_dispatch.cpp")

        if(LOGOS_CPP_SDK_IS_SOURCE)
            add_custom_command(
                OUTPUT "${_PROVIDER_DISPATCH}"
                COMMAND "${CPP_GENERATOR}" --provider-header "${_PROVIDER_HEADER_ABS}"
                        --output-dir "${PLUGINS_OUTPUT_DIR}"
                DEPENDS "${_PROVIDER_HEADER_ABS}"
                WORKING_DIRECTORY "${LOGOS_DEPS_ROOT}"
                COMMENT "Generating provider dispatch for ${MODULE_NAME}"
                VERBATIM
            )
        endif()

        if(EXISTS "${_PROVIDER_DISPATCH}" OR LOGOS_CPP_SDK_IS_SOURCE)
            list(APPEND PLUGIN_SOURCES "${_PROVIDER_DISPATCH}")
            set_source_files_properties("${_PROVIDER_DISPATCH}" PROPERTIES GENERATED TRUE)
        endif()
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

    # Include directories
    target_include_directories(${MODULE_NAME}_module_plugin PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}
        ${CMAKE_CURRENT_SOURCE_DIR}/src
        ${CMAKE_CURRENT_BINARY_DIR}
        ${PLUGINS_OUTPUT_DIR}
    )

    # Add include directories based on layout type
    if(LOGOS_MODULE_IS_SOURCE)
        target_include_directories(${MODULE_NAME}_module_plugin PRIVATE ${LOGOS_MODULE_ROOT}/src)
    else()
        target_include_directories(${MODULE_NAME}_module_plugin PRIVATE ${LOGOS_MODULE_ROOT}/include/module_lib)
    endif()

    if(LOGOS_CPP_SDK_IS_SOURCE)
        target_include_directories(${MODULE_NAME}_module_plugin PRIVATE
            ${LOGOS_CPP_SDK_ROOT}/cpp
            ${LOGOS_CPP_SDK_ROOT}/cpp/generated
        )
    else()
        target_include_directories(${MODULE_NAME}_module_plugin PRIVATE
            ${LOGOS_CPP_SDK_ROOT}/include
            ${LOGOS_CPP_SDK_ROOT}/include/cpp
            ${PLUGINS_OUTPUT_DIR}/include
        )
    endif()
    # Qt developer layer (LogosAPI, provider glue, legacy PluginInterface —
    # include/core moved here from logos-cpp-sdk in the qt split)
    if(LOGOS_QT_SDK_IS_SOURCE)
        target_include_directories(${MODULE_NAME}_module_plugin PRIVATE
            ${LOGOS_QT_SDK_ROOT}/cpp
            ${LOGOS_QT_SDK_ROOT}/core
        )
    else()
        target_include_directories(${MODULE_NAME}_module_plugin PRIVATE
            ${LOGOS_QT_SDK_ROOT}/include
            ${LOGOS_QT_SDK_ROOT}/include/cpp
            ${LOGOS_QT_SDK_ROOT}/include/core
        )
    endif()
    # Protocol layer headers (transports, consumer core, lp_* C ABI)
    if(EXISTS "${LOGOS_PROTOCOL_ROOT}/cpp/logos_protocol.h")
        target_include_directories(${MODULE_NAME}_module_plugin PRIVATE
            ${LOGOS_PROTOCOL_ROOT}/cpp
        )
    else()
        target_include_directories(${MODULE_NAME}_module_plugin PRIVATE
            ${LOGOS_PROTOCOL_ROOT}/include
            ${LOGOS_PROTOCOL_ROOT}/include/cpp
        )
    endif()

    # Add custom include directories
    foreach(dir ${MODULE_INCLUDE_DIRS})
        target_include_directories(${MODULE_NAME}_module_plugin PRIVATE ${dir})
    endforeach()

    # Link Qt libraries
    target_link_libraries(${MODULE_NAME}_module_plugin PRIVATE 
        Qt${QT_VERSION_MAJOR}::Core 
        Qt${QT_VERSION_MAJOR}::RemoteObjects
    )

    # Link the Qt SDK via its exported CMake target so the consumer inherits
    # the full transitive link interface (logos-protocol, and through it
    # OpenSSL, Boost::system, nlohmann_json). The protocol layer must come
    # from an exported target — a bare archive on the link line would leave
    # every Boost.Asio TLS symbol undefined.
    if(NOT LOGOS_QT_SDK_IS_SOURCE)
        find_package(logos-protocol REQUIRED CONFIG
            PATHS ${LOGOS_PROTOCOL_ROOT}/lib/cmake/logos-protocol
            NO_DEFAULT_PATH)
        find_package(logos-qt-sdk REQUIRED CONFIG
            PATHS ${LOGOS_QT_SDK_ROOT}/lib/cmake/logos-qt-sdk
            NO_DEFAULT_PATH)
        target_link_libraries(${MODULE_NAME}_module_plugin PRIVATE logos-qt-sdk::logos_qt_sdk)
    else()
        # Source-layout qt-sdk: its sources are compiled into the plugin
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

    # Qt-free base SDK headers (logos_module_context.h / logos_json.h /
    # logos_result.h → nlohmann_json include path).
    if(EXISTS "${LOGOS_CPP_SDK_ROOT}/lib/cmake/logos-cpp-sdk")
        find_package(logos-cpp-sdk REQUIRED CONFIG
            PATHS ${LOGOS_CPP_SDK_ROOT}/lib/cmake/logos-cpp-sdk
            NO_DEFAULT_PATH)
        target_link_libraries(${MODULE_NAME}_module_plugin PRIVATE logos-cpp-sdk::logos_headers)
    else()
        find_package(nlohmann_json REQUIRED)
        target_link_libraries(${MODULE_NAME}_module_plugin PRIVATE nlohmann_json::nlohmann_json)
    endif()

    # Handle external libraries
    foreach(ext_lib ${MODULE_EXTERNAL_LIBS})
        # Allow nix dev shell (or any caller) to point directly at a store path
        # by exporting LOGOS_EXT_ROOT_<NAME>=/nix/store/…, skipping the ./lib/ staging copy.
        # The expected format is a package root laid out as lib/+include/ (a Nix
        # derivation), unlike the ./lib/ fallback, which is one flat directory
        # holding both the library and its headers.
        string(TOUPPER "${ext_lib}" _ext_lib_upper)
        set(_ext_root_var "LOGOS_EXT_ROOT_${_ext_lib_upper}")
        if(DEFINED ENV{${_ext_root_var}})
            set(EXT_LIB_DIR "$ENV{${_ext_root_var}}/lib")
            set(EXT_INCLUDE_DIR "$ENV{${_ext_root_var}}/include")
        else()
            set(EXT_LIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/lib")
            set(EXT_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/lib")
        endif()

        # Find the library (prefer shared, fall back to static)
        if(APPLE)
            set(EXT_LIB_NAMES lib${ext_lib}.dylib lib${ext_lib}.so ${ext_lib}.dylib ${ext_lib}.so lib${ext_lib}.a ${ext_lib}.a)
        else()
            set(EXT_LIB_NAMES lib${ext_lib}.so lib${ext_lib}.dylib ${ext_lib}.so ${ext_lib}.dylib lib${ext_lib}.a ${ext_lib}.a)
        endif()

        find_library(${ext_lib}_PATH NAMES ${EXT_LIB_NAMES} PATHS ${EXT_LIB_DIR} NO_DEFAULT_PATH)

        if(${ext_lib}_PATH)
            target_link_libraries(${MODULE_NAME}_module_plugin PRIVATE ${${ext_lib}_PATH})
            target_include_directories(${MODULE_NAME}_module_plugin PRIVATE ${EXT_INCLUDE_DIR})

            # Copy shared libraries to output directory (static archives are linked in, no runtime copy needed)
            get_filename_component(EXT_LIB_FILENAME "${${ext_lib}_PATH}" NAME)
            if(NOT EXT_LIB_FILENAME MATCHES "\\.a$")
                add_custom_command(TARGET ${MODULE_NAME}_module_plugin PRE_LINK
                    COMMAND ${CMAKE_COMMAND} -E copy_if_different
                        ${${ext_lib}_PATH}
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
                if(APPLE)
                    target_link_libraries(${MODULE_NAME}_module_plugin PRIVATE
                        "-framework CoreFoundation" "-framework Security")
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

    message(STATUS "Logos module ${MODULE_NAME} configured successfully")
endfunction()
