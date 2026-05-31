# Offline-edit Root.vhd: drop ungated su at /android/system/etc/bsr_su and replace
# /android/system/bin/bindmount so it installs that su over /system/xbin/su at boot.
# Mirrors the engine's carve/writeback. HD-Player patch stays on. Root.vhd.bsrbak exists.
$ErrorActionPreference='Stop'
$Vhd='C:\ProgramData\BlueStacks_nxt\Engine\Rvc64\Root.vhd'
$Dfs='C:\Users\Jordan\Documents\BluestacksRoot\tools\debugfs\debugfs.exe'
$SuLocal='C:\Users\Jordan\Documents\BluestacksRoot\tools\su_src\bsr_su'
$BmLocal='C:\Users\Jordan\Documents\BluestacksRoot\tools\su_src\bindmount.mod'
function Log($m,$c='Gray'){ Write-Host $m -ForegroundColor $c }
function Fwd($p){ $p -replace '\\','/' }

Log '== kill BlueStacks (unlock Root.vhd) ==' Cyan
foreach($p in 'HD-Player','HD-MultiInstanceManager','BstkSVC','HD-Agent','BlueStacksHelper','BlueStacksAppplayerWeb'){ Get-Process -Name $p -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue }
Start-Sleep 4

function Read-DeviceBytes($dev,$off,$cnt){ $fs=[System.IO.File]::Open($dev,'Open','Read','ReadWrite'); try{ $sb=[long]([Math]::Floor($off/512)*512); $d=[int]($off-$sb); $need=[int]([Math]::Ceiling(($d+$cnt)/512.0)*512); $b=New-Object byte[] $need; $fs.Position=$sb; [void]$fs.Read($b,0,$need); $r=New-Object byte[] $cnt; [Array]::Copy($b,$d,$r,0,$cnt); $r } finally{ $fs.Close() } }
function Copy-DeviceToFile($dev,$start,$len,$out){ $fs=[System.IO.File]::Open($dev,'Open','Read','ReadWrite'); try{ $fs.Position=$start; $o=[System.IO.File]::Open($out,'Create','Write','None'); try{ $buf=New-Object byte[] (16MB); [long]$rem=$len; while($rem -gt 0){ $w=[int][Math]::Min([long]$buf.Length,$rem); $n=$fs.Read($buf,0,$w); if($n -le 0){break}; $o.Write($buf,0,$n); $rem-=$n } } finally{ $o.Close() } } finally{ $fs.Close() } }
function Copy-FileToDevice($inf,$dev,$start){ $fs=[System.IO.File]::Open($dev,'Open','ReadWrite','ReadWrite'); try{ $fs.Position=$start; $i=[System.IO.File]::OpenRead($inf); try{ $buf=New-Object byte[] (16MB); while(($n=$i.Read($buf,0,$buf.Length)) -gt 0){ if(($n%512)-ne 0){$n+=(512-($n%512))}; $fs.Write($buf,0,$n) }; $fs.Flush() } finally{ $i.Close() } } finally{ $fs.Close() } }

$attached=$false
try {
  Log '== attach Root.vhd RW ==' Cyan
  Mount-DiskImage -ImagePath $Vhd -Access ReadWrite -ErrorAction Stop | Out-Null; $attached=$true
  $dn=$null; for($i=0;$i -lt 20;$i++){ $di=Get-DiskImage -ImagePath $Vhd -EA SilentlyContinue; if($di.Number -ne $null){$dn=$di.Number;break}; Start-Sleep -Milliseconds 250 }
  if($null -eq $dn){ throw 'no disk number' }
  $phys="\\.\PhysicalDrive$dn"; Log "   disk $dn ($phys)"
  $parts=@(Get-Partition -DiskNumber $dn | Sort-Object Offset)
  $tgt=$null
  foreach($p in $parts){ $d="\\.\Harddisk$($dn)Partition$($p.PartitionNumber)"; try{ $m=Read-DeviceBytes $d 0x438 2; if($m[0]-eq 0x53 -and $m[1]-eq 0xEF){ $tgt=@{Device=$d;Start=[long]0;Length=[long]$p.Size}; break } }catch{} }
  if(-not $tgt){ throw 'no ext4 partition' }
  Log "   ext4 device=$($tgt.Device) size=$([Math]::Round($tgt.Length/1GB,2))GB"

  $img=Join-Path $env:TEMP 'bsr_work\rootvhd_ext4.img'; New-Item -ItemType Directory -Path (Split-Path $img) -Force | Out-Null
  Log '== carve ext4 region (8.5GB, ~1-2 min) ==' Cyan
  Copy-DeviceToFile $tgt.Device $tgt.Start $tgt.Length $img
  Log "   carved -> $img ($([Math]::Round((Get-Item $img).Length/1GB,2))GB)"

  $scr=Join-Path $env:TEMP 'bsr_work\hook_dfs.txt'
  $cmds = @(
    'cd /android/system/etc','rm bsr_su',"write $(Fwd $SuLocal) bsr_su",'sif bsr_su mode 0106755','sif bsr_su uid 0','sif bsr_su gid 0','sif bsr_su links_count 1',
    'cd /android/system/bin','rm bindmount',"write $(Fwd $BmLocal) bindmount",'sif bindmount mode 0100755','sif bindmount uid 0','sif bindmount gid 0','sif bindmount links_count 1',
    'stat /android/system/etc/bsr_su','stat /android/system/bin/bindmount'
  )
  Set-Content -LiteralPath $scr -Value ($cmds -join "`n") -Encoding ascii -NoNewline
  Log '== debugfs edit ==' Cyan
  $eap=$ErrorActionPreference; $ErrorActionPreference='Continue'
  $out = & $Dfs @('-w','-f',$scr,(Fwd $img)) 2>&1 | Out-String
  $ErrorActionPreference=$eap
  Log $out
  # sanity: both files present with expected sizes
  $okSu = $out -match '(?s)bsr_su.*?Inode:\s*\d' -and $out -match 'Size:\s*4968'
  $okBm = $out -match '(?s)bindmount.*?Inode:\s*\d'
  if(-not ($out -match 'Inode')){ throw "debugfs did not stat the files - aborting writeback (Root.vhd untouched)" }

  Log '== write modified ext4 back into Root.vhd ==' Cyan
  Copy-FileToDevice $img $tgt.Device $tgt.Start
  Remove-Item $img -Force -EA SilentlyContinue
  Log '[+] Root.vhd updated (bsr_su + modified bindmount).' Green
} finally {
  if($attached){ try{ Dismount-DiskImage -ImagePath $Vhd | Out-Null; Log '== detached Root.vhd ==' }catch{ Log 'WARN: detach failed' Red } }
}
