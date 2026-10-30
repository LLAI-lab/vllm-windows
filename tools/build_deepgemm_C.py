# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright contributors to the vLLM project
"""Build DeepGEMM's `_C` extension for the vendored package.

Driven from cmake/external_projects/deepgemm.cmake.

- WIN32 (SystemPanic/DeepGEMM-windows, legacy PYBIND11_MODULE layout):
  compiles csrc/python_api.cpp directly with cl.exe for <TARGET_PY>.
  Usage: python build_deepgemm_C.py <SRC> <OUT> <TARGET_PY>
- elsewhere (vllm-project/DeepGEMM, TORCH_LIBRARY layout): delegates to
  DeepGEMM's ``setup.py build_ext --inplace`` and copies the shim plus
  the abi3 extension into the output directory.
  Usage: python build_deepgemm_C.py <DEEPGEMM_SRC_DIR> <OUTPUT_DIR>
"""

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

IS_WINDOWS = sys.platform == "win32"

if IS_WINDOWS:
    import torch
    from torch.utils import cpp_extension

    if len(sys.argv) != 4:
        sys.exit(f"usage: {sys.argv[0]} <SRC> <OUT> <TARGET_PY>")

    src = Path(sys.argv[1]).resolve()
    out = Path(sys.argv[2]).resolve()
    target_py = sys.argv[3]
    out.mkdir(parents=True, exist_ok=True)

    info = json.loads(
        subprocess.check_output(
            [
                target_py,
                "-c",
                "import sysconfig, json; "
                "print(json.dumps({k: sysconfig.get_config_var(k) "
                "for k in ('EXT_SUFFIX', 'INCLUDEPY')}))",
            ]
        ).decode()
    )

    cuda_home = cpp_extension.CUDA_HOME
    if cuda_home is None:
        sys.exit("CUDA_HOME not found; cannot build DeepGEMM _C")
    # CCCL lives outside the standard CUDAToolkit search (mirrors DeepGEMM's setup.py).
    includes = [
        info["INCLUDEPY"],
        f"{cuda_home}/include",
        f"{cuda_home}/include/cccl",
        str(src / "csrc"),
        str(src / "deep_gemm/include"),
        str(src / "third-party/cutlass/include"),
        str(src / "third-party/cutlass/tools/util/include"),
        str(src / "third-party/fmt/include"),
        *cpp_extension.include_paths(device_type="cuda"),
    ]

    cmd = [
        os.environ.get("CXX", "cl.exe"),
        "/nologo",
        "/MD",
        "/EHsc",
        "/O2",
        "/std:c++20",
        "/bigobj",
        "/DTORCH_API_INCLUDE_EXTENSION_H",
        "/DTORCH_EXTENSION_NAME=_C",
        "/DNOMINMAX",
        "/DWIN32_LEAN_AND_MEAN",
        "/D_CRT_SECURE_NO_WARNINGS",
        "/utf-8",
        "/Zc:preprocessor",
        *(f"/I{p}" for p in includes),
        str(src / "csrc/python_api.cpp"),
        "/LD",
        f"/Fe:{str(out / f'_C{info["EXT_SUFFIX"]}')}",
        f"/Fo:{out}{os.sep}",
        "/link",
        *(f"/LIBPATH:{p}" for p in cpp_extension.library_paths(device_type="cuda")),
        f"/LIBPATH:{str(Path(sys.base_prefix) / 'libs')}",
        f"torch.lib",
        f"torch_python.lib",
        f"torch_cpu.lib",
        f"torch_cuda.lib",
        f"c10.lib",
        f"c10_cuda.lib",
        f"cudart.lib",
        f"nvrtc.lib",
        f"cublas.lib",
        f"cublasLt.lib"
    ]
    print("[build_deepgemm_C] " + " ".join(cmd), flush=True)
    subprocess.check_call(cmd)
else:
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} <SRC> <OUT>")

    src = Path(sys.argv[1]).resolve()
    out = Path(sys.argv[2]).resolve()
    _pkg = src / "deep_gemm"
    out.mkdir(parents=True, exist_ok=True)

    if not (_pkg / "_C.py").is_file():
        sys.exit(
            f"DeepGEMM source at {src} is missing deep_gemm/_C.py; "
            "expected TORCH_LIBRARY migration layout"
        )

    # Avoid DeepGEMM's clean-git assertion when vendoring a local dirty tree.
    env = os.environ.copy()
    env.pop("DG_SKIP_CUDA_BUILD", None)

    print(f"[build_deepgemm_C] building in {src} with {sys.executable}", flush=True)
    # CMake decides when to rebuild; setuptools would only check python_api.cpp.
    subprocess.check_call(
        [sys.executable, "setup.py", "build_ext", "--inplace", "--force"],
        cwd=src,
        env=env,
    )

    shim = _pkg / "_C.py"
    shutil.copy2(shim, out / shim.name)

    so = _pkg / "_C_extension.abi3.so"
    if not so.is_file():
        sys.exit(f"DeepGEMM build did not produce {so}")
    for stale in out.glob("_C_extension*.so"):
        stale.unlink()
    shutil.copy2(so, out / so.name)
    print(f"[build_deepgemm_C] installed {so.name} -> {out}", flush=True)
