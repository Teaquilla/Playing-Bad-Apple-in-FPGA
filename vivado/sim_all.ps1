# vivado/sim_all.ps1
# Skrip regresi otomatis untuk menjalankan seluruh testbench HDL M1 di Vivado xsim
# dan menampilkan ringkasan status PASS/FAIL.

[CmdletBinding()]
param()

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# Pastikan environment Vivado 2026.1 termuat
$settingsBat = "D:\Vivado\2026.1\Vivado\settings64.bat"
if (-not (Get-Command xvhdl -ErrorAction SilentlyContinue)) {
    if (Test-Path $settingsBat) {
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
    } else {
        Write-Error "Vivado settings64.bat tidak ditemukan di $settingsBat"
        exit 1
    }
}

$testSuites = @(
    @{
        Name    = "tb_frame_timer"
        Hdl     = @("hdl/frame_timer.vhd")
        Tb      = "sim/tb_frame_timer.vhd"
        Top     = "tb_frame_timer"
        PassKey = "TEST PASSED: frame_timer"
    },
    @{
        Name    = "tb_uart_tx"
        Hdl     = @("hdl/uart_tx.vhd")
        Tb      = "sim/tb_uart_tx.vhd"
        Top     = "tb_uart_tx"
        PassKey = "TEST PASSED: uart_tx"
    },
    @{
        Name    = "tb_frame_source"
        Hdl     = @("hdl/frame_source.vhd")
        Tb      = "sim/tb_frame_source.vhd"
        Top     = "tb_frame_source"
        PassKey = "TEST PASSED: frame_source"
    },
    @{
        Name    = "tb_decoder"
        Hdl     = @("hdl/decoder.vhd")
        Tb      = "sim/tb_decoder.vhd"
        Top     = "tb_decoder"
        PassKey = "TEST PASSED: decoder"
    },
    @{
        Name    = "tb_frame_buffer"
        Hdl     = @("hdl/frame_buffer.vhd")
        Tb      = "sim/tb_frame_buffer.vhd"
        Top     = "tb_frame_buffer"
        PassKey = "TEST PASSED: frame_buffer"
    },
    @{
        Name    = "tb_ascii_sink"
        Hdl     = @("hdl/ascii_sink.vhd")
        Tb      = "sim/tb_ascii_sink.vhd"
        Top     = "tb_ascii_sink"
        PassKey = "TEST PASSED: ascii_sink"
    },
    @{
        Name    = "tb_top"
        Hdl     = @("hdl/frame_timer.vhd", "hdl/uart_tx.vhd", "hdl/frame_source.vhd", "hdl/decoder.vhd", "hdl/frame_buffer.vhd", "hdl/ascii_sink.vhd", "hdl/top.vhd")
        Tb      = "sim/tb_top.vhd"
        Top     = "tb_top"
        PassKey = "TEST PASSED: tb_top berhasil memverifikasi kedua mode"
    }
)

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "        REGRESI TESTBENCH HDL BAD APPLE (VIVADO XSIM)           " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

$results = @()
$allPass = $true

foreach ($t in $testSuites) {
    Write-Host "`n[RUNNING] $($t.Name)..." -ForegroundColor Yellow
    $snap = "snap_$($t.Top)"
    
    # 1. Compile VHDL files
    $srcFiles = ($t.Hdl + $t.Tb) -join " "
    $compileCmd = "xvhdl -2008 $srcFiles"
    $compileOut = cmd.exe /c "$compileCmd 2>&1"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[FAIL] $($t.Name) - Gagal Kompilasi xvhdl" -ForegroundColor Red
        $results += [PSCustomObject]@{ Test = $t.Name; Status = "FAIL (Kompilasi)"; Details = ($compileOut | Select-String "ERROR" | Out-String).Trim() }
        $allPass = $false
        continue
    }

    # 2. Elaborate snapshot
    $elabCmd = "xelab -debug typical $($t.Top) -s $snap"
    $elabOut = cmd.exe /c "$elabCmd 2>&1"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[FAIL] $($t.Name) - Gagal Elaborasi xelab" -ForegroundColor Red
        $results += [PSCustomObject]@{ Test = $t.Name; Status = "FAIL (Elaborasi)"; Details = ($elabOut | Select-String "ERROR" | Out-String).Trim() }
        $allPass = $false
        continue
    }

    # 3. Simulate with xsim
    $simCmd = "xsim $snap -R"
    $simOut = cmd.exe /c "$simCmd 2>&1"
    $simOutStr = $simOut | Out-String
    
    if ($simOutStr -match [regex]::Escape($t.PassKey)) {
        Write-Host "[PASS] $($t.Name)" -ForegroundColor Green
        $results += [PSCustomObject]@{ Test = $t.Name; Status = "PASS"; Details = "Kriteria lolos terverifikasi" }
    } else {
        Write-Host "[FAIL] $($t.Name) - Kriteria PASS tidak terpenuhi" -ForegroundColor Red
        $results += [PSCustomObject]@{ Test = $t.Name; Status = "FAIL (Simulasi)"; Details = ($simOut | Select-String "Failure|Error" | Out-String).Trim() }
        $allPass = $false
    }
}

Write-Host "`n================================================================" -ForegroundColor Cyan
Write-Host "                    RINGKASAN HASIL REGRESI                     " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
$results | Format-Table -AutoSize

if ($allPass) {
    Write-Host "SELURUH TESTBENCH LOLOS DENGAN SUKSES (ALL PASS)!" -ForegroundColor Green
    exit 0
} else {
    Write-Host "ADA TESTBENCH YANG GAGAL!" -ForegroundColor Red
    exit 1
}
