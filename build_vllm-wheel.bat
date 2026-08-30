@echo on

call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" x64

 set CUDA_ROOT=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.0
set DISTUTILS_USE_SDK=1
set VLLM_TARGET_DEVICE=cuda
REM (replace 10 with your desired cpu threads to use in parallel to speed up compilation)
set MAX_JOBS=10

REM Optional variables:

REM To include cuDSS (only if you have cuDSS installed)
set USE_CUDSS=1
set CUDSS_LIBRARY_PATH=C:\Program Files\NVIDIA cuDSS\v0.8\lib\13
set CUDSS_INCLUDE_PATH=C:\Program Files\NVIDIA cuDSS\v0.8\include

REM To include cuSPARSELt (only if you have cuSPARSELt installed)
set USE_CUSPARSELT=1
set CUSPARSELT_INCLUDE_PATH=C:\Program Files\NVIDIA cuSPARSELt\v0.9\include
set CUSPARSELT_LIBRARY_PATH=C:\Program Files\NVIDIA cuSPARSELt\v0.9\lib\13

REM To include cuDNN:
set USE_CUDNN=1
set CUDNN_LIBRARY_PATH=C:\Program Files\NVIDIA\CUDNN\v9.16\lib\13.0\x64
set CUDNN_INCLUDE_PATH=C:\Program Files\NVIDIA\CUDNN\v9.16\include\13.0

REM Flash Attention v3 build has been disabled inside WSL2 and Windows due to compiler being killed on WSL2, and extremely REM long compiling times on Windows. Hopper is not available on Windows, so FA3 has no sense anyway.
REM Build can be forcefully enabled using the following environment var:
REM DO NOT ENABLE: hopper/flash_api.cpp does not compile with MSVC (preprocessor
REM directives inside ARCH_SWITCH/PAGEDKV_SWITCH macro arguments -> C2059/C3878),
REM and FA3 is sm90-only, so it is dead code on this sm120 GPU anyway.
REM set VLLM_FORCE_FA3_WINDOWS_BUILD=1

REM Use a persistent local checkout of vllm-project/flash-attention instead of
REM letting FetchContent re-clone it (plus all submodules) on every attempt.
REM Populate it once with fetch_fa_cutlass.bat. Without this, a failed configure
REM makes CMake delete .deps\vllm-flash-attn-src and download ~220 MB again.
REM NOTE: forward slashes are required - CMake parses this value as a string and
REM chokes on backslashes ("Invalid character escape '\G'").
set VLLM_FLASH_ATTN_SRC_DIR=D:/Green/AI/code/vllm-flash-attn

REM Build DeepGEMM from the locally fixed Windows checkout instead of the
REM FetchContent tag (6714f34), whose JIT still resolves nvcc without .exe,
REM so runtime kernel compilation fails with exists(nvcc_path) assertion.
set DEEPGEMM_SRC_DIR=D:/Green/AI/code/DeepGEMM-windows

REM vLLM setup.py reads CMAKE_ARGS (not VLLM_CMAKE_ARGS) and appends it to its
REM cmake invocation. The explicit make-program override beats the stale
REM CMAKE_MAKE_PROGRAM cached in build/ from the old Python313 environment.
set CMAKE_ARGS=-DCMAKE_MAKE_PROGRAM=D:/Green/AI/ComfyUI-aki/python/Scripts/ninja.exe -DPython3_EXECUTABLE=D:/Green/AI/ComfyUI-aki/python/python.exe -DPython3_INCLUDE_DIR=D:/Green/AI/ComfyUI-aki/python/include -DPython3_LIBRARY=D:/Green/AI/ComfyUI-aki/python/libs/python313.lib



set Python3_ROOT_DIR=D:\Green\AI\ComfyUI-aki\python
set Python3_FIND_STRATEGY=LOCATION

"D:\Green\AI\ComfyUI-aki\python\python.exe" -m pip wheel . --no-build-isolation --no-deps -w dist -v


