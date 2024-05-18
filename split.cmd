@echo off

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
taskkill /IM "HD-MultiInstanceManager.exe" /F 2>NUL
taskkill /IM "HD-Player.exe" /F 2>NUL
taskkill /IM "BlueStacksHelper.exe" /F 2>NUL
taskkill /IM "BstkSVC.exe" /F 2>NUL

:: Get the installation path of BlueStacks from the registry
for /f "tokens=2*" %%a in ('reg query "HKEY_LOCAL_MACHINE\SOFTWARE\BlueStacks_nxt" /v "UserDefinedDir"') do set "defaultDirectory=%%~dpb"
echo %defaultDirectory%

:: Rename the defaultDirectory to rootDirectory and create a copy for noRootDirectory
set "rootDirectory=%defaultDirectory%BlueStacks_nxtRoot"
set "noRootDirectory=%defaultDirectory%BlueStacks_nxtNoRoot"

:: Check if the rootDirectory and noRootDirectory already exist
if exist "%rootDirectory%" (
    echo The directory "%rootDirectory%" already exists.
    pause
    exit /b
)
if exist "%noRootDirectory%" (
    echo The directory "%noRootDirectory%" already exists.
    pause
    exit /b
)

:: Change the permissions of the defaultDirectory and remove the read-only attribute
icacls "%defaultDirectory%BlueStacks_nxt" /grant Everyone:(OI)(CI)F /T
attrib -R "%defaultDirectory%BlueStacks_nxt\*.*" /S

:: Rename the defaultDirectory to rootDirectory
echo Renaming "%defaultDirectory%BlueStacks_nxt" to "%rootDirectory%"
ren "%defaultDirectory%BlueStacks_nxt" "BlueStacks_nxtRoot"

:: Copy the rootDirectory to noRootDirectory
echo Copying from "%rootDirectory%" to "%noRootDirectory%"
xcopy /E /I "%rootDirectory%" "%noRootDirectory%"
pause