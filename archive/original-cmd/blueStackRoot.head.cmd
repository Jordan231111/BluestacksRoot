@echo off
setlocal enabledelayedexpansion
title blueStackRoot - one-file BlueStacks 5 / MSI App Player rooter

REM ====================================================================
REM  blueStackRoot.cmd  -  SINGLE-FILE BlueStacks rooter
REM
REM  A batch orchestrator + an embedded PowerShell engine + an embedded,
REM  already-decrypted setuid "su" payload.  Faithful re-implementation
REM  of BstkRooter.exe, derived from
REM     recovered/BstkRooter/BstkRooter_FULL_DERIVATION.md
REM
REM  It does NOT depend on BstkRooter.exe (you may delete that file).
REM
REM  APPLY (root) performs, in order:
REM     1. kill HD-Player / HD-MultiInstanceManager / BstkSVC / Helper
REM     2. .bstk disk mode  type="Readonly" -> type="Normal"   (global)
REM     3. bluestacks.conf  enable_root_access / enable_adb_access /
REM        bst.feature.rooting = "1"  for the chosen instance
REM     4. HD-Player.exe disk-integrity bypass (version-proof byte scan)
REM     5. install setuid su into /system:
REM          PRIMARY  - boot the instance and push it over BlueStacks' own adb
REM                     (HD-Adb), letting Android's kernel write its own ext4.
REM          FALLBACK - if the instance can't boot/root, inject it OFFLINE into
REM                     the ext4 inside Root.vhd using the EMBEDDED debugfs.
REM  UNDO reverses every step (offline su removal via the embedded debugfs).
REM
REM  The embedded engine, su, and debugfs bundle live after the EXIT below,
REM  between marker lines.  cmd never executes them; the script extracts the
REM  engine to a temp .ps1 and runs it, and the engine reads its own su /
REM  debugfs payloads back out of this file.
REM ====================================================================

REM ---- require Administrator (BstkRooter is requireAdministrator) ----
net session >nul 2>&1
if %errorlevel% NEQ 0 (
    echo Requesting administrative privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
cd /d "%~dp0"

REM ---- globals shared with the engine via environment ----
set "BSR_SELF=%~f0"
set "BSR_ENGINE=%TEMP%\bsr_engine_%RANDOM%%RANDOM%.ps1"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass"

REM ---- registry discovery: BlueStacks 5 (nxt) then MSI App Player (msi5) ----
set "EMUKEY=HKLM\SOFTWARE\BlueStacks_nxt"
call :read_reg
if not defined DATA_DIR (
    set "EMUKEY=HKLM\SOFTWARE\BlueStacks_msi5"
    call :read_reg
)
if not defined DATA_DIR set "DATA_DIR=%ProgramData%\BlueStacks_nxt"

REM ---- optional saved custom path (option 8) overrides DataDir ----
set "customDirectory="
if exist "%~dp0bluestacksconfig.txt" set /p customDirectory=<"%~dp0bluestacksconfig.txt"
if not defined customDirectory set "customDirectory=%DATA_DIR%"
:trim_cd
if not defined customDirectory goto trim_done
if "!customDirectory:~-1!"==" " ( set "customDirectory=!customDirectory:~0,-1!" & goto trim_cd )
if "!customDirectory:~-1!"=="\" set "customDirectory=!customDirectory:~0,-1!"
:trim_done
set "DATA_DIR=!customDirectory!"

REM ---- extract the embedded engine once ----
call :extract_engine || ( pause & exit /b 1 )

REM ---- normalize DataDir to the folder holding bluestacks.conf + Engine\
REM      (newer BlueStacks reports DataDir as ...\BlueStacks_nxt\Engine) ----
set "BSR_DATADIR=%DATA_DIR%"
set "BSR_USERDEF=%USERDEF_DIR%"
for /f "usebackq delims=" %%D in (`%PS% -File "%BSR_ENGINE%" -Action BaseDir`) do set "DATA_DIR=%%D"

REM ---- locate debugfs.exe (required for the offline su step only) ----
call :find_debugfs

:menu
cls
%PS% -Command "Write-Host 'blueStackRoot' -ForegroundColor Cyan -NoNewline; Write-Host ' - single-file BlueStacks rooter'"
echo ------------------------------------------------------------
echo   DataDir : %DATA_DIR%
echo   Install : %INSTALL_DIR%
echo   su      : adb online (primary) + embedded debugfs offline (fallback)
if defined BSR_DEBUGFS echo   debugfs : external override -^> %BSR_DEBUGFS%
echo ------------------------------------------------------------
echo   Root (apply):            Unroot (undo):
echo     1. Android 7  Nougat32    4. Android 7  Nougat32
echo     2. Android 9  Pie64       5. Android 9  Pie64
echo     3. Android 11 Rvc64       6. Android 11 Rvc64
echo                               7. Final undo (pick version)
echo.
echo     8. Set custom BlueStacks path        0. Exit
echo ------------------------------------------------------------
set "choice="
set /p "choice=Enter option number: "

if "%choice%"=="1" ( set "BASE=Nougat32" & goto apply )
if "%choice%"=="2" ( set "BASE=Pie64"    & goto apply )
if "%choice%"=="3" ( set "BASE=Rvc64"    & goto apply )
if "%choice%"=="4" ( set "BASE=Nougat32" & goto undo )
if "%choice%"=="5" ( set "BASE=Pie64"    & goto undo )
if "%choice%"=="6" ( set "BASE=Rvc64"    & goto undo )
if "%choice%"=="7" goto undo_pick
if "%choice%"=="8" goto set_path
if "%choice%"=="0" goto bye
echo Invalid option.
timeout /t 1 /nobreak >nul
goto menu

:undo_pick
echo   1. Android 7 Nougat32   2. Android 9 Pie64   3. Android 11 Rvc64
set "vc="
set /p "vc=Pick version to fully undo: "
if "%vc%"=="1" ( set "BASE=Nougat32" & goto undo )
if "%vc%"=="2" ( set "BASE=Pie64"    & goto undo )
if "%vc%"=="3" ( set "BASE=Rvc64"    & goto undo )
goto undo_pick

:set_path
echo Default is %ProgramData%\BlueStacks_nxt
set "np="
set /p "np=Enter your BlueStacks DataDir (folder with bluestacks.conf): "
if defined np (
    if "!np:~-1!"=="\" set "np=!np:~0,-1!"
    >"%~dp0bluestacksconfig.txt" echo !np!
    set "DATA_DIR=!np!"
    %PS% -Command "Write-Host 'Saved to bluestacksconfig.txt' -ForegroundColor Green"
)
pause
goto menu

REM ====================================================================
REM  APPLY (root)
REM ====================================================================
:apply
call :kill
call :resolve_paths
if errorlevel 1 goto menu_pause
%PS% -Command "Write-Host 'Rooting instance: ' -NoNewline; Write-Host '%BSR_INSTANCE%' -ForegroundColor Green; Write-Host 'Master (Root.vhd): %BSR_MASTER%   adb port: %BSR_ADBPORT%'"
call :av_exclude
set "BSR_EXE=%INSTALL_DIR%\HD-Player.exe"
set "BSR_ADB=%INSTALL_DIR%\HD-Adb.exe"
set "BSR_PLAYER=%INSTALL_DIR%\HD-Player.exe"

echo [1/4] Disk -^> R/W (.bstk)
%PS% -File "%BSR_ENGINE%" -Action DiskRW

echo [2/4] bluestacks.conf root flags
%PS% -File "%BSR_ENGINE%" -Action ConfRoot

echo [3/4] HD-Player.exe integrity bypass
%PS% -File "%BSR_ENGINE%" -Action Patch

echo [4/4] Install setuid su  (online via adb; offline debugfs fallback)
%PS% -File "%BSR_ENGINE%" -Action AdbRoot
set "RC=!errorlevel!"
if not "!RC!"=="0" (
    %PS% -Command "Write-Host '[~] Online adb root unavailable - falling back to OFFLINE debugfs into Root.vhd.' -ForegroundColor Yellow"
    call :kill
    %PS% -File "%BSR_ENGINE%" -Action Root
)
call :av_unexclude
echo.
%PS% -Command "Write-Host 'APPLY complete.' -ForegroundColor Green; Write-Host 'In the instance: open Magisk -> Install -> Direct Install (to /system), wait for the SU-conflict message, reboot the instance, THEN run an Undo option.'"
goto menu_pause

REM ====================================================================
REM  UNDO (unroot)
REM ====================================================================
:undo
call :kill
call :resolve_paths
if errorlevel 1 goto menu_pause
%PS% -Command "Write-Host 'Unrooting instance: ' -NoNewline; Write-Host '%BSR_INSTANCE%' -ForegroundColor Yellow"
call :av_exclude

echo [1/4] Remove su from Root.vhd (offline, embedded debugfs)
%PS% -File "%BSR_ENGINE%" -Action Unroot

echo [2/4] Restore HD-Player.exe
set "BSR_EXE=%INSTALL_DIR%\HD-Player.exe"
%PS% -File "%BSR_ENGINE%" -Action Patch -Restore

echo [3/4] bluestacks.conf flags -^> 0
%PS% -File "%BSR_ENGINE%" -Action ConfUnroot

echo [4/4] Disk -^> Readonly (.bstk)
%PS% -File "%BSR_ENGINE%" -Action DiskRO
call :av_unexclude
echo.
%PS% -Command "Write-Host 'UNDO complete.' -ForegroundColor Green"
goto menu_pause

REM ====================================================================
REM  subroutines
REM ====================================================================
:read_reg
set "INSTALL_DIR="
set "DATA_DIR="
set "USERDEF_DIR="
for /f "tokens=2*" %%a in ('reg query "%EMUKEY%" /v InstallDir 2^>nul') do set "INSTALL_DIR=%%b"
for /f "tokens=2*" %%a in ('reg query "%EMUKEY%" /v DataDir 2^>nul') do set "DATA_DIR=%%b"
for /f "tokens=2*" %%a in ('reg query "%EMUKEY%" /v UserDefinedDir 2^>nul') do set "USERDEF_DIR=%%b"
if not defined DATA_DIR set "DATA_DIR=%USERDEF_DIR%"
exit /b 0

:find_debugfs
set "BSR_DEBUGFS="
if exist "%~dp0debugfs.exe" set "BSR_DEBUGFS=%~dp0debugfs.exe"
if not defined BSR_DEBUGFS if exist "%~dp0tools\debugfs.exe" set "BSR_DEBUGFS=%~dp0tools\debugfs.exe"
if not defined BSR_DEBUGFS for %%I in (debugfs.exe) do if not "%%~$PATH:I"=="" set "BSR_DEBUGFS=%%~$PATH:I"
exit /b 0

:extract_engine
%PS% -Command "$ErrorActionPreference='Stop'; $t=[IO.File]::ReadAllText($env:BSR_SELF); $b='__BSR_ENGINE_'+'BEGIN__'; $e='__BSR_ENGINE_'+'END__'; $i=$t.IndexOf($b); $j=$t.IndexOf($e); if($i -lt 0 -or $j -le $i){throw 'engine block not found in self'}; $i=$t.IndexOf([char]10,$i)+1; [IO.File]::WriteAllText($env:BSR_ENGINE,$t.Substring($i,$j-$i))"
if not exist "%BSR_ENGINE%" ( %PS% -Command "Write-Host '[!] Failed to extract engine.' -ForegroundColor Red" & exit /b 1 )
exit /b 0

:resolve_paths
set "BSR_DATADIR=%DATA_DIR%"
set "BSR_USERDEF=%USERDEF_DIR%"
set "BSR_BASE=%BASE%"
set "BSR_INSTANCE="
set "BSR_MASTER="
set "BSR_BSTK="
set "BSR_CONF="
set "BSR_VHD="
set "BSR_ADBPORT="
for /f "usebackq delims=" %%L in (`%PS% -File "%BSR_ENGINE%" -Action Resolve`) do set "%%L"
if not defined BSR_BSTK ( %PS% -Command "Write-Host '[!] Could not resolve BlueStacks paths.' -ForegroundColor Red" & exit /b 1 )
if not exist "%BSR_BSTK%" (
    %PS% -Command "Write-Host '[!] .bstk not found: %BSR_BSTK%' -ForegroundColor Red; Write-Host '    Launch the instance once and close it, then retry.'"
    exit /b 1
)
exit /b 0

:kill
for %%P in (HD-Player.exe HD-MultiInstanceManager.exe BstkSVC.exe BlueStacksHelper.exe) do taskkill /F /IM %%P >nul 2>&1
timeout /t 1 /nobreak >nul
exit /b 0

:av_exclude
%PS% -Command "try{ Add-MpPreference -ExclusionPath '%DATA_DIR%','%~dp0' -ErrorAction Stop }catch{}" >nul 2>&1
exit /b 0

:av_unexclude
%PS% -Command "try{ Remove-MpPreference -ExclusionPath '%~dp0' -ErrorAction Stop }catch{}" >nul 2>&1
exit /b 0

:menu_pause
echo.
pause
goto menu

:bye
if exist "%BSR_ENGINE%" del /q "%BSR_ENGINE%" >nul 2>&1
endlocal
exit /b 0

REM ====================================================================
REM  Everything below this line is DATA, never executed by cmd.
REM  (engine PowerShell, then the gzip+base64 su payload)
REM ====================================================================
