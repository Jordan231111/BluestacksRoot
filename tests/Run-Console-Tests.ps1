# Optional Windows desktop check: render the shipped menu into a separate hidden
# console and read its real screen buffer at several font sizes and viewports.
# This changes only the child console, never Windows display settings.
[CmdletBinding()]
param([switch]$Worker, [string]$ResultPath)
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools\bsr_build.ps1')
. (Join-Path $PSScriptRoot 'Test-Support.ps1')

if($Worker) {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BsrConsoleTest {
    [StructLayout(LayoutKind.Sequential)] public struct Coord { public short X, Y; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct Font {
        public uint Size, Index; public Coord Cell; public int Family, Weight;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string Face;
    }
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int handle);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool SetCurrentConsoleFontEx(IntPtr output, bool maximum, ref Font font);
    public static void SetFont(short pixels) {
        var font=new Font { Size=(uint)Marshal.SizeOf(typeof(Font)),
            Cell=new Coord { X=0, Y=pixels }, Family=54, Weight=400, Face="Consolas" };
        if(!SetCurrentConsoleFontEx(GetStdHandle(-11),false,ref font))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
}
'@
        $env:BSR_SELF=Join-Path $repo 'blueStackRoot.cmd'
        . ([scriptblock]::Create((Get-BsrEmbeddedText ([IO.File]::ReadAllBytes($env:BSR_SELF)) 'LAUNCHER')))
        $script:installDir='C:\Games\'+('Long install folder\'*8)
        $script:dataDir='C:\Users\PrivateName\'+('Long data folder\'*8)
        $results=New-Object System.Collections.Generic.List[object]
        foreach($pixels in @(16,20,24,28,32,40,48)) {
            [Console]::SetWindowSize(40,16)
            [BsrConsoleTest]::SetFont($pixels)
            foreach($size in @(@(40,18),@(60,20),@(80,25),@(120,35))) {
                $width=[Math]::Min($size[0],[Console]::LargestWindowWidth)
                $height=[Math]::Min($size[1],[Console]::LargestWindowHeight)
                [Console]::SetWindowSize(1,1)
                [Console]::SetBufferSize($width,[Math]::Max(100,$height))
                [Console]::SetWindowSize($width,$height)
                Show-LauncherMenu
                Write-Host '  Enter option > : ' -NoNewline
                $cursor=[Console]::CursorTop
                $rectangle=New-Object Management.Automation.Host.Rectangle(0,0,($width-1),($height-1))
                $buffer=$Host.UI.RawUI.GetBufferContents($rectangle)
                $lines=for($row=0;$row -lt $height;$row++) {
                    $line=New-Object Text.StringBuilder
                    for($column=0;$column -lt $width;$column++){
                        $cell=$buffer.GetValue($row,$column)
                        [void]$line.Append($cell.Character)
                    }
                    $line.ToString().TrimEnd()
                }
                $text=$lines -join "`n"
                $ok=$cursor -lt $height -and $text -notmatch 'PrivateName'
                foreach($action in @('1  Android 9','2  Android 11','3  Android 13','4  Android 9','5  Android 11','6  Android 13','7  Full host scrub','8  Set custom path','0  Exit','Enter option >')) {
                    if(-not $text.Contains($action)){$ok=$false}
                }
                $results.Add([pscustomobject]@{FontPixels=$pixels;Width=$width;Height=$height;CursorRow=$cursor;Pass=$ok;Text=$text})
            }
        }
        [IO.File]::WriteAllText($ResultPath,($results | ConvertTo-Json -Depth 4))
        exit 0
    } catch {
        [IO.File]::WriteAllText($ResultPath,(@{Error=$_.Exception.Message;Stack=$_.ScriptStackTrace} | ConvertTo-Json))
        exit 1
    }
}

$work=Join-Path ([IO.Path]::GetTempPath()) ('bsr_console_test_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$process=$null
try {
    $result=Join-Path $work 'console.json'
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Worker','-ResultPath',$result)
    $commandLine=($arguments | ForEach-Object {Quote-BsrNativeArgument $_}) -join ' '
    $process=Start-Process powershell.exe -ArgumentList $commandLine -WindowStyle Hidden -PassThru
    if(-not $process.WaitForExit(30000)){$process.Kill();throw 'Console test timed out.'}
    if(-not (Test-Path -LiteralPath $result)){throw 'The hidden console did not write its results.'}
    $results=[IO.File]::ReadAllText($result) | ConvertFrom-Json
    if($process.ExitCode -ne 0){throw ($results.Error+' '+$results.Stack)}
    $failed=@($results | Where-Object {-not $_.Pass})
    foreach($entry in $results) {
        $status=if($entry.Pass){'PASS'}else{'FAIL'}
        Write-Host "[$status] native console: $($entry.Width)x$($entry.Height), Consolas $($entry.FontPixels)px, prompt row $($entry.CursorRow)"
        if(-not $entry.Pass){Write-Host $entry.Text}
    }
    Write-Host "RESULT: $($results.Count-$failed.Count) passed, $($failed.Count) failed"
    exit ([int]($failed.Count -gt 0))
} finally {
    if($process){$process.Dispose()}
    Remove-BsrTestDirectory $work
}
