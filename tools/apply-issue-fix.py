"""Temporary, deterministic source patcher for the investigation branch only."""
from pathlib import Path

root = Path(__file__).resolve().parent.parent

def read(path):
    return (root / path).read_bytes().decode('utf-8')

def save(path, text):
    (root / path).write_bytes(text.encode('utf-8'))

def replace(text, old, new, count=1):
    if old not in text and new in text:
        return text
    if text.count(old) != count:
        raise RuntimeError('Unexpected source at: ' + old[:90])
    return text.replace(old, new)

helper = '# BSR_HOST_HELPERS_BEGIN\n' + read('tools/bsr_host.ps1').rstrip() + '\n# BSR_HOST_HELPERS_END\n\n'
markers = {'tools/bsr_engine.ps1': '# Allow the .cmd to pass', 'tools/bsr_magisk.ps1': 'function Redact-UserPath', 'debug.cmd': '# ----------------------------- logging / redaction'}
for path, marker in markers.items():
    text = read(path)
    if '# BSR_HOST_HELPERS_BEGIN' not in text:
        index = text.index(marker)
        block = helper.replace('\n', '\r\n') if path == 'debug.cmd' else helper
        text = text[:index] + block + text[index:]
        save(path, text)

p = 'tools/bsr_engine.ps1'; t = read(p)
t = replace(t, 'Mount-DiskImage -ImagePath $Vhd -Access ReadWrite -ErrorAction Stop | Out-Null', 'Mount-BsrDiskImage $Vhd | Out-Null', 2)
t = replace(t, "Start-Process -FilePath $Player -ArgumentList @('--instance', $Instance) | Out-Null", 'Start-BsrPlayer $Player $Instance | Out-Null')
save(p,t)
p = 'tools/bsr_magisk.ps1'; t = read(p)
t = replace(t, 'Mount-DiskImage -ImagePath $Vhd -Access ReadWrite -ErrorAction Stop | Out-Null; $attached=$true', 'Mount-BsrDiskImage $Vhd | Out-Null; $attached=$true')
t = replace(t, 'if($di.Number -ne $null){$dn=$di.Number;break}', 'if($di -and $di.Number -ne $null){$dn=$di.Number;break}')
t = replace(t, "        if($null -eq $dn){ throw 'no disk number' }", "        if($null -eq $dn){\n            $disk = Get-DiskImage -ImagePath $Vhd -ErrorAction Stop | Get-Disk -ErrorAction Stop\n            if($disk){ $dn=$disk.Number }\n        }\n        if($null -eq $dn){ throw '[BSR_DISK_ATTACH] Could not determine the attached disk number.' }")
t = replace(t, "Start-Process -FilePath $Player -ArgumentList @('--instance',$Instance) | Out-Null", 'Start-BsrPlayer $Player $Instance | Out-Null')
t = replace(t, "    $lastLaunch = Start-BsrInstanceLaunch\n    Set-PlayerLogMark   # only count [Ready] lines written AFTER this launch, not a prior boot's", "    Set-PlayerLogMark   # set BEFORE launch so a fast [Ready] event is not discarded\n    $lastLaunch = Start-BsrInstanceLaunch")
t = replace(t, '    Kill-BlueStacks\n\n    # 0) one-time pristine safety backup', "    Kill-BlueStacks\n\n    Say '[*] preflight: verify Windows can attach the detected disk format (RW)...' Cyan\n    Test-BsrDiskAttach $Vhd\n\n    # 0) one-time pristine safety backup")
save(p,t)
p = 'debug.cmd'; t = read(p)
t = replace(t, 'powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %1\r\ndel', 'powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %1\r\nset "BSR_DEBUG_RC=%errorlevel%"\r\ndel')
t = replace(t, 'pause\r\nexit /b\r\n', 'pause\r\nexit /b %BSR_DEBUG_RC%\r\n')
t = replace(t, "try{ Start-Process -FilePath $Player -ArgumentList @('--instance',$Instance) | Out-Null }catch{ Log \"[!] launch failed: $($_.Exception.Message)\" Red }", '''try { Start-BsrPlayer $Player $Instance | Out-Null } catch {
  Log "[!] launch failed: $($_.Exception.Message)" Red
  Section 'VERDICT'
  Log 'HOST_LAUNCH_FAILED: Windows rejected HD-Player; ADB polling and guest probes were not attempted.' Red
  Log "Full log: $(Redact $LogFile)"
  Log 'Attach this log to the issue. The instance was NOT started.'
  exit 1
}'''.replace('\n','\r\n'))
save(p,t)
p = 'blueStackRoot.cmd'; t = read(p)
lines = [line for line in t.splitlines() if '[X] Magisk pipeline FAILED' in line]
if len(lines) != 1: raise RuntimeError('Expected one error footer')
t = t.replace(lines[0], '    echo [X] Magisk pipeline FAILED ^(exit code !BSR_RC!^). Read the first error above. A disk-provider or HD-Player launch error is not proof of antivirus corruption. For launch failures, run debug.cmd and attach its log.', 1)
save(p,t)
p = 'tools/reembed.ps1'; t = read(p)
if '$hostSource =' not in t:
    refresh = '''# Keep the three single-file entry points in sync with the canonical host helpers.
$hostSource = [IO.File]::ReadAllText((Join-Path $Here 'bsr_host.ps1')).TrimEnd("`r", "`n")
foreach ($file in @($Engine, $Magisk, (Join-Path $Here '..\\debug.cmd'))) {
    $text = [IO.File]::ReadAllText($file)
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $rx = [regex]'(?ms)^# BSR_HOST_HELPERS_BEGIN\\r?\\n.*?^# BSR_HOST_HELPERS_END(?=\\r?$)'
    if ($rx.Matches($text).Count -ne 1) { throw "Expected one host-helper block in $file" }
    $block = '# BSR_HOST_HELPERS_BEGIN' + $nl + ($hostSource -replace '\\r?\\n', $nl) + $nl + '# BSR_HOST_HELPERS_END'
    $text = $rx.Replace($text, [Text.RegularExpressions.MatchEvaluator]{ param($m) $block })
    [IO.File]::WriteAllText($file, $text, (New-Object Text.UTF8Encoding($false)))
}

'''
    t = replace(t, '$bytes = [IO.File]::ReadAllBytes($Cmd)', refresh + '$bytes = [IO.File]::ReadAllBytes($Cmd)')
    save(p,t)
print('Source changes applied. Run tools/reembed.ps1 before testing/shipping.')
