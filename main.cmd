@echo off
setlocal enabledelayedexpansion


:begin
echo 1. BlueStacks Android 9 Root
echo 2. BlueStacks Android 11 Root
set /p choice=Enter option number: 

if "%choice%"=="1" (
    :: Run the script for BlueStacks Android 9 Root
    set "version=Pie64"
    set "clonedVersion=Pie64"
) else if "%choice%"=="2" (
    :: Run the script for BlueStacks Android 11 Root
    set "version=Rvc64"
    set "clonedVersion=Rvc64"
) else (
    echo Invalid option. Please enter 1 or 2.
    echo.
    goto begin
)

:: BatchGotAdmin
:-------------------------------------
REM  --> Check for permissions
net session >nul 2>&1
if '%errorlevel%' NEQ '0' (
    echo Requesting administrative privileges...
    echo If the script does not work, please manually run it as an administrator.
    pause
    goto UACPrompt
) else ( goto gotAdmin )

:UACPrompt
    echo Set UAC = CreateObject^("Shell.Application"^) > "%temp%\getadmin.vbs"
    echo UAC.ShellExecute "%~s0", "", "", "runas", 1 >> "%temp%\getadmin.vbs"

    "%temp%\getadmin.vbs"
    exit /B

:gotAdmin
    if exist "%temp%\getadmin.vbs" ( del "%temp%\getadmin.vbs" )
    pushd "%CD%"
    CD /D "%~dp0"
:--------------------------------------
:: Your batch script starts here


taskkill /IM "HD-MultiInstanceManager.exe" /F 2>NUL
if "%ERRORLEVEL%"=="0" (
    powershell -Command "Write-Host 'Failure to meet best practices' -ForegroundColor Red"
)

taskkill /IM "HD-Player.exe" /F 2>NUL
if "%ERRORLEVEL%"=="0" (
    powershell -Command "Write-Host 'Failure to meet best practices' -ForegroundColor Red"
)

taskkill /IM "BlueStacksHelper.exe" /F 2>NUL
if "%ERRORLEVEL%"=="0" (
    powershell -Command "Write-Host 'Failure to meet best practices' -ForegroundColor Red"
)


set "XML_FILE=%ProgramData%\BlueStacks_nxt\Engine\%clonedVersion%\%clonedVersion%.bstk"
set "CONF_FILE=%ProgramData%\BlueStacks_nxt\bluestacks.conf"
attrib -R "!XML_FILE!"
attrib -R "!CONF_FILE!"
set "TEMP_FILE=!CONF_FILE!.tmp"
attrib -R "!TEMP_FILE!"


:check_file
if not exist "!CONF_FILE!" (
    echo Configuration file not found.
    echo The default path is C:\ProgramData\BlueStacks_nxt
    set /p "BLUESTACKS_PATH=Please enter the path to your BlueStacks_nxt directory choose a different directory if it include spaces, special characters or other unreasonable file paths: "
    echo BLUESTACKS_PATH is set to: !BLUESTACKS_PATH!
    set "XML_FILE=!BLUESTACKS_PATH!\Engine\%clonedVersion%\%clonedVersion%.bstk"
    echo XML_FILE is set to: !XML_FILE!
    set "CONF_FILE=!BLUESTACKS_PATH!\bluestacks.conf"
    echo CONF_FILE is set to: !CONF_FILE!
    set "TEMP_FILE=!CONF_FILE!.tmp"
    attrib -R "!XML_FILE!"
    attrib -R "!CONF_FILE!"
    attrib -R "!TEMP_FILE!"
    goto check_file
)


if not exist "!XML_FILE!" (
    echo Android emulator not installed or not run at least once and closed or wrong instance chosen.
    pause
    exit /B
)

:: Set the ENGINE_PATH variable to the hardcoded path
set "ENGINE_PATH=%ProgramData%\BlueStacks_nxt\Engine"


if exist "!BLUESTACKS_PATH!" (
    echo alternate path discovered
    set "ENGINE_PATH=!BLUESTACKS_PATH!\Engine"
)

echo Automatically detecting... please run the cloned instance you wish to root and close it before proceeding
echo.
echo.
echo Detecting the cloned instance to root...
echo --------------------------------------------------------------------------
:: Call PowerShell to check the file size and delete the file if it's too large

powershell -Command "$enginePath = '!ENGINE_PATH!'; $enginePath = $enginePath -replace '\\Engine$'; $fileSize = (Get-Item $enginePath\Logs\Player.log).Length / 1MB; if ($fileSize -gt 10) { Remove-Item $enginePath\Logs\Player.log -Force; Write-Host 'The log file was too large and has been deleted. Please rerun your cloned instance you wish to root and close the script'; exit 1 } else { exit 0 }" || (pause && exit /b)


:: Call PowerShell to read the log file in reverse order and search for the pattern to get cloned instance #
if "%clonedVersion%"=="Rvc64" (
    for /f "delims=" %%i in ('powershell -Command "$enginePath = '!ENGINE_PATH!'; $enginePath = $enginePath -replace '\\Engine$'; $logContent = Get-Content $enginePath\Logs\Player.log -ReadCount 0; $instanceNumber = $logContent | Select-String 'Rvc64(_\d+)?' -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Value } | Select-Object -Last 1; $instanceNumber"') do (
        powershell -Command "Write-Host 'The program detected %%i ' -ForegroundColor Green"
        set "tempVar=%%i"
    )
    set "version=!tempVar!"
    echo.
) else if "%clonedVersion%"=="Pie64" (
    for /f "delims=" %%i in ('powershell -Command "$enginePath = '!ENGINE_PATH!'; $enginePath = $enginePath -replace '\\Engine$'; $logContent = Get-Content $enginePath\Logs\Player.log -ReadCount 0; $instanceNumber = $logContent | Select-String 'Pie64(_\d+)?' -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Value } | Select-Object -Last 1; $instanceNumber"') do (
        powershell -Command "Write-Host 'The program detected %%i ' -ForegroundColor Green"
        set "tempVar=%%i"
    )
    set "version=!tempVar!"
    echo.
)
echo The program will root: !version!

:: Rest of your script...
for %%i in ("%CONF_FILE%") do set "BLUESTACKS_PATH=%%~dpi"
echo BLUESTACKS_PATH is set to: %BLUESTACKS_PATH%

powershell -Command "Add-MpPreference -ExclusionPath '%BLUESTACKS_PATH%' 2>$null" && (
    echo Excluded path: %BLUESTACKS_PATH%
) || (
    echo No Windows antivirus detected.
)
powershell -Command "Add-MpPreference -ExclusionPath '%~dp0' 2>$null" && (
    echo Excluded path: %~dp0
) || (
    echo No Windows antivirus detected.
)

rem Define search and replace strings
set "search_str1=format=\"VDI\" type=\"ReadOnly\""
set "replace_str1=format=\"VDI\" type=\"Normal\""

set "search_str2=format=\"VHD\" type=\"ReadOnly\""
set "replace_str2=format=\"VHD\" type=\"Normal\""

:promptUserOptions
rem Display user options
echo 1. Apply changes
echo 2. Undo Writable Disk
echo 3. Undo Root
echo 4. Undo Both Writable Disk and Root
set /p OPTION=Enter option number: 

rem Process user choice
if "%OPTION%" == "1" (
    goto apply_changes
) else if "%OPTION%" == "2" (
    goto undo_xml_changes
) else if "%OPTION%" == "3" (
    goto undo_conf_changes
) else if "%OPTION%" == "4" (
    goto undo_both_changes
) else (
    echo Invalid option. Please enter a number between 1 and 4.
    goto promptUserOptions
)


:undo_both_changes
call :undo_xml_changes
call :undo_conf_changes
goto :eof

:apply_changes
rem Create a backup of the original XML file
attrib -R "%XML_FILE%.bak"
copy "%XML_FILE%" "%XML_FILE%.bak" /Y > nul

rem Make changes to the XML file
copy "%XML_FILE%" "%TEMP_FILE%" /Y > nul
powershell -Command "(Get-Content '%TEMP_FILE%') -replace '%search_str1%', '%replace_str1%' | Set-Content '%TEMP_FILE%'"
powershell -Command "(Get-Content '%TEMP_FILE%') -replace '%search_str2%', '%replace_str2%' | Set-Content '%TEMP_FILE%'"
move /Y "%TEMP_FILE%" "%XML_FILE%" > nul

rem Create a backup of the original bluestacks.conf file
attrib -R "%CONF_FILE%.bak"
copy "%CONF_FILE%" "%CONF_FILE%.bak" /Y > nul

rem Make changes to the temporary bluestacks.conf file using PowerShell
copy "%CONF_FILE%" "%TEMP_FILE%" /Y > nul
powershell -Command "(Get-Content '%TEMP_FILE%') -replace 'bst.instance.%version%.enable_root_access=\"0\"', 'bst.instance.%version%.enable_root_access=\"1\"' | Set-Content '%TEMP_FILE%'"
powershell -Command "(Get-Content '%TEMP_FILE%') -replace 'bst.feature.rooting=\"0\"', 'bst.feature.rooting=\"1\"' | Set-Content '%TEMP_FILE%'"

rem Replace the original bluestacks.conf file with the modified temporary bluestacks.conf file
move /Y "%TEMP_FILE%" "%CONF_FILE%" > nul

powershell -Command "Write-Host 'Changes applied successfully.' -ForegroundColor Green"
echo If you suspect bluestacks.conf file was corrupted, please run this program again with same options but *MUST* choose undo both writable and root
powershell -Command "Remove-MpPreference -ExclusionPath '%~dp0' 2>$null" && (
    echo Exclusion removed for path: %~dp0
)
pause
exit /b 0

:undo_xml_changes
rem Revert changes in the XML file
echo Reverting changes in XML file...
powershell -Command "(Get-Content '%XML_FILE%') -replace '%replace_str1%', '%search_str1%' | Set-Content '%XML_FILE%'"
powershell -Command "(Get-Content '%XML_FILE%') -replace '%replace_str2%', '%search_str2%' | Set-Content '%XML_FILE%'"

rem Check if the PowerShell command executed successfully
if %errorlevel% neq 0 (
    echo Failed to revert changes in XML file. Restoring from backup...
    copy "%XML_FILE%.bak" "%XML_FILE%" /Y > nul
    pause
    exit /b 1
)

powershell -Command "Write-Host 'XML changes undone successfully.' -ForegroundColor Green"
powershell -Command "Remove-MpPreference -ExclusionPath '%~dp0' 2>$null" && (
    echo Exclusion removed for path: %~dp0
)
goto :eof

:undo_conf_changes
rem Make changes to the temporary bluestacks.conf file using PowerShell
copy "%CONF_FILE%" "%TEMP_FILE%" /Y > nul
powershell -Command "(Get-Content '%TEMP_FILE%') -replace 'bst.instance.%version%.enable_root_access=\"1\"', 'bst.instance.%version%.enable_root_access=\"0\"' | Set-Content '%TEMP_FILE%'"
powershell -Command "(Get-Content '%TEMP_FILE%') -replace 'bst.feature.rooting=\"1\"', 'bst.feature.rooting=\"0\"' | Set-Content '%TEMP_FILE%'"

rem Check if the PowerShell command executed successfully
if %errorlevel% neq 0 (
    echo Failed to revert changes in bluestacks.conf file. Restoring from backup...
    copy "%CONF_FILE%.bak" "%CONF_FILE%" /Y > nul
    pause
    exit /b 1
)

rem Replace the original bluestacks.conf file with the modified temporary bluestacks.conf file
move /Y "%TEMP_FILE%" "%CONF_FILE%" > nul

powershell -Command "Write-Host 'Root changes undone successfully.' -ForegroundColor Green"
powershell -Command "Remove-MpPreference -ExclusionPath '%~dp0' 2>$null" && (
    echo Exclusion removed for path: %~dp0
)
pause
exit /b 0
