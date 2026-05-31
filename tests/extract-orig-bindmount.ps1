# READ-ONLY: extract the pristine /android/system/bin/bindmount from Root.vhd.bsrbak
# so we can restore the genuine stock script (no traces of our edits).
$ErrorActionPreference='Continue'
$Bak='C:\ProgramData\BlueStacks_nxt\Engine\Rvc64\Root.vhd.bsrbak'
$Dfs='C:\Users\Jordan\Documents\BluestacksRoot\tools\debugfs\debugfs.exe'
$OutDir='C:\Users\Jordan\Documents\BluestacksRoot\tools\su_src'
function Log($m,$c='Gray'){ Write-Host $m -ForegroundColor $c }
function Fwd($p){ $p -replace '\\','/' }
function Read-DeviceBytes($dev,$off,$cnt){ $fs=[System.IO.File]::Open($dev,'Open','Read','ReadWrite'); try{ $sb=[long]([Math]::Floor($off/512)*512); $d=[int]($off-$sb); $need=[int]([Math]::Ceiling(($d+$cnt)/512.0)*512); $b=New-Object byte[] $need; $fs.Position=$sb; [void]$fs.Read($b,0,$need); $r=New-Object byte[] $cnt; [Array]::Copy($b,$d,$r,0,$cnt); $r } finally{ $fs.Close() } }

foreach($p in 'HD-Player','HD-MultiInstanceManager','BstkSVC','HD-Agent','BlueStacksHelper','BlueStacksAppplayerWeb'){ Get-Process -Name $p -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue }
Start-Sleep 4

$Tmp=Join-Path $env:TEMP 'bsr_work\orig_root.vhd'
New-Item -ItemType Directory -Path (Split-Path $Tmp) -Force | Out-Null
Log "== copy bsrbak -> $Tmp (.vhd ext for DiskImage) ==" Cyan
Copy-Item -LiteralPath $Bak -Destination $Tmp -Force
$attached=$false
try {
  Log '== attach READ-ONLY ==' Cyan
  Mount-DiskImage -ImagePath $Tmp -Access ReadOnly -ErrorAction Stop | Out-Null; $attached=$true
  $dn=$null; for($i=0;$i -lt 20;$i++){ $di=Get-DiskImage -ImagePath $Tmp -EA SilentlyContinue; if($di.Number -ne $null){$dn=$di.Number;break}; Start-Sleep -Milliseconds 250 }
  if($null -eq $dn){ throw 'no disk number' }
  $parts=@(Get-Partition -DiskNumber $dn | Sort-Object Offset)
  $dev=$null
  foreach($p in $parts){ $d="\\.\Harddisk$($dn)Partition$($p.PartitionNumber)"; try{ $m=Read-DeviceBytes $d 0x438 2; if($m[0]-eq 0x53 -and $m[1]-eq 0xEF){ $dev=$d; break } }catch{} }
  if(-not $dev){ throw 'no ext4 partition' }
  Log "   ext4 device=$dev"

  $out=Join-Path $OutDir 'bindmount.orig'
  if(Test-Path $out){ Remove-Item $out -Force }
  Log '== debugfs dump bindmount (direct device, no carve) ==' Cyan
  $scr=Join-Path $env:TEMP 'bsr_work\dump_bm.txt'; New-Item -ItemType Directory -Path (Split-Path $scr) -Force | Out-Null
  Set-Content -LiteralPath $scr -Value ("stat /android/system/bin/bindmount`ndump /android/system/bin/bindmount $(Fwd $out)") -Encoding ascii -NoNewline
  $o = & $Dfs @('-f',$scr,$dev) 2>&1 | Out-String
  Log $o
  if(Test-Path $out){ Log "[+] extracted -> $out ($((Get-Item $out).Length) bytes)" Green } else { Log '[!] dump produced no file' Red }
} finally {
  if($attached){ try{ Dismount-DiskImage -ImagePath $Tmp | Out-Null; Log '== detached ==' }catch{ Log 'WARN detach failed' Red } }
  Remove-Item -LiteralPath $Tmp -Force -EA SilentlyContinue
}
