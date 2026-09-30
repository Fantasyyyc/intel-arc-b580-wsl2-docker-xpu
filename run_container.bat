@echo off
setlocal enabledelayedexpansion

set DEFAULT_DRV=/usr/lib/wsl/drivers/iigd_dch_d.inf_amd64_59943e79877d96f1
set INTEL_DRV=

echo === Resolving Intel WSL driver path dynamically ===
for /f "tokens=*" %%i in ('wsl.exe -e sh -c "find /usr/lib/wsl/drivers -name 'libwsl_compute_helper.so' -exec dirname {} \; 2>/dev/null | tail -n 1"') do set INTEL_DRV=%%i

if "%INTEL_DRV%"=="" (
    echo [WARN] Dynamic lookup returned empty, using fallback: %DEFAULT_DRV%
    set INTEL_DRV=%DEFAULT_DRV%
) else (
    echo Found active driver path: %INTEL_DRV%
)

echo === Building image ===
docker build -t intel_arc_xpu:latest -f Dockerfile.xpu .

echo === Removing old container ===
docker rm -f intel_arc_xpu 2>nul

echo === Starting intel_arc_xpu container ===
docker run -d ^
  --name intel_arc_xpu ^
  --privileged ^
  --device=/dev/dxg ^
  -v /usr/lib/wsl:/usr/lib/wsl ^
  -e LD_LIBRARY_PATH=/usr/lib/wsl/lib:%INTEL_DRV% ^
  -e ZES_ENABLE_SYSMAN=0 ^
  -v "%cd%:/workspace" ^
  intel_arc_xpu:latest ^
  tail -f /dev/null

echo.
if %ERRORLEVEL% equ 0 (
    echo [OK] Container intel_arc_xpu is running!
    echo To verify GPU acceleration, run:
    echo docker exec -it intel_arc_xpu python3 /workspace/test_xpu.py
) else (
    echo [ERROR] Container failed to start!
)
pause
