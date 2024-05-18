@echo off
setlocal enabledelayedexpansion


:: Check for administrative privileges
net session >nul 2>&1
if %errorLevel% == 0 (
    echo Success: The script is running with administrative privileges.
) else (
    echo Failure: The script is not running with administrative privileges.
    echo Requesting administrative privileges...
    
    :: Elevate the script using PowerShell
    powershell -Command "Start-Process cmd.exe -ArgumentList '/c ""%~s0""' -Verb RunAs"
    
    :: Exit the non-elevated script
    exit /b
)

:: Close BlueStacks Multi-Instance Manager
taskkill /F /IM HD-MultiInstanceManager.exe
taskkill /IM "BlueStacksHelper.exe" /F 2>NUL
taskkill /IM "BstkSVC.exe" /F 2>NUL

:: Get the installation path of BlueStacks from the registry
rem you can hard code the path here if you know what you are doing
for /f "tokens=2*" %%a in ('reg query "HKEY_LOCAL_MACHINE\SOFTWARE\BlueStacks_nxt" /v "UserDefinedDir"') do set "BlueStacksPath=%%b"
set "BlueStacksRootPath=%BlueStacksPath%Root"



:: Check if the BlueStacks path exists
if exist "%BlueStacksPath%" (
    echo BlueStacks installation path is: %BlueStacksPath%
)


if exist "%BlueStacksRootPath%" (
    echo BlueStacks root path found: %BlueStacksRootPath%
    
    :: Remove the BlueStacks_nxt directory
    rmdir /s /q "%BlueStacksPath%"
    
    :: Create the symbolic link
    mklink /J "%BlueStacksPath%" "%BlueStacksRootPath%"
    
    :: Check if the command executed successfully
    if %errorlevel% equ 0 (
        powershell -Command "Write-Host 'Command executed successfully on %BlueStacksPath% and linked to %BlueStacksRootPath%' -ForegroundColor Green"
    ) else (
        echo Command execution failed on %BlueStacksPath%
    )
    
    :: Reopen BlueStacks Multi-Instance Manager
    for /f "tokens=2*" %%a in ('reg query "HKEY_LOCAL_MACHINE\SOFTWARE\BlueStacks_nxt" /v "InstallDir"') do set "BlueStacksProgramPath=%%b"

    start "" "!BlueStacksProgramPath!\HD-MultiInstanceManager.exe"
) else (
    :: Print a warning message in red using PowerShell
    powershell -Command "Write-Host 'The directory %BlueStacksRootPath% does not exist. Your BlueStacks or other system files may be deleted If incorrect edits are made, please install Bluestacks to default path or edit the paths manually carefully.' -ForegroundColor Red"
)


pause