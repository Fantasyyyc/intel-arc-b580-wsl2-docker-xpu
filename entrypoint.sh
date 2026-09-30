#!/bin/bash
set -e

# Default verified driver path fallback (Intel Arc baseline)
DEFAULT_DRV_DIR="/usr/lib/wsl/drivers/iigd_dch_d.inf_amd64_59943e79877d96f1"

# Dynamically locate the Intel WSL compute helper regardless of Windows DriverStore hash changes
HELPER_PATH=$(find /usr/lib/wsl/drivers -name "libwsl_compute_helper.so" 2>/dev/null | head -n 1)

if [ -n "$HELPER_PATH" ]; then
    DRV_DIR=$(dirname "$HELPER_PATH")
    echo "[entrypoint] Found Intel driver directory: $DRV_DIR"
elif [ -d "$DEFAULT_DRV_DIR" ]; then
    echo "[entrypoint] Dynamic lookup failed, falling back to default driver path: $DEFAULT_DRV_DIR"
    DRV_DIR="$DEFAULT_DRV_DIR"
else
    echo "[entrypoint] WARNING: Neither dynamic nor default driver path found! Check -v /usr/lib/wsl:/usr/lib/wsl mount."
    DRV_DIR=""
fi

if [ -n "$DRV_DIR" ]; then
    # /usr/lib/wsl/lib must come first, followed by vendor driver folder
    export LD_LIBRARY_PATH="/usr/lib/wsl/lib:${DRV_DIR}:${LD_LIBRARY_PATH}"
else
    export LD_LIBRARY_PATH="/usr/lib/wsl/lib:${LD_LIBRARY_PATH}"
fi

export ZES_ENABLE_SYSMAN=0

exec "$@"
