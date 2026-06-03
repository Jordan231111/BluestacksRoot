# READ-ONLY investigation: enumerate ALL rooting-related files in the PRISTINE factory
# Root.vhd (bsrbak, taken before any of our work) so we can tell factory vs injected.
$ErrorActionPreference='Continue'
$Here = if($PSScriptRoot){ $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Repo = Split-Path -Parent $Here
$Bak='C:\ProgramData\BlueStacks_nxt\Engine\Rvc64\Root.vhd.bsrbak'
$Dfs=Join-Path $Repo 'tools\debugfs\debugfs.exe'
function Redact-UserPath($v){ if($null -eq $v){return $v}; $s=[string]$v; $s=$s -replace '(?i)([A-Z]:[\\/]+Users[\\/]+)([^\\/]+)(?=$|[\\/])','${1}xxxxx'; $s=$s -replace '(?i)(/Users/)([^/]+)(?=$|/)','${1}xxxxx'; $s }
function Log($m,$c='Gray'){ Write-Host (Redact-UserPath $m) -ForegroundColor $c }
function Fwd($p){ $p -replace '\\','/' }
function Read-DeviceBytes($dev,$off,$cnt){ $fs=[System.IO.File]::Open($dev,'Open','Read','ReadWrite'); try{ $sb=[long]([Math]::Floor($off/512)*512); $d=[int]($off-$sb); $need=[int]([Math]::Ceiling(($d+$cnt)/512.0)*512); $b=New-Object byte[] $need; $fs.Position=$sb; [void]$fs.Read($b,0,$need); $r=New-Object byte[] $cnt; [Array]::Copy($b,$d,$r,0,$cnt); $r } finally{ $fs.Close() } }

foreach($p in 'HD-Player','HD-MultiInstanceManager','BstkSVC','HD-Agent','BlueStacksHelper','BlueStacksAppplayerWeb'){ Get-Process -Name $p -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue }
Start-Sleep 4

$Tmp=Join-Path $env:TEMP 'bsr_work\factory_root.vhd'
New-Item -ItemType Directory -Path (Split-Path $Tmp) -Force | Out-Null
Log "== copy bsrbak -> temp .vhd ==" Cyan
Copy-Item -LiteralPath $Bak -Destination $Tmp -Force
$attached=$false
try {
  Mount-DiskImage -ImagePath $Tmp -Access ReadOnly -ErrorAction Stop | Out-Null; $attached=$true
  $dn=$null; for($i=0;$i -lt 20;$i++){ $di=Get-DiskImage -ImagePath $Tmp -EA SilentlyContinue; if($di.Number -ne $null){$dn=$di.Number;break}; Start-Sleep -Milliseconds 250 }
  if($null -eq $dn){ throw 'no disk number' }
  $dev=$null
  foreach($p in @(Get-Partition -DiskNumber $dn | Sort-Object Offset)){ $d="\\.\Harddisk$($dn)Partition$($p.PartitionNumber)"; try{ $m=Read-DeviceBytes $d 0x438 2; if($m[0]-eq 0x53 -and $m[1]-eq 0xEF){ $dev=$d; break } }catch{} }
  if(-not $dev){ throw 'no ext4 partition' }
  Log "   factory ext4 device=$dev" DarkGray

  $scr=Join-Path $env:TEMP 'bsr_work\factinv.txt'
  $cmds = @(
    '# --- xbin su family ---',
    'stat /android/system/xbin/su',
    'stat /android/system/xbin/daemonsu',
    'ls -l /android/system/xbin/bstk',
    '# --- /system/bin su/magisk (should be ABSENT factory) ---',
    'stat /android/system/bin/su',
    'stat /android/system/bin/magisk',
    'stat /android/system/bin/magiskpolicy',
    'stat /android/system/bin/bindmount',
    '# --- init wiring (bootanim should be STOCK, no magisk) ---',
    'stat /android/system/etc/init/bootanim.rc',
    'stat /android/system/etc/init/bootanim.rc.gz',
    'stat /android/system/etc/init/magisk',
    'stat /android/system/etc/bsr_su',
    '# --- full xbin listing (filter su/daemon in PS) ---',
    'ls -l /android/system/xbin'
  )
  Set-Content -LiteralPath $scr -Value ($cmds -join "`n") -Encoding ascii -NoNewline
  Log '================= FACTORY (bsrbak) ROOTING INVENTORY =================' Cyan
  $out = & $Dfs @('-f',$scr,$dev) 2>&1 | Out-String
  # print everything except the giant busybox symlink list; keep su/daemon/magisk lines from xbin ls
  $lines = $out -split "`r?`n"
  $inXbinLs=$false
  foreach($ln in $lines){
    if($ln -match 'ls -l /android/system/xbin$'){ $inXbinLs=$true; Write-Host $ln -ForegroundColor Yellow; continue }
    if($inXbinLs){ if($ln -match 'su|daemon|magisk|bstk|busybox'){ Write-Host "   $ln" } }
    else { Write-Host $ln }
  }
} finally {
  if($attached){ try{ Dismount-DiskImage -ImagePath $Tmp | Out-Null; Log '== detached ==' }catch{ Log 'WARN detach failed' Red } }
  Remove-Item -LiteralPath $Tmp -Force -EA SilentlyContinue
}
