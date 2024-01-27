@echo off

set XML_FILE=C:\ProgramData\BlueStacks_nxt\Engine\Rvc64\Rvc64.bstk
set TEMP_FILE=%XML_FILE%.tmp

rem Display user options
echo 1. Apply changes
echo 2. Undo changes
set /p OPTION=Enter option number: 

rem Process user choice
if "%OPTION%" == "1" (
    goto apply_changes
) else if "%OPTION%" == "2" (
    goto undo_changes
) else (
    echo Invalid option.
    pause
    exit /b 1
)

:apply_changes
rem Create a backup of the original XML file
copy "%XML_FILE%" "%XML_FILE%.bak" /Y > nul

rem Make changes to the temporary file using PowerShell
copy "%XML_FILE%" "%TEMP_FILE%" /Y > nul
powershell -Command "(Get-Content '%TEMP_FILE%') -replace 'type=\"ReadOnly\"', 'type=\"Normal\"' | Set-Content '%TEMP_FILE%'"

rem Replace the original XML file with the modified temporary file
move /Y "%TEMP_FILE%" "%XML_FILE%" > nul

echo Changes applied successfully.
pause
exit /b 0
