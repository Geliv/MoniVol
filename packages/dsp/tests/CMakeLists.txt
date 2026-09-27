cmake_minimum_required(VERSION 3.20)

# Enable testing
enable_testing()

# Test executable
add_executable(monivol_dsp_tests
    test_main.cpp
    test_biquad.cpp
    test_smoothing.cpp
    test_preset.cpp
    test_engine.cpp
    test_frequency_response.cpp
)

# Link against DSP library
target_link_libraries(monivol_dsp_tests PRIVATE monivol_dsp)

# Include test utilities
target_include_directories(monivol_dsp_tests PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)

# Compiler flags for tests
target_compile_options(monivol_dsp_tests PRIVATE
    -Wall -Wextra -Wpedantic
)

# Add test to CTest
add_test(NAME monivol_dsp_tests COMMAND monivol_dsp_tests)

# Set test properties
set_tests_properties(monivol_dsp_tests PROPERTIES
    TIMEOUT 60
    LABELS "unit"
)

message(STATUS "Test suite configured: monivol_dsp_tests")
