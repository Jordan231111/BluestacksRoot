@echo off
setlocal enabledelayedexpansion

:: =========================================================================
:: BlueStacks Root Tool - Optimized Version
:: 
:: This script enables or disables root access on BlueStacks 5
:: Android emulator instances (Nougat32, Pie64, Rvc64, Tiramisu64)
:: =========================================================================

:: Check for administrative privileges
>nul 2>&1 net session || (
    echo Requesting administrative privileges...
    echo If the script does not work, please manually run it as an administrator.
    >"%temp%\getadmin.vbs" echo Set UAC = CreateObject^("Shell.Application"^)
    >>"%temp%\getadmin.vbs" echo UAC.ShellExecute "%~s0", "", "", "runas", 1
    "%temp%\getadmin.vbs"
    exit /B
)

:: Clean up temporary VBScript file and set working directory
if exist "%temp%\getadmin.vbs" del "%temp%\getadmin.vbs"
pushd "%CD%"
cd /d "%~dp0"

:: =========================================================================
:: Initialize Environment Variables
:: =========================================================================

:: Retrieve BlueStacks installation path from registry
set "defaultDirectory="
for /f "tokens=2*" %%a in ('reg query "HKEY_LOCAL_MACHINE\SOFTWARE\BlueStacks_nxt" /v "UserDefinedDir" 2^>nul') do (
    set "defaultDirectory=%%b"
)

:: Handle missing registry entry
if not defined defaultDirectory (
    echo Warning: BlueStacks registry entry not found.
    powershell -Command "Write-Host 'Please use option 10 to set the correct path.' -ForegroundColor Red"
    set "defaultDirectory=%ProgramData%\BlueStacks_nxt"
)

:: Load custom directory from config file or use default
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

:: Remove trailing spaces and slashes from custom directory
set "customDirectory=!customDirectory: =!"
if "!customDirectory:~-1!"=="\" set "customDirectory=!customDirectory:~0,-1!"
if "!customDirectory:~-1!"=="/" set "customDirectory=!customDirectory:~0,-1!"

:: =========================================================================
:: Main Menu Function
:: =========================================================================
:start_options
cls
powershell -Command ^
"Write-Host '  ____  _                 _             _          ____             _     _____           _ ' -ForegroundColor Blue; ^
 Write-Host ' | __ )| |_   _  ___  ___| |_ __ _  ___| | _____  |  _ \ ___   ___ | |_  |_   _|__   ___ | |' -ForegroundColor Blue; ^
 Write-Host ' |  _ \| | | | |/ _ \/ __| __/ _` |/ __| |/ / __| | |_) / _ \ / _ \| __|   | |/ _ \ / _ \| |' -ForegroundColor Blue; ^
 Write-Host ' | |_) | | |_| |  __/\__ \ || (_| | (__|   <\__ \ |  _ < (_) | (_) | |_    | | (_) | (_) | |' -ForegroundColor Blue; ^
 Write-Host ' |____/|_|\__,_|\___||___/\__\__,_|\___|_|\_\___/ |_| \_\___/ \___/ \__|   |_|\___/ \___/|_|' -ForegroundColor Blue; ^
 Write-Host ''; ^
 Write-Host 'Root Options:' -ForegroundColor Green; ^
 Write-Host '1. Android 7  (Nougat32)'; ^
 Write-Host '2. Android 9  (Pie64)'; ^
 Write-Host '3. Android 11 (Rvc64)'; ^
 Write-Host '4. Android 13 (Tiramisu64)'; ^
 Write-Host ''; ^
 Write-Host 'Unroot Options:' -ForegroundColor Yellow; ^
 Write-Host '5. Android 7  (Nougat32)'; ^
 Write-Host '6. Android 9  (Pie64)'; ^
 Write-Host '7. Android 11 (Rvc64)'; ^
 Write-Host '8. Android 13 (Tiramisu64)'; ^
 Write-Host ''; ^
 Write-Host 'Other Options:' -ForegroundColor Cyan; ^
 Write-Host '9.  FinalUndoRoot All Versions'; ^
 Write-Host '10. Set Custom BlueStacks Path'; ^
 Write-Host '12. Exit'; ^
 Write-Host ''; ^
 Write-Host ('Current Path: ' + '!customDirectory!') -ForegroundColor Magenta; ^
 Write-Host '';"

set "choice="
set /p "choice=Enter option number (1-10,12): "

:: Process user choice with improved structure
if not defined choice set "choice=0"

:: Root options (1-4)
if "%choice%" geq "1" if "%choice%" leq "4" (
    set /a androidIndex=%choice% - 1
    set "androidVersions=Nougat32 Pie64 Rvc64 Tiramisu64"
    
    for /f "tokens=%androidIndex% delims= " %%a in ("%androidVersions%") do (
        set "clonedVersion=%%a"
    )
    
    if "%choice%"=="1" (
        powershell -Command "Write-Host 'You chose to root Android 7 (Nougat32)' -ForegroundColor Red -NoNewline; Write-Host ' Please edit the bat file and replace Nougat32 with Nougat64 if using 64-bit Android 7' -ForegroundColor Red; Start-Sleep -Seconds 3"
    )
    
    goto :apply_changes
)

:: Unroot options (5-8)
if "%choice%" geq "5" if "%choice%" leq "8" (
    set /a androidIndex=%choice% - 5
    set "androidVersions=Nougat32 Pie64 Rvc64 Tiramisu64"
    
    for /f "tokens=%androidIndex% delims= " %%a in ("%androidVersions%") do (
        set "clonedVersion=%%a"
    )
    
    goto :undo_both_changes
)

:: Other options
if "%choice%"=="9" (
    goto :undo_all_changes_final
) else if "%choice%"=="10" (
    call :set_custom_path
    goto :start_options
) else if "%choice%"=="12" (
    echo Exiting...
    exit /b 0
) else (
    echo Invalid option. Please enter a number between 1 and 10, or 12.
    timeout /t 2 >nul
    goto :start_options
)

:: =========================================================================
:: Apply Root Changes Function
:: =========================================================================
:apply_changes
    call :terminate_processes
    call :initialize_paths

    :: Verify configuration file exists
    if not exist "%CONF_FILE%" (
        call :prompt_for_path
        if not exist "!CONF_FILE!" (
            powershell -Command "Write-Host 'Configuration file still not found. Please rerun and use option 10.' -ForegroundColor Red"
            pause
            goto :start_options
        )
    )

    :: Detect the cloned instance
    call :detect_instance "%clonedVersion%"
    set "version=%detectedInstance%"
    set "XML_FILE=%customDirectory%\Engine\%version%\%version%.bstk"

    :: Verify XML file exists
    if not exist "%XML_FILE%" (
        powershell -Command "Write-Host 'Android emulator not installed, not run at least once, or wrong instance chosen.' -ForegroundColor Red"
        pause
        goto :start_options
    )

    :: Set BLUESTACKS_PATH for exclusions
    for %%i in ("%CONF_FILE%") do set "BLUESTACKS_PATH=%%~dpi"

    :: Temporarily exclude paths from Windows Defender
    powershell -Command ^
        "Try { Add-MpPreference -ExclusionPath '%BLUESTACKS_PATH%','%~dp0' -ErrorAction SilentlyContinue; ^
        Write-Host 'Added exclusions for: %BLUESTACKS_PATH%, %~dp0' -ForegroundColor Green } ^
        Catch { Write-Host 'No Windows antivirus detected or exclusions not required.' -ForegroundColor Yellow }"

    :: Backup files
    (
        attrib -R "%XML_FILE%.bak" 2>nul
        copy "%XML_FILE%" "%XML_FILE%.bak" /Y >nul
        attrib -R "%CONF_FILE%.bak" 2>nul
        copy "%CONF_FILE%" "%CONF_FILE%.bak" /Y >nul
    )

    :: Modify XML file (make disks writable)
    (
        attrib -R "%XML_FILE%"
        copy "%XML_FILE%" "%TEMP_FILE%" /Y >nul
        powershell -Command "(Get-Content '%TEMP_FILE%') -replace 'type=\"ReadOnly\"', 'type=\"Normal\"' | Set-Content '%TEMP_FILE%'"
        move /Y "%TEMP_FILE%" "%XML_FILE%" >nul
    )

    :: Modify configuration file (enable root for all instances)
    (
        attrib -R "%CONF_FILE%"
        copy "%CONF_FILE%" "%TEMP_FILE%" /Y >nul
        powershell -Command ^
            "$baseVersion = '%clonedVersion%'; ^
            (Get-Content '%TEMP_FILE%') -replace ^
            ('(^bst\.instance\.' + [regex]::Escape($baseVersion) + '(_\d+)?\.enable_root_access=)\"0\"'), ^
            '$1\"1\"' -replace 'bst.feature.rooting=\"0\"', 'bst.feature.rooting=\"1\"' | ^
            Set-Content '%TEMP_FILE%'"
        move /Y "%TEMP_FILE%" "%CONF_FILE%" >nul
    )

    :: Notify success and clean up
    powershell -Command "Write-Host 'Changes applied successfully.' -ForegroundColor Green"
    echo If you suspect bluestacks.conf corruption, select undo immediately.
    powershell -Command "Try { Remove-MpPreference -ExclusionPath '%~dp0' -ErrorAction SilentlyContinue } Catch {}"
    
    pause
    goto :start_options

:: =========================================================================
:: Undo Root Changes Function
:: =========================================================================
:undo_both_changes
    call :terminate_processes
    call :initialize_paths

    :: Verify configuration file exists
    if not exist "%CONF_FILE%" (
        call :prompt_for_path
        if not exist "!CONF_FILE!" (
            powershell -Command "Write-Host 'Configuration file still not found. Please rerun and use option 10.' -ForegroundColor Red"
            pause
            goto :start_options
        )
    )

    :: Detect the cloned instance
    call :detect_instance "%clonedVersion%"
    set "version=%detectedInstance%"
    set "XML_FILE=%customDirectory%\Engine\%version%\%version%.bstk"

    :: Verify XML file exists
    if not exist "%XML_FILE%" (
        powershell -Command "Write-Host 'Android emulator not installed, not run at least once, or wrong instance chosen.' -ForegroundColor Red"
        pause
        goto :start_options
    )

    :: Set BLUESTACKS_PATH for exclusions
    for %%i in ("%CONF_FILE%") do set "BLUESTACKS_PATH=%%~dpi"

    :: Temporarily exclude paths from Windows Defender
    powershell -Command ^
        "Try { Add-MpPreference -ExclusionPath '%BLUESTACKS_PATH%','%~dp0' -ErrorAction SilentlyContinue; ^
        Write-Host 'Added exclusions for: %BLUESTACKS_PATH%, %~dp0' -ForegroundColor Green } ^
        Catch { Write-Host 'No Windows antivirus detected or exclusions not required.' -ForegroundColor Yellow }"

    :: Revert XML file (restore read-only disks)
    (
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
        if !errorlevel! neq 0 (
            echo Failed to revert XML changes. Restoring from backup...
            copy "%XML_FILE%.bak" "%XML_FILE%" /Y >nul
            pause
            goto :start_options
        )
        move /Y "%TEMP_FILE%" "%XML_FILE%" >nul
    )

    :: Revert configuration file (disable root)
    (
        attrib -R "%CONF_FILE%"
        copy "%CONF_FILE%" "%TEMP_FILE%" /Y >nul
        powershell -Command ^
            "(Get-Content '%TEMP_FILE%') -replace ^
            'bst.instance.%version%.enable_root_access=\"1\"', ^
            'bst.instance.%version%.enable_root_access=\"0\"' -replace ^
            'bst.feature.rooting=\"1\"', 'bst.feature.rooting=\"0\"' | ^
            Set-Content '%TEMP_FILE%'"
        if !errorlevel! neq 0 (
            echo Failed to revert conf changes. Restoring from backup...
            copy "%CONF_FILE%.bak" "%CONF_FILE%" /Y >nul
            pause
            goto :start_options
        )
        move /Y "%TEMP_FILE%" "%CONF_FILE%" >nul
    )

    :: Notify success and clean up
    powershell -Command "Write-Host 'Changes undone successfully.' -ForegroundColor Green"
    powershell -Command "Try { Remove-MpPreference -ExclusionPath '%~dp0' -ErrorAction SilentlyContinue } Catch {}"
    
    pause
    goto :start_options

:: =========================================================================
:: Undo All Root Changes Function
:: =========================================================================
:undo_all_changes_final
    call :terminate_processes

    :: Prompt for version selection
    powershell -Command ^
        "Write-Host 'Please choose the Android version to unroot:' -ForegroundColor Cyan; ^
         Write-Host '1. Android 7  (Nougat32)'; ^
         Write-Host '2. Android 9  (Pie64)'; ^
         Write-Host '3. Android 11 (Rvc64)'; ^
         Write-Host '4. Android 13 (Tiramisu64)';"
    
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
        echo Invalid option. Please enter a number between 1 and 4.
        pause
        goto :undo_all_changes_final
    )

    call :initialize_paths

    :: Verify configuration file exists
    if not exist "%CONF_FILE%" (
        call :prompt_for_path
        if not exist "!CONF_FILE!" (
            powershell -Command "Write-Host 'Configuration file still not found. Please rerun and use option 10.' -ForegroundColor Red"
            pause
            goto :start_options
        )
    )

    :: Detect the cloned instance
    call :detect_instance "%clonedVersion%"
    set "version=%detectedInstance%"
    set "XML_FILE=%customDirectory%\Engine\%version%\%version%.bstk"

    :: Verify XML file exists
    if not exist "%XML_FILE%" (
        powershell -Command "Write-Host 'Android emulator not installed, not run at least once, or wrong instance chosen.' -ForegroundColor Red"
        pause
        goto :start_options
    )

    :: Set BLUESTACKS_PATH for exclusions
    for %%i in ("%CONF_FILE%") do set "BLUESTACKS_PATH=%%~dpi"

    :: Temporarily exclude paths from Windows Defender
    powershell -Command ^
        "Try { Add-MpPreference -ExclusionPath '%BLUESTACKS_PATH%','%~dp0' -ErrorAction SilentlyContinue; ^
        Write-Host 'Added exclusions for: %BLUESTACKS_PATH%, %~dp0' -ForegroundColor Green } ^
        Catch { Write-Host 'No Windows antivirus detected or exclusions not required.' -ForegroundColor Yellow }"

    :: Revert XML file (restore read-only disks)
    (
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
        if !errorlevel! neq 0 (
            echo Failed to revert XML changes. Restoring from backup...
            copy "%XML_FILE%.bak" "%XML_FILE%" /Y >nul
            pause
            goto :start_options
        )
        move /Y "%TEMP_FILE%" "%XML_FILE%" >nul
    )

    :: Revert configuration file (disable root for all instances)
    (
        attrib -R "%CONF_FILE%"
        copy "%CONF_FILE%" "%TEMP_FILE%" /Y >nul
        powershell -Command ^
            "$baseVersion = '%clonedVersion%'; ^
            (Get-Content '%TEMP_FILE%') -replace ^
            ('(^bst\.instance\.' + [regex]::Escape($baseVersion) + '(_\d+)?\.enable_root_access=)\"1\"'), ^
            '$1\"0\"' -replace 'bst.feature.rooting=\"1\"', 'bst.feature.rooting=\"0\"' | ^
            Set-Content '%TEMP_FILE%'"
        if !errorlevel! neq 0 (
            echo Failed to revert conf changes. Restoring from backup...
            copy "%CONF_FILE%.bak" "%CONF_FILE%" /Y >nul
            pause
            goto :start_options
        )
        move /Y "%TEMP_FILE%" "%CONF_FILE%" >nul
    )

    :: Notify success and clean up
    powershell -Command "Write-Host 'Changes undone successfully for all %clonedVersion% instances.' -ForegroundColor Green"
    powershell -Command "Try { Remove-MpPreference -ExclusionPath '%~dp0' -ErrorAction SilentlyContinue } Catch {}"
    
    pause
    goto :start_options

:: =========================================================================
:: Helper Functions
:: =========================================================================

:set_custom_path
    echo The default directory is C:\ProgramData\BlueStacks_nxt
    set /p "customDirectory=Please enter your BlueStacks_nxt directory: "
    
    :: Trim trailing slashes
    if "!customDirectory:~-1!"=="\" set "customDirectory=!customDirectory:~0,-1!"
    if "!customDirectory:~-1!"=="/" set "customDirectory=!customDirectory:~0,-1!"
    
    if not exist "!customDirectory!" (
        echo The specified directory does not exist. Please try again.
        pause
        exit /b 1
    )
    
    echo You entered: !customDirectory!
    echo !customDirectory!>bluestacksconfig.txt
    powershell -Command "Write-Host 'Path saved to bluestacksconfig.txt for future use.' -ForegroundColor Green"
    pause
    exit /b 0

:terminate_processes
    taskkill /F /IM "HD-MultiInstanceManager.exe" /IM "HD-Player.exe" /IM "BlueStacksHelper.exe" /IM "BstkSVC.exe" /IM "BlueStacksServices.exe" 2>nul
    exit /b 0

:detect_instance
    set "pattern=%~1"
    echo Automatically detecting... please run the cloned instance and close it before proceeding
    echo Detecting the cloned instance...
    echo --------------------------------------------------------------------------
    
    :: Check log file size and delete if too large
    set "LOG_FILE=!customDirectory!\Logs\Player.log"
    if not exist "!LOG_FILE!" (
        echo Log file not found. Please run BlueStacks at least once.
        pause
        goto :start_options
    )
    
    powershell -Command ^
        "$logPath = '!LOG_FILE!'; ^
        if (Test-Path $logPath) { ^
            $fileSize = (Get-Item $logPath).Length / 1MB; ^
            if ($fileSize -gt 10) { ^
                Remove-Item $logPath -Force; ^
                Write-Host 'Log file too large and deleted. Rerun your instance and retry.' -ForegroundColor Red; ^
                exit 1 ^
            } ^
        } else { ^
            Write-Host 'Log file not found. Please run BlueStacks at least once.' -ForegroundColor Red; ^
            exit 1 ^
        }" || (
        pause
        goto :start_options
    )
    
    :: Detect instance from log with improved error handling
    for /f "delims=" %%i in ('powershell -Command ^
        "$logPath = '!LOG_FILE!'; ^
        if (Test-Path $logPath) { ^
            $logContent = Get-Content $logPath -ErrorAction SilentlyContinue; ^
            if ($logContent) { ^
                $instanceMatches = $logContent | Select-String '%pattern%(_\\d+)?' -AllMatches; ^
                if ($instanceMatches) { ^
                    $instanceNumber = $instanceMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Value } | Select-Object -Last 1; ^
                    if ($instanceNumber) { ^
                        Write-Output $instanceNumber ^
                    } else { ^
                        Write-Output '%pattern%' ^
                    } ^
                } else { ^
                    Write-Output '%pattern%' ^
                } ^
            } else { ^
                Write-Output '%pattern%' ^
            } ^
        } else { ^
            Write-Output '%pattern%' ^
        }"') do (
        powershell -Command "Write-Host 'The program detected %%i' -ForegroundColor Green"
        set "detectedInstance=%%i"
    )
    
    echo The program will process: %detectedInstance%
    echo.
    exit /b 0

:initialize_paths
    set "ENGINE_PATH=%customDirectory%\Engine"
    set "CONF_FILE=%customDirectory%\bluestacks.conf"
    set "TEMP_FILE=%CONF_FILE%.tmp"
    exit /b 0

:prompt_for_path
    echo Configuration file not found.
    echo The default path is C:\ProgramData\BlueStacks_nxt
    set /p "BLUESTACKS_PATH=Please enter your BlueStacks_nxt directory (avoid spaces/special chars): "
    
    :: Trim trailing characters
    if "!BLUESTACKS_PATH:~-1!"=="\" set "BLUESTACKS_PATH=!BLUESTACKS_PATH:~0,-1!"
    if "!BLUESTACKS_PATH:~-1!"=="/" set "BLUESTACKS_PATH=!BLUESTACKS_PATH:~0,-1!"
    
    set "customDirectory=!BLUESTACKS_PATH!"
    set "ENGINE_PATH=!BLUESTACKS_PATH!\Engine"
    set "CONF_FILE=!BLUESTACKS_PATH!\bluestacks.conf"
    set "TEMP_FILE=!CONF_FILE!.tmp"
    
    attrib -R "!CONF_FILE!" 2>nul
    attrib -R "!TEMP_FILE!" 2>nul
    exit /b 0

:: End of script
