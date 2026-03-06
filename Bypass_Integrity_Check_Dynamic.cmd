@echo off
setlocal

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrative Privileges...
    powershell -NoProfile -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

set "SCRIPT=%~dp0Bypass_Integrity_Check_Semantic.py"
if not exist "%SCRIPT%" (
    echo Error: %SCRIPT% not found.
    echo Press any key to exit...
    pause >nul
    exit /b 1
)

where python >nul 2>&1
if %errorlevel% equ 0 (
    python "%SCRIPT%" %*
    set "RC=%errorlevel%"
) else (
    where py >nul 2>&1
    if %errorlevel% neq 0 (
        echo Error: Python 3 was not found in PATH.
        echo Press any key to exit...
        pause >nul
        exit /b 1
    )
    py -3 "%SCRIPT%" %*
    set "RC=%errorlevel%"
)

echo.
if not "%RC%"=="0" (
    echo Patcher exited with code %RC%.
)
echo Press any key to exit...
pause >nul
exit /b %RC%
