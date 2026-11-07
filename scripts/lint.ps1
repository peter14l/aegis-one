# ============================================================================
# Script: scripts/lint.ps1
# Project: Aegis-One Hyper-Hybrid Tiered Memory Controller
# Description: RAM-only Verilator lint runner for Windows / WSL environments
# ============================================================================

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

# Collect SV files
$svFiles = @("docs/01_INTERFACES.sv")
if (Test-Path "rtl") {
    $svFiles += (Get-ChildItem -Path "rtl" -Recurse -Filter "*.sv" | ForEach-Object { $_.FullName })
}

# Check for native Verilator executable
$nativeVerilator = Get-Command "verilator" -ErrorAction SilentlyContinue

if ($nativeVerilator) {
    # Windows native RAM fallback using $env:TEMP
    $vlintDir = Join-Path $env:TEMP ("aegis_vlint_" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $vlintDir | Out-Null

    try {
        Write-Host "==> [Aegis-One] Running native Verilator lint in RAM ($vlintDir)..." -ForegroundColor Cyan
        & verilator --lint-only -Wall -Wno-MULTITOP --timing -Mdir $vlintDir $svFiles
        if ($LASTEXITCODE -ne 0) {
            throw "Verilator lint failed with exit code $LASTEXITCODE"
        }
        Write-Host "==> [Aegis-One] Lint clean. Zero warnings, zero errors." -ForegroundColor Green
    }
    finally {
        if (Test-Path $vlintDir) {
            Remove-Item -Recurse -Force $vlintDir -ErrorAction SilentlyContinue
        }
    }
} else {
    # Check for WSL fallback
    $wsl = Get-Command "wsl" -ErrorAction SilentlyContinue
    if ($wsl) {
        Write-Host "==> [Aegis-One] Native Verilator not in PATH. Delegating to WSL /dev/shm..." -ForegroundColor Yellow
        $wslCmd = "mkdir -p /dev/shm/vlint && cd /mnt/f/aegis-one && bash -c 'shopt -s globstar nullglob; verilator --lint-only -Wall -Wno-MULTITOP --timing -Mdir /dev/shm/vlint docs/01_INTERFACES.sv rtl/**/*.sv'"
        & wsl sh -c $wslCmd
        if ($LASTEXITCODE -ne 0) {
            throw "WSL Verilator lint failed with exit code $LASTEXITCODE"
        }
        Write-Host "==> [Aegis-One] Lint clean via WSL. Zero warnings, zero errors." -ForegroundColor Green
    } else {
        throw "Neither native Verilator nor WSL was found. Please install Verilator."
    }
}
