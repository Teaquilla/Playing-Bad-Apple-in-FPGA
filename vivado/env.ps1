# vivado/env.ps1
# Skrip pembantu untuk memuat environment Vivado 2026.1 ke sesi PowerShell saat ini (Scope: Process).
# Tidak mengubah PATH sistem permanen.
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Command
)

$settingsBat = $null
if (-not (Get-Command xvhdl -ErrorAction SilentlyContinue)) {
    $candidates = @()
    if ($env:VIVADO_SETTINGS) { $candidates += $env:VIVADO_SETTINGS }
    $candidates += @(
        "D:\Vivado\2026.1\Vivado\settings64.bat",
        "C:\Xilinx\Vivado\*\settings64.bat",
        "D:\Xilinx\Vivado\*\settings64.bat",
        "C:\Vivado\*\Vivado\settings64.bat",
        "D:\Vivado\*\Vivado\settings64.bat",
        "C:\AMD\Vivado\*\Vivado\settings64.bat",
        "D:\AMD\Vivado\*\Vivado\settings64.bat"
    )
    foreach ($pattern in $candidates) {
        $found = Get-Item -Path $pattern -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($found) {
            $settingsBat = $found.FullName
            break
        }
    }

    if (-not $settingsBat) {
        Write-Error "settings64.bat Vivado tidak ditemukan. Pastikan Vivado ada di PATH atau set `$env:VIVADO_SETTINGS ke path settings64.bat."
        return
    }
}

# Ekstrak variabel lingkungan yang di-set oleh settings64.bat bila belum ada di PATH
if ($settingsBat) {
    $tempFile = [System.IO.Path]::GetTempFileName()
    cmd.exe /c "call `"$settingsBat`" >nul 2>&1 && set > `"$tempFile`""

    if (Test-Path $tempFile) {
        Get-Content $tempFile | ForEach-Object {
            if ($_ -match '^([^=]+)=(.*)$') {
                [System.Environment]::SetEnvironmentVariable($matches[1], $matches[2], "Process")
            }
        }
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }
}

if ($Command -and $Command.Count -gt 0) {
    & $Command[0] $Command[1..($Command.Count - 1)]
} else {
    Write-Host "Environment Vivado berhasil dimuat ke proses PowerShell ini." -ForegroundColor Green
}
