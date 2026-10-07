# Diagnostic file/cloud/temp/payload fixtures. Never starts BlueStacks or mounts
# a disk. Workers exercise the actual self-contained debug.cmd under PS 5.1.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools\bsr_build.ps1')
. (Join-Path $PSScriptRoot 'Test-Support.ps1')
$debug=Join-Path $repo 'debug.cmd'
$text=[IO.File]::ReadAllText($debug)
$body=$text.Substring($text.IndexOf('#__BSR'+'_DEBUG_PS__'))
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($body,[ref]$tokens,[ref]$errors)
if($errors){throw ($errors.Message -join '; ')}
foreach($name in @('Redact','Compact','Log-Failure','New-DiagnosticLog','Get-DiagnosticPathFlags','Get-DiagnosticSyncRoot','Report-DiagnosticPath','Get-DiagnosticHash','Get-DiagnosticBlock','Remove-DiagnosticScratch','Invoke-DiagnosticTempProbe','Invoke-DiagnosticWorker')){
    $node=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false))
    if($node.Count -ne 1){throw "Missing or duplicate diagnostic function: $name"}
    . ([scriptblock]::Create($node[0].Extent.Text))
}
$work=Join-Path ([IO.Path]::GetTempPath()) ('bsr_preflight_test_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$pass=0;$fail=0
function Check($ok,$name){if($ok){$script:pass++;Write-Host "[PASS] $name"}else{$script:fail++;Write-Host "[FAIL] $name"}}
$script:lines=New-Object System.Collections.Generic.List[string]
$script:DiagnosticFailures=0
function Log($message,$color){$script:lines.Add((Redact $message))}
$oldSelf=$env:SELF;$oldTemp=$env:TEMP;$oldTmp=$env:TMP
$oldDrive=$env:OneDrive;$oldConsumer=$env:OneDriveConsumer;$oldCommercial=$env:OneDriveCommercial
try {
    $env:SELF=$debug
    $normal=Get-DiagnosticPathFlags 0x20
    Check (-not $normal.Offline -and -not $normal.RecallOnDataAccess -and -not $normal.Unpinned) 'ordinary local file is not classified as requiring retrieval'
    $cloud=Get-DiagnosticPathFlags (0x400 -bor 0x1000 -bor 0x100000 -bor 0x400000)
    Check ($cloud.ReparsePoint -and $cloud.Offline -and $cloud.Unpinned -and $cloud.RecallOnDataAccess -and -not $cloud.Pinned) 'offline/unpinned/recall flags decode even under .NET Framework'
    $reparse=Get-DiagnosticPathFlags 0x400
    Check (-not $reparse.Offline -and -not $reparse.RecallOnDataAccess) 'a junction or other reparse point alone does not establish a cloud-content problem'

    $env:OneDriveCommercial=Join-Path $work 'OneDrive - Example'
    $env:OneDrive='';$env:OneDriveConsumer=''
    Check ((Get-DiagnosticSyncRoot (Join-Path $env:OneDriveCommercial 'Desktop\rooter.cmd')) -eq 'OneDriveCommercial') 'OneDrive membership uses the configured sync root'
    Check (-not (Get-DiagnosticSyncRoot ($env:OneDriveCommercial+'-unrelated\rooter.cmd'))) 'similarly named sibling directory is not treated as a sync root'
    Check (-not (Get-DiagnosticSyncRoot (Join-Path $work 'Not configured\OneDrive\rooter.cmd'))) 'a OneDrive name alone is not evidence of sync-root membership'

    $blocked=Join-Path $work 'not-a-directory';[IO.File]::WriteAllText($blocked,'fixture')
    $fallback=Join-Path $work 'fallback'
    $log=New-DiagnosticLog @($blocked,$fallback)
    Check ([IO.File]::Exists($log) -and [IO.Path]::GetDirectoryName($log) -ceq $fallback) 'log creation falls back when the preferred destination cannot be used'

    $temp=Join-Path $work ("Users\Profile [1] & O'Brien ! "+[char]0xe9+'\AppData\Local\Temp')
    [void][IO.Directory]::CreateDirectory($temp)
    Invoke-DiagnosticTempProbe $temp
    Check (($script:lines -join "`n") -match 'TEMP PowerShell -File launch: PASS' -and @(Get-ChildItem -LiteralPath $temp -Force).Count -eq 0) 'temp probe tests real I/O and script execution, then removes only its scratch files'
    $env:TEMP=$temp;$env:TMP=$temp
    $script:lines.Clear()
    $code=Invoke-DiagnosticWorker 'Temp' (Join-Path $work 'missing-temp')
    $output=$script:lines -join "`n"
    Check ($code -ne 0 -and $output -match 'Temp root metadata|configured temporary directory' -and $output -match 'HRESULT=') 'missing temp directory produces a failed probe with native exception evidence'
    $env:SELF=Join-Path $work 'missing-debug.cmd'
    $script:lines.Clear();$code=Invoke-DiagnosticWorker 'File' $debug
    $output=$script:lines -join "`n"
    Check ($code -ne 0 -and $output -match 'Worker bootstrap failed' -and $output -notmatch '<Objs|EncodedCommand' -and -not $output.Contains($env:USERPROFILE)) 'worker bootstrap failures are readable and redact paths without CLI XML metadata'
    $env:SELF=$debug

    $locked=Join-Path $work 'locked [file].cmd';[IO.File]::WriteAllText($locked,'fixture')
    $lock=[IO.File]::Open($locked,'Open','Read','None')
    try {
        $script:lines.Clear();$code=Invoke-DiagnosticWorker 'File' $locked
        $output=$script:lines -join "`n"
        Check ($code -ne 0 -and $output -match '0x80070020' -and $output -match 'source:|stack:') 'locked file preserves sharing-violation HRESULT and the failing operation'
    }finally{$lock.Dispose()}

    $cmdBytes=[IO.File]::ReadAllBytes((Join-Path $repo 'blueStackRoot.cmd'))
    $rooter=Join-Path $work "rooter [1] & O'Brien !.cmd"
    [IO.File]::WriteAllBytes($rooter,$cmdBytes)
    $script:lines.Clear();$code=Invoke-DiagnosticWorker 'Payload' $rooter
    $output=$script:lines -join "`n"
    Check ($code -eq 0 -and $output -match 'PASS Ensure-MagiskApk' -and $output -match 'PASS Ensure-BsrSu' -and $output -match 'PASS Ensure-Debugfs' -and $output -match 'debugfs executable/DLL check:') 'actual embedded payload functions and debugfs runtime succeed from complex paths'
    Check ($output -notmatch '<Objs|<S N="User">|EncodedCommand' -and -not $output.Contains($env:USERPROFILE)) 'worker output contains plain redacted evidence without CLI XML identity metadata'
    Check ((Get-BsrFileHash $rooter) -ceq (Get-BsrBytesHash $cmdBytes) -and @(Get-ChildItem -LiteralPath $temp -Force).Count -eq 0) 'payload probe leaves its source unchanged and cleans all extracted files'

    # Damage only the bootstrap block; APK/debugfs must still be tested, and the
    # exact failing function must be retained without asserting an AV cause.
    $broken=Set-BsrEmbeddedBlock $cmdBytes 'BSRSU' ([Text.Encoding]::ASCII.GetBytes("not-base64`r`n"))
    [IO.File]::WriteAllBytes($rooter,$broken)
    $script:lines.Clear();$code=Invoke-DiagnosticWorker 'Payload' $rooter
    $output=$script:lines -join "`n"
    Check ($code -ne 0 -and $output -match 'Payload preparation: Ensure-BsrSu' -and $output -match 'PASS Ensure-Debugfs' -and $output -match 'HRESULT=') 'damaged bootstrap is identified while independent payload checks continue'
    Check ($output -notmatch 'antivirus quarantined it|antivirus most likely removed') 'damaged payload evidence does not invent an antivirus cause'

    $magisk=Get-BsrEmbeddedText $cmdBytes 'MAGISK'
    $parsed=[Management.Automation.Language.Parser]::ParseInput($magisk,[ref]$tokens,[ref]$errors)
    $suFunction=$parsed.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Ensure-BsrSu'},$false)
    $slow=$magisk.Replace($suFunction.Extent.Text,'function Ensure-BsrSu { Start-Sleep -Seconds 30 }')
    [IO.File]::WriteAllBytes($rooter,(Set-BsrEmbeddedBlock $cmdBytes 'MAGISK' ([Text.Encoding]::UTF8.GetBytes($slow))))
    $cache=Join-Path $temp 'bsr_work';[void][IO.Directory]::CreateDirectory($cache)
    $sentinel=Join-Path $cache 'existing.txt';[IO.File]::WriteAllText($sentinel,'keep')
    $script:lines.Clear();$code=Invoke-DiagnosticWorker 'Payload' $rooter 8
    $output=$script:lines -join "`n"
    Check ($code -ne 0 -and $output -match 'timed out' -and $output -match 'BEGIN Ensure-BsrSu') 'hung extraction preserves the last reached stage and returns failure'
    Check (@(Get-ChildItem -LiteralPath $temp -Directory -Filter 'bsr_diag_probe_*').Count -eq 0 -and [IO.File]::ReadAllText($sentinel) -ceq 'keep') 'parent cleans timed-out extraction without deleting a pre-existing rooter cache'

    # Missing markers fail before any extraction or runtime actions.
    [IO.File]::WriteAllText($rooter,'incomplete download')
    $script:lines.Clear();$code=Invoke-DiagnosticWorker 'Payload' $rooter
    Check ($code -ne 0 -and ($script:lines -join "`n") -match 'incomplete ENGINE block') 'truncated rooter is distinguished from temp, cloud and emulator failures'

    $runner=Join-Path $work 'run-files-only.ps1'
    [IO.File]::WriteAllText($runner,@'
param($Diagnostic,$Rooter,$Logs)
$env:SELF=$Diagnostic
$t=[IO.File]::ReadAllText($Diagnostic)
& ([scriptblock]::Create($t.Substring($t.IndexOf('#__BSR'+'_DEBUG_PS__')))) -FilesOnly -RooterPath $Rooter -LogDirectory $Logs
'@,(New-Object Text.UTF8Encoding($true)))
    [IO.File]::WriteAllBytes($rooter,$cmdBytes)
    $logs=Join-Path $work 'integration-logs'
    $result=Invoke-BsrNative 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$runner,$debug,$rooter,$logs) 45
    Check ($result.ExitCode -eq 0 -and $result.Output -match 'Rooter payloads : PASS' -and $result.Output -match 'BlueStacks / ADB : SKIP' -and $result.Output -notmatch 'CLEAN START|LAUNCH \+ WATCH') 'files-only integration stops before any BlueStacks discovery, restart or disk probe'
    $saved=@(Get-ChildItem -LiteralPath $logs -Filter '*.log')
    Check ($saved.Count -eq 1 -and [IO.File]::ReadAllText($saved[0].FullName).Contains('DIAGNOSTIC SUMMARY')) 'complete files-only evidence and summary are saved to a real log'

    $badResult=Invoke-BsrNative 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$runner,$debug,(Join-Path $work 'missing.cmd'),$logs) 45
    Check ($badResult.ExitCode -ne 0 -and $badResult.Output -match 'Rooter payloads : FAIL' -and $badResult.Output -match 'DIAGNOSTIC SUMMARY') 'missing rooter still saves a final summary and returns failure'
} catch {$fail++;Write-Host "[FAIL] $_";Write-Host $_.ScriptStackTrace}
finally {
    $env:SELF=$oldSelf;$env:TEMP=$oldTemp;$env:TMP=$oldTmp
    $env:OneDrive=$oldDrive;$env:OneDriveConsumer=$oldConsumer;$env:OneDriveCommercial=$oldCommercial
    Remove-BsrTestDirectory $work
}
Write-Host "RESULT: $pass passed, $fail failed"
exit ([int]($fail -gt 0))
