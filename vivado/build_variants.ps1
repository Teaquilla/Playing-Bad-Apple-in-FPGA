# vivado/build_variants.ps1
# Pembungkus PowerShell untuk membangun baseline + 4 varian orientasi OLED
# dengan SATU proses Vivado terpisah per konfigurasi agar bebas status terbawa antar-iterasi.

[CmdletBinding()]
param(
    [string]$OutRoot = ""
)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
if ([string]::IsNullOrWhiteSpace($OutRoot)) {
    $OutRoot = "scratch/build_variants"
}

$settingsBat = "D:\Vivado\2026.1\Vivado\settings64.bat"
if (-not (Get-Command vivado -ErrorAction SilentlyContinue)) {
    & "$PSScriptRoot\env.ps1" | Out-Null
}
$vivadoCmd = Get-Command vivado.bat -ErrorAction SilentlyContinue
if (-not $vivadoCmd) {
    $vivadoCmd = Get-Command vivado -ErrorAction SilentlyContinue
}
if (-not $vivadoCmd) {
    Write-Error "Perintah 'vivado' tidak ditemukan setelah memuat env.ps1."
    exit 1
}

New-Item -ItemType Directory -Force -Path $OutRoot | Out-Null
$tclScript = "vivado/build_variants.tcl"

$configs = @(
    @{ Name = "baseline"; Seg = "BASELINE"; Com = "BASELINE" },
    @{ Name = "A0_C0";    Seg = "A0";       Com = "C0" },
    @{ Name = "A0_C8";    Seg = "A0";       Com = "C8" },
    @{ Name = "A1_C0";    Seg = "A1";       Com = "C0" },
    @{ Name = "A1_C8";    Seg = "A1";       Com = "C8" }
)

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  BUILD TERISOLASI PER PROSES VIVADO (BASELINE + 4 VARIAN)     " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "OutRoot : $OutRoot"

foreach ($cfg in $configs) {
    $vname = $cfg.Name
    $vdir  = Join-Path $OutRoot $vname
    New-Item -ItemType Directory -Force -Path $vdir | Out-Null
    $logFile = Join-Path $vdir "vivado_${vname}.log"
    $vdirFwd = $vdir -replace '\\', '/'
    $logFwd  = $logFile -replace '\\', '/'

    Write-Host "`n[START] Proses Vivado terpisah untuk varian '$vname' ($($cfg.Seg), $($cfg.Com))..." -ForegroundColor Yellow
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if (Test-Path $settingsBat) {
        cmd.exe /c "call $settingsBat >nul 2>&1 && vivado -mode batch -nojournal -nolog -source $tclScript -tclargs $($cfg.Seg) $($cfg.Com) $vdirFwd > $logFwd 2>&1"
    } else {
        cmd.exe /c "vivado -mode batch -nojournal -nolog -source $tclScript -tclargs $($cfg.Seg) $($cfg.Com) $vdirFwd > $logFwd 2>&1"
    }
    $ec = $LASTEXITCODE
    $sw.Stop()

    $expectedBit = Join-Path $vdir "top_${vname}_compressed.bit"
    $expectedDcp = Join-Path $vdir "top_routed_${vname}.dcp"
    if ($ec -ne 0 -or -not (Test-Path $expectedBit) -or -not (Test-Path $expectedDcp)) {
        Write-Host "[FAIL] Varian '$vname' gagal dengan exit code $ec. Lihat log: $logFile" -ForegroundColor Red
        exit $(if ($ec -ne 0) { $ec } else { 1 })
    }
    Write-Host "[OK] Varian '$vname' selesai dalam $([math]::Round($sw.Elapsed.TotalSeconds, 1)) detik -> $vdir" -ForegroundColor Green
}

Write-Host "`nSELURUH 5 KONFIGURASI (BASELINE + 4 VARIAN) SELESAI DENGAN SUKSES!" -ForegroundColor Green
exit 0
} finally {
    Pop-Location
}
