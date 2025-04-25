@echo off
REM BlueStacks Root Tool - Fixed Version
REM This script correctly enables/disables root access on BlueStacks 5

REM Set code page to UTF-8
chcp 65001 >nul

REM Enable delayed expansion
setlocal enabledelayedexpansion

REM Script version
set "VERSION=2.1"
set "SCRIPT_NAME=BlueStacks Root Tool"
set "SCRIPT_DATE=March 2025"

REM Color definitions for PowerShell
set "PS_BLUE=Blue"
set "PS_GREEN=Green"
set "PS_YELLOW=Yellow"
set "PS_RED=Red"
set "PS_MAGENTA=Magenta"
set "PS_CYAN=Cyan"
set "PS_WHITE=White"
set "PS_GRAY=Gray"

REM Check for administrative privileges
net session >nul 2>&1
if errorlevel 1 (
    cls
    echo.
    echo ══════════════════════════════════════════════════════════════════
    echo            ADMINISTRATOR PRIVILEGES REQUIRED
    echo ══════════════════════════════════════════════════════════════════
    echo.
    powershell -Command "Write-Host ' The script requires administrator rights to function properly. ' -ForegroundColor Black -BackgroundColor Yellow"
    echo.
    powershell -Command "Write-Host ' Requesting elevation... ' -ForegroundColor White"
    echo.
    
    REM Create and run elevation script
    echo Set UAC = CreateObject^("Shell.Application"^) > "%temp%\getadmin.vbs"
    echo UAC.ShellExecute "%~s0", "", "", "runas", 1 >> "%temp%\getadmin.vbs"
    "%temp%\getadmin.vbs"
    
    REM Exit this instance - will continue in elevated instance
    exit /b
)

REM Clean up temporary VBScript file and set working directory
if exist "%temp%\getadmin.vbs" del "%temp%\getadmin.vbs"
cd /d "%~dp0"

REM =========================================================================
REM Initialize Environment Variables
REM =========================================================================

REM Retrieve BlueStacks installation path from registry
set "defaultDirectory="
for /f "tokens=2*" %%a in ('reg query "HKEY_LOCAL_MACHINE\SOFTWARE\BlueStacks_nxt" /v "UserDefinedDir" 2^>nul') do (
    set "defaultDirectory=%%b"
)

REM Handle missing registry entry
if not defined defaultDirectory (
    echo Warning: BlueStacks registry entry not found.
    powershell -Command "Write-Host '  Please use option 10 to set the correct path. ' -ForegroundColor Black -BackgroundColor Yellow"
    set "defaultDirectory=%ProgramData%\BlueStacks_nxt"
)

REM Load custom directory from config file or use default
if exist "%~dp0bluestacksconfig.txt" (
    set /p customDirectory=<"%~dp0bluestacksconfig.txt"
    if "!customDirectory!"=="" set "customDirectory=!defaultDirectory!"
    if not exist "!customDirectory!" (
        echo Custom directory in bluestacksconfig.txt does not exist. Reverting to default.
        set "customDirectory=!defaultDirectory!"
    )
) else (
    set "customDirectory=!defaultDirectory!"
)

REM Remove trailing spaces and slashes from custom directory
set "customDirectory=!customDirectory: =!"
if "!customDirectory:~-1!"=="\" set "customDirectory=!customDirectory:~0,-1!"
if "!customDirectory:~-1!"=="/" set "customDirectory=!customDirectory:~0,-1!"

REM =========================================================================
REM Utility Functions
REM =========================================================================

call :main_menu
exit /b

REM Function to draw a line
:draw_line
    set "char=%~1"
    set "len=%~2"
    set "line="
    
    for /L %%i in (1,1,%len%) do set "line=!line!%char%"
    echo !line!
    exit /b

REM Function to draw a box with title
:draw_box
    set "title=%~1"
    set "width=%~2"
    
    call :draw_line "═" %width%
    
    set "padding=   "
    set "titleLen=0"
    set "title_text=%~1"
    
    :count_loop
    if not "!title_text!"=="" (
        set "title_text=!title_text:~1!"
        set /a "titleLen+=1"
        goto :count_loop
    )
    
    set /a "spaces=(%width%-%titleLen%-6)/2"
    set "titlePadding="
    
    if %spaces% gtr 0 (
        for /L %%i in (1,1,%spaces%) do set "titlePadding=!titlePadding! "
    ) else (
        set "titlePadding= "
    )
    
    echo ║%padding%!titlePadding!%title%!titlePadding!%padding%║
    call :draw_line "═" %width%
    exit /b

REM Function to display a section header
:section_header
    powershell -Command "Write-Host ''; Write-Host ' %~1 ' -ForegroundColor Black -BackgroundColor %~2; Write-Host ''"
    exit /b

REM Function to show progress bar
:show_progress
    set "percent=%~1"
    set "message=%~2"
    set "barSize=40"
    set /a "filled=(%percent%*%barSize%)/100"
    set /a "empty=%barSize%-%filled%"

    set "bar=["
    for /L %%i in (1,1,%filled%) do set "bar=!bar!█"
    for /L %%i in (1,1,%empty%) do set "bar=!bar!░"
    set "bar=!bar!] %percent%%%"

    echo %message% !bar!
    exit /b

REM Function to terminate BlueStacks processes
:terminate_processes
    echo  • Closing BlueStacks Multi-Instance Manager...
    taskkill /F /IM "HD-MultiInstanceManager.exe" 2>nul
    
    echo  • Closing BlueStacks Player...
    taskkill /F /IM "HD-Player.exe" 2>nul
    
    echo  • Closing BlueStacks Helper...
    taskkill /F /IM "BlueStacksHelper.exe" 2>nul
    
    echo  • Closing BlueStacks Services...
    taskkill /F /IM "BstkSVC.exe" 2>nul
    taskkill /F /IM "BlueStacksServices.exe" 2>nul
    
    ping -n 1 127.0.0.1 > nul
    exit /b

REM Function to initialize paths
:initialize_paths
    set "ENGINE_PATH=%customDirectory%\Engine"
    set "CONF_FILE=%customDirectory%\bluestacks.conf"
    set "TEMP_FILE=%CONF_FILE%.tmp"
    exit /b

REM Function to detect BlueStacks instance
:detect_instance
    set "pattern=%~1"
    powershell -Command "Write-Host ' Automatically detecting instance... ' -ForegroundColor Cyan"
    echo  Please ensure you've run the target instance at least once.
    echo.
    echo  Scanning logs for %pattern% instances...
    
    REM Set the log file path correctly by starting from Engine path and going up one level
    powershell -Command "$enginePath = '!ENGINE_PATH!'; $logPath = $enginePath -replace '\\Engine$',''; $logFile = Join-Path $logPath 'Logs\Player.log'; Write-Output $logFile" > "%temp%\logpath.txt"
    set /p LOG_FILE=<"%temp%\logpath.txt"
    del "%temp%\logpath.txt" >nul 2>&1
    
    if not exist "!LOG_FILE!" (
        powershell -Command "Write-Host ' ERROR: ' -NoNewline -ForegroundColor Black -BackgroundColor Red; Write-Host ' Log file not found (!LOG_FILE!). Please run BlueStacks at least once.' -ForegroundColor Red"
        pause
        set "detectedInstance=%pattern%"
        exit /b
    )
    
    REM Check log file size
    for /f "tokens=*" %%a in ('powershell -Command "if (Test-Path '!LOG_FILE!') { Write-Output ((Get-Item '!LOG_FILE!').Length / 1MB) }"') do (
        set "fileSize=%%a"
    )
    
    REM If log file too large, delete it
    set /a "fileSizeInt=!fileSize!"
    if !fileSizeInt! gtr 10 (
        del "!LOG_FILE!" /f
        powershell -Command "Write-Host ' ERROR: ' -NoNewline -ForegroundColor Black -BackgroundColor Red; Write-Host ' Log file too large and deleted. Rerun your instance and retry.' -ForegroundColor Red"
        pause
        set "detectedInstance=%pattern%"
        exit /b
    )
    
    REM Detect instance from log - improved to match main.cmd's approach
    powershell -Command "Write-Host ' DEBUG: ' -NoNewline -ForegroundColor Black -BackgroundColor Gray; Write-Host ' Searching for %pattern% instances in !LOG_FILE! ' -ForegroundColor Gray"
    
    for /f "delims=" %%i in ('powershell -Command "$logFile = '!LOG_FILE!'; $pattern = '%pattern%'; $logContent = Get-Content $logFile -ReadCount 0; $instanceNumber = $logContent | Select-String ($pattern + '(_\d+)?') -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Value } | Select-Object -Last 1; if($instanceNumber) { Write-Output $instanceNumber } else { Write-Output $pattern }"') do (
        powershell -Command "Write-Host ' DETECTED: ' -NoNewline -ForegroundColor Black -BackgroundColor Green; Write-Host ' Found instance %%i' -ForegroundColor Green"
        set "detectedInstance=%%i"
    )
    
    if not defined detectedInstance set "detectedInstance=!pattern!"
    
    echo  The program will process: !detectedInstance!
    ping -n 2 127.0.0.1 > nul
    echo.
    exit /b

REM Function to prompt for BlueStacks path
:prompt_for_path
    echo.
    powershell -Command "Write-Host ' Configuration file not found.' -ForegroundColor Yellow"
    powershell -Command "Write-Host ' The default path is C:\ProgramData\BlueStacks_nxt' -ForegroundColor Cyan"
    echo.
    set /p "BLUESTACKS_PATH=Please enter your BlueStacks_nxt directory: "
    
    REM Use default if empty
    if "!BLUESTACKS_PATH!"=="" set "BLUESTACKS_PATH=%ProgramData%\BlueStacks_nxt"
    
    REM Trim trailing characters
    if "!BLUESTACKS_PATH:~-1!"=="\" set "BLUESTACKS_PATH=!BLUESTACKS_PATH:~0,-1!"
    if "!BLUESTACKS_PATH:~-1!"=="/" set "BLUESTACKS_PATH=!BLUESTACKS_PATH:~0,-1!"
    
    set "customDirectory=!BLUESTACKS_PATH!"
    set "ENGINE_PATH=!BLUESTACKS_PATH!\Engine"
    set "CONF_FILE=!BLUESTACKS_PATH!\bluestacks.conf"
    set "TEMP_FILE=!CONF_FILE!.tmp"
    
    attrib -R "!CONF_FILE!" 2>nul
    attrib -R "!TEMP_FILE!" 2>nul
    exit /b

REM =========================================================================
REM Main Menu Function
REM =========================================================================
:main_menu
    cls
    REM Display logo and menu with multiple PowerShell commands as in the original
    powershell -Command "Write-Host ''"
    powershell -Command "Write-Host ' ██████╗ ██╗     ██╗   ██╗███████╗███████╗████████╗ █████╗  ██████╗██╗  ██╗███████╗' -ForegroundColor Blue"
    powershell -Command "Write-Host ' ██╔══██╗██║     ██║   ██║██╔════╝██╔════╝╚══██╔══╝██╔══██╗██╔════╝██║ ██╔╝██╔════╝' -ForegroundColor Blue"
    powershell -Command "Write-Host ' ██████╔╝██║     ██║   ██║█████╗  ███████╗   ██║   ███████║██║     █████╔╝ ███████╗' -ForegroundColor Blue"
    powershell -Command "Write-Host ' ██╔══██╗██║     ██║   ██║██╔══╝  ╚════██║   ██║   ██╔══██║██║     ██╔═██╗ ╚════██║' -ForegroundColor Blue"
    powershell -Command "Write-Host ' ██████╔╝███████╗╚██████╔╝███████╗███████║   ██║   ██║  ██║╚██████╗██║  ██╗███████║' -ForegroundColor Blue"
    powershell -Command "Write-Host ' ╚═════╝ ╚══════╝ ╚═════╝ ╚══════╝╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝╚══════╝' -ForegroundColor Blue"
    powershell -Command "Write-Host ''"
    powershell -Command "Write-Host ' ██████╗  ██████╗  ██████╗ ████████╗    ████████╗ ██████╗  ██████╗ ██╗     ' -ForegroundColor Cyan"
    powershell -Command "Write-Host ' ██╔══██╗██╔═══██╗██╔═══██╗╚══██╔══╝    ╚══██╔══╝██╔═══██╗██╔═══██╗██║     ' -ForegroundColor Cyan"
    powershell -Command "Write-Host ' ██████╔╝██║   ██║██║   ██║   ██║          ██║   ██║   ██║██║   ██║██║     ' -ForegroundColor Cyan"
    powershell -Command "Write-Host ' ██╔══██╗██║   ██║██║   ██║   ██║          ██║   ██║   ██║██║   ██║██║     ' -ForegroundColor Cyan"
    powershell -Command "Write-Host ' ██║  ██║╚██████╔╝╚██████╔╝   ██║          ██║   ╚██████╔╝╚██████╔╝███████╗' -ForegroundColor Cyan"
    powershell -Command "Write-Host ' ╚═╝  ╚═╝ ╚═════╝  ╚═════╝    ╚═╝          ╚═╝    ╚═════╝  ╚═════╝ ╚══════╝  v%VERSION%' -ForegroundColor Cyan"
    echo.
    
    call :draw_box "MAIN MENU" 70
    echo.

    REM Root options section
    call :section_header "ROOT OPTIONS" %PS_GREEN%
    powershell -Command "Write-Host ' [1] ' -NoNewline -ForegroundColor Black -BackgroundColor Green; Write-Host ' Android 7  (Nougat32)  ' -NoNewline -ForegroundColor Green; Write-Host '  Enable root access for Android 7'"
    powershell -Command "Write-Host ' [2] ' -NoNewline -ForegroundColor Black -BackgroundColor Green; Write-Host ' Android 9  (Pie64)     ' -NoNewline -ForegroundColor Green; Write-Host '  Enable root access for Android 9'"
    powershell -Command "Write-Host ' [3] ' -NoNewline -ForegroundColor Black -BackgroundColor Green; Write-Host ' Android 11 (Rvc64)     ' -NoNewline -ForegroundColor Green; Write-Host '  Enable root access for Android 11'"
    powershell -Command "Write-Host ' [4] ' -NoNewline -ForegroundColor Black -BackgroundColor Green; Write-Host ' Android 13 (Tiramisu64)' -NoNewline -ForegroundColor Green; Write-Host '  Enable root access for Android 13'"

    REM Unroot options section
    call :section_header "UNROOT OPTIONS" %PS_YELLOW%
    powershell -Command "Write-Host ' [5] ' -NoNewline -ForegroundColor Black -BackgroundColor Yellow; Write-Host ' Android 7  (Nougat32)  ' -NoNewline -ForegroundColor Yellow; Write-Host '  Disable root access for Android 7'"
    powershell -Command "Write-Host ' [6] ' -NoNewline -ForegroundColor Black -BackgroundColor Yellow; Write-Host ' Android 9  (Pie64)     ' -NoNewline -ForegroundColor Yellow; Write-Host '  Disable root access for Android 9'"
    powershell -Command "Write-Host ' [7] ' -NoNewline -ForegroundColor Black -BackgroundColor Yellow; Write-Host ' Android 11 (Rvc64)     ' -NoNewline -ForegroundColor Yellow; Write-Host '  Disable root access for Android 11'"
    powershell -Command "Write-Host ' [8] ' -NoNewline -ForegroundColor Black -BackgroundColor Yellow; Write-Host ' Android 13 (Tiramisu64)' -NoNewline -ForegroundColor Yellow; Write-Host '  Disable root access for Android 13'"

    REM Other options section
    call :section_header "OTHER OPTIONS" %PS_CYAN%
    powershell -Command "Write-Host ' [9]  ' -NoNewline -ForegroundColor Black -BackgroundColor Cyan; Write-Host ' Final Undo Root       ' -NoNewline -ForegroundColor Cyan; Write-Host '  Disable root after Magisk system install'"
    powershell -Command "Write-Host ' [10] ' -NoNewline -ForegroundColor Black -BackgroundColor Cyan; Write-Host ' Set Custom Path       ' -NoNewline -ForegroundColor Cyan; Write-Host '  Configure BlueStacks installation path'"
    powershell -Command "Write-Host ' [11] ' -NoNewline -ForegroundColor Black -BackgroundColor Cyan; Write-Host ' About                 ' -NoNewline -ForegroundColor Cyan; Write-Host '  Information about this tool'"
    powershell -Command "Write-Host ' [12] ' -NoNewline -ForegroundColor Black -BackgroundColor Cyan; Write-Host ' Help                  ' -NoNewline -ForegroundColor Cyan; Write-Host '  Show instructions and troubleshooting'"
    powershell -Command "Write-Host ' [0]  ' -NoNewline -ForegroundColor Black -BackgroundColor Red; Write-Host ' Exit                  ' -NoNewline -ForegroundColor Red; Write-Host '  Close this application'"

    REM Status bar
    echo.
    call :draw_line "─" 70
    powershell -Command "Write-Host ' Current Path: ' -NoNewline -ForegroundColor Magenta; Write-Host '!customDirectory!' -ForegroundColor White;"
    call :draw_line "─" 70
    echo.

    REM Get user choice
    set "choice="
    set /p "choice=Enter option number (0-12): "
    if not defined choice set "choice=0"

    REM Process user choice
    if "%choice%"=="0" (
        cls
        echo.
        call :draw_box "THANK YOU FOR USING %SCRIPT_NAME%" 70
        echo.
        powershell -Command "Write-Host ' Exiting...                                                          ' -ForegroundColor Gray"
        ping -n 2 127.0.0.1 > nul
        exit /b
    )

    if "%choice%"=="11" (
        call :show_about
        goto :main_menu
    )

    if "%choice%"=="12" (
        call :show_help
        goto :main_menu
    )

    REM Root options (1-4)
    if "%choice%" geq "1" if "%choice%" leq "4" (
        set /a androidIndex=%choice% - 1
        set "androidVersions=Nougat32 Pie64 Rvc64 Tiramisu64"
        
        for /f "tokens=%androidIndex% delims= " %%a in ("%androidVersions%") do (
            set "clonedVersion=%%a"
        )
        
        if "%choice%"=="1" (
            powershell -Command "Write-Host ''; Write-Host ' IMPORTANT: ' -NoNewline -ForegroundColor Black -BackgroundColor Yellow; Write-Host ' You chose to root Android 7 (Nougat32)' -ForegroundColor Yellow"
            powershell -Command "Write-Host '          Please edit the bat file and replace Nougat32 with Nougat64 if using 64-bit Android 7' -ForegroundColor Yellow"
            ping -n 3 127.0.0.1 > nul
        )
        
        call :apply_changes
        goto :main_menu
    )

    REM Unroot options (5-8)
    if "%choice%" geq "5" if "%choice%" leq "8" (
        set /a androidIndex=%choice% - 5
        set "androidVersions=Nougat32 Pie64 Rvc64 Tiramisu64"
        
        for /f "tokens=%androidIndex% delims= " %%a in ("%androidVersions%") do (
            set "clonedVersion=%%a"
        )
        
        call :undo_both_changes
        goto :main_menu
    )

    REM Other options
    if "%choice%"=="9" (
        call :undo_all_changes_final
        goto :main_menu
    ) else if "%choice%"=="10" (
        call :set_custom_path
        goto :main_menu
    ) else (
        echo.
        powershell -Command "Write-Host ' Invalid option. Please enter a number between 0 and 12. ' -ForegroundColor Black -BackgroundColor Red"
        ping -n 2 127.0.0.1 > nul
        goto :main_menu
    )
    exit /b

REM =========================================================================
REM Display functions
REM =========================================================================

REM Show the About screen
:show_about
    cls
    echo.
    powershell -Command "Write-Host ' ██████╗ ██╗     ██╗   ██╗███████╗███████╗████████╗ █████╗  ██████╗██╗  ██╗███████╗' -ForegroundColor Blue"
    powershell -Command "Write-Host ' ██╔══██╗██║     ██║   ██║██╔════╝██╔════╝╚══██╔══╝██╔══██╗██╔════╝██║ ██╔╝██╔════╝' -ForegroundColor Blue"
    powershell -Command "Write-Host ' ██████╔╝██║     ██║   ██║█████╗  ███████╗   ██║   ███████║██║     █████╔╝ ███████╗' -ForegroundColor Blue"
    powershell -Command "Write-Host ' ██╔══██╗██║     ██║   ██║██╔══╝  ╚════██║   ██║   ██╔══██║██║     ██╔═██╗ ╚════██║' -ForegroundColor Blue"
    powershell -Command "Write-Host ' ██████╔╝███████╗╚██████╔╝███████╗███████║   ██║   ██║  ██║╚██████╗██║  ██╗███████║' -ForegroundColor Blue"
    powershell -Command "Write-Host ' ╚═════╝ ╚══════╝ ╚═════╝ ╚══════╝╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝╚══════╝' -ForegroundColor Blue"
    powershell -Command "Write-Host ''"
    powershell -Command "Write-Host ' ██████╗  ██████╗  ██████╗ ████████╗    ████████╗ ██████╗  ██████╗ ██╗     ' -ForegroundColor Cyan"
    powershell -Command "Write-Host ' ██╔══██╗██╔═══██╗██╔═══██╗╚══██╔══╝    ╚══██╔══╝██╔═══██╗██╔═══██╗██║     ' -ForegroundColor Cyan"
    powershell -Command "Write-Host ' ██████╔╝██║   ██║██║   ██║   ██║          ██║   ██║   ██║██║   ██║██║     ' -ForegroundColor Cyan"
    powershell -Command "Write-Host ' ██╔══██╗██║   ██║██║   ██║   ██║          ██║   ██║   ██║██║   ██║██║     ' -ForegroundColor Cyan"
    powershell -Command "Write-Host ' ██║  ██║╚██████╔╝╚██████╔╝   ██║          ██║   ╚██████╔╝╚██████╔╝███████╗' -ForegroundColor Cyan"
    powershell -Command "Write-Host ' ╚═╝  ╚═╝ ╚═════╝  ╚═════╝    ╚═╝          ╚═╝    ╚═════╝  ╚═════╝ ╚══════╝  v%VERSION%' -ForegroundColor Cyan"
    echo.
    call :draw_box "ABOUT %SCRIPT_NAME% v%VERSION%" 70
    echo.
    powershell -Command "Write-Host ' Description:' -ForegroundColor Cyan -NoNewline; Write-Host ' A tool to easily root BlueStacks 5 instances'"
    powershell -Command "Write-Host ' Author:     ' -ForegroundColor Cyan -NoNewline; Write-Host ' Jordan231111'"
    powershell -Command "Write-Host ' Repository: ' -ForegroundColor Cyan -NoNewline; Write-Host ' https://github.com/Jordan231111/BluestacksRoot'"
    powershell -Command "Write-Host ' Version:    ' -ForegroundColor Cyan -NoNewline; Write-Host ' %VERSION% (%SCRIPT_DATE%)'"
    powershell -Command "Write-Host ' License:    ' -ForegroundColor Cyan -NoNewline; Write-Host ' Creative Commons Attribution-NonCommercial-NoDerivatives 4.0'"
    echo.
    call :draw_line "─" 70
    echo.
    powershell -Command "Write-Host ' Features:' -ForegroundColor Cyan"
    echo   • Root BlueStacks 5 Android instances (Nougat32, Pie64, Rvc64, Tiramisu64)
    echo   • Switch between rooted and unrooted configurations
    echo   • Maintain separate environments for rooted and unrooted instances
    echo   • Support for all recent BlueStacks 5 versions
    echo.
    call :draw_line "─" 70
    echo.
    powershell -Command "Write-Host ' Support/Donation:' -ForegroundColor Cyan"
    echo   • https://ko-fi.com/yejordan
    echo   • https://buymeacoffee.com/yejordan
    echo.
    call :draw_line "─" 70
    echo.
    powershell -Command "Write-Host ' Press any key to return to the main menu...' -ForegroundColor Gray"
    pause >nul
    exit /b

REM Show the Help screen
:show_help
    cls
    echo.
    powershell -Command "Write-Host ' ██████╗ ██╗     ██╗   ██╗███████╗███████╗████████╗ █████╗  ██████╗██╗  ██╗███████╗' -ForegroundColor Blue"
    powershell -Command "Write-Host ' ██╔══██╗██║     ██║   ██║██╔════╝██╔════╝╚══██╔══╝██╔══██╗██╔════╝██║ ██╔╝██╔════╝' -ForegroundColor Blue"
    powershell -Command "Write-Host ' ██████╔╝██║     ██║   ██║█████╗  ███████╗   ██║   ███████║██║     █████╔╝ ███████╗' -ForegroundColor Blue"
    powershell -Command "Write-Host ' ██╔══██╗██║     ██║   ██║██╔══╝  ╚════██║   ██║   ██╔══██║██║     ██╔═██╗ ╚════██║' -ForegroundColor Blue"
    powershell -Command "Write-Host ' ██████╔╝███████╗╚██████╔╝███████╗███████║   ██║   ██║  ██║╚██████╗██║  ██╗███████║' -ForegroundColor Blue"
    powershell -Command "Write-Host ' ╚═════╝ ╚══════╝ ╚═════╝ ╚══════╝╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝╚══════╝' -ForegroundColor Blue"
    echo.
    call :draw_box "HELP & INSTRUCTIONS" 70
    echo.
    powershell -Command "Write-Host ' HOW TO USE:' -ForegroundColor Cyan"
    echo.
    powershell -Command "Write-Host ' 1. Root Options (1-4):' -ForegroundColor Yellow"
    echo    Use these options to enable root access for specific Android versions.
    echo    Make sure to first install Magisk on the instance you want to root.
    echo.
    powershell -Command "Write-Host ' 2. Unroot Options (5-8):' -ForegroundColor Yellow"
    echo    Use these to disable root for specific Android versions.
    echo    This returns instances to their default unrooted state.
    echo.
    powershell -Command "Write-Host ' 3. Final Undo Root (Option 9):' -ForegroundColor Yellow"
    echo    Apply this after installing Magisk to system partition when
    echo    you receive the SU conflict message in the Magisk app.
    echo.
    powershell -Command "Write-Host ' 4. Other Options:' -ForegroundColor Yellow"
    echo    • Set Custom Path: Configure where BlueStacks is installed
    echo    • About: View information about the tool
    echo    • Help: Show this help screen
    echo    • Exit: Close the application
    echo.
    call :draw_line "─" 70
    echo.
    powershell -Command "Write-Host ' STEP BY STEP GUIDE:' -ForegroundColor Cyan"
    echo.
    echo   1. Download all required script files from the repository
    echo   2. Run split.cmd ONCE to prepare your environment
    echo   3. Use RootJunction.cmd to switch to root mode
    echo   4. Create the instances you want to root
    echo   5. Install Magisk on each instance to be rooted
    echo   6. Run this tool and select the appropriate root option
    echo   7. After getting SU conflict message, run Final Undo Root
    echo   8. Use UnRootJunction.cmd to switch between modes as needed
    echo.
    call :draw_line "─" 70
    echo.
    powershell -Command "Write-Host ' TROUBLESHOOTING:' -ForegroundColor Cyan"
    echo.
    echo  • Ensure BlueStacks is completely closed before running the script
    echo  • For Android 7 (Nougat32), replace with Nougat64 if using 64-bit version
    echo  • Make sure proper Magisk version is used for your Android version
    echo  • For errors, check the BlueStacks path is correctly set
    echo  • If stuck, try undoing changes with options 5-9
    echo.
    powershell -Command "Write-Host ' For more details, please check the README.md file in the repository.' -ForegroundColor Gray"
    echo.
    call :draw_line "─" 70
    echo.
    powershell -Command "Write-Host ' Press any key to return to the main menu...' -ForegroundColor Gray"
    pause >nul
    exit /b

REM =========================================================================
REM Root Operations Functions
REM =========================================================================
:apply_changes
    REM Show operation header
    cls
    call :draw_box "APPLYING ROOT - %clonedVersion%" 70
    echo.
    
    REM Terminate processes with visual feedback
    powershell -Command "Write-Host ' [1/5] ' -NoNewline -ForegroundColor Black -BackgroundColor Cyan; Write-Host ' Terminating BlueStacks processes...                           ' -ForegroundColor Cyan"
    call :terminate_processes
    call :show_progress 20 " Progress:"
    
    powershell -Command "Write-Host ' [2/5] ' -NoNewline -ForegroundColor Black -BackgroundColor Cyan; Write-Host ' Initializing paths...                                        ' -ForegroundColor Cyan"
    call :initialize_paths
    call :show_progress 40 " Progress:"

    REM Verify configuration file exists
    if not exist "%CONF_FILE%" (
        powershell -Command "Write-Host ' ALERT: ' -NoNewline -ForegroundColor Black -BackgroundColor Yellow; Write-Host ' Configuration file not found. Prompting for path...     ' -ForegroundColor Yellow"
        call :prompt_for_path
        if not exist "!CONF_FILE!" (
            powershell -Command "Write-Host ' ERROR: ' -NoNewline -ForegroundColor Black -BackgroundColor Red; Write-Host ' Configuration file still not found. Please rerun and use option 10.' -ForegroundColor Red"
            pause
            exit /b
        )
    )

    REM Detect the cloned instance
    powershell -Command "Write-Host ' [3/5] ' -NoNewline -ForegroundColor Black -BackgroundColor Cyan; Write-Host ' Detecting instance...                                         ' -ForegroundColor Cyan"
    call :detect_instance "%clonedVersion%"
    set "version=%detectedInstance%"
    set "XML_FILE=%customDirectory%\Engine\%version%\%version%.bstk"
    call :show_progress 60 " Progress:"

    REM Verify XML file exists
    if not exist "%XML_FILE%" (
        powershell -Command "Write-Host ' ERROR: ' -NoNewline -ForegroundColor Black -BackgroundColor Red; Write-Host ' Android emulator not installed, not run at least once, or wrong instance chosen.' -ForegroundColor Red"
        pause
        exit /b
    )

    REM Set BLUESTACKS_PATH for exclusions
    for %%i in ("%CONF_FILE%") do set "BLUESTACKS_PATH=%%~dpi"

    REM Temporarily exclude paths from Windows Defender
    powershell -Command "Write-Host ' [4/5] ' -NoNewline -ForegroundColor Black -BackgroundColor Cyan; Write-Host ' Setting up environment...                                     ' -ForegroundColor Cyan"
    powershell -Command ^
        "Try { Add-MpPreference -ExclusionPath '%BLUESTACKS_PATH%','%~dp0' -ErrorAction SilentlyContinue; ^
        Write-Host ' INFO: ' -NoNewline -ForegroundColor Black -BackgroundColor Gray; Write-Host ' Added exclusions for: %BLUESTACKS_PATH%, %~dp0' -ForegroundColor Gray } ^
        Catch { Write-Host ' INFO: ' -NoNewline -ForegroundColor Black -BackgroundColor Gray; Write-Host ' No Windows antivirus detected or exclusions not required.' -ForegroundColor Gray }"
    call :show_progress 80 " Progress:"

    REM Backup files
    attrib -R "%XML_FILE%.bak" 2>nul
    copy "%XML_FILE%" "%XML_FILE%.bak" /Y >nul
    attrib -R "%CONF_FILE%.bak" 2>nul
    copy "%CONF_FILE%" "%CONF_FILE%.bak" /Y >nul

    REM Modify XML file (make disks writable)
    powershell -Command "Write-Host ' [5/5] ' -NoNewline -ForegroundColor Black -BackgroundColor Cyan; Write-Host ' Applying root changes...                                      ' -ForegroundColor Cyan"
    
    attrib -R "%XML_FILE%"
    copy "%XML_FILE%" "%TEMP_FILE%" /Y >nul
    powershell -Command "(Get-Content '%TEMP_FILE%') -replace 'type=\"ReadOnly\"', 'type=\"Normal\"' | Set-Content '%TEMP_FILE%'"
    move /Y "%TEMP_FILE%" "%XML_FILE%" >nul
    
    REM Modify configuration file (enable root for all instances)
    attrib -R "%CONF_FILE%"
    copy "%CONF_FILE%" "%TEMP_FILE%" /Y >nul
    powershell -Command ^
        "$baseVersion = '%clonedVersion%'; ^
        (Get-Content '%TEMP_FILE%') -replace ^
        ('(^bst\.instance\.' + [regex]::Escape($baseVersion) + '(_\\d+)?\.enable_root_access=)\"0\"'), ^
        '$1\"1\"' -replace 'bst.feature.rooting=\"0\"', 'bst.feature.rooting=\"1\"' | ^
        Set-Content '%TEMP_FILE%'"
    move /Y "%TEMP_FILE%" "%CONF_FILE%" >nul
    
    call :show_progress 100 " Progress:"

    REM Notify success and clean up
    echo.
    powershell -Command "Write-Host ' OPERATION COMPLETE ' -ForegroundColor Black -BackgroundColor Green"
    echo.
    powershell -Command "Write-Host ' Root access has been successfully enabled for %version%.' -ForegroundColor Green"
    echo.
    powershell -Command "Write-Host ' NOTE: ' -NoNewline -ForegroundColor Black -BackgroundColor Yellow; Write-Host ' If you suspect bluestacks.conf corruption, select undo immediately.' -ForegroundColor Yellow"
    powershell -Command "Try { Remove-MpPreference -ExclusionPath '%~dp0' -ErrorAction SilentlyContinue } Catch {}"
    
    echo.
    call :draw_line "─" 70
    powershell -Command "Write-Host ' NEXT STEPS:' -ForegroundColor Cyan"
    echo   1. Install Magisk to the system partition using the Magisk app
    echo   2. Wait for the SU conflict message in the Magisk app
    echo   3. Restart your BlueStacks instance
    echo   4. Run the Final Undo Root option (9) after installation is complete
    call :draw_line "─" 70
    echo.
    
    pause
    exit /b

:undo_both_changes
    REM Show operation header
    cls
    call :draw_box "REMOVING ROOT - %clonedVersion%" 70
    echo.
    
    REM Terminate processes with visual feedback
    powershell -Command "Write-Host ' [1/5] ' -NoNewline -ForegroundColor Black -BackgroundColor Cyan; Write-Host ' Terminating BlueStacks processes...                           ' -ForegroundColor Cyan"
    call :terminate_processes
    call :show_progress 20 " Progress:"
    
    powershell -Command "Write-Host ' [2/5] ' -NoNewline -ForegroundColor Black -BackgroundColor Cyan; Write-Host ' Initializing paths...                                        ' -ForegroundColor Cyan"
    call :initialize_paths
    call :show_progress 40 " Progress:"

    REM Verify configuration file exists
    if not exist "%CONF_FILE%" (
        powershell -Command "Write-Host ' ALERT: ' -NoNewline -ForegroundColor Black -BackgroundColor Yellow; Write-Host ' Configuration file not found. Prompting for path...     ' -ForegroundColor Yellow"
        call :prompt_for_path
        if not exist "!CONF_FILE!" (
            powershell -Command "Write-Host ' ERROR: ' -NoNewline -ForegroundColor Black -BackgroundColor Red; Write-Host ' Configuration file still not found. Please rerun and use option 10.' -ForegroundColor Red"
            pause
            exit /b
        )
    )

    REM Detect the cloned instance
    powershell -Command "Write-Host ' [3/5] ' -NoNewline -ForegroundColor Black -BackgroundColor Cyan; Write-Host ' Detecting instance...                                         ' -ForegroundColor Cyan"
    call :detect_instance "%clonedVersion%"
    set "version=%detectedInstance%"
    set "XML_FILE=%customDirectory%\Engine\%version%\%version%.bstk"
    call :show_progress 60 " Progress:"

    REM Verify XML file exists
    if not exist "%XML_FILE%" (
        powershell -Command "Write-Host ' ERROR: ' -NoNewline -ForegroundColor Black -BackgroundColor Red; Write-Host ' Android emulator not installed, not run at least once, or wrong instance chosen.' -ForegroundColor Red"
        pause
        exit /b
    )

    REM Set BLUESTACKS_PATH for exclusions
    for %%i in ("%CONF_FILE%") do set "BLUESTACKS_PATH=%%~dpi"

    REM Temporarily exclude paths from Windows Defender
    powershell -Command "Write-Host ' [4/5] ' -NoNewline -ForegroundColor Black -BackgroundColor Cyan; Write-Host ' Setting up environment...                                     ' -ForegroundColor Cyan"
    powershell -Command ^
        "Try { Add-MpPreference -ExclusionPath '%BLUESTACKS_PATH%','%~dp0' -ErrorAction SilentlyContinue; ^
        Write-Host ' INFO: ' -NoNewline -ForegroundColor Black -BackgroundColor Gray; Write-Host ' Added exclusions for: %BLUESTACKS_PATH%, %~dp0' -ForegroundColor Gray } ^
        Catch { Write-Host ' INFO: ' -NoNewline -ForegroundColor Black -BackgroundColor Gray; Write-Host ' No Windows antivirus detected or exclusions not required.' -ForegroundColor Gray }"
    call :show_progress 80 " Progress:"

    REM Revert XML file (restore read-only disks)
    powershell -Command "Write-Host ' [5/5] ' -NoNewline -ForegroundColor Black -BackgroundColor Cyan; Write-Host ' Removing root access...                                       ' -ForegroundColor Cyan"

    attrib -R "%XML_FILE%"
    copy "%XML_FILE%" "%TEMP_FILE%" /Y >nul
    powershell -Command ^
        "(Get-Content '%TEMP_FILE%') | ForEach-Object { ^
            if ($_ -match 'location=\"fastboot.vdi\"' -or $_ -match 'location=\"Root.vhd\"') { ^
                $_ -replace 'type=\"Normal\"', 'type=\"ReadOnly\"' ^
            } else { ^
                $_ ^
            } ^
        } | Set-Content '%TEMP_FILE%'"
    
    if errorlevel 1 (
        powershell -Command "Write-Host ' ERROR: ' -NoNewline -ForegroundColor Black -BackgroundColor Red; Write-Host ' Failed to revert XML changes. Restoring from backup...' -ForegroundColor Red"
        copy "%XML_FILE%.bak" "%XML_FILE%" /Y >nul
        pause
        exit /b
    )
    
    move /Y "%TEMP_FILE%" "%XML_FILE%" >nul

    REM Revert configuration file (disable root)
    attrib -R "%CONF_FILE%"
    copy "%CONF_FILE%" "%TEMP_FILE%" /Y >nul
    powershell -Command ^
        "(Get-Content '%TEMP_FILE%') -replace ^
        'bst.instance.%version%.enable_root_access=\"1\"', ^
        'bst.instance.%version%.enable_root_access=\"0\"' -replace ^
        'bst.feature.rooting=\"1\"', 'bst.feature.rooting=\"0\"' | ^
        Set-Content '%TEMP_FILE%'"
    
    if errorlevel 1 (
        powershell -Command "Write-Host ' ERROR: ' -NoNewline -ForegroundColor Black -BackgroundColor Red; Write-Host ' Failed to revert conf changes. Restoring from backup...' -ForegroundColor Red"
        copy "%CONF_FILE%.bak" "%CONF_FILE%" /Y >nul
        pause
        exit /b
    )
    
    move /Y "%TEMP_FILE%" "%CONF_FILE%" >nul
    call :show_progress 100 " Progress:"

    REM Notify success and clean up
    echo.
    powershell -Command "Write-Host ' OPERATION COMPLETE ' -ForegroundColor Black -BackgroundColor Green"
    echo.
    powershell -Command "Write-Host ' Root access has been successfully disabled for %version%.' -ForegroundColor Green"
    powershell -Command "Try { Remove-MpPreference -ExclusionPath '%~dp0' -ErrorAction SilentlyContinue } Catch {}"
    
    echo.
    pause
    exit /b

:undo_all_changes_final
    REM Show operation header
    cls
    call :draw_box "FINAL UNDO ROOT (AFTER MAGISK SYSTEM INSTALL)" 70
    echo.
    
    REM Terminate processes with visual feedback
    powershell -Command "Write-Host ' [1/6] ' -NoNewline -ForegroundColor Black -BackgroundColor Cyan; Write-Host ' Terminating BlueStacks processes...                           ' -ForegroundColor Cyan"
    call :terminate_processes
    call :show_progress 15 " Progress:"

    REM Prompt for version selection with improved UI
    powershell -Command ^
        "Write-Host ' [2/6] ' -NoNewline -ForegroundColor Black -BackgroundColor Cyan; Write-Host ' Select Android version to finalize:                              ' -ForegroundColor Cyan"
    echo.
    echo   Select the Android version you've installed Magisk to:
    echo.
    powershell -Command "Write-Host '   [1] ' -NoNewline -ForegroundColor Black -BackgroundColor Green; Write-Host ' Android 7  (Nougat32)     '"
    powershell -Command "Write-Host '   [2] ' -NoNewline -ForegroundColor Black -BackgroundColor Green; Write-Host ' Android 9  (Pie64)     '"
    powershell -Command "Write-Host '   [3] ' -NoNewline -ForegroundColor Black -BackgroundColor Green; Write-Host ' Android 11 (Rvc64)     '"
    powershell -Command "Write-Host '   [4] ' -NoNewline -ForegroundColor Black -BackgroundColor Green; Write-Host ' Android 13 (Tiramisu64)'"
    echo.
    
    set "version_choice="
    set /p "version_choice=Enter option number (1-4): "
    if not defined version_choice set "version_choice=0"

    set "androidVersions=Nougat32 Pie64 Rvc64 Tiramisu64"
    if "%version_choice%" geq "1" if "%version_choice%" leq "4" (
        set /a androidIndex=%version_choice% - 1
        for /f "tokens=%androidIndex% delims= " %%a in ("%androidVersions%") do (
            set "clonedVersion=%%a"
        )
    ) else (
        powershell -Command "Write-Host ' ERROR: ' -NoNewline -ForegroundColor Black -BackgroundColor Red; Write-Host ' Invalid option. Please enter a number between 1 and 4.' -ForegroundColor Red"
        pause
        goto :undo_all_changes_final
    )
    call :show_progress 30 " Progress:"

    powershell -Command "Write-Host ' [3/6] ' -NoNewline -ForegroundColor Black -BackgroundColor Cyan; Write-Host ' Initializing paths...                                        ' -ForegroundColor Cyan"
    call :initialize_paths
    call :show_progress 45 " Progress:"

    REM Verify configuration file exists
    if not exist "%CONF_FILE%" (
        powershell -Command "Write-Host ' ALERT: ' -NoNewline -ForegroundColor Black -BackgroundColor Yellow; Write-Host ' Configuration file not found. Prompting for path...     ' -ForegroundColor Yellow"
        call :prompt_for_path
        if not exist "!CONF_FILE!" (
            powershell -Command "Write-Host ' ERROR: ' -NoNewline -ForegroundColor Black -BackgroundColor Red; Write-Host ' Configuration file still not found. Please rerun and use option 10.' -ForegroundColor Red"
            pause
            exit /b
        )
    )

    REM Detect the cloned instance
    powershell -Command "Write-Host ' [4/6] ' -NoNewline -ForegroundColor Black -BackgroundColor Cyan; Write-Host ' Detecting instance...                                         ' -ForegroundColor Cyan"
    call :detect_instance "%clonedVersion%"
    set "version=%detectedInstance%"
    set "XML_FILE=%customDirectory%\Engine\%version%\%version%.bstk"
    call :show_progress 60 " Progress:"

    REM Verify XML file exists
    if not exist "%XML_FILE%" (
        powershell -Command "Write-Host ' ERROR: ' -NoNewline -ForegroundColor Black -BackgroundColor Red; Write-Host ' Android emulator not installed, not run at least once, or wrong instance chosen.' -ForegroundColor Red"
        pause
        exit /b
    )

    REM Set BLUESTACKS_PATH for exclusions
    for %%i in ("%CONF_FILE%") do set "BLUESTACKS_PATH=%%~dpi"

    REM Temporarily exclude paths from Windows Defender
    powershell -Command "Write-Host ' [5/6] ' -NoNewline -ForegroundColor Black -BackgroundColor Cyan; Write-Host ' Setting up environment...                                     ' -ForegroundColor Cyan"
    powershell -Command ^
        "Try { Add-MpPreference -ExclusionPath '%BLUESTACKS_PATH%','%~dp0' -ErrorAction SilentlyContinue; ^
        Write-Host ' INFO: ' -NoNewline -ForegroundColor Black -BackgroundColor Gray; Write-Host ' Added exclusions for: %BLUESTACKS_PATH%, %~dp0' -ForegroundColor Gray } ^
        Catch { Write-Host ' INFO: ' -NoNewline -ForegroundColor Black -BackgroundColor Gray; Write-Host ' No Windows antivirus detected or exclusions not required.' -ForegroundColor Gray }"
    call :show_progress 75 " Progress:"

    REM Revert XML file (restore read-only disks)
    powershell -Command "Write-Host ' [6/6] ' -NoNewline -ForegroundColor Black -BackgroundColor Cyan; Write-Host ' Applying final changes...                                     ' -ForegroundColor Cyan"
    
    attrib -R "%XML_FILE%"
    copy "%XML_FILE%" "%TEMP_FILE%" /Y >nul
    powershell -Command ^
        "(Get-Content '%TEMP_FILE%') | ForEach-Object { ^
            if ($_ -match 'location=\"fastboot.vdi\"' -or $_ -match 'location=\"Root.vhd\"') { ^
                $_ -replace 'type=\"Normal\"', 'type=\"ReadOnly\"' ^
            } else { ^
                $_ ^
            } ^
        } | Set-Content '%TEMP_FILE%'"
    
    if errorlevel 1 (
        powershell -Command "Write-Host ' ERROR: ' -NoNewline -ForegroundColor Black -BackgroundColor Red; Write-Host ' Failed to revert XML changes. Restoring from backup...' -ForegroundColor Red"
        copy "%XML_FILE%.bak" "%XML_FILE%" /Y >nul
        pause
        exit /b
    )
    
    move /Y "%TEMP_FILE%" "%XML_FILE%" >nul

    REM Revert configuration file (disable root for all instances)
    attrib -R "%CONF_FILE%"
    copy "%CONF_FILE%" "%TEMP_FILE%" /Y >nul
    powershell -Command ^
        "$baseVersion = '%clonedVersion%'; ^
        (Get-Content '%TEMP_FILE%') -replace ^
        ('(^bst\.instance\.' + [regex]::Escape($baseVersion) + '(_\\d+)?\.enable_root_access=)\"1\"'), ^
        '$1\"0\"' -replace 'bst.feature.rooting=\"1\"', 'bst.feature.rooting=\"0\"' | ^
        Set-Content '%TEMP_FILE%'"
    
    if errorlevel 1 (
        powershell -Command "Write-Host ' ERROR: ' -NoNewline -ForegroundColor Black -BackgroundColor Red; Write-Host ' Failed to revert conf changes. Restoring from backup...' -ForegroundColor Red"
        copy "%CONF_FILE%.bak" "%CONF_FILE%" /Y >nul
        pause
        exit /b
    )
    
    move /Y "%TEMP_FILE%" "%CONF_FILE%" >nul
    call :show_progress 100 " Progress:"

    REM Notify success and clean up
    echo.
    powershell -Command "Write-Host ' OPERATION COMPLETE ' -ForegroundColor Black -BackgroundColor Green"
    echo.
    powershell -Command "Write-Host ' Final changes have been applied for all %clonedVersion% instances.' -ForegroundColor Green"
    echo.
    powershell -Command "Write-Host ' NOTE: ' -NoNewline -ForegroundColor Black -BackgroundColor Cyan; Write-Host ' You can now launch both rooted and unrooted instances.' -ForegroundColor Cyan"
    powershell -Command "Try { Remove-MpPreference -ExclusionPath '%~dp0' -ErrorAction SilentlyContinue } Catch {}"
    
    echo.
    pause
    exit /b

:set_custom_path
    cls
    call :draw_box "SET CUSTOM BLUESTACKS PATH" 70
    echo.
    powershell -Command "Write-Host ' The default directory is C:\ProgramData\BlueStacks_nxt' -ForegroundColor Cyan"
    echo.
    powershell -Command "Write-Host ' Current Path: ' -NoNewline -ForegroundColor Magenta; Write-Host '!customDirectory!' -ForegroundColor White;"
    echo.
    echo  Enter the full path to your BlueStacks_nxt directory.
    echo  Leave empty to use the default path.
    echo.
    set /p "customDirectory=New Path: "
    
    REM Use default if empty
    if "!customDirectory!"=="" set "customDirectory=%ProgramData%\BlueStacks_nxt"
    
    REM Trim trailing slashes
    if "!customDirectory:~-1!"=="\" set "customDirectory=!customDirectory:~0,-1!"
    if "!customDirectory:~-1!"=="/" set "customDirectory=!customDirectory:~0,-1!"
    
    if not exist "!customDirectory!" (
        powershell -Command "Write-Host ' ERROR: ' -NoNewline -ForegroundColor Black -BackgroundColor Red; Write-Host ' The specified directory does not exist. Please try again.' -ForegroundColor Red"
        pause
        exit /b
    )
    
    powershell -Command "Write-Host ' Path set to: ' -NoNewline -ForegroundColor Green; Write-Host '!customDirectory!' -ForegroundColor White;"
    echo !customDirectory!>bluestacksconfig.txt
    powershell -Command "Write-Host ' SUCCESS: ' -NoNewline -ForegroundColor Black -BackgroundColor Green; Write-Host ' Path saved to bluestacksconfig.txt for future use.' -ForegroundColor Green"
    pause
    exit /b

REM End of script
