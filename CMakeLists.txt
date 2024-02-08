cmake_minimum_required(VERSION 3.20)

include(pico_sdk_import.cmake)
project(picoatxt)

set(ZIG_OBJ_PATH "${CMAKE_CURRENT_LIST_DIR}/zig-out/out/picoatxt_zig.o")
set(DUMMY_SRC_PATH "${CMAKE_CURRENT_LIST_DIR}/src/cmake_dummy.c")
set(OTHER_SRC_PATH "${CMAKE_CURRENT_LIST_DIR}/src/usb_descriptors.c")

# Supress warnings about picoatxt_zig.o not existing.
# This is kind of a hack but it shouldn't(???) matter as the actual object file is generated
# along with the cmake dummy object file, so it will be present when linking.
# We also want to touch the dummy file so that zig build is ran on every make.
add_custom_target(fix_zig_obj_file
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_LIST_DIR}/zig-out/out"
    COMMAND ${CMAKE_COMMAND} -E touch "${ZIG_OBJ_PATH}"
    COMMAND ${CMAKE_COMMAND} -E touch_nocreate "${DUMMY_SRC_PATH}"
    BYPRODUCTS "${ZIG_OBJ_PATH}"
)

# Create zig_runner, if needed. This is executed on every make.
add_custom_target(zig_runner
    COMMAND zig build
    WORKING_DIRECTORY "${CMAKE_CURRENT_LIST_DIR}/util"
)

add_executable(picoatxt ${OTHER_SRC_PATH} ${DUMMY_SRC_PATH} ${ZIG_OBJ_PATH})
add_dependencies(picoatxt fix_zig_obj_file zig_runner)

pico_sdk_init()

# Link with pico libs
target_link_libraries(picoatxt pico_stdlib pico_bootrom tinyusb_device)
pico_enable_stdio_uart(picoatxt 0)
pico_enable_stdio_usb(picoatxt 0)

# Fix RP2040-E5 errata (takes up GPIO15)
target_compile_definitions(picoatxt PUBLIC PICO_RP2040_USB_DEVICE_ENUMERATION_FIX=1)

# Let TinyUSB find tusb_config.h
target_include_directories(picoatxt PUBLIC ${CMAKE_CURRENT_LIST_DIR}/src)

# Produce uf2 file
pico_add_extra_outputs(picoatxt)

# Here we're faced with a problem: we need to give our Zig code the full command line it would normally receive
# such that it knows about pre-included files, directories, definitions, etc.
# To fix this, we execute a dummy C file but subvert the compiler launcher
# to a script which forwards the args to our Zig build script.
# If the file is not recognized it just runs the compiler executable in-place.
# Note that it will still compile the dummy file as CMake will try to link with its object file.
# This works seamlessly as it is the command given to compile our cmake_dummy and thus
# CMake will wait for us to finish before linking; meaning we can generate the Zig object file and link with it.
set_target_properties(picoatxt
    PROPERTIES C_COMPILER_LAUNCHER "${CMAKE_CURRENT_LIST_DIR}/util/zig-out/bin/zig_runner"
)
