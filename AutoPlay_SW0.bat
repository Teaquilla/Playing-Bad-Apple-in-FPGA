@echo off
setlocal
cd /d "%~dp0"

if exist ".venv\Scripts\python.exe" (
    set "PYEXE=.venv\Scripts\python.exe"
) else (
    set "PYEXE=python"
)

if not exist "data\stream_full.bin" (
    echo [INFO] data\stream_full.bin belum ada. Membuat stream video penuh sekali ini...
    "%PYEXE%" python\make_full_stream.py --out data\stream_full.bin
    if errorlevel 1 (
        echo [GAGAL] Gagal membuat data\stream_full.bin.
        pause
        exit /b 1
    )
)

echo [INFO] Menjalankan Bad Apple!! Standby Auto-Player...
"%PYEXE%" python\auto_player.py
if errorlevel 1 (
    echo.
    pause
)
