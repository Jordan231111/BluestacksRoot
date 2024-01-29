@echo off
setlocal enabledelayedexpansion
:: BatchGotAdmin
:-------------------------------------
REM  --> Check for permissions
net session >nul 2>&1
if '%errorlevel%' NEQ '0' (
    echo Requesting administrative privileges...
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

set "XML_FILE=%ProgramData%\BlueStacks_nxt\Engine\Rvc64\Rvc64.bstk"
set "CONF_FILE=%ProgramData%\BlueStacks_nxt\bluestacks.conf"
set "TEMP_FILE=%CONF_FILE%.tmp"

:check_file
if not exist "!CONF_FILE!" (
    echo Configuration file not found.
    echo The default path is C:\ProgramData\BlueStacks_nxt
    set /p "BLUESTACKS_PATH=Please enter the path to your BlueStacks_nxt directory choose a different directory if it include spaces, special characters or other unreasonable file paths: "
    echo BLUESTACKS_PATH is set to: !BLUESTACKS_PATH!
    set "XML_FILE=!BLUESTACKS_PATH!\Engine\Rvc64\Rvc64.bstk"
    echo XML_FILE is set to: !XML_FILE!
    set "CONF_FILE=!BLUESTACKS_PATH!\bluestacks.conf"
    echo CONF_FILE is set to: !CONF_FILE!
    set "TEMP_FILE=!CONF_FILE!.tmp"
    goto check_file
)

if not exist "!XML_FILE!" (
    echo Android 11 not installed or not run at least once and closed.
    pause
    exit /B
)

:: Rest of your script...

rem Define search and replace strings
set "search_str1=format=\"VDI\" type=\"ReadOnly\""
set "replace_str1=format=\"VDI\" type=\"Normal\""

set "search_str2=format=\"VHD\" type=\"ReadOnly\""
set "replace_str2=format=\"VHD\" type=\"Normal\""

rem Display user options
echo 1. Apply changes
echo 2. Undo Writable Disk
echo 3. Undo Root
set /p OPTION=Enter option number: 

rem Process user choice
if "%OPTION%" == "1" (
    goto apply_changes
) else if "%OPTION%" == "2" (
    goto undo_xml_changes
) else if "%OPTION%" == "3" (
    goto undo_conf_changes
) else (
    echo Invalid option.
    pause
    exit /b 1
)

:apply_changes
rem Create a backup of the original XML file
copy "%XML_FILE%" "%XML_FILE%.bak" /Y > nul

rem Make changes to the XML file
copy "%XML_FILE%" "%TEMP_FILE%" /Y > nul
powershell -Command "(Get-Content '%TEMP_FILE%') -replace '%search_str1%', '%replace_str1%' | Set-Content '%TEMP_FILE%'"
powershell -Command "(Get-Content '%TEMP_FILE%') -replace '%search_str2%', '%replace_str2%' | Set-Content '%TEMP_FILE%'"
move /Y "%TEMP_FILE%" "%XML_FILE%" > nul

rem Create a backup of the original bluestacks.conf file
copy "%CONF_FILE%" "%CONF_FILE%.bak" /Y > nul

rem Make changes to the temporary bluestacks.conf file using PowerShell
copy "%CONF_FILE%" "%TEMP_FILE%" /Y > nul
powershell -Command "(Get-Content '%TEMP_FILE%') -replace 'bst.instance.Rvc64.enable_root_access=\"0\"', 'bst.instance.Rvc64.enable_root_access=\"1\"' | Set-Content '%TEMP_FILE%'"
powershell -Command "(Get-Content '%TEMP_FILE%') -replace 'bst.feature.rooting=\"0\"', 'bst.feature.rooting=\"1\"' | Set-Content '%TEMP_FILE%'"

rem Replace the original bluestacks.conf file with the modified temporary bluestacks.conf file
move /Y "%TEMP_FILE%" "%CONF_FILE%" > nul

echo Changes applied successfully.
pause
exit /b 0

:undo_xml_changes
rem Restore the original XML file from the backup file
echo Restoring XML file from backup...
copy "%XML_FILE%.bak" "%XML_FILE%" /Y > nul

rem Revert changes in the XML file
echo Reverting changes in XML file...
powershell -Command "(Get-Content '%XML_FILE%') -replace '%replace_str1%', '%search_str1%' | Set-Content '%XML_FILE%'"
powershell -Command "(Get-Content '%XML_FILE%') -replace '%replace_str2%', '%search_str2%' | Set-Content '%XML_FILE%'"

rem Check if the PowerShell command executed successfully
if %errorlevel% neq 0 (
    echo Failed to revert changes in XML file.
    pause
    exit /b 1
)

echo XML changes undone successfully.
pause
exit /b 0

:undo_conf_changes
rem Restore the original bluestacks.conf file from the backup file
copy "%CONF_FILE%.bak" "%CONF_FILE%" /Y > nul

rem Make changes to the temporary bluestacks.conf file using PowerShell
copy "%CONF_FILE%" "%TEMP_FILE%" /Y > nul
powershell -Command "(Get-Content '%TEMP_FILE%') -replace 'bst.instance.Rvc64.enable_root_access=\"1\"', 'bst.instance.Rvc64.enable_root_access=\"0\"' | Set-Content '%TEMP_FILE%'"
powershell -Command "(Get-Content '%TEMP_FILE%') -replace 'bst.feature.rooting=\"1\"', 'bst.feature.rooting=\"0\"' | Set-Content '%TEMP_FILE%'"

rem Replace the original bluestacks.conf file with the modified temporary bluestacks.conf file
move /Y "%TEMP_FILE%" "%CONF_FILE%" > nul

echo bluestacks.conf root changes undone successfully
pause
exit /b 0
