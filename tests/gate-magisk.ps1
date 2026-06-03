# Offline-edit the SHARED master Root.vhd: replace the Magisk bootanim.rc with a GATED version that
# only activates Magisk when THIS instance carries /data/adb/.bsr_root (a per-instance flag).
# Result: rooted instances (flag present) get Magisk; unrooted instances (no flag) run NO magiskd,
# get NO su and NO app -> fully unrooted, no leak. Master stays Readonly/shareable.
$ErrorActionPreference='Stop'
$Here = if($PSScriptRoot){ $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Repo = Split-Path -Parent $Here
$Vhd='C:\ProgramData\BlueStacks_nxt\Engine\Rvc64\Root.vhd'
$Dfs=Join-Path $Repo 'tools\debugfs\debugfs.exe'
if(-not (Test-Path $Dfs)){ $Dfs=Join-Path $env:TEMP 'bsr_work\debugfs\debugfs.exe' }
function Redact-UserPath($v){ if($null -eq $v){return $v}; $s=[string]$v; $s=$s -replace '(?i)([A-Z]:[\\/]+Users[\\/]+)([^\\/]+)(?=$|[\\/])','${1}xxxxx'; $s=$s -replace '(?i)(/Users/)([^/]+)(?=$|/)','${1}xxxxx'; $s }
function Log($m,$c='Gray'){ Write-Host (Redact-UserPath $m) -ForegroundColor $c }
function Fwd($p){ $p -replace '\\','/' }
function Read-DeviceBytes($dev,$off,$cnt){ $fs=[System.IO.File]::Open($dev,'Open','Read','ReadWrite'); try{ $sb=[long]([Math]::Floor($off/512)*512); $d=[int]($off-$sb); $need=[int]([Math]::Ceiling(($d+$cnt)/512.0)*512); $b=New-Object byte[] $need; $fs.Position=$sb; [void]$fs.Read($b,0,$need); $r=New-Object byte[] $cnt; [Array]::Copy($b,$d,$r,0,$cnt); $r } finally{ $fs.Close() } }
function Copy-DeviceToFile($dev,$start,$len,$out){ $fs=[System.IO.File]::Open($dev,'Open','Read','ReadWrite'); try{ $fs.Position=$start; $o=[System.IO.File]::Open($out,'Create','Write','None'); try{ $buf=New-Object byte[] (16MB); [long]$rem=$len; while($rem -gt 0){ $w=[int][Math]::Min([long]$buf.Length,$rem); $n=$fs.Read($buf,0,$w); if($n -le 0){break}; $o.Write($buf,0,$n); $rem-=$n } } finally{ $o.Close() } } finally{ $fs.Close() } }
function Copy-FileToDevice($inf,$dev,$start){ $fs=[System.IO.File]::Open($dev,'Open','ReadWrite','ReadWrite'); try{ $fs.Position=$start; $i=[System.IO.File]::OpenRead($inf); try{ $buf=New-Object byte[] (16MB); while(($n=$i.Read($buf,0,$buf.Length)) -gt 0){ if(($n%512)-ne 0){$n+=(512-($n%512))}; $fs.Write($buf,0,$n) }; $fs.Flush() } finally{ $i.Close() } } finally{ $fs.Close() } }

$BOOTANIM = @'
service bootanim /system/bin/bootanimation
    class core animation
    user graphics
    group graphics audio
    disabled
    oneshot
    ioprio rt 0
    task_profiles MaxPerformance
on post-fs-data
    start logd
    exec u:r:su:s0 root root -- /system/etc/init/magisk/bsr_boot.sh post-fs-data
on nonencrypted
    exec u:r:su:s0 root root -- /system/etc/init/magisk/bsr_boot.sh service
on property:vold.decrypt=trigger_restart_framework
    exec u:r:su:s0 root root -- /system/etc/init/magisk/bsr_boot.sh service
on property:sys.boot_completed=1
    exec u:r:su:s0 root root -- /system/etc/init/magisk/bsr_boot.sh boot-complete
on property:init.svc.zygote=restarting
    exec u:r:su:s0 root root -- /system/etc/init/magisk/bsr_boot.sh zygote-restart
on property:init.svc.zygote=stopped
    exec u:r:su:s0 root root -- /system/etc/init/magisk/bsr_boot.sh zygote-restart
'@ -replace "`r`n","`n"

$BSRBOOT = @'
#!/system/bin/sh
# BSR per-instance Magisk gate. Magisk activates ONLY if THIS instance (its own /data) is flagged.
# Unrooted instances have no flag -> no magiskd, no /system/bin/su, no manager app, no leak.
[ -f /data/adb/.bsr_root ] || exit 0
M=/system/etc/init/magisk
case "$1" in
  post-fs-data)
    "$M/magiskpolicy" --live --magisk 2>/dev/null
    "$M/magisk64" --auto-selinux --setup-sbin "$M" /sbin 2>/dev/null
    /sbin/magisk --auto-selinux --post-fs-data 2>/dev/null
    ;;
  service)        /sbin/magisk --auto-selinux --service 2>/dev/null ;;
  boot-complete)  mkdir -p /data/adb/magisk; /sbin/magisk --auto-selinux --boot-complete 2>/dev/null ;;
  zygote-restart) /sbin/magisk --auto-selinux --zygote-restart 2>/dev/null ;;
esac
exit 0
'@ -replace "`r`n","`n"

Log '== kill all BlueStacks ==' Cyan
Get-Process -EA SilentlyContinue | Where-Object { $_.Name -match '^(HD-|Bstk|BlueStacks)' } | Stop-Process -Force -EA SilentlyContinue
Start-Sleep 5

$work=Join-Path $env:TEMP 'bsr_work'; New-Item -ItemType Directory -Path $work -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $work 'bootanim.rc'), $BOOTANIM, (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $work 'bsr_boot.sh'), $BSRBOOT, (New-Object Text.UTF8Encoding($false)))

$attached=$false
try {
  Log '== attach master Root.vhd RW ==' Cyan
  Mount-DiskImage -ImagePath $Vhd -Access ReadWrite -ErrorAction Stop | Out-Null; $attached=$true
  $dn=$null; for($i=0;$i -lt 20;$i++){ $di=Get-DiskImage -ImagePath $Vhd -EA SilentlyContinue; if($di.Number -ne $null){$dn=$di.Number;break}; Start-Sleep -Milliseconds 250 }
  if($null -eq $dn){ throw 'no disk number' }
  $tgt=$null
  foreach($p in @(Get-Partition -DiskNumber $dn | Sort-Object Offset)){ $d="\\.\Harddisk$($dn)Partition$($p.PartitionNumber)"; try{ $m=Read-DeviceBytes $d 0x438 2; if($m[0]-eq 0x53 -and $m[1]-eq 0xEF){ $tgt=@{Device=$d;Start=[long]0;Length=[long]$p.Size}; break } }catch{} }
  if(-not $tgt){ throw 'no ext4' }
  $img=Join-Path $work 'rootvhd_ext4.img'
  Log '== carve ext4 (~1-2 min) ==' Cyan
  Copy-DeviceToFile $tgt.Device $tgt.Start $tgt.Length $img

  $scr=Join-Path $work 'gate_dfs.txt'
  $cmds=@(
    'cd /android/system/etc/init','rm bootanim.rc',"write $(Fwd (Join-Path $work 'bootanim.rc')) bootanim.rc",'sif bootanim.rc mode 0100664','sif bootanim.rc uid 1000','sif bootanim.rc gid 1000','sif bootanim.rc links_count 1',
    'cd /android/system/etc/init/magisk','rm bsr_boot.sh',"write $(Fwd (Join-Path $work 'bsr_boot.sh')) bsr_boot.sh",'sif bsr_boot.sh mode 0100700','sif bsr_boot.sh uid 0','sif bsr_boot.sh gid 0','sif bsr_boot.sh links_count 1',
    'stat /android/system/etc/init/bootanim.rc','stat /android/system/etc/init/magisk/bsr_boot.sh'
  )
  Set-Content -LiteralPath $scr -Value ($cmds -join "`n") -Encoding ascii -NoNewline
  Log '== debugfs: install gated bootanim.rc + bsr_boot.sh ==' Cyan
  $eap=$ErrorActionPreference; $ErrorActionPreference='Continue'
  $out = & $Dfs @('-w','-f',$scr,(Fwd $img)) 2>&1 | Out-String
  $ErrorActionPreference=$eap
  Log $out DarkGray
  $ok = ($out -match '(?s)bootanim\.rc.*?Inode:\s*\d') -and ($out -match '(?s)bsr_boot\.sh.*?Inode:\s*\d')
  if(-not $ok){ throw 'gate files not written - aborting writeback' }
  Log '== write back ==' Cyan
  Copy-FileToDevice $img $tgt.Device $tgt.Start
  Remove-Item $img -Force -EA SilentlyContinue
  Log '[+] Gated bootanim.rc + bsr_boot.sh installed on master Root.vhd.' Green
} finally {
  if($attached){ try{ Dismount-DiskImage -ImagePath $Vhd | Out-Null; Log '== detached ==' }catch{ Log 'WARN detach failed' Red } }
}
