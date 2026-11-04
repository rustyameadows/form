# Built within the pinned standalone Cycles tree, independent of SwiftPM's C++ ABI.
set(LAB_CYCLES_LIBRARIES cycles_device cycles_kernel cycles_scene cycles_session
  cycles_bvh cycles_subd cycles_graph cycles_util extern_sky)
cycles_external_libraries_append(LAB_CYCLES_LIBRARIES)
add_executable(lab-cycles-render lab_cycles.mm)
set_source_files_properties(lab_cycles.mm PROPERTIES LANGUAGE CXX)
target_include_directories(lab-cycles-render PRIVATE "${PROJECT_SOURCE_DIR}/src")
get_directory_property(LAB_CYCLES_INCLUDES DIRECTORY "${PROJECT_SOURCE_DIR}/src" INCLUDE_DIRECTORIES)
target_include_directories(lab-cycles-render PRIVATE ${LAB_CYCLES_INCLUDES})
get_directory_property(LAB_CYCLES_DEFINITIONS DIRECTORY "${PROJECT_SOURCE_DIR}/src" COMPILE_DEFINITIONS)
target_compile_definitions(lab-cycles-render PRIVATE ${LAB_CYCLES_DEFINITIONS})
target_compile_options(lab-cycles-render PRIVATE -fobjc-arc)
set_property(TARGET lab-cycles-render PROPERTY CXX_STANDARD 20)
target_compile_definitions(lab-cycles-render PRIVATE
  LAB_CYCLES_COMMIT="3eb35f85996baa6c1b2e19bf297b22745c85e321")
target_link_libraries(lab-cycles-render PRIVATE ${LAB_CYCLES_LIBRARIES})
cycles_install_libraries(lab-cycles-render)
install(TARGETS lab-cycles-render DESTINATION .)
