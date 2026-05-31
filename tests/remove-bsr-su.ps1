# Offline-edit live Root.vhd to ERASE our su (make Magisk the sole root, no traces):
#   - remove /android/system/etc/bsr_su
#   - restore the STOCK /android/system/bin/bindmount (uid 1000, gid 1000, mode 0775)
# Keeps Magisk's /system install + the HD-Player patch untouched.
# Backs up the current (Magisk-good) Root.vhd first.
$ErrorActionPreference='Stop'
$Vhd='C:\ProgramData\BlueStacks_nxt\Engine\Rvc64\Root.vhd'
$BakGood='C:\ProgramData\BlueStacks_nxt\Engine\Rvc64\Root.vhd.magiskgood'
$Dfs='C:\Users\Jordan\Documents\BluestacksRoot\tools\debugfs\debugfs.exe'
$BmOrig='C:\Users\Jordan\Documents\BluestacksRoot\tools\su_src\bindmount.orig'
function Log($m,$c='Gray'){ Write-Host $m -ForegroundColor $c }
function Fwd($p){ $p -replace '\\','/' }
function Read-DeviceBytes($dev,$off,$cnt){ $fs=[System.IO.File]::Open($dev,'Open','Read','ReadWrite'); try{ $sb=[long]([Math]::Floor($off/512)*512); $d=[int]($off-$sb); $need=[int]([Math]::Ceiling(($d+$cnt)/512.0)*512); $b=New-Object byte[] $need; $fs.Position=$sb; [void]$fs.Read($b,0,$need); $r=New-Object byte[] $cnt; [Array]::Copy($b,$d,$r,0,$cnt); $r } finally{ $fs.Close() } }
function Copy-DeviceToFile($dev,$start,$len,$out){ $fs=[System.IO.File]::Open($dev,'Open','Read','ReadWrite'); try{ $fs.Position=$start; $o=[System.IO.File]::Open($out,'Create','Write','None'); try{ $buf=New-Object byte[] (16MB); [long]$rem=$len; while($rem -gt 0){ $w=[int][Math]::Min([long]$buf.Length,$rem); $n=$fs.Read($buf,0,$w); if($n -le 0){break}; $o.Write($buf,0,$n); $rem-=$n } } finally{ $o.Close() } } finally{ $fs.Close() } }
function Copy-FileToDevice($inf,$dev,$start){ $fs=[System.IO.File]::Open($dev,'Open','ReadWrite','ReadWrite'); try{ $fs.Position=$start; $i=[System.IO.File]::OpenRead($inf); try{ $buf=New-Object byte[] (16MB); while(($n=$i.Read($buf,0,$buf.Length)) -gt 0){ if(($n%512)-ne 0){$n+=(512-($n%512))}; $fs.Write($buf,0,$n) }; $fs.Flush() } finally{ $i.Close() } } finally{ $fs.Close() } }

Log '== kill BlueStacks ==' Cyan
foreach($p in 'HD-Player','HD-MultiInstanceManager','BstkSVC','HD-Agent','BlueStacksHelper','BlueStacksAppplayerWeb'){ Get-Process -Name $p -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue }
Start-Sleep 4

if(-not (Test-Path $BakGood)){
  Log "== backup current (Magisk-good) Root.vhd -> $BakGood ==" Cyan
  Copy-Item -LiteralPath $Vhd -Destination $BakGood -Force
  Log "   backed up ($([Math]::Round((Get-Item $BakGood).Length/1GB,2))GB)"
} else { Log "== backup already exists: $BakGood ==" DarkGray }

if(-not (Test-Path $BmOrig)){ throw "missing bindmount.orig at $BmOrig" }

$attached=$false
try {
  Log '== attach Root.vhd RW ==' Cyan
  Mount-DiskImage -ImagePath $Vhd -Access ReadWrite -ErrorAction Stop | Out-Null; $attached=$true
  $dn=$null; for($i=0;$i -lt 20;$i++){ $di=Get-DiskImage -ImagePath $Vhd -EA SilentlyContinue; if($di.Number -ne $null){$dn=$di.Number;break}; Start-Sleep -Milliseconds 250 }
  if($null -eq $dn){ throw 'no disk number' }
  $parts=@(Get-Partition -DiskNumber $dn | Sort-Object Offset)
  $tgt=$null
  foreach($p in $parts){ $d="\\.\Harddisk$($dn)Partition$($p.PartitionNumber)"; try{ $m=Read-DeviceBytes $d 0x438 2; if($m[0]-eq 0x53 -and $m[1]-eq 0xEF){ $tgt=@{Device=$d;Start=[long]0;Length=[long]$p.Size}; break } }catch{} }
  if(-not $tgt){ throw 'no ext4 partition' }
  Log "   ext4 device=$($tgt.Device) size=$([Math]::Round($tgt.Length/1GB,2))GB"

  $img=Join-Path $env:TEMP 'bsr_work\rootvhd_ext4.img'; New-Item -ItemType Directory -Path (Split-Path $img) -Force | Out-Null
  Log '== carve ext4 region (~1-2 min) ==' Cyan
  Copy-DeviceToFile $tgt.Device $tgt.Start $tgt.Length $img

  $scr=Join-Path $env:TEMP 'bsr_work\remove_dfs.txt'
  $cmds = @(
    'cd /android/system/etc','rm bsr_su',
    'cd /android/system/bin','rm bindmount',"write $(Fwd $BmOrig) bindmount",
    'sif bindmount mode 0100775','sif bindmount uid 1000','sif bindmount gid 1000','sif bindmount links_count 1',
    'stat /android/system/bin/bindmount',
    'stat /android/system/etc/bsr_su'
  )
  Set-Content -LiteralPath $scr -Value ($cmds -join "`n") -Encoding ascii -NoNewline
  Log '== debugfs: rm bsr_su + restore stock bindmount ==' Cyan
  $eap=$ErrorActionPreference; $ErrorActionPreference='Continue'
  $out = & $Dfs @('-w','-f',$scr,(Fwd $img)) 2>&1 | Out-String
  $ErrorActionPreference=$eap
  Log $out

  # sanity: bindmount present & 1339 bytes; bsr_su must be GONE
  $bmOk = ($out -match '(?s)/android/system/bin/bindmount.*?Size:\s*1339') -or ($out -match 'Size:\s*1339')
  $suGone = ($out -match 'bsr_su:\s*File not found') -or ($out -match "File not found by ext2_lookup")
  if(-not ($out -match 'Inode')){ throw "debugfs did not stat bindmount - aborting writeback (Root.vhd untouched)" }
  if(-not $bmOk){ throw "bindmount not 1339 bytes after write - aborting writeback" }
  Log "   bindmount restored (1339B): $bmOk ; bsr_su removed: $suGone" $(if($suGone){'Green'}else{'Yellow'})

  Log '== write modified ext4 back into Root.vhd ==' Cyan
  Copy-FileToDevice $img $tgt.Device $tgt.Start
  Remove-Item $img -Force -EA SilentlyContinue
  Log '[+] Root.vhd cleaned (bsr_su removed, stock bindmount restored).' Green
} finally {
  if($attached){ try{ Dismount-DiskImage -ImagePath $Vhd | Out-Null; Log '== detached Root.vhd ==' }catch{ Log 'WARN: detach failed' Red } }
}
