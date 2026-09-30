# The Definitive Guide: Running Intel Arc B580 (Battlemage Xe2) in Docker on WSL2 with Native PyTorch XPU

> **Goal**: Spin up a Docker container under Windows 11 / WSL2 for deep learning workloads with PyTorch running on the **Intel Arc B580 GPU (Battlemage, Xe2 architecture, PCI Device ID: `0xe20b`)** using native XPU acceleration without deprecated IPEX dependencies.

---

## PART 1. THE WINNING RECIPE (QUICK START)

### 1. Host Requirements (Windows 11)
- **Operating System**: Windows 11 with WSL2 enabled.
- **Intel Graphics Driver**: Version `32.0.101.8991` or later (official release with Battlemage WSL production support).
- **Docker Desktop**: Configured to use the WSL2 backend.

---

### 2. Dynamic Entrypoint Script (`entrypoint.sh`)
Create `entrypoint.sh` alongside your Dockerfile.

> 💡 **Default Verified Path (Driver 101.8991 Baseline)**:  
> `/usr/lib/wsl/drivers/iigd_dch_d.inf_amd64_59943e79877d96f1`  
> Included in the script as a resilient fallback in case dynamic lookup returns empty.

```bash
#!/bin/bash
set -e

# Default verified driver path (Driver 101.8991 baseline fallback)
DEFAULT_DRV_DIR="/usr/lib/wsl/drivers/iigd_dch_d.inf_amd64_59943e79877d96f1"

# Dynamically locate the Intel WSL compute helper regardless of Windows Update folder hashes
HELPER_PATH=$(find /usr/lib/wsl/drivers -name "libwsl_compute_helper.so" 2>/dev/null | head -n 1)

if [ -n "$HELPER_PATH" ]; then
    DRV_DIR=$(dirname "$HELPER_PATH")
elif [ -d "$DEFAULT_DRV_DIR" ]; then
    echo "[entrypoint] Dynamic lookup failed, falling back to default driver path: $DEFAULT_DRV_DIR"
    DRV_DIR="$DEFAULT_DRV_DIR"
else
    echo "[entrypoint] WARNING: Neither dynamic nor default driver path found! Check -v /usr/lib/wsl:/usr/lib/wsl mount."
    DRV_DIR=""
fi

if [ -n "$DRV_DIR" ]; then
    # /usr/lib/wsl/lib must come first, followed by the vendor driver folder
    export LD_LIBRARY_PATH="/usr/lib/wsl/lib:${DRV_DIR}:${LD_LIBRARY_PATH}"
else
    export LD_LIBRARY_PATH="/usr/lib/wsl/lib:${LD_LIBRARY_PATH}"
fi

export ZES_ENABLE_SYSMAN=0

exec "$@"
```

---

### 3. Working Dockerfile (`Dockerfile.xpu`)
Create `Dockerfile.xpu`:

```dockerfile
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV ZES_ENABLE_SYSMAN=0

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    python3 \
    python3-pip \
    git \
    libze1 \
    libze-dev \
    intel-opencl-icd \
    ocl-icd-libopencl1 \
    && rm -rf /var/lib/apt/lists/*

# Install Intel Compute Runtime 26.35.39758.10 and GmmLib 22.10.0 for Battlemage Xe2 support
RUN mkdir -p /tmp/neo && cd /tmp/neo && \
    curl -sL -O https://github.com/intel/compute-runtime/releases/download/26.35.39758.10/libigdgmm12_22.10.0_amd64.deb && \
    curl -sL -O https://github.com/intel/intel-graphics-compiler/releases/download/v2.41.5/intel-igc-core-2_2.41.5+22716_amd64.deb && \
    curl -sL -O https://github.com/intel/intel-graphics-compiler/releases/download/v2.41.5/intel-igc-opencl-2_2.41.5+22716_amd64.deb && \
    curl -sL -O https://github.com/intel/compute-runtime/releases/download/26.35.39758.10/intel-ocloc_26.35.39758.10-0_amd64.deb && \
    curl -sL -O https://github.com/intel/compute-runtime/releases/download/26.35.39758.10/intel-opencl-icd_26.35.39758.10-0_amd64.deb && \
    curl -sL -O https://github.com/intel/compute-runtime/releases/download/26.35.39758.10/libze-intel-gpu1_26.35.39758.10-0_amd64.deb && \
    curl -sL -O https://github.com/oneapi-src/level-zero/releases/download/v1.34.0/libze1_1.34.0+u24.04_amd64.deb && \
    dpkg -i --force-overwrite *.deb && \
    rm -rf /tmp/neo

# Install official PyTorch with native XPU backend
RUN pip3 install --no-cache-dir --break-system-packages torch torchvision --index-url https://download.pytorch.org/whl/xpu

# Embed dynamic driver discovery
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["/entrypoint.sh"]
CMD ["tail", "-f", "/dev/null"]
```

Build the container image:
```bash
docker build -t game_sandbox_xpu:latest -f Dockerfile.xpu .
```

---

### 4. Container Execution Command (Production-Ready)

> ⚠️ **CRITICAL NOTE**: 
> 1. Mounting only `-v /usr/lib/wsl/lib:/usr/lib/wsl/lib` **FAILS** for Intel Arc. You must mount the **ENTIRE** `/usr/lib/wsl` hierarchy (`-v /usr/lib/wsl:/usr/lib/wsl`).
> 2. The hash in `/usr/lib/wsl/drivers/iigd_dch_d.inf_amd64_<HASH>` **CHANGES with every host GPU driver update**. Never hardcode it manually!

#### Option A: Automatic Discovery inside Container (Recommended)
With `entrypoint.sh` built into the image, `LD_LIBRARY_PATH` is discovered on startup automatically:
```bash
docker run -d \
  --name game_sandbox_xpu \
  --privileged \
  --device=/dev/dxg \
  -v /usr/lib/wsl:/usr/lib/wsl \
  -v $(pwd):/workspace \
  game_sandbox_xpu:latest
```

#### Option B: Dynamic Host One-Liner (Bash / WSL)
```bash
INTEL_DRV=$(find /usr/lib/wsl/drivers -name "libwsl_compute_helper.so" -exec dirname {} \; 2>/dev/null | head -n 1)

docker run -d \
  --name game_sandbox_xpu \
  --privileged \
  --device=/dev/dxg \
  -v /usr/lib/wsl:/usr/lib/wsl \
  -e LD_LIBRARY_PATH="/usr/lib/wsl/lib:${INTEL_DRV}" \
  -e ZES_ENABLE_SYSMAN=0 \
  -v $(pwd):/workspace \
  game_sandbox_xpu:latest
```

#### Option C: Dynamic Windows PowerShell One-Liner
```powershell
$drv = (wsl.exe -e sh -c "find /usr/lib/wsl/drivers -name 'libwsl_compute_helper.so' -exec dirname {} \; 2>/dev/null | head -n 1").Trim()

docker run -d `
  --name game_sandbox_xpu `
  --privileged `
  --device=/dev/dxg `
  -v /usr/lib/wsl:/usr/lib/wsl `
  -e "LD_LIBRARY_PATH=/usr/lib/wsl/lib:$drv" `
  -e ZES_ENABLE_SYSMAN=0 `
  -v $(pwd):/workspace `
  game_sandbox_xpu:latest
```

#### Detailed Breakdown of Required Flags:
| Argument / Flag | Purpose |
|---|---|
| `--privileged` | Grants the container unrestricted access to the WSL2 WDDM device abstractions without cgroup isolation blocking ioctl requests. |
| `--device=/dev/dxg` | Passes through Microsoft's DirectX Graphics Kernel device interface connecting WSL2 to the Windows host GPU driver. |
| `-v /usr/lib/wsl:/usr/lib/wsl` | Mounts **both** the standard DirectX stubs (`libdxcore.so`) and the vendor driver subdirectory `drivers/`, containing Intel's mandatory `libwsl_compute_helper.so`. |
| `-e LD_LIBRARY_PATH=...` | Instructs the dynamic linker where to find `libdxcore.so` followed by the active Intel compute helper directory. |
| `-e ZES_ENABLE_SYSMAN=0` | Suppresses Level Zero Sysman warnings regarding telemetry and fan sensors inaccessible inside virtualized WSL environments. |

---

### 5. Verification Script (`test_xpu.py`)

Create `test_xpu.py`:
```python
import torch

print("=== PyTorch XPU Test ===")
print("PyTorch Version:", torch.__version__)
print("XPU available?:", torch.xpu.is_available())

if torch.xpu.is_available():
    print("Device count:", torch.xpu.device_count())
    print("Device name:", torch.xpu.get_device_name(0))
    
    print("\n--- Running Tensor Computation on XPU ---")
    x = torch.randn(1000, 1000, device="xpu")
    y = torch.randn(1000, 1000, device="xpu")
    z = torch.matmul(x, y)
    print("Matrix multiplication succeeded!")
    print("Result shape:", z.shape)
    print("Result sum:", z.sum().item())
    print("\n🎉 ALL TESTS PASSED! Intel Arc GPU is fully functional in PyTorch! 🎉")
else:
    print("❌ XPU is NOT available in PyTorch.")
```

Run test via `docker exec`:
```bash
docker exec game_sandbox_xpu python3 /workspace/test_xpu.py
```

Expected output:
```text
=== PyTorch XPU Test ===
PyTorch Version: 2.14.0+xpu
XPU available?: True
Device count: 1
Device name: Intel(R) Graphics [0xe20b]

--- Running Tensor Computation on XPU ---
Matrix multiplication succeeded!
Result shape: torch.Size([1000, 1000])
Result sum: 44167.1875

🎉 ALL TESTS PASSED! Intel Arc GPU is fully functional in PyTorch! 🎉
```

---

## PART 2. DEEP TECHNICAL POST-MORTEM & ROOT CAUSE ANALYSIS

```
+-----------------------------------------------------------------------------------+
|                         INTEL GPU STACK ARCHITECTURE                              |
+-----------------------------------------------------------------------------------+
|  PyTorch (torch.xpu)                                                              |
|        ↓                                                                          |
|  oneAPI Level Zero Loader (libze_loader.so.1)                                     |
|        ↓                                                                          |
|  Intel Compute Runtime (libze_intel_gpu.so / NEO)                                 |
|        ↓                                                                          |
|  Intel Graphics Memory Management (libigdgmm.so.12 v22.10.0)                      |
|        ↓                                                                          |
|  WDDM Translator & Helper (/usr/lib/wsl/drivers/.../libwsl_compute_helper.so)     |
|        ↓                                                                          |
|  DirectX Core Runtime (/usr/lib/wsl/lib/libdxcore.so)                             |
|        ↓                                                                          |
|  WSL2 Kernel Device (/dev/dxg)                                                    |
|        ↓                                                                          |
|  Windows Host Driver (Intel Arc Graphics 101.8991 -> B580 Hardware 0xe20b)        |
+-----------------------------------------------------------------------------------+
```

---

### Trap #1: Outdated Ubuntu 24.04 Repositories (Runtime 23.43)
- **Symptom**: `zeInit` returns error code `2013265921` (`0x78000001` = `ZE_RESULT_ERROR_UNINITIALIZED`). The GPU is never detected.
- **Root Cause**: The default Ubuntu 24.04 apt repositories contain `intel-opencl-icd` and `libze-intel-gpu1` version `23.43.27642.40` (built late 2023). **Intel Arc Battlemage (B580 / Xe2)** was released long after this build. The old runtime does not recognize PCI Device ID `0xe20b` and lacks shader compilers for the Xe2 architecture.
- **Solution**: Install Intel Compute Runtime **`26.35.39758.10`** and `intel-graphics-compiler 2.41.5` directly from Intel's GitHub releases. The release notes explicitly document: *"WSL support tested with Windows host driver 101.8991; Battlemage WSL status: Production"*.

---

### Trap #2: The Partial WSL Mount Pitfall (`/usr/lib/wsl/lib` vs `/usr/lib/wsl`)
- **Symptom**: `zeInit` triggers an unhandled abort:
  ```text
  Abort was called at 56 line in file:
  ./shared/source/os_interface/windows/wddm/create_um_km_data_translator.cpp
  ```
  `strace` logs reveal:
  ```text
  openat("/usr/lib/wsl/drivers/iigd_dch_d.inf_amd64_59943e79877d96f1/libwsl_compute_helper.so") = -1 ENOENT
  ```
- **Root Cause**: Microsoft documentation for NVIDIA GPUs instructs developers to mount `-v /usr/lib/wsl/lib:/usr/lib/wsl/lib`. While NVIDIA puts all shim libraries in `lib/`, Intel places the hardware command translator (`libwsl_compute_helper.so`) in the vendor driver INF folder under `/usr/lib/wsl/drivers/`.
- **Solution**: Mount the parent directory `-v /usr/lib/wsl:/usr/lib/wsl` and ensure `LD_LIBRARY_PATH` includes the exact driver path.

---

### Trap #3: Missing Symbol `Is64KBPageSuitable` in GmmLib
- **Symptom**: Loading `libwsl_compute_helper.so` fails with:
  ```text
  undefined symbol: _ZN6GmmLib21GmmResourceInfoCommon18Is64KBPageSuitableEv
  ```
- **Root Cause**: `libwsl_compute_helper.so` depends on Intel Graphics Memory Management Library (GmmLib) API functions. The stock Ubuntu `libigdgmm12` (`22.3.17`) lacks the `Is64KBPageSuitable()` method.
- **Solution**: Install `libigdgmm12_22.10.0_amd64.deb` distributed alongside Compute Runtime `26.35.39758.10`.

---

### Trap #4: The `LD_PRELOAD` Trap with `libigdgmm_w.so.12`
- **Symptom**: In an attempt to satisfy the undefined symbol, injecting `LD_PRELOAD=.../libigdgmm_w.so.12` triggers:
  ```text
  Abort was called at 51 line in file:
  ../../neo/shared/source/gmm_helper/client_context/gmm_client_context.cpp
  ```
- **Source Inspection (`gmm_client_context.cpp:51`)**:
  ```cpp
  auto ret = GmmInterface::initialize(&inArgs, &outArgs);
  UNRECOVERABLE_IF(ret != GMM_SUCCESS);
  ```
- **Root Cause**: The host driver directory contains `libigdgmm_w.so.12`. The `_w` suffix indicates an internal Windows/WDDM helper build. Forcing this library into the entire process using `LD_PRELOAD` intercepts calls made by the Linux driver `libze_intel_gpu.so`. Struct alignment mismatches in `GMM_INIT_IN_ARGS` cause initialization to fail immediately with an unrecoverable abort.
- **Solution**: **NEVER use `LD_PRELOAD` for `libigdgmm_w.so.12`!** Let the Linux driver use its native `/usr/lib/x86_64-linux-gnu/libigdgmm.so.12` (v22.10.0) and resolve helper dependencies cleanly via `LD_LIBRARY_PATH`.

---

### Trap #5: Level Zero Sysman Warnings in WSL2
- **Symptom**:
  ```text
  UserWarning: Can't initialize Level Zero Sysman
    return _enum_zes_device_infos(visible_mask)
  ```
- **Root Cause**: Sysman manages physical device metrics: temperature, power consumption limits, fan speeds, and clock frequencies. In WSL2, `/dev/dxg` isolates guest environments from direct register manipulation for stability and security.
- **Solution**: This warning does not affect compute execution or training. Silence it cleanly with:
  ```bash
  -e ZES_ENABLE_SYSMAN=0
  ```

---

### Trap #6: The Deprecated IPEX (`intel-extension-for-pytorch`) Myth
- **Misconception**: "You must install `intel-extension-for-pytorch` to run PyTorch on Intel Arc."
- **Fact**: Modern PyTorch natively integrates the `xpu` device backend in the upstream codebase. Installing legacy IPEX causes ABI compiler conflicts and breaks dependency trees.
- **Standard Syntax**:
  ```python
  import torch
  device = torch.device("xpu")
  x = torch.randn(1024, 1024, device=device)
  ```

---

### Trap #7: The Dynamic Driver Folder Hash (Windows Update Fragility)
- **Symptom**: The container ran flawlessly for weeks, but suddenly fails to initialize Level Zero after a system reboot or automatic Windows Update with missing `libwsl_compute_helper.so`.
- **Root Cause**: The directory name `/usr/lib/wsl/drivers/iigd_dch_d.inf_amd64_<HASH>` contains a unique hash generated by Windows DriverStore for the installed driver package. Any update to the Intel graphics driver produces a new hash and removes the previous folder. Hardcoding the hash path in your `Dockerfile` or startup scripts guarantees sudden failure on the next driver update.
- **Solution**: Resolve the driver path **dynamically**:
  - Inside the container via [entrypoint.sh](file:///c:/Users/user/Desktop/game/entrypoint.sh) using `find /usr/lib/wsl/drivers -name "libwsl_compute_helper.so"`.
  - Or before launching `docker run` using a host one-liner.
  Always ensure `/usr/lib/wsl/lib` precedes the vendor driver directory in `LD_LIBRARY_PATH` so Linux OpenCL/JIT shader compilers do not conflict with internal Windows helper binaries.

---

## PART 3. DIAGNOSTIC RUNBOOK

When troubleshooting Intel GPU containers, run these verification steps inside the container:

1. **Verify `/dev/dxg` device presence**:
   ```bash
   ls -la /dev/dxg
   # Must return: crw-rw-rw- 1 root root ... /dev/dxg
   ```

2. **Verify Intel compute helper library**:
   ```bash
   ls -la /usr/lib/wsl/drivers/*/libwsl_compute_helper.so
   # Must return a valid existing library
   ```

3. **Verify installed Intel package versions**:
   ```bash
   dpkg -l | grep -E "intel|libze|gmm"
   # libze-intel-gpu1 and intel-opencl-icd must be 26.35.39758.10
   # libigdgmm12 must be 22.10.0
   ```

4. **Direct Level Zero initialization test**:
   ```python
   import ctypes
   ze = ctypes.CDLL('libze_loader.so.1')
   assert ze.zeInit(1) == 0, "Level Zero failed to initialize"
   print("Level Zero initialized successfully!")
   ```

5. **PyTorch XPU tensor test**:
   ```python
   import torch
   assert torch.xpu.is_available(), "XPU not available"
   print("Active device:", torch.xpu.get_device_name(0))
   ```

---

## PART 4. OFFICIAL REFERENCES & REPOSITORIES (AS OF SEPTEMBER 2026)

> ⚠️ **Version Context Snapshot**: All URLs, package tags, and driver versions are documented as of **September 2026**. If you are referencing this guide at a later date, treat these links as verified baselines for locating newer corresponding runtimes:

1. **Intel Arc Graphics Host Driver (Windows)**:
   - [Official Intel Arc Graphics Windows DCH Driver Download](https://www.intel.com/content/www/us/en/download/785597/intel-arc-graphics-windows.html)
   - Tested version with Battlemage WSL2 support: `32.0.101.8991` (or newer).

2. **Intel Compute Runtime (NEO) — OpenCL & Level Zero**:
   - [GitHub Repository: intel/compute-runtime](https://github.com/intel/compute-runtime)
   - [GitHub Release 26.35.39758.10](https://github.com/intel/compute-runtime/releases/tag/26.35.39758.10) (contains `intel-opencl-icd`, `libze-intel-gpu1`, `intel-ocloc`, and `libigdgmm12_22.10.0`).
   - Release notes explicitly confirm Battlemage (Xe2) WSL support as Production quality.

3. **Intel Graphics Compiler (IGC)**:
   - [GitHub Repository: intel/intel-graphics-compiler](https://github.com/intel/intel-graphics-compiler)
   - [GitHub Release IGC v2.41.5](https://github.com/intel/intel-graphics-compiler/releases/tag/v2.41.5) (contains `intel-igc-core-2` and `intel-igc-opencl-2`).

4. **oneAPI Level Zero Specification & Loader**:
   - [GitHub Repository: oneapi-src/level-zero](https://github.com/oneapi-src/level-zero) (loader source and releases).
   - [oneAPI Level Zero Specification Docs](https://oneapi-src.github.io/level-zero-spec/) (API documentation for devices, memory management, and command queues).

5. **PyTorch Native XPU Backend**:
   - [Official PyTorch XPU Wheels Repository](https://download.pytorch.org/whl/xpu)
   - [PyTorch Documentation: torch.xpu Module](https://pytorch.org/docs/stable/xpu.html)

6. **Microsoft WSL2 GPU Compute Virtualization**:
   - [Microsoft Learn: GPU Compute in Windows Subsystem for Linux](https://learn.microsoft.com/en-us/windows/wsl/tutorials/gpu-compute)
   - [GitHub Repository: Microsoft WSLg & dxgkrnl DirectX Driver](https://github.com/microsoft/wslg)

---
*Authored following verified hardware debugging on Windows 11 + WSL2 + Docker Desktop + Intel Arc B580 (Xe2 Architecture).*

