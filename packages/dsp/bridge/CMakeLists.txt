# Bridge library CMake configuration
cmake_minimum_required(VERSION 3.20)

# Bridge library (ObjC++)
add_library(monivol_dsp_bridge
    MoniVolDSPEngine.mm
)

target_include_directories(monivol_dsp_bridge
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}
        ${CMAKE_SOURCE_DIR}/include
)

target_link_libraries(monivol_dsp_bridge
    PUBLIC
        monivol_dsp
)

# Enable Objective-C++ and ARC
set_target_properties(monivol_dsp_bridge PROPERTIES
    COMPILE_FLAGS "-x objective-c++ -fobjc-arc"
    LINKER_LANGUAGE CXX
)

# Link Foundation framework
target_link_libraries(monivol_dsp_bridge
    PUBLIC
        "-framework Foundation"
)

# Install headers
install(FILES
    MoniVolDSPEngine.h
    DESTINATION include/monivol/bridge
)

# Install library
install(TARGETS monivol_dsp_bridge
    LIBRARY DESTINATION lib
    ARCHIVE DESTINATION lib
)
