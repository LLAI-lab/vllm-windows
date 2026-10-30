include(FetchContent)

# If DEEPGEMM_SRC_DIR is set, DeepGEMM is built from that directory
# instead of downloading.
# It can be set as an environment variable or passed as a cmake argument.
# The environment variable takes precedence.
if (DEFINED ENV{DEEPGEMM_SRC_DIR})
  set(DEEPGEMM_SRC_DIR $ENV{DEEPGEMM_SRC_DIR})
endif()

# Local tree: set deepgemm_SOURCE_DIR directly (no FetchContent download).
# Upstream git: use FetchContent_Populate with explicit options (CMP0169 NEW
# disallows one-argument Populate(dep) after Declare; MakeAvailable would run
# DeepGEMM's top-level CMakeLists.txt, which vLLM must not load).
if(DEEPGEMM_SRC_DIR)
  # cmake_path(ABSOLUTE_PATH <var> ...) reads the path from <var>; NORMALIZE is a
  # flag (no trailing path argument). Resolve relative paths against vLLM root.
  set(_deepgemm_user_src "${DEEPGEMM_SRC_DIR}")
  cmake_path(ABSOLUTE_PATH _deepgemm_user_src
    BASE_DIRECTORY "${CMAKE_SOURCE_DIR}"
    NORMALIZE)
  set(DEEPGEMM_SRC_DIR "${_deepgemm_user_src}")
  if(NOT IS_DIRECTORY "${DEEPGEMM_SRC_DIR}")
    message(FATAL_ERROR
      "DEEPGEMM_SRC_DIR is not an existing directory: '${DEEPGEMM_SRC_DIR}'")
  endif()
  set(deepgemm_SOURCE_DIR "${DEEPGEMM_SRC_DIR}")
  message(STATUS "DeepGEMM using local DEEPGEMM_SRC_DIR: ${deepgemm_SOURCE_DIR}")
else()
  # Keep in sync with tools/install_deepgemm.sh
  if(WIN32)
    set(_DEEPGEMM_UPSTREAM_REPO "https://github.com/SystemPanic/DeepGEMM-windows.git")
    set(_DEEPGEMM_UPSTREAM_TAG "6714f340520959297d9248f181c027f6cfea5a44")
  else()
    set(_DEEPGEMM_UPSTREAM_REPO "https://github.com/vllm-project/DeepGEMM.git")
    # Pinned to the fork's dev branch: upstream's 26/09/30 release (2.8.1)
    # plus the SM120 port, the SM90 paged-MQA kv_block=32/next_n=4 port,
    # configurable SwiGLU alpha/beta, SiTU for FP8/FP4 Mega MoE, and NVFP4
    # Mega MoE, plus swiglustep for BF16/FP8/NVFP4 Mega MoE and F8_128x4
    # SFs for the FP8 einsum output (vllm-project/DeepGEMM#40), plus
    # fp4_fp4_mega_moe and fused post-expert RMSNorm for Muse Spark Open
    # (vllm-project/DeepGEMM#39), and the MX MegaMoE alignment fix
    # (vllm-project/DeepGEMM#43).
    # Uses the PyTorch 2.11 stable ABI and CPython 3.10 limited API.
    set(_DEEPGEMM_UPSTREAM_TAG "5cdb145704ec4672ecf4b61441599521ce635df6")
  endif()

  set(_deepgemm_fc_root "${FETCHCONTENT_BASE_DIR}")
  if(NOT _deepgemm_fc_root)
    set(_deepgemm_fc_root "${CMAKE_BINARY_DIR}/_deps")
  endif()
  set(_deepgemm_src "${_deepgemm_fc_root}/deepgemm-src")
  set(_deepgemm_bin "${_deepgemm_fc_root}/deepgemm-build")
  set(_deepgemm_sub "${_deepgemm_fc_root}/deepgemm-subbuild")

  # Layout marker + submodules differ per source:
  #  - WIN32 (SystemPanic/DeepGEMM-windows): legacy PYBIND11_MODULE layout
  #    (csrc/python_api.cpp, cutlass + fmt submodules).
  #  - elsewhere (vllm-project/DeepGEMM): TORCH_LIBRARY layout
  #    (deep_gemm/_C.py, cutlass + deep_jit submodules).
  if(WIN32)
    set(_dg_layout_marker "csrc/python_api.cpp")
    set(_dg_submodules "third-party/cutlass" "third-party/fmt")
  else()
    set(_dg_layout_marker "deep_gemm/_C.py")
    set(_dg_submodules "third-party/cutlass" "third-party/deep_jit")
  endif()

  if(EXISTS "${_deepgemm_src}/${_dg_layout_marker}")
    set(deepgemm_SOURCE_DIR "${_deepgemm_src}")
    set(deepgemm_BINARY_DIR "${_deepgemm_bin}")
  else()
    FetchContent_Populate(
      deepgemm
      SUBBUILD_DIR "${_deepgemm_sub}"
      SOURCE_DIR "${_deepgemm_src}"
      BINARY_DIR "${_deepgemm_bin}"
      GIT_REPOSITORY "${_DEEPGEMM_UPSTREAM_REPO}"
      GIT_TAG "${_DEEPGEMM_UPSTREAM_TAG}"
      GIT_SUBMODULES ${_dg_submodules}
      GIT_PROGRESS TRUE
    )
  endif()
  message(STATUS "DeepGEMM is available at ${deepgemm_SOURCE_DIR}")
endif()

# DeepGEMM requires CUDA 12.3+ for SM90, 12.9+ for SM100 (official upstream),
# and 12.8+ for SM120 / SM12x. CUDA 13+ can use the family-specific SM12x
# arch; CUDA 12.x builds the arch-specific SM120/SM121 variants.
set(DEEPGEMM_SUPPORT_ARCHS)
if(${CMAKE_CUDA_COMPILER_VERSION} VERSION_GREATER_EQUAL 12.3)
  list(APPEND DEEPGEMM_SUPPORT_ARCHS "9.0a")
endif()
if(${CMAKE_CUDA_COMPILER_VERSION} VERSION_GREATER_EQUAL 12.8)
  if(${CMAKE_CUDA_COMPILER_VERSION} VERSION_GREATER_EQUAL 12.9)
    list(APPEND DEEPGEMM_SUPPORT_ARCHS "10.0f")
    if(${CMAKE_CUDA_COMPILER_VERSION} VERSION_GREATER_EQUAL 13.4)
      list(APPEND DEEPGEMM_SUPPORT_ARCHS "10.7f")
    endif()
  else()
    list(APPEND DEEPGEMM_SUPPORT_ARCHS "10.0a")
  endif()
  if(${CMAKE_CUDA_COMPILER_VERSION} VERSION_GREATER_EQUAL 13.0)
    list(APPEND DEEPGEMM_SUPPORT_ARCHS "12.0f")
  else()
    list(APPEND DEEPGEMM_SUPPORT_ARCHS "12.0a" "12.1a")
  endif()
endif()

cuda_archs_loose_intersection(DEEPGEMM_ARCHS
  "${DEEPGEMM_SUPPORT_ARCHS}" "${CUDA_ARCHS}")

if(DEEPGEMM_ARCHS)
  message(STATUS "DeepGEMM CUDA architectures: ${DEEPGEMM_ARCHS}")

  #
  # DeepGEMM integration notes
  # --------------------------
  # We vendor DeepGEMM into vllm/third_party/deep_gemm/ and bundle:
  #   - WIN32: a `_C.<EXT_SUFFIX>` extension for every target CPython
  #     (PYBIND11_MODULE links private CPython symbols, so a single abi3
  #     `_C` is not viable; see #41476 / #41512). Built directly with
  #     cl.exe via tools/build_deepgemm_C.py.
  #   - elsewhere: deep_gemm/_C.py (Python shim over torch.ops.deep_gemm)
  #     plus deep_gemm/_C_extension.abi3.so (single limited-API extension).
  #     The build is delegated to tools/build_deepgemm_C.py
  #     (setup.py build_ext).
  #
  # TODO: AOT-compile DeepGEMM's CUDA kernels instead of runtime JIT to drop
  # the vendored CUTLASS/CCCL headers and the CUDA-toolkit-at-runtime
  # requirement.
  #

  # DEEPGEMM_PYTHON_INTERPRETERS: ":"-separated target Python paths.
  # Empty/unset → fall back to the build interpreter (editable installs).
  # (Empty-but-set env vars test as DEFINED in cmake — treat as unset.)
  if(NOT "$ENV{DEEPGEMM_PYTHON_INTERPRETERS}" STREQUAL "")
    string(REPLACE ":" ";" _dg_pythons "$ENV{DEEPGEMM_PYTHON_INTERPRETERS}")
  else()
    set(_dg_pythons "${Python_EXECUTABLE}")
  endif()
  if(WIN32)
    message(STATUS "DeepGEMM _C will be built for: ${_dg_pythons}")
  else()
    message(STATUS "DeepGEMM extension will be built with: ${Python_EXECUTABLE}")
  endif()

  # add_custom_command does no implicit header scanning; glob explicitly so
  # header-only edits in DeepGEMM/cutlass/deep_jit re-trigger the rebuild.
  file(GLOB_RECURSE _dg_headers
    "${deepgemm_SOURCE_DIR}/csrc/*.h"
    "${deepgemm_SOURCE_DIR}/csrc/*.hpp"
    "${deepgemm_SOURCE_DIR}/deep_gemm/include/*.h"
    "${deepgemm_SOURCE_DIR}/deep_gemm/include/*.hpp"
    "${deepgemm_SOURCE_DIR}/deep_gemm/include/*.cuh"
    "${deepgemm_SOURCE_DIR}/third-party/deep_jit/include/*.h"
    "${deepgemm_SOURCE_DIR}/third-party/deep_jit/include/*.hpp")

  if(WIN32)
    set(_dg_markers)
    set(_dg_seen_soabis)
    foreach(_pybin IN LISTS _dg_pythons)
      execute_process(
        COMMAND "${_pybin}" -c
          "import sysconfig; s = sysconfig.get_config_var('SOABI'); s = s if s and s != 'None' else sysconfig.get_config_var('EXT_SUFFIX').lstrip('.').rsplit('.',1)[0]; print(s)"
        OUTPUT_VARIABLE _dg_soabi
        OUTPUT_STRIP_TRAILING_WHITESPACE
        COMMAND_ERROR_IS_FATAL ANY)
      # Dedup interpreters that resolve to the same CPython.
      if(_dg_soabi IN_LIST _dg_seen_soabis)
        continue()
      endif()
      list(APPEND _dg_seen_soabis "${_dg_soabi}")
      set(_dg_dir "${CMAKE_CURRENT_BINARY_DIR}/deepgemm_C_${_dg_soabi}")
      set(_dg_marker "${_dg_dir}/.built")
      add_custom_command(
        OUTPUT "${_dg_marker}"
        COMMAND "${Python_EXECUTABLE}"
                "${CMAKE_SOURCE_DIR}/tools/build_deepgemm_C.py"
                "${deepgemm_SOURCE_DIR}" "${_dg_dir}" "${_pybin}"
        COMMAND "${CMAKE_COMMAND}" -E touch "${_dg_marker}"
        DEPENDS "${CMAKE_SOURCE_DIR}/tools/build_deepgemm_C.py"
                "${deepgemm_SOURCE_DIR}/csrc/python_api.cpp"
                ${_dg_headers}
        COMMENT "Building DeepGEMM _C for ${_pybin}"
        VERBATIM)
      list(APPEND _dg_markers "${_dg_marker}")
      install(DIRECTORY "${_dg_dir}/"
        DESTINATION vllm/third_party/deep_gemm
        COMPONENT _deep_gemm_C
        FILES_MATCHING
          PATTERN "_C.cpython-*.so"
          PATTERN "_C*.pyd")
    endforeach()
    add_custom_target(_deep_gemm_C ALL DEPENDS ${_dg_markers})
  else()
    set(_dg_dir "${CMAKE_CURRENT_BINARY_DIR}/deepgemm_C")
    set(_dg_marker "${_dg_dir}/.built")
    add_custom_command(
      OUTPUT "${_dg_marker}"
      COMMAND "${Python_EXECUTABLE}"
              "${CMAKE_SOURCE_DIR}/tools/build_deepgemm_C.py"
              "${deepgemm_SOURCE_DIR}" "${_dg_dir}"
      COMMAND "${CMAKE_COMMAND}" -E touch "${_dg_marker}"
      DEPENDS "${CMAKE_SOURCE_DIR}/tools/build_deepgemm_C.py"
              "${deepgemm_SOURCE_DIR}/csrc/python_api.cpp"
              "${deepgemm_SOURCE_DIR}/deep_gemm/_C.py"
              "${deepgemm_SOURCE_DIR}/setup.py"
              ${_dg_headers}
      COMMENT "Building DeepGEMM _C_extension (abi3)"
      VERBATIM)
    add_custom_target(_deep_gemm_C ALL DEPENDS "${_dg_marker}")

    install(DIRECTORY "${_dg_dir}/"
      DESTINATION vllm/third_party/deep_gemm
      COMPONENT _deep_gemm_C
      FILES_MATCHING
        PATTERN "_C.py"
        PATTERN "_C_extension*.so")
  endif()

  #
  # Vendor DeepGEMM Python package files
  #
  install(FILES
    "${deepgemm_SOURCE_DIR}/deep_gemm/__init__.py"
    DESTINATION vllm/third_party/deep_gemm
    COMPONENT _deep_gemm_C)
  # locality_domain.py exists only in the TORCH_LIBRARY layout source.
  if(EXISTS "${deepgemm_SOURCE_DIR}/deep_gemm/locality_domain.py")
    install(FILES
      "${deepgemm_SOURCE_DIR}/deep_gemm/locality_domain.py"
      DESTINATION vllm/third_party/deep_gemm
      COMPONENT _deep_gemm_C)
  endif()

  install(DIRECTORY "${deepgemm_SOURCE_DIR}/deep_gemm/utils/"
    DESTINATION vllm/third_party/deep_gemm/utils
    COMPONENT _deep_gemm_C
    FILES_MATCHING PATTERN "*.py")

  install(DIRECTORY "${deepgemm_SOURCE_DIR}/deep_gemm/testing/"
    DESTINATION vllm/third_party/deep_gemm/testing
    COMPONENT _deep_gemm_C
    FILES_MATCHING PATTERN "*.py")

  install(DIRECTORY "${deepgemm_SOURCE_DIR}/deep_gemm/legacy/"
    DESTINATION vllm/third_party/deep_gemm/legacy
    COMPONENT _deep_gemm_C
    FILES_MATCHING PATTERN "*.py")

  install(DIRECTORY "${deepgemm_SOURCE_DIR}/deep_gemm/mega/"
    DESTINATION vllm/third_party/deep_gemm/mega
    COMPONENT _deep_gemm_C
    FILES_MATCHING PATTERN "*.py")

  # Generate envs.py (normally generated by DeepGEMM's setup.py build step)
  file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/deep_gemm_envs.py"
    "# Pre-installed environment variables\npersistent_envs = dict()\n")
  install(FILES "${CMAKE_CURRENT_BINARY_DIR}/deep_gemm_envs.py"
    DESTINATION vllm/third_party/deep_gemm
    RENAME envs.py
    COMPONENT _deep_gemm_C)

  #
  # Install include files needed for JIT compilation at runtime.
  # The JIT compiler finds these relative to the package directory.
  #

  # DeepGEMM's own CUDA headers
  install(DIRECTORY "${deepgemm_SOURCE_DIR}/deep_gemm/include/"
    DESTINATION vllm/third_party/deep_gemm/include
    COMPONENT _deep_gemm_C)

  # CUTLASS and CuTe headers (vendored for JIT, separate from vLLM's CUTLASS)
  install(DIRECTORY "${deepgemm_SOURCE_DIR}/third-party/cutlass/include/"
    DESTINATION vllm/third_party/deep_gemm/include
    COMPONENT _deep_gemm_C)

else()
  message(STATUS "DeepGEMM will not compile: "
    "unsupported CUDA architecture ${CUDA_ARCHS}")
  # Create empty target so setup.py doesn't fail on unsupported systems
  add_custom_target(_deep_gemm_C)
endif()
