cmake_minimum_required(VERSION 3.24)
project(SottoLinux VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(Qt6 6.8 REQUIRED COMPONENTS Core Gui Quick QuickControls2 Multimedia Network DBus Widgets)
qt_standard_project_setup(REQUIRES 6.8)
find_package(PkgConfig REQUIRED)
pkg_check_modules(Samplerate REQUIRED IMPORTED_TARGET samplerate>=0.2.2)

add_library(sotto-linux-core STATIC
    src/PcmMeter.cpp src/PcmMeter.h
    src/AudioConverter.cpp src/AudioConverter.h
    src/GenerationClient.cpp src/GenerationClient.h
    src/DictationController.cpp src/DictationController.h
    src/TranscriptValidation.h
    src/PersonalDictionary.cpp src/PersonalDictionary.h
    src/RecordingStatus.cpp src/RecordingStatus.h
    src/PiDictationBridge.cpp src/PiDictationBridge.h
    src/DesktopShortcuts.cpp src/DesktopShortcuts.h
    src/DesktopPaste.cpp src/DesktopPaste.h
    src/CaptureController.cpp src/CaptureController.h
    src/ServerStatus.cpp src/ServerStatus.h
)
target_link_libraries(sotto-linux-core PUBLIC Qt6::Core Qt6::Gui Qt6::Multimedia Qt6::Network Qt6::DBus PkgConfig::Samplerate)
target_include_directories(sotto-linux-core PUBLIC src)
target_compile_options(sotto-linux-core PRIVATE -Wall -Wextra -Wpedantic)

add_library(sotto-desktop-tray STATIC src/TrayController.cpp src/TrayController.h)
target_include_directories(sotto-desktop-tray PUBLIC src)
target_link_libraries(sotto-desktop-tray PUBLIC Qt6::Widgets Qt6::DBus)
target_compile_options(sotto-desktop-tray PRIVATE -Wall -Wextra -Wpedantic)

qt_add_executable(sotto-linux src/main.cpp)
qt_add_qml_module(sotto-linux
    URI SottoLinux
    VERSION 1.0
    QML_FILES qml/Main.qml
)
target_link_libraries(sotto-linux PRIVATE sotto-linux-core sotto-desktop-tray Qt6::Quick Qt6::QuickControls2)
target_compile_options(sotto-linux PRIVATE -Wall -Wextra -Wpedantic)
configure_file(resources/org.sotto.Sotto.Dev.desktop.in org.sotto.Sotto.Dev.desktop @ONLY)

# Installing this component never enables startup.
include(cmake/Startup.cmake)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/cotto.service" "${CMAKE_CURRENT_BINARY_DIR}/cotto-inference.service"
    DESTINATION share/systemd/user COMPONENT cotto-startup)
install(FILES resources/cotto-managed.desktop DESTINATION share/applications
    RENAME org.sotto.Sotto.Dev.desktop COMPONENT cotto-startup)

include(CTest)
if(BUILD_TESTING)
    add_test(NAME sotto-startup-config COMMAND ${CMAKE_COMMAND}
        "-DCOTTO_SOURCE=${CMAKE_CURRENT_SOURCE_DIR}"
        "-DCOTTO_TEST_ROOT=${CMAKE_CURRENT_BINARY_DIR}/startup-config-tests"
        -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/StartupTests.cmake)
    set_tests_properties(sotto-startup-config PROPERTIES TIMEOUT 120)
    find_package(Qt6 REQUIRED COMPONENTS Test QuickTest)
    qt_add_executable(sotto-settings-tests tests/SettingsTests.cpp)
    target_link_libraries(sotto-settings-tests PRIVATE Qt6::QuickTest Qt6::QuickControls2)
    target_compile_definitions(sotto-settings-tests PRIVATE QUICK_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/qml")
    add_test(NAME sotto-settings-ui COMMAND ${CMAKE_COMMAND} -E env QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software $<TARGET_FILE:sotto-settings-tests>)
    qt_add_executable(sotto-recording-status-tests tests/RecordingStatusTests.cpp)
    target_link_libraries(sotto-recording-status-tests PRIVATE sotto-linux-core Qt6::Test)
    add_test(NAME sotto-recording-status COMMAND sotto-recording-status-tests)
    qt_add_executable(sotto-dictionary-tests tests/DictionaryTests.cpp)
    target_link_libraries(sotto-dictionary-tests PRIVATE sotto-linux-core Qt6::Test)
    add_test(NAME sotto-personal-dictionary COMMAND sotto-dictionary-tests)
    qt_add_executable(sotto-linux-tests tests/CoreTests.cpp)
    target_link_libraries(sotto-linux-tests PRIVATE sotto-linux-core Qt6::Test)
    add_test(NAME sotto-linux-core COMMAND sotto-linux-tests)
    qt_add_executable(sotto-generation-tests tests/GenerationTests.cpp)
    target_link_libraries(sotto-generation-tests PRIVATE sotto-linux-core Qt6::Test)
    add_test(NAME sotto-generation-protocol COMMAND sotto-generation-tests)
    qt_add_executable(sotto-pi-bridge-tests tests/PiBridgeTests.cpp)
    target_link_libraries(sotto-pi-bridge-tests PRIVATE sotto-linux-core Qt6::Test)
    add_test(NAME sotto-pi-bridge COMMAND sotto-pi-bridge-tests)
    find_program(BUN_EXECUTABLE NAMES bun
        HINTS "${CMAKE_CURRENT_SOURCE_DIR}/../.local/tools/bun-linux-x64")
    if(BUN_EXECUTABLE)
        add_test(NAME sotto-pi-dictation COMMAND ${BUN_EXECUTABLE} test
            ${CMAKE_CURRENT_SOURCE_DIR}/tests/PiDictationTests.test.ts
            ${CMAKE_CURRENT_SOURCE_DIR}/tests/PiPreferencesTests.test.ts
            ${CMAKE_CURRENT_SOURCE_DIR}/tests/PiQuestionTests.test.ts
            ${CMAKE_CURRENT_SOURCE_DIR}/tests/RecordingStatusTests.test.ts)
        set_tests_properties(sotto-pi-dictation PROPERTIES TIMEOUT 60)
    else()
        message(WARNING "Isolated Pi dictation tests unavailable: install the repository's Bun version.")
    endif()
    qt_add_executable(sotto-live-inference-tests tests/LiveInferenceTests.cpp)
    target_link_libraries(sotto-live-inference-tests PRIVATE sotto-linux-core Qt6::Test)
    add_test(NAME sotto-live-inference COMMAND sotto-live-inference-tests)
    find_program(DBUS_RUN_SESSION dbus-run-session REQUIRED)
    qt_add_executable(sotto-tray-tests tests/TrayTests.cpp)
    target_link_libraries(sotto-tray-tests PRIVATE sotto-desktop-tray Qt6::Test)
    add_test(NAME sotto-desktop-tray COMMAND ${DBUS_RUN_SESSION} --config-file=${CMAKE_CURRENT_SOURCE_DIR}/tests/private-bus.conf -- ${CMAKE_COMMAND} -E env
        QT_QPA_PLATFORM=offscreen SOTTO_TEST_PRIVATE_BUS=1 $<TARGET_FILE:sotto-tray-tests>)
    qt_add_executable(sotto-paste-tests tests/DesktopPasteTests.cpp)
    target_link_libraries(sotto-paste-tests PRIVATE sotto-linux-core Qt6::Test)
    add_test(NAME sotto-desktop-paste COMMAND ${DBUS_RUN_SESSION} --config-file=${CMAKE_CURRENT_SOURCE_DIR}/tests/private-bus.conf -- ${CMAKE_COMMAND} -E env
        QT_QPA_PLATFORM=offscreen SOTTO_TEST_PRIVATE_BUS=1 $<TARGET_FILE:sotto-paste-tests>)
    qt_add_executable(sotto-shortcut-tests tests/ShortcutTests.cpp)
    target_link_libraries(sotto-shortcut-tests PRIVATE sotto-linux-core Qt6::Test)
    add_test(NAME sotto-desktop-shortcuts COMMAND ${DBUS_RUN_SESSION} --config-file=${CMAKE_CURRENT_SOURCE_DIR}/tests/private-bus.conf -- ${CMAKE_COMMAND} -E env
        SOTTO_TEST_PRIVATE_BUS=1 $<TARGET_FILE:sotto-shortcut-tests>)
endif()
