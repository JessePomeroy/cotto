# Configure only: no build, installation, service activation, or application launch.
foreach(required COTTO_SOURCE COTTO_TEST_ROOT COTTO_TEST_GENERATOR)
    if(NOT DEFINED ${required} OR "${${required}}" STREQUAL "")
        message(FATAL_ERROR "Missing ${required}")
    endif()
endforeach()

foreach(case unset empty relative custom override)
    set(directory "${COTTO_TEST_ROOT}/${case}")
    set(expected "${COTTO_TEST_ROOT}/home/.config")
    set(environment)
    set(options)
    if(case STREQUAL "empty")
        set(environment "XDG_CONFIG_HOME=")
    elseif(case STREQUAL "relative")
        set(environment "XDG_CONFIG_HOME=relative-profile")
    elseif(case STREQUAL "custom" OR case STREQUAL "override")
        set(expected "${COTTO_TEST_ROOT}/custom profile")
        set(environment "XDG_CONFIG_HOME=${expected}")
    endif()
    if(case STREQUAL "override")
        set(expected "${COTTO_TEST_ROOT}/explicit profile")
        set(options "-DCOTTO_QT_CONFIG_HOME=${expected}")
    endif()

    # Remove only this test's generated configure cache, so defaults are re-evaluated.
    file(REMOVE_RECURSE "${directory}")
    execute_process(
        COMMAND "${CMAKE_COMMAND}" -E env --unset=XDG_CONFIG_HOME
            "HOME=${COTTO_TEST_ROOT}/home" ${environment}
            "${CMAKE_COMMAND}" -S "${COTTO_SOURCE}" -B "${directory}"
            -G "${COTTO_TEST_GENERATOR}" -DBUILD_TESTING=OFF ${options}
        RESULT_VARIABLE result OUTPUT_VARIABLE output ERROR_VARIABLE errors)
    if(NOT result EQUAL 0)
        message(FATAL_ERROR "${case} configuration failed: ${output}\n${errors}")
    endif()
    file(READ "${directory}/cotto.service" service)
    string(FIND "${service}" "Environment=\"XDG_CONFIG_HOME=${expected}\"" match)
    if(match EQUAL -1)
        message(FATAL_ERROR "${case}: service did not preserve expected profile ${expected}")
    endif()
endforeach()
message(STATUS "Startup profiles: unset, empty, relative, custom, and explicit override passed")
