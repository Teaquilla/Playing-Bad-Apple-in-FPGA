# vivado/env.ps1
# Skrip pembantu untuk memuat environment Vivado 2026.1 ke sesi PowerShell saat ini (Scope: Process).
# Tidak mengubah PATH sistem permanen.
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Command
)

$settingsBat = "D:\Vivado\2026.1\Vivado\settings64.bat"

if (-not (Test-Path $settingsBat)) {
    Write-Error "settings64.bat tidak ditemukan di: $settingsBat"
    return
}

# Ekstrak variabel lingkungan yang di-set oleh settings64.bat
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

if ($Command -and $Command.Count -gt 0) {
    & $Command[0] $Command[1..($Command.Count - 1)]
} else {
    Write-Host "Environment Vivado 2026.1 berhasil dimuat ke proses PowerShell ini." -ForegroundColor Green
}
