@echo off

set XML_FILE=C:\ProgramData\BlueStacks_nxt\Engine\Rvc64\Rvc64.bstk
set TEMP_FILE=%XML_FILE%.tmp

rem Check if the action is specified
if "%1" == "apply" (
    goto apply_changes
) else if "%1" == "undo" (
    goto undo_changes
) else (
    echo Usage: %0 [apply | undo]
    exit /b 1
)

:apply_changes
rem Make changes to the temporary file using PowerShell
copy "%XML_FILE%" "%TEMP_FILE%" /Y > nul
powershell -Command "(Get-Content '%TEMP_FILE%') -replace 'type=\"ReadOnly\"', 'type=\"Normal\"' | Set-Content '%TEMP_FILE%'"

rem Replace the original XML file with the modified temporary file
move /Y "%TEMP_FILE%" "%XML_FILE%" > nul

echo Changes applied successfully.
exit /b 0

:undo_changes
rem Restore the original XML file from the backup file
copy "%XML_FILE%.bak" "%XML_FILE%" /Y > nul

echo Changes undone successfully.
exit /b 0
