@echo off
REM ---------------------------------------------------------------------------
REM Fetch ONLY the cutlass submodule needed by vllm-flash-attn (CUDA build).
REM The ROCm submodules (composable_kernel, aiter) are not used on Windows/CUDA
REM and are deliberately skipped.
REM
REM Uses a depth-1 fetch of the exact pinned commit (a few hundred MB instead of
REM cutlass' full history) and retries, with TLS settings that survive the
REM "schannel: failed to receive handshake" / "server closed abruptly" errors.
REM ---------------------------------------------------------------------------
setlocal EnableDelayedExpansion

set "FA=D:\Green\AI\code\vllm-flash-attn"
set "SHA=62750a2b75c802660e4894434dc55e839f322277"
set "REPO=https://github.com/NVIDIA/cutlass.git"

REM If GitHub keeps dropping the connection, uncomment ONE mirror line below:
REM set "REPO=https://gh-proxy.com/https://github.com/NVIDIA/cutlass.git"
REM set "REPO=https://ghfast.top/https://github.com/NVIDIA/cutlass.git"

REM Hardened transport options, applied per-command (no global git config change)
set "GITOPT=-c http.sslBackend=openssl -c http.version=HTTP/1.1 -c http.postBuffer=524288000 -c core.compression=0 -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=120"

if not exist "%FA%\csrc\cutlass" mkdir "%FA%\csrc\cutlass"
if not exist "%FA%\csrc\cutlass\.git" (
  git init -q "%FA%\csrc\cutlass" || goto :err
  git -C "%FA%\csrc\cutlass" remote add origin "%REPO%" || goto :err
)
git -C "%FA%\csrc\cutlass" remote set-url origin "%REPO%"

set /a N=0
:retry
set /a N+=1
echo.
echo === cutlass fetch attempt !N! from %REPO% ===
git %GITOPT% -C "%FA%\csrc\cutlass" fetch --depth 1 --progress origin %SHA%
if not errorlevel 1 goto :ok
if !N! GEQ 8 goto :err
echo Fetch failed, retrying in 5s ...
timeout /t 5 /nobreak >nul
goto :retry

:ok
git -C "%FA%\csrc\cutlass" checkout --force --detach FETCH_HEAD || goto :err
if not exist "%FA%\csrc\cutlass\include\cutlass\cutlass.h" goto :err
echo.
echo OK: cutlass checked out at %SHA%
git -C "%FA%\csrc\cutlass" log -1 --oneline
endlocal
exit /b 0

:err
echo.
echo FAILED to fetch cutlass. Try a mirror (see the commented lines near the
echo top of this script) or a VPN/proxy, then run this script again.
endlocal
exit /b 1
