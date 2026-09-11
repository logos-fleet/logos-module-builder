cmake_minimum_required(VERSION 3.16)
project(ViewCounterPlugin LANGUAGES CXX)

if(DEFINED ENV{LOGOS_MODULE_BUILDER_ROOT})
    include($ENV{LOGOS_MODULE_BUILDER_ROOT}/cmake/LogosModule.cmake)
else()
    message(FATAL_ERROR "LogosModule.cmake not found. Set LOGOS_MODULE_BUILDER_ROOT.")
endif()

logos_module(
    NAME view_counter
    REP_FILE src/view_counter.rep
    SOURCES
        src/view_counter_interface.h
        src/view_counter_plugin.h
        src/view_counter_plugin.cpp
)
