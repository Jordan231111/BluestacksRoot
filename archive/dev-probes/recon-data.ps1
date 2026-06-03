# READ-ONLY recon of Data.vhdx: can debugfs open the partition device directly,
# and is /downloads/.xb/su really there? No writes. Instance must be killed first.
$ErrorActionPreference='Continue'
$Here = if($PSScriptRoot){ $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Repo = Split-Path -Parent (Split-Path -Parent $Here)
$Data='C:\ProgramData\BlueStacks_nxt\Engine\Rvc64\Data.vhdx'
$Dfs=Join-Path $Repo 'tools\debugfs\debugfs.exe'
function Redact-UserPath($v){ if($null -eq $v){return $v}; $s=[string]$v; $s=$s -replace '(?i)([A-Z]:[\\/]+Users[\\/]+)([^\\/]+)(?=$|[\\/])','${1}xxxxx'; $s=$s -replace '(?i)(/Users/)([^/]+)(?=$|/)','${1}xxxxx'; $s }
function Log($m,$c='Gray'){ Write-Host (Redact-UserPath $m) -ForegroundColor $c }

Log '== kill BlueStacks so Data.vhdx is unlocked ==' Cyan
foreach($p in 'HD-Player','HD-MultiInstanceManager','BstkSVC','HD-Agent','BlueStacksHelper','BlueStacksAppplayerWeb'){ Get-Process -Name $p -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue }
Start-Sleep 4

$attached=$false
try {
  Log '== attach Data.vhdx READ-ONLY ==' Cyan
  Mount-DiskImage -ImagePath $Data -Access ReadOnly -ErrorAction Stop | Out-Null
  $attached=$true
  $dn=$null
  for($i=0;$i -lt 20;$i++){ $di=Get-DiskImage -ImagePath $Data -EA SilentlyContinue; if($di -and $di.Number -ne $null){$dn=$di.Number;break}; Start-Sleep -Milliseconds 250 }
  if($null -eq $dn){ throw 'no disk number' }
  $phys="\\.\PhysicalDrive$dn"
  Log "   attached as disk $dn ($phys)"

  # find ext4 partition (probe 0xEF53 @ +0x438)
  $parts=@(Get-Partition -DiskNumber $dn -EA SilentlyContinue | Sort-Object Offset)
  Log ("   partitions: " + (($parts | ForEach-Object { "#$($_.PartitionNumber)@$([Math]::Round($_.Offset/1MB))MB/$([Math]::Round($_.Size/1GB,1))GB" }) -join ', '))
  $dev=$null
  foreach($p in $parts){
    $d="\\.\Harddisk$($dn)Partition$($p.PartitionNumber)"
    try {
      $fs=[System.IO.File]::Open($d,'Open','Read','ReadWrite'); $buf=New-Object byte[] 512
      $fs.Position=0x400; [void]$fs.Read($buf,0,512); $fs.Close()
      if($buf[0x38] -eq 0x53 -and $buf[0x39] -eq 0xEF){ $dev=$d; Log "   ext4 on $d" Green; break }
    } catch { Log "   (cant open $d : $($_.Exception.Message))" Yellow }
  }
  if(-not $dev){ throw 'no ext4 partition found' }

  $devFwd = ($dev -replace '\\','/')
  Log "== debugfs (READ-ONLY) on device: $devFwd ==" Cyan
  $script=Join-Path $env:TEMP 'recon_dfs.txt'
  Set-Content -LiteralPath $script -Value "stat /downloads/.xb/su`nstat /downloads/.xb/bstk/su`n" -Encoding ascii -NoNewline
  $out = & $Dfs @('-f',$script,$devFwd) 2>&1 | Out-String
  Remove-Item $script -Force -EA SilentlyContinue
  Log $out
} catch {
  Log "RECON ERROR: $($_.Exception.Message)" Red
} finally {
  if($attached){ try { Dismount-DiskImage -ImagePath $Data | Out-Null; Log '== detached Data.vhdx ==' } catch { Log 'WARN: detach failed; use Disk Management' Red } }
}
