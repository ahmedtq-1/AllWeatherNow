@echo off
title AllWeatherNow Engine Launcher

:: Force the working directory to where this batch file is saved
cd /d "%~dp0"

:: Check if Python is installed
python --version >nul 2>&1
if %errorlevel% neq 0 (
    echo Python is not detected on this system.
    echo Attempting to automatically install Python via winget...
    
    winget install Python.Python.3.11 --silent --accept-package-agreements --accept-source-agreements
    
    if %errorlevel% neq 0 (
        echo Automatic installation failed or winget is unavailable.
        echo Please manually install Python from python.org and check "Add Python to PATH".
        pause
        exit /b
    )
    
    echo Python installed successfully. Please restart this batch file.
    pause
    exit /b
)

:: Run the Python bridge script
echo Starting AllWeatherNow Bridge...
python AllWeatherNow_Bridge_1_3_6.py

pause