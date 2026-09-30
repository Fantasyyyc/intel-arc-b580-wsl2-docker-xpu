@echo off
echo === Building Intel Arc XPU image ===
docker build -t intel_arc_xpu:latest -f Dockerfile.xpu .

echo === Removing old container ===
docker rm -f intel_arc_xpu 2>nul

echo === Starting intel_arc_xpu container ===
docker run -d ^
  --name intel_arc_xpu ^
  --privileged ^
  --device=/dev/dxg ^
  -v /usr/lib/wsl:/usr/lib/wsl ^
  -v "%cd%:/workspace" ^
  intel_arc_xpu:latest ^
  tail -f /dev/null

echo.
echo [OK] Container intel_arc_xpu is running!
echo To test PyTorch XPU inside container, run:
echo docker exec -it intel_arc_xpu python3 /workspace/test_xpu.py
pause
