@echo off
setlocal enabledelayedexpansion

:: Check for administrative privileges
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

rem define the path to the BlueStacks configuration file
set "defaultDirectory=%ProgramData%\BlueStacks_nxt"
if exist "%~dp0bluestacksconfig.txt" (
    set /p customDirectory=<bluestacksconfig.txt
    if not defined customDirectory (
        set "customDirectory=%defaultDirectory%"
    )
) else (
    set "customDirectory=%defaultDirectory%"
)

rem remove spaces from the custom directory
set "customDirectory=%customDirectory: =%"


:: Ascii art for the program :D
:: Presenting all options at the beginning
:start_options
powershell -Command "Write-Host '  ____  _                 _             _          ____             _     _____           _ ' -ForegroundColor Blue; Write-Host ' | __ )| |_   _  ___  ___| |_ __ _  ___| | _____  |  _ \ ___   ___ | |_  |_   _|__   ___ | |' -ForegroundColor Blue; Write-Host ' |  _ \| | | | |/ _ \/ __| __/ _` |/ __| |/ / __| | |_) / _ \ / _ \| __|   | |/ _ \ / _ \| |' -ForegroundColor Blue; Write-Host ' | |_) | | |_| |  __/\__ \ || (_| | (__|   <\__ \ |  _ < (_) | (_) | |_    | | (_) | (_) | |' -ForegroundColor Blue; Write-Host ' |____/|_|\__,_|\___||___/\__\__,_|\___|_|\_\___/ |_| \_\___/ \___/ \__|   |_|\___/ \___/|_|' -ForegroundColor Blue; Write-Host ''; Write-Host ('{0,-30} | {1,-30} | {2,-30}' -f 'Root Options:', 'Unroot Options:', 'Other Options:'); Write-Host ('{0,-30} | {1,-30} | {2,-30}' -f '1. Apply BlueStacks Android 9', '3. Undo BlueStacks Android 9', '5. Force Custom BlueStacks Path'); Write-Host ('{0,-30} | {1,-30} | {2,-30}' -f '2. Apply BlueStacks Android 11', '4. Undo BlueStacks Android 11', 'Current Path: %customDirectory%'); Write-Host ('{0,-30} | {1,-30} | {2,-30}' -f '', '6. FinalUndoRoot Android 9', ''); Write-Host ('{0,-30} | {1,-30} | {2,-30}' -f '', '7. FinalUndoRoot Android 11', ''); Write-Host '';"
set /p choice=Enter option number: 

if "%choice%"=="1" (
    set "version=Pie64"
    set "clonedVersion=Pie64" 
    goto apply_changes
) else if "%choice%"=="2" (
    set "version=Rvc64"
    set "clonedVersion=Rvc64"
    goto apply_changes
) else if "%choice%"=="3" (
    set "version=Pie64"
    set "clonedVersion=Pie64"
    goto undo_both_changes  
) else if "%choice%"=="4" (
    set "version=Rvc64"
    set "clonedVersion=Rvc64"
    goto undo_both_changes
) else if "%choice%"=="5" (
    echo The default directory is C:\ProgramData\BlueStacks_nxt
    set /p "customDirectory=Please enter your Bluestacks_nxt directory: "
    if "!customDirectory:~-1!"=="\" (
        set "customDirectory=!customDirectory:~0,-1!"
    )
    if "!customDirectory:~-1!"=="/" (
        set "customDirectory=!customDirectory:~0,-1!"
    )

    echo You entered: !customDirectory!
    echo !customDirectory! > bluestacksconfig.txt
    powershell -Command "Write-Host 'The path you entered has been saved to bluestacksconfig.txt for future rooting if this script''s location does not change' -ForegroundColor Green"
    pause
    powershell -Command "Clear-Host"
    goto start_options
) else if "%choice%"=="6" (
    set "version=Pie64"
    set "clonedVersion=Pie64"
    goto undo_both_changes_final
) else if "%choice%"=="7" (
    set "version=Rvc64"
    set "clonedVersion=Rvc64"
    goto undo_both_changes_final
) else if "%choice%"=="0" (
    exit /b
) else (
    echo Invalid option. Please enter a number between 1 and 7.
    pause
    exit /b 1
)

:apply_changes
taskkill /IM "HD-MultiInstanceManager.exe" /F 2>NUL
taskkill /IM "HD-Player.exe" /F 2>NUL
taskkill /IM "BlueStacksHelper.exe" /F 2>NUL
taskkill /IM "BstkSVC.exe" /F 2>NUL


set "XML_FILE=%customDirectory%\Engine\%clonedVersion%\%clonedVersion%.bstk"
set "CONF_FILE=%customDirectory%\bluestacks.conf"
attrib -R "!XML_FILE!"
attrib -R "!CONF_FILE!"
set "TEMP_FILE=!CONF_FILE!.tmp"
attrib -R "!TEMP_FILE!"

:check_file
if not exist "!CONF_FILE!" (
    powershell -Command "Write-Host 'Configuration file not found. If you are here please rerun script and choose option 5' -ForegroundColor Red"
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
    powershell -Command "Write-Host 'Android emulator not installed or not run at least once and closed or wrong instance chosen.' -ForegroundColor Red"
    pause
    exit /B
)

:: Set the ENGINE_PATH variable to the hardcoded path
set "ENGINE_PATH=%customDirectory%\Engine"

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

powershell -Command "Add-MpPreference -ExclusionPath '%BLUESTACKS_PATH%' 2>$null; Add-MpPreference -ExclusionPath '%~dp0' 2>$null" && (
    echo Excluded path: %BLUESTACKS_PATH%
    echo Excluded path: %~dp0
) || (
    echo No Windows antivirus detected.
)

rem Define search and replace strings
set "search_str1=format=\"VDI\" type=\"ReadOnly\""
set "replace_str1=format=\"VDI\" type=\"Normal\""

set "search_str2=format=\"VHD\" type=\"ReadOnly\""
set "replace_str2=format=\"VHD\" type=\"Normal\""

rem Create a backup of the original XML file
attrib -R "%XML_FILE%.bak"
copy "%XML_FILE%" "%XML_FILE%.bak" /Y > nul

rem Make changes to the XML file
copy "%XML_FILE%" "%TEMP_FILE%" /Y > nul
powershell -Command "(Get-Content '%TEMP_FILE%') -replace '%search_str1%', '%replace_str1%' | Set-Content '%TEMP_FILE%'; (Get-Content '%TEMP_FILE%') -replace '%search_str2%', '%replace_str2%' | Set-Content '%TEMP_FILE%'"
move /Y "%TEMP_FILE%" "%XML_FILE%" > nul

rem Create a backup of the original bluestacks.conf file
attrib -R "%CONF_FILE%.bak"
copy "%CONF_FILE%" "%CONF_FILE%.bak" /Y > nul

rem Make changes to the temporary bluestacks.conf file using PowerShell
copy "%CONF_FILE%" "%TEMP_FILE%" /Y > nul
powershell -Command "Get-Content '%TEMP_FILE%' | ForEach-Object { $_ -replace 'enable_root_access=\"0\"', 'enable_root_access=\"1\"' -replace 'bst.feature.rooting=\"0\"', 'bst.feature.rooting=\"1\"' } | Set-Content '%TEMP_FILE%.tmp'; Remove-Item -Path '%TEMP_FILE%'; Rename-Item -Path '%TEMP_FILE%.tmp' -NewName '%TEMP_FILE%'"


rem Replace the original bluestacks.conf file with the modified temporary bluestacks.conf file
move /Y "%TEMP_FILE%" "%CONF_FILE%" > nul

powershell -Command "Write-Host 'Changes applied successfully.' -ForegroundColor Green"
echo If you suspect bluestacks.conf file was corrupted, please choose undo both writable and root immediately
powershell -Command "Remove-MpPreference -ExclusionPath '%~dp0' 2>$null" && (
    echo Exclusion removed for path: %~dp0
)
pause
powershell -Command "Clear-Host"
goto start_options

:undo_both_changes
taskkill /IM "HD-MultiInstanceManager.exe" /F 2>NUL
taskkill /IM "HD-Player.exe" /F 2>NUL
taskkill /IM "BlueStacksHelper.exe" /F 2>NUL
taskkill /IM "BstkSVC.exe" /F 2>NUL

set "XML_FILE=%customDirectory%\Engine\%clonedVersion%\%clonedVersion%.bstk"
set "CONF_FILE=%customDirectory%\bluestacks.conf"
attrib -R "!XML_FILE!"
attrib -R "!CONF_FILE!"
set "TEMP_FILE=!CONF_FILE!.tmp"
attrib -R "!TEMP_FILE!"

:check_file_undo
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
    goto check_file_undo
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

echo Automatically detecting... please run the cloned instance you wish to undo root and close it before proceeding
echo.
echo.
echo Detecting the cloned instance to undo root...
echo --------------------------------------------------------------------------
:: Call PowerShell to check the file size and delete the file if it's too large
powershell -Command "$enginePath = '!ENGINE_PATH!'; $enginePath = $enginePath -replace '\\Engine$'; $fileSize = (Get-Item $enginePath\Logs\Player.log).Length / 1MB; if ($fileSize -gt 10) { Remove-Item $enginePath\Logs\Player.log -Force; Write-Host 'The log file was too large and has been deleted. Please rerun your cloned instance you wish to undo root and close the script'; exit 1 } else { exit 0 }" || (pause && exit /b)

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
echo The program will undo root for: !version!

:: Rest of your script...
for %%i in ("%CONF_FILE%") do set "BLUESTACKS_PATH=%%~dpi"
echo BLUESTACKS_PATH is set to: %BLUESTACKS_PATH%

powershell -Command "Add-MpPreference -ExclusionPath '%BLUESTACKS_PATH%' 2>$null; Add-MpPreference -ExclusionPath '%~dp0' 2>$null" && (
    echo Excluded paths: %BLUESTACKS_PATH%, %~dp0
) || (
    echo No Windows antivirus detected.
)

rem Define search and replace strings
set "search_str1=format=\"VDI\" type=\"Normal\""
set "replace_str1=format=\"VDI\" type=\"ReadOnly\""

set "search_str2=format=\"VHD\" type=\"Normal\""
set "replace_str2=format=\"VHD\" type=\"ReadOnly\""

rem Revert changes in the XML file
echo Reverting changes in XML file...
powershell -Command "(Get-Content '%XML_FILE%') -replace '%search_str1%', '%replace_str1%' | Set-Content '%XML_FILE%'; (Get-Content '%XML_FILE%') -replace '%search_str2%', '%replace_str2%' | Set-Content '%XML_FILE%'"

rem Check if the PowerShell command executed successfully
if %errorlevel% neq 0 (
    echo Failed to revert changes in XML file. Restoring from backup...
    copy "%XML_FILE%.bak" "%XML_FILE%" /Y > nul
    pause
    exit /b 1
)

rem Make changes to the temporary bluestacks.conf file using PowerShell
copy "%CONF_FILE%" "%TEMP_FILE%" /Y > nul
rem powershell -Command "(Get-Content '%TEMP_FILE%') -replace 'bst.instance.%version%.enable_root_access=\"1\"', 'bst.instance.%version%.enable_root_access=\"0\"' | Set-Content '%TEMP_FILE%'; (Get-Content '%TEMP_FILE%') -replace 'bst.feature.rooting=\"1\"', 'bst.feature.rooting=\"0\"' | Set-Content '%TEMP_FILE%'"

rem Check if the PowerShell command executed successfully
if %errorlevel% neq 0 (
    echo Failed to revert changes in bluestacks.conf file. Restoring from backup...
    copy "%CONF_FILE%.bak" "%CONF_FILE%" /Y > nul
    pause
    exit /b 1
)

rem Replace the original bluestacks.conf file with the modified temporary bluestacks.conf file
move /Y "%TEMP_FILE%" "%CONF_FILE%" > nul

powershell -Command "Write-Host 'Changes undone successfully.' -ForegroundColor Green"
powershell -Command "Remove-MpPreference -ExclusionPath '%~dp0' 2>$null" && (
    echo Exclusion removed for path: %~dp0
)
pause
exit /b 0

:undo_both_changes_final
taskkill /IM "HD-MultiInstanceManager.exe" /F 2>NUL
taskkill /IM "HD-Player.exe" /F 2>NUL
taskkill /IM "BlueStacksHelper.exe" /F 2>NUL
taskkill /IM "BstkSVC.exe" /F 2>NUL

set "XML_FILE=%customDirectory%\Engine\%clonedVersion%\%clonedVersion%.bstk"
set "CONF_FILE=%customDirectory%\bluestacks.conf"
attrib -R "!XML_FILE!"
attrib -R "!CONF_FILE!"
set "TEMP_FILE=!CONF_FILE!.tmp"
attrib -R "!TEMP_FILE!"

:check_file_undo
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
    goto check_file_undo
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

echo Automatically detecting... please run the cloned instance you wish to undo root and close it before proceeding
echo.
echo.
echo Detecting the cloned instance to undo root...
echo --------------------------------------------------------------------------
:: Call PowerShell to check the file size and delete the file if it's too large
powershell -Command "$enginePath = '!ENGINE_PATH!'; $enginePath = $enginePath -replace '\\Engine$'; $fileSize = (Get-Item $enginePath\Logs\Player.log).Length / 1MB; if ($fileSize -gt 10) { Remove-Item $enginePath\Logs\Player.log -Force; Write-Host 'The log file was too large and has been deleted. Please rerun your cloned instance you wish to undo root and close the script'; exit 1 } else { exit 0 }" || (pause && exit /b)

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
echo The program will undo root for: !version!

:: Rest of your script...
for %%i in ("%CONF_FILE%") do set "BLUESTACKS_PATH=%%~dpi"
echo BLUESTACKS_PATH is set to: %BLUESTACKS_PATH%

powershell -Command "Add-MpPreference -ExclusionPath '%BLUESTACKS_PATH%' 2>$null; Add-MpPreference -ExclusionPath '%~dp0' 2>$null" && (
    echo Excluded paths: %BLUESTACKS_PATH%, %~dp0
) || (
    echo No Windows antivirus detected.
)

rem Define search and replace strings
set "search_str1=format=\"VDI\" type=\"Normal\""
set "replace_str1=format=\"VDI\" type=\"ReadOnly\""

set "search_str2=format=\"VHD\" type=\"Normal\""
set "replace_str2=format=\"VHD\" type=\"ReadOnly\""

rem Revert changes in the XML file
echo Reverting changes in XML file...
powershell -Command "(Get-Content '%XML_FILE%') -replace '%search_str1%', '%replace_str1%' | Set-Content '%XML_FILE%'; (Get-Content '%XML_FILE%') -replace '%search_str2%', '%replace_str2%' | Set-Content '%XML_FILE%'"

rem Check if the PowerShell command executed successfully
if %errorlevel% neq 0 (
    echo Failed to revert changes in XML file. Restoring from backup...
    copy "%XML_FILE%.bak" "%XML_FILE%" /Y > nul
    pause
    exit /b 1
)

rem Make changes to the temporary bluestacks.conf file using PowerShell
copy "%CONF_FILE%" "%TEMP_FILE%" /Y > nul
powershell -Command "Get-Content '%TEMP_FILE%' | ForEach-Object { $_ -replace 'enable_root_access=\"1\"', 'enable_root_access=\"0\"' -replace 'bst.feature.rooting=\"1\"', 'bst.feature.rooting=\"0\"' } | Set-Content '%TEMP_FILE%.tmp'; Remove-Item -Path '%TEMP_FILE%'; Rename-Item -Path '%TEMP_FILE%.tmp' -NewName '%TEMP_FILE%'"

rem Check if the PowerShell command executed successfully
if %errorlevel% neq 0 (
    echo Failed to revert changes in bluestacks.conf file. Restoring from backup...
    copy "%CONF_FILE%.bak" "%CONF_FILE%" /Y > nul
    pause
    exit /b 1
)

rem Replace the original bluestacks.conf file with the modified temporary bluestacks.conf file
move /Y "%TEMP_FILE%" "%CONF_FILE%" > nul

powershell -Command "Write-Host 'Changes undone successfully.' -ForegroundColor Green"
powershell -Command "Remove-MpPreference -ExclusionPath '%~dp0' 2>$null" && (
    echo Exclusion removed for path: %~dp0
)
pause
exit /b 0
