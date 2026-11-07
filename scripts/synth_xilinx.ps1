# ============================================================================
# File: scripts/synth_xilinx.ps1
# Project: Aegis-One Hyper-Hybrid Tiered Memory Controller
# Description: PowerShell wrapper to synthesize Aegis-One for UltraScale+
# ============================================================================

$ErrorActionPreference = "Stop"

Write-Host "==> [Aegis-One] Delegating UltraScale+ synthesis to WSL in RAM..." -ForegroundColor Cyan

$wsl_cmd = "bash -c 'bash /mnt/f/aegis-one/scripts/synth_xilinx.sh'"
wsl bash -c $wsl_cmd

if ($LASTEXITCODE -ne 0) {
    Write-Error "Synthesis failed with exit code $LASTEXITCODE"
} else {
    Write-Host "==> [Aegis-One] Synthesis succeeded with zero latches." -ForegroundColor Green
}
