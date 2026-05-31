# READ-ONLY: read Data.vhdx ext4 superblock -> compute true filesystem size.
$ErrorActionPreference='Continue'
$Data='C:\ProgramData\BlueStacks_nxt\Engine\Rvc64\Data.vhdx'
function Log($m,$c='Gray'){ Write-Host $m -ForegroundColor $c }
foreach($p in 'HD-Player','HD-MultiInstanceManager','BstkSVC','HD-Agent','BlueStacksHelper','BlueStacksAppplayerWeb'){ Get-Process -Name $p -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue }
Start-Sleep 3
$attached=$false
try{
  Mount-DiskImage -ImagePath $Data -Access ReadOnly -ErrorAction Stop | Out-Null; $attached=$true
  $dn=$null; for($i=0;$i -lt 20;$i++){ $di=Get-DiskImage -ImagePath $Data -EA SilentlyContinue; if($di.Number -ne $null){$dn=$di.Number;break}; Start-Sleep -Milliseconds 250 }
  $part=@(Get-Partition -DiskNumber $dn | Sort-Object Offset)[0]
  $dev="\\.\Harddisk$($dn)Partition$($part.PartitionNumber)"
  Log "disk=$dn dev=$dev partSize=$([Math]::Round($part.Size/1GB,1))GB partOffset=$($part.Offset)"
  $fs=[System.IO.File]::Open($dev,'Open','Read','ReadWrite')
  $buf=New-Object byte[] 1024; $fs.Position=1024; [void]$fs.Read($buf,0,1024); $fs.Close()
  $magic = $buf[0x38] -bor ($buf[0x39] -shl 8)
  $inodes = [BitConverter]::ToUInt32($buf,0x0)
  $blocksLo = [BitConverter]::ToUInt32($buf,0x4)
  $blocksHi = [BitConverter]::ToUInt32($buf,0x150)
  $logbs = [BitConverter]::ToUInt32($buf,0x18)
  $bs = 1024 -shl $logbs
  $blocks = [uint64]$blocksLo -bor ([uint64]$blocksHi -shl 32)
  $fsBytes = [uint64]$blocks * [uint64]$bs
  $freeBlocksLo = [BitConverter]::ToUInt32($buf,0xC)
  Log ("ext4 magic = 0x{0:X} (EF53 expected)" -f $magic)
  Log ("block size = $bs")
  Log ("total blocks = $blocks  -> FS SIZE = $([Math]::Round($fsBytes/1GB,3)) GB ($fsBytes bytes)")
  Log ("inodes = $inodes ; free blocks (lo) = $freeBlocksLo -> ~$([Math]::Round(($freeBlocksLo*$bs)/1GB,2)) GB free")
  if($fsBytes -lt 20GB){ Log "==> FS is small enough to CARVE ($([Math]::Round($fsBytes/1GB,2)) GB). PATH B feasible." Green }
  else { Log "==> FS is large ($([Math]::Round($fsBytes/1GB,2)) GB); carve not feasible." Yellow }
} catch { Log "ERR: $($_.Exception.Message)" Red }
finally { if($attached){ try{ Dismount-DiskImage -ImagePath $Data | Out-Null }catch{} } }
