# UNIT TEST (safe, scratch disk): prove the offline Magisk /system install + bootstrap-su writes
# land BYTE-IDENTICAL files into a fresh copy of the pristine Root.vhd, without touching anything live.
# Strategy: copy bsrbak -> scratch.vhd, carve ext4, run the SAME debugfs writes Do-Prep uses,
# then dump each written file back out and SHA-compare to its source. No write-back (read-only proof).
$ErrorActionPreference='Continue'
$Here = if($PSScriptRoot){ $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Repo = Split-Path -Parent $Here
$Bak='C:\ProgramData\BlueStacks_nxt\Engine\Rvc64\Root.vhd.bsrbak'
$Dfs=Join-Path $Repo 'tools\debugfs\debugfs.exe'
if(-not (Test-Path $Dfs)){ $Dfs=Join-Path $env:TEMP 'bsr_work\debugfs\debugfs.exe' }
$DB=Join-Path $Repo 'tools\magisk_databin'      # APK-extracted binaries
$BsrSu=Join-Path $Repo 'tools\su_src\bsr_su'
$BA=Join-Path $Repo 'tools\magisk_artifacts\bootanim.rc'
function Redact-UserPath($v){ if($null -eq $v){return $v}; $s=[string]$v; $s=$s -replace '(?i)([A-Z]:[\\/]+Users[\\/]+)([^\\/]+)(?=$|[\\/])','${1}xxxxx'; $s=$s -replace '(?i)(/Users/)([^/]+)(?=$|/)','${1}xxxxx'; $s }
function Log($m,$c='Gray'){ Write-Host (Redact-UserPath $m) -ForegroundColor $c }
function Fwd($p){ $p -replace '\\','/' }
function Read-DeviceBytes($dev,$off,$cnt){ $fs=[System.IO.File]::Open($dev,'Open','Read','ReadWrite'); try{ $sb=[long]([Math]::Floor($off/512)*512); $d=[int]($off-$sb); $need=[int]([Math]::Ceiling(($d+$cnt)/512.0)*512); $b=New-Object byte[] $need; $fs.Position=$sb; [void]$fs.Read($b,0,$need); $r=New-Object byte[] $cnt; [Array]::Copy($b,$d,$r,0,$cnt); $r } finally{ $fs.Close() } }
function Copy-DeviceToFile($dev,$start,$len,$out){ $fs=[System.IO.File]::Open($dev,'Open','Read','ReadWrite'); try{ $fs.Position=$start; $o=[System.IO.File]::Open($out,'Create','Write','None'); try{ $buf=New-Object byte[] (16MB); [long]$rem=$len; while($rem -gt 0){ $w=[int][Math]::Min([long]$buf.Length,$rem); $n=$fs.Read($buf,0,$w); if($n -le 0){break}; $o.Write($buf,0,$n); $rem-=$n } } finally{ $o.Close() } } finally{ $fs.Close() } }
function Sha($p){ $s=[System.Security.Cryptography.SHA256]::Create(); try{ $fs=[System.IO.File]::OpenRead($p); try{ ([BitConverter]::ToString($s.ComputeHash($fs)) -replace '-','').ToLower() } finally{ $fs.Close() } } finally{ $s.Dispose() } }

foreach($p in 'HD-Player','HD-MultiInstanceManager','BstkSVC','HD-Agent'){ Get-Process -Name $p -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue }
Start-Sleep 3
$work=Join-Path $env:TEMP 'bsr_work'; New-Item -ItemType Directory -Path $work -Force | Out-Null
$scratch=Join-Path $work 'scratch.vhd'
Log "== copy pristine bsrbak -> scratch.vhd ==" Cyan
Copy-Item -LiteralPath $Bak -Destination $scratch -Force

$pass=$true; $attached=$false
try{
  Mount-DiskImage -ImagePath $scratch -Access ReadWrite -ErrorAction Stop | Out-Null; $attached=$true
  $dn=$null; for($i=0;$i -lt 20;$i++){ $di=Get-DiskImage -ImagePath $scratch -EA SilentlyContinue; if($di.Number -ne $null){$dn=$di.Number;break}; Start-Sleep -Milliseconds 250 }
  $dev=$null; $len=0; foreach($p in @(Get-Partition -DiskNumber $dn | Sort-Object Offset)){ $d="\\.\Harddisk$($dn)Partition$($p.PartitionNumber)"; try{ $m=Read-DeviceBytes $d 0x438 2; if($m[0]-eq 0x53 -and $m[1]-eq 0xEF){ $dev=$d; $len=[long]$p.Size; break } }catch{} }
  if(-not $dev){ throw 'no ext4' }
  $img=Join-Path $work 'scratch_ext4.img'
  Log "== carve ext4 ($([Math]::Round($len/1GB,2))GB) ==" Cyan
  Copy-DeviceToFile $dev 0 $len $img
  if(-not (Test-Path $img) -or (Get-Item $img).Length -lt 1GB){ throw "carve failed ($([Math]::Round((Get-Item $img).Length/1MB,1))MB)" }

  # config template (matches live)
  $cfg=Join-Path $work 'config'; [IO.File]::WriteAllText($cfg,"SYSTEMMODE=true`nRECOVERYMODE=false`n",(New-Object Text.UTF8Encoding($false)))

  # SAME debugfs writes as Do-Prep
  $cmds=@('mkdir /android','mkdir /android/system','mkdir /android/system/etc','mkdir /android/system/etc/init','mkdir /android/system/etc/init/magisk','cd /android/system/etc/init/magisk')
  foreach($f in 'magisk32','magisk64','magiskinit','magiskpolicy','stub.apk'){ $cmds+=@("rm $f","write $(Fwd (Join-Path $DB $f)) $f","sif $f mode 0100700","sif $f uid 0","sif $f gid 0","sif $f links_count 1") }
  $cmds+=@("rm config","write $(Fwd $cfg) config","sif config mode 0100700","sif config uid 0","sif config gid 0","sif config links_count 1")
  $cmds+=@('cd /android/system/etc/init','rm bootanim.rc',"write $(Fwd $BA) bootanim.rc",'sif bootanim.rc mode 0100664','sif bootanim.rc uid 1000','sif bootanim.rc gid 1000')
  $cmds+=@('cd /android/system/etc','rm bsr_su',"write $(Fwd $BsrSu) bsr_su",'sif bsr_su mode 0106755','sif bsr_su uid 0','sif bsr_su gid 0')
  $scr=Join-Path $work 'prep.txt'; Set-Content -LiteralPath $scr -Value ($cmds -join "`n") -Encoding ascii -NoNewline
  Log "== debugfs write (magisk /system + bootanim + bsr_su) ==" Cyan
  (& $Dfs @('-w','-f',$scr,(Fwd $img)) 2>&1 | Out-String) | Out-Null

  # dump each written file back out and SHA-compare to source
  $outdir=Join-Path $work 'verify'; New-Item -ItemType Directory -Path $outdir -Force | Out-Null
  $dump=@('cd /android/system/etc/init/magisk')
  foreach($f in 'magisk32','magisk64','magiskinit','magiskpolicy','stub.apk','config'){ $dump+=@("dump $f $(Fwd (Join-Path $outdir $f))") }
  $dump+=@("dump /android/system/etc/init/bootanim.rc $(Fwd (Join-Path $outdir 'bootanim.rc'))","dump /android/system/etc/bsr_su $(Fwd (Join-Path $outdir 'bsr_su'))")
  $dump+=@('stat /android/system/etc/init/magisk/magisk64','stat /android/system/etc/init/bootanim.rc','stat /android/system/etc/bsr_su')
  $scr2=Join-Path $work 'dump.txt'; Set-Content -LiteralPath $scr2 -Value ($dump -join "`n") -Encoding ascii -NoNewline
  $statOut = & $Dfs @('-f',$scr2,(Fwd $img)) 2>&1 | Out-String

  Log "== SHA verification (carved-then-dumped vs source) ==" Cyan
  $checks=@(
    @{n='magisk32'; src=(Join-Path $DB 'magisk32')},
    @{n='magisk64'; src=(Join-Path $DB 'magisk64')},
    @{n='magiskinit'; src=(Join-Path $DB 'magiskinit')},
    @{n='magiskpolicy'; src=(Join-Path $DB 'magiskpolicy')},
    @{n='stub.apk'; src=(Join-Path $DB 'stub.apk')},
    @{n='config'; src=$cfg},
    @{n='bootanim.rc'; src=$BA},
    @{n='bsr_su'; src=$BsrSu}
  )
  foreach($c in $checks){
    $dp=Join-Path $outdir $c.n
    if(-not (Test-Path $dp)){ Log ("  {0,-14} MISSING (not written!)" -f $c.n) Red; $pass=$false; continue }
    $a=Sha $dp; $b=Sha $c.src
    if($a -eq $b){ Log ("  {0,-14} OK  {1}" -f $c.n,$a.Substring(0,16)) Green } else { Log ("  {0,-14} MISMATCH  carved={1} src={2}" -f $c.n,$a.Substring(0,16),$b.Substring(0,16)) Red; $pass=$false }
  }
  Log "== mode/owner checks (from stat) ==" Cyan
  $okMode = ($statOut -match '(?s)bsr_su.*?Mode:\s*0?6755') -and ($statOut -match '(?s)bootanim\.rc.*?Mode:\s*0?0?664')
  Log ("  bsr_su=06755 & bootanim.rc=0664 : {0}" -f $okMode) $(if($okMode){'Green'}else{'Yellow'})
  Remove-Item $img -Force -EA SilentlyContinue
} catch { Log "ERROR: $($_.Exception.Message)" Red; $pass=$false }
finally {
  if($attached){ try{ Dismount-DiskImage -ImagePath $scratch | Out-Null }catch{} }
  Remove-Item $scratch -Force -EA SilentlyContinue
}
Log ("`n==== OFFLINE-PREP UNIT TEST: {0} ====" -f $(if($pass){'PASS'}else{'FAIL'})) $(if($pass){'Green'}else{'Red'})
