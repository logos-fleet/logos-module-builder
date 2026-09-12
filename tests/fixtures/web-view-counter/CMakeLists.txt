cmake_minimum_required(VERSION 3.16)
project(WebCounterPlugin LANGUAGES CXX)

if(DEFINED ENV{LOGOS_MODULE_BUILDER_ROOT})
    include($ENV{LOGOS_MODULE_BUILDER_ROOT}/cmake/LogosModule.cmake)
else()
    message(FATAL_ERROR "LogosModule.cmake not found. Set LOGOS_MODULE_BUILDER_ROOT.")
endif()

logos_module(
    NAME web_counter
    REP_FILE src/web_counter.rep
    SOURCES
        src/web_counter_interface.h
        src/web_counter_plugin.h
        src/web_counter_plugin.cpp
        src/WebCounterBackend.h
        src/WebCounterBackend.cpp
)
