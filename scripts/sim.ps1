# ============================================================================
# Script: scripts/sim.ps1
# Project: Aegis-One Hyper-Hybrid Tiered Memory Controller
# Description: Compiles and runs cycle-accurate Verilator C++ simulation in RAM
# ============================================================================

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

$nativeVerilator = Get-Command "verilator" -ErrorAction SilentlyContinue

if ($nativeVerilator) {
    $vbuildDir = Join-Path $env:TEMP ("aegis_vbuild_" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $vbuildDir | Out-Null
    try {
        Write-Host "==> [Aegis-One] Building simulation in RAM ($vbuildDir)..." -ForegroundColor Cyan
        & verilator --cc --exe -O3 --build -j 4 -Mdir $vbuildDir -Wall -Wno-MULTITOP --top-module aegis_top docs/01_INTERFACES.sv (Get-ChildItem rtl -Recurse -Filter *.sv | ForEach-Object { $_.FullName }) tb/tb_top.cpp
        & (Join-Path $vbuildDir "Vaegis_top.exe")
    }
    finally {
        if (Test-Path $vbuildDir) {
            Remove-Item -Recurse -Force $vbuildDir -ErrorAction SilentlyContinue
        }
    }
} else {
    $wsl = Get-Command "wsl" -ErrorAction SilentlyContinue
    if ($wsl) {
        Write-Host "==> [Aegis-One] Delegating simulation to WSL /dev/shm..." -ForegroundColor Yellow
        $wslCmd = "mkdir -p /dev/shm/vbuild && cd /mnt/f/aegis-one && verilator --cc --exe -O3 --build -j 4 -Mdir /dev/shm/vbuild -Wall -Wno-MULTITOP --top-module aegis_top docs/01_INTERFACES.sv rtl/*.sv rtl/core/*.sv tb/tb_top.cpp && /dev/shm/vbuild/Vaegis_top"
        & wsl sh -c $wslCmd
    } else {
        throw "Neither native Verilator nor WSL was found."
    }
}
