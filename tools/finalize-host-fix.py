"""Temporary second-pass changes derived from the real Windows regression."""
from pathlib import Path
root=Path(__file__).resolve().parent.parent

def read(p): return (root/p).read_bytes().decode('utf-8').replace('\r\n','\n')
def write(p,t): (root/p).write_bytes(t.encode('utf-8'))
def once(t,a,b):
    if a not in t and b in t: return t
    if t.count(a)!=1: raise RuntimeError('Unexpected source: '+a[:90])
    return t.replace(a,b,1)

p='tools/bsr_host.ps1';t=read(p)
t=once(t,'    $parts = New-Object System.Collections.Generic.List[string]\n    while', "    $parts = New-Object System.Collections.Generic.List[string]\n    if ($record -is [System.Management.Automation.ErrorRecord]) {\n        [void]$parts.Add(\"ErrorId=$($record.FullyQualifiedErrorId)\")\n    }\n    while")
t=once(t,'        # A query can itself fail when the filename has the wrong extension.\n        # Let the explicit-format mount report the authoritative native error.', '        # Query with the detected format too; otherwise an existing VHDX mount\n        # under a .vhd name can be missed by the extension-selected provider.')
t=once(t,'Get-DiskImage -ImagePath $path -ErrorAction Stop', 'Get-DiskImage -ImagePath $path -StorageType $storage -ErrorAction Stop')
t=once(t,'        Mount-BsrDiskImage $ImagePath | Out-Null\n        $attached = $true', '        $mount = Mount-BsrDiskImage $ImagePath\n        $attached = $true')
t=once(t,'Dismount-DiskImage -ImagePath $ImagePath -ErrorAction Stop', 'Dismount-DiskImage -InputObject $mount -ErrorAction Stop')
write(p,t)
for p in ('tools/bsr_engine.ps1','tools/bsr_magisk.ps1'):
    t=read(p)
    t=t.replace('Mount-BsrDiskImage $Vhd | Out-Null', '$mount = Mount-BsrDiskImage $Vhd')
    t=t.replace('Get-DiskImage -ImagePath $Vhd -', 'Get-DiskImage -ImagePath $Vhd -StorageType $mount.StorageType -')
    t=t.replace('Get-DiskImage -ImagePath $Vhd |', 'Get-DiskImage -ImagePath $Vhd -StorageType $mount.StorageType |')
    t=t.replace('Dismount-DiskImage -ImagePath $Vhd', 'Dismount-DiskImage -InputObject $mount')
    if p.endswith('bsr_magisk.ps1'):
        block="    Say '[*] preflight: verify Windows can attach the detected disk format (RW)...' Cyan\n    Test-BsrDiskAttach $Vhd\n\n"
        # Preserve the existing pristine backup before any read/write attachment.
        if block in t:
            t=once(t,block,'')
            t=once(t,'    # 1) HD-Player anti-tamper patch',block+'    # 1) HD-Player anti-tamper patch')
    write(p,t)
p='tests/Run-Host-IO-Tests.ps1';t=read(p)
t=once(t,'function Get-DiskImage { [CmdletBinding()]param($ImagePath)', 'function Get-DiskImage { [CmdletBinding()]param($ImagePath,$StorageType)')
t=once(t,'[pscustomobject]@{Attached=$true;Number=7}', '[pscustomobject]@{Attached=$true;Number=7;StorageType=$StorageType}')
t=once(t,'function Dismount-DiskImage { [CmdletBinding()]param($ImagePath) $script:detaches++ }', 'function Dismount-DiskImage { [CmdletBinding()]param($InputObject) $script:detaches++; $script:detachedType=$InputObject.StorageType }')
t=once(t,"    Check 'Successful preflight detaches its own mount once' ($script:detaches -eq 1)", "    Check 'Successful preflight detaches its own mount once' ($script:detaches -eq 1)\n    Check 'Detach uses the typed mount object, not the filename' ($script:detachedType -eq 'VHDX')")
t=once(t,"    Check 'HRESULT rendered as unsigned hex' ($detail -match 'HRESULT=0x[0-9A-F]{8}')", "    Check 'HRESULT rendered as unsigned hex' ($detail -match 'HRESULT=0x[0-9A-F]{8}')\n    $cimLike = New-Object Management.Automation.ErrorRecord($outer,'HRESULT 0xC03A0014,Mount-DiskImage',[Management.Automation.ErrorCategory]::NotSpecified,$vhdx)\n    Check 'Native CIM HRESULT retained in ErrorId' ((Get-BsrExceptionDetail $cimLike) -match 'ErrorId=HRESULT 0xC03A0014')")
t=once(t,"    function Copy-Item { throw 'BUG: backup was reached before preflight' }", '    function Copy-Item { $script:backupAttempted=$true }')
t=once(t,"    $null=Expect-Error 'Prep mount failure precedes patch/conf/backup' { Do-Prep } 'BSR_DISK_ATTACH'", "    $script:backupAttempted=$false\n    $null=Expect-Error 'Prep mount failure precedes patch/conf' { Do-Prep } 'BSR_DISK_ATTACH'\n    Check 'Pristine backup attempted before RW attachment' $script:backupAttempted")
t=t.replace('Dismount-DiskImage -ImagePath $renamed -ErrorAction Stop', 'Dismount-DiskImage -ImagePath $renamed -StorageType $format -ErrorAction Stop')
t=once(t,'                if($owned){Dismount-DiskImage -ImagePath $renamed -StorageType $format -ErrorAction Stop | Out-Null}', '                if($owned){Dismount-DiskImage -InputObject $mounted -ErrorAction Stop | Out-Null}')
t=once(t,'                Check "Real $format mount succeeds through helper" ($mounted.Attached)', '                Check "Real $format mount succeeds through helper" ($mounted.Attached)\n                $queried=Get-DiskImage -ImagePath $renamed -StorageType $mounted.StorageType -ErrorAction Stop\n                Check "Real $format disk-number query keeps format" ($queried.Attached -and $null -ne $queried.Number)')
write(p,t)
print('Format-aware query/detach, native CIM errors, and backup ordering corrected.')
