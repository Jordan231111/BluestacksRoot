$ErrorActionPreference='Continue'
$Here = if($PSScriptRoot){ $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Repo = Split-Path -Parent $Here
$Inst='Rvc64'; $Install='C:\Program Files\BlueStacks_nxt'; $Conf='C:\ProgramData\BlueStacks_nxt\bluestacks.conf'
$Adb=Join-Path $Install 'HD-Adb.exe'; $Player=Join-Path $Install 'HD-Player.exe'
$Engine=Join-Path $Repo 'tools\bsr_engine.ps1'
function Redact-UserPath($v){ if($null -eq $v){return $v}; $s=[string]$v; $s=$s -replace '(?i)([A-Z]:[\\/]+Users[\\/]+)([^\\/]+)(?=$|[\\/])','${1}xxxxx'; $s=$s -replace '(?i)(/Users/)([^/]+)(?=$|/)','${1}xxxxx'; $s }
function Log($m,$c='Gray'){ Write-Host (Redact-UserPath $m) -ForegroundColor $c }
function A($ar){ (& $Adb @ar 2>&1 | Out-String).Trim() }
function Dev{ $d=(A @('devices')) -split "`n" | Where-Object {$_ -match '\tdevice$'} | %{($_ -split '\t')[0]}; if($d){@($d)[0]}else{$null} }
function Sh($s,$c){ (& $Adb @('-s',$s,'shell',$c) 2>&1 | Out-String).Trim() }

Log '== kill, ensure root conf flags (no race) ==' Cyan
foreach($p in 'HD-Player','HD-MultiInstanceManager','BstkSVC','HD-Agent','BlueStacksHelper','BlueStacksAppplayerWeb'){ Get-Process -Name $p -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue }
Start-Sleep 4
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Engine -Action ConfRoot -Conf $Conf -Instance $Inst 2>&1 | Select-Object -Last 1 | %{ Log "   $_" }

Log '== launch ==' Cyan
Start-Process -FilePath $Player -ArgumentList @('--instance',$Inst) | Out-Null
$serial=$null
for($i=0;$i -lt 120;$i++){ Start-Sleep 2; & $Adb @('start-server') *>$null; $serial=Dev; if($serial -and (Sh $serial 'getprop sys.boot_completed') -match '1'){ Log "   booted (~$($i*2)s) serial=$serial" Green; break } }
if(-not $serial){ Log 'no device'; exit 1 }
Start-Sleep 4

Log '== did our bindmount run? (kmsg + xbin state) ==' Cyan
Log ('   bst.config.bindmount = ' + (Sh $serial 'getprop bst.config.bindmount'))
Log ('   kmsg bsr/bindmount: ' + (Sh $serial 'dmesg 2>/dev/null | grep -iE "bsr:|bindmount|to_mount" | tail -6'))
Log ('   /system/xbin/su = ' + (Sh $serial 'ls -l /system/xbin/su'))
Log ('   (ours = 4968 bytes; stock = 41160)')

Log '== ROOT TEST ==' Cyan
$rooted=$false
foreach($c in 'su -c id','su 0 id','su -c "id -u"'){ $o=Sh $serial $c; if($o -match 'uid=0'){ Log "   [$c] -> $o   <<<<<< ROOT uid=0" Green; $rooted=$true } else { Log "   [$c] -> '$o'" } }

$shot=Join-Path $PSScriptRoot 'root_proof.png'
$b=& $Adb @('-s',$serial,'exec-out','screencap','-p') 2>$null; if($b){ [System.IO.File]::WriteAllBytes($shot,[byte[]]$b) }
if($rooted){ Log "`n*** ROOT ACHIEVED (uid=0) via ungated su. serial=$serial ***" Green }
else { Log "`n*** still no root -- check kmsg above. serial=$serial ***" Yellow }
