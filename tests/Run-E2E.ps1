<#
  Run-E2E.ps1  --  end-to-end tests against a THROWAWAY VHD in %TEMP%.

  NEVER touches a real BlueStacks install.  Requires Administrator (VHD attach +
  raw disk I/O).  Auto-skips parts whose tools are missing.

  Part 1 (admin only):       create VHD -> stamp ext4 magic -> attach -> detect ->
                             carve -> write the same bytes back -> verify byte-identical.
                             Validates the dangerous disk path with NO debugfs.
  Part 2 (admin + debugfs + mke2fs):
                             make a real ext4 inside the VHD partition, run the engine
                             Root (inject su) and Unroot (remove su), verifying each.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-E2E.ps1
    ... -Debugfs C:\tools\debugfs.exe -Mke2fs C:\tools\mke2fs.exe
#>
[CmdletBinding()]
param(
    [string]$Engine,
    [string]$Cmd,
    [string]$Debugfs,
    [string]$Mke2fs,
    [int]$SizeMB = 96
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
$repo = Split-Path -Parent $here
if (-not $Engine) { $Engine = Join-Path $repo 'tools\bsr_engine.ps1' }
if (-not $Cmd) { $Cmd = Join-Path $repo 'blueStackRoot.cmd' }
if (-not $Debugfs) { $d = Join-Path $repo 'tools\debugfs\debugfs.exe'; if (Test-Path $d) { $Debugfs = $d } }
if (-not $Mke2fs) {
    foreach ($p in @((Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\mke2fs.exe'))) { if (Test-Path $p) { $Mke2fs = $p; break } }
    if (-not $Mke2fs) { $c = Get-Command mke2fs.exe -EA SilentlyContinue; if ($c) { $Mke2fs = $c.Source } }
}
# native e2fsprogs tools print to stderr; don't let that throw under EAP=Stop
function NativeQuiet([scriptblock]$sb) { $o = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; try { & $sb 2>&1 | Out-String } finally { $ErrorActionPreference = $o } }

$pass = 0; $fail = 0; $skip = 0
function Ok($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:pass++ }
function No($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fail++ }
function Sk($m) { Write-Host "  [SKIP] $m" -ForegroundColor DarkGray; $script:skip++ }
function Check($c, $m) { if ($c) { Ok $m } else { No $m } }
function RunEng([string[]]$a) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Engine @a 2>&1 | Out-String } finally { $ErrorActionPreference = $old }
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) { Sk "E2E needs Administrator (VHD attach). Re-run elevated."; Write-Host "PASS=$pass FAIL=$fail SKIP=$skip"; exit 0 }

$work = Join-Path $env:TEMP ("bsr_e2e_" + $PID)
New-Item -ItemType Directory -Path $work -Force | Out-Null
$vhd = Join-Path $work 'throwaway.vhd'

function Diskpart([string[]]$lines) {
    $sf = Join-Path $work 'dp.txt'
    Set-Content -LiteralPath $sf -Value ($lines -join "`r`n") -Encoding ascii
    $o = & diskpart.exe /s $sf 2>&1 | Out-String
    Remove-Item $sf -Force -EA SilentlyContinue
    return $o
}
function Read-DevBytes([string]$dev, [long]$off, [int]$n) {
    $fs = [IO.File]::Open($dev, 'Open', 'Read', 'ReadWrite')
    try { $base = [long]([Math]::Floor($off / 512) * 512); $d = [int]($off - $base); $need = [int]([Math]::Ceiling(($d + $n) / 512.0) * 512); $b = New-Object byte[] $need; $fs.Position = $base; [void]$fs.Read($b, 0, $need); $r = New-Object byte[] $n; [Array]::Copy($b, $d, $r, 0, $n); return $r } finally { $fs.Close() }
}
function Write-DevBytes([string]$dev, [long]$off, [byte[]]$data) {
    $fs = [IO.File]::Open($dev, 'Open', 'ReadWrite', 'ReadWrite')
    try { $base = [long]([Math]::Floor($off / 512) * 512); $d = [int]($off - $base); $sec = New-Object byte[] 512; $fs.Position = $base; [void]$fs.Read($sec, 0, 512); [Array]::Copy($data, 0, $sec, $d, $data.Length); $fs.Position = $base; $fs.Write($sec, 0, 512); $fs.Flush() } finally { $fs.Close() }
}

try {
    Write-Host "`n=== Part 1: VHD attach / ext4-detect / carve / write-back ===" -ForegroundColor Cyan
    Write-Host "creating throwaway VHD ($SizeMB MB) via diskpart..." -ForegroundColor DarkGray
    [void](Diskpart @("create vdisk file=`"$vhd`" maximum=$SizeMB type=fixed", "select vdisk file=`"$vhd`"", "attach vdisk", "create partition primary", "detach vdisk"))
    Check (Test-Path $vhd) "throwaway VHD created with a primary partition"

    # stamp ext4 magic 0xEF53 at partition.Offset + 0x438
    Mount-DiskImage -ImagePath $vhd -Access ReadWrite | Out-Null
    $stamped = $false
    try {
        $dn = (Get-DiskImage -ImagePath $vhd).Number
        $part = Get-Partition -DiskNumber $dn | Sort-Object Offset | Select-Object -First 1
        $pdev = "\\.\Harddisk$($dn)Partition$($part.PartitionNumber)"
        Write-DevBytes $pdev 0x438 ([byte[]](0x53, 0xEF))
        $chk = Read-DevBytes $pdev 0x438 2
        $stamped = ($chk[0] -eq 0x53 -and $chk[1] -eq 0xEF)
    }
    finally { Dismount-DiskImage -ImagePath $vhd | Out-Null }
    Check $stamped "ext4 superblock magic stamped at partition+0x438"

    $r = RunEng @('-Action', 'VhdSelfTest', '-Vhd', $vhd)
    Check ($r.Code -eq 0 -and $r.Out -match 'byte-identical') "VHD carve + write-back is byte-identical (no corruption)"
    if ($r.Code -ne 0) { Write-Host $r.Out -ForegroundColor DarkGray }

    Write-Host "`n=== Part 2: full su Root/Unroot in the VHD (needs debugfs + mke2fs) ===" -ForegroundColor Cyan
    if ($Debugfs -and $Mke2fs -and (Test-Path $Debugfs) -and (Test-Path $Mke2fs)) {
        # build a real ext4 in the partition: carve -> mke2fs -> mkdir tree -> write back
        Mount-DiskImage -ImagePath $vhd -Access ReadWrite | Out-Null
        try {
            $dn = (Get-DiskImage -ImagePath $vhd).Number
            $part = Get-Partition -DiskNumber $dn | Sort-Object Offset | Select-Object -First 1
            $pdev = "\\.\Harddisk$($dn)Partition$($part.PartitionNumber)"
            $img = Join-Path $work 'fs.img'
            $fs = [IO.File]::Open($pdev, 'Open', 'Read', 'ReadWrite'); $buf = New-Object byte[] $part.Size; [void]$fs.Read($buf, 0, $buf.Length); $fs.Close()
            [IO.File]::WriteAllBytes($img, $buf)
            NativeQuiet { & $Mke2fs -F -t ext4 -q $img } | Out-Null   # engine Root creates the /android/system/xbin tree itself
            $in = [IO.File]::OpenRead($img); $fw = [IO.File]::Open($pdev, 'Open', 'ReadWrite', 'ReadWrite'); $b2 = New-Object byte[] (4MB)
            while (($k = $in.Read($b2, 0, $b2.Length)) -gt 0) { if ($k % 512) { $k += 512 - ($k % 512) }; $fw.Write($b2, 0, $k) }
            $in.Close(); $fw.Flush(); $fw.Close()
        }
        finally { Dismount-DiskImage -ImagePath $vhd | Out-Null }

        $r = RunEng @('-Action', 'Root', '-Vhd', $vhd, '-SelfPath', $Cmd, '-Debugfs', $Debugfs, '-NoBackup')
        Check ($r.Code -eq 0 -and $r.Out -match 'Rooted successfully') "engine Root injected su into the VHD ext4"

        # verify su present by re-carving and statting with debugfs
        Mount-DiskImage -ImagePath $vhd -Access ReadWrite | Out-Null
        try {
            $dn = (Get-DiskImage -ImagePath $vhd).Number
            $part = Get-Partition -DiskNumber $dn | Sort-Object Offset | Select-Object -First 1
            $pdev = "\\.\Harddisk$($dn)Partition$($part.PartitionNumber)"
            $img = Join-Path $work 'fs2.img'
            $fs = [IO.File]::Open($pdev, 'Open', 'Read', 'ReadWrite'); $buf = New-Object byte[] $part.Size; [void]$fs.Read($buf, 0, $buf.Length); $fs.Close()
            [IO.File]::WriteAllBytes($img, $buf)
        }
        finally { Dismount-DiskImage -ImagePath $vhd | Out-Null }
        $stat = NativeQuiet { & $Debugfs -R "stat /android/system/xbin/su" ($img -replace '\\', '/') }
        Check ($stat -match '(?im)Mode:\s*0*6755') "su present in VHD ext4 with mode 06755 (setuid)"

        $r = RunEng @('-Action', 'Unroot', '-Vhd', $vhd, '-Debugfs', $Debugfs)
        Check ($r.Code -eq 0 -and $r.Out -match 'Unrooted successfully') "engine Unroot removed su from the VHD ext4"
    }
    else { Sk "Part 2 full su Root/Unroot (pass -Debugfs and -Mke2fs to enable)" }
}
finally {
    # make sure nothing stays attached, then delete the throwaway VHD
    try { Dismount-DiskImage -ImagePath $vhd -EA SilentlyContinue | Out-Null } catch {}
    Remove-Item $work -Recurse -Force -EA SilentlyContinue
}

Write-Host "`n================ E2E SUMMARY ================" -ForegroundColor Cyan
$col = if ($fail) { 'Red' } else { 'Green' }
Write-Host ("  PASS=$pass  FAIL=$fail  SKIP=$skip") -ForegroundColor $col
exit ([int]($fail -gt 0))
