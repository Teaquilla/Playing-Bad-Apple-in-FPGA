# vivado/collect_release.ps1
# Mengumpulkan bitstream rilis M4 baseline terkompresi (.bit dan .bin) dari folder
# build_variants_4u_* terbaru ke release\m4\ dan menulis release\m4\SHA256SUMS.txt.

[CmdletBinding()]
param(
    [string]$Source = "",
    [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"

$ExpectedBaselineBinSha256 = "497BD582BAB3ACD558DBE7546DDEFF5E3089DE3F19EC13426FB0AA057AE4D305"
$repoRoot = Split-Path -Parent $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $repoRoot "release\m4"
}

if ([string]::IsNullOrWhiteSpace($Source)) {
    $searchPatterns = @(
        (Join-Path $repoRoot "scratch\build_variants_4u_*"),
        (Join-Path $env:USERPROFILE ".gemini\antigravity\brain\*\scratch\build_variants_4u_*")
    )
    $candidates = @()
    foreach ($pattern in $searchPatterns) {
        $found = Get-Item -Path $pattern -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer }
        if ($found) {
            $candidates += $found
        }
    }
    $selected = $candidates | Sort-Object -Property LastWriteTime, Name -Descending | Select-Object -First 1
    if (-not $selected) {
        throw "Folder build_variants_4u_* tidak ditemukan di scratch repo maupun scratch Antigravity. Berikan parameter -Source secara eksplisit."
    }
    $Source = $selected.FullName
}

if (-not (Test-Path -Path $Source -PathType Container)) {
    throw "Direktori sumber tidak ditemukan: $Source"
}

# Terima baik akar build_variants_4u_* maupun subdirektori baseline langsung
$baselineDir = Join-Path $Source "baseline"
if (-not (Test-Path -Path $baselineDir -PathType Container)) {
    if (Test-Path -Path (Join-Path $Source "top_baseline_compressed.bit") -PathType Leaf) {
        $baselineDir = $Source
    } else {
        throw "Subdirektori baseline atau top_baseline_compressed.bit tidak ditemukan di: $Source"
    }
}

$srcBit = Join-Path $baselineDir "top_baseline_compressed.bit"
$srcBin = Join-Path $baselineDir "top_baseline_compressed.bin"
foreach ($req in @($srcBit, $srcBin)) {
    if (-not (Test-Path -Path $req -PathType Leaf)) {
        throw "Berkas baseline tidak ditemukan: $req"
    }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$dstBit = Join-Path $OutDir "top_baseline_compressed.bit"
$dstBin = Join-Path $OutDir "top_baseline_compressed.bin"
Copy-Item -Path $srcBit -Destination $dstBit -Force
Copy-Item -Path $srcBin -Destination $dstBin -Force

$hashBit = (Get-FileHash -Path $dstBit -Algorithm SHA256).Hash.ToUpperInvariant()
$hashBin = (Get-FileHash -Path $dstBin -Algorithm SHA256).Hash.ToUpperInvariant()

if ($hashBin -ne $ExpectedBaselineBinSha256) {
    throw "SHA-256 top_baseline_compressed.bin tidak cocok! Harapan: $ExpectedBaselineBinSha256, Didapat: $hashBin"
}

$sumsPath = Join-Path $OutDir "SHA256SUMS.txt"
$sumsLines = @(
    "$hashBit  top_baseline_compressed.bit",
    "$hashBin  top_baseline_compressed.bin"
)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($sumsPath, $sumsLines, $utf8NoBom)

Write-Output "Sumber   : $Source"
Write-Output "Tujuan   : $OutDir"
Write-Output "BIT      : $dstBit ($((Get-Item $dstBit).Length) B) SHA256=$hashBit"
Write-Output "BIN      : $dstBin ($((Get-Item $dstBin).Length) B) SHA256=$hashBin"
Write-Output "Checksums: $sumsPath"
Write-Output "Verifikasi baseline .bin SHA-256: COCOK ($ExpectedBaselineBinSha256)"
