# Tools directory CMake configuration

# WAV processor executable
add_executable(wav_processor
    wav_processor.cpp
)

target_link_libraries(wav_processor
    PRIVATE
        monivol_dsp
)

target_include_directories(wav_processor
    PRIVATE
        ${CMAKE_SOURCE_DIR}/include
)

# Install
install(TARGETS wav_processor
    RUNTIME DESTINATION bin
)
