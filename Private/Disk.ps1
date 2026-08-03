# Host disk identification and state. Every refusal in here exists because the
# failure mode is someone's data.

function Get-RescueDiskInventory {
    [CmdletBinding()]
    param()

    $rows = @()
    foreach ($d in (Get-Disk | Sort-Object Number)) {
        $bus = '?'
        try {
            $pd = Get-PhysicalDisk -ErrorAction Stop |
                  Where-Object { $_.DeviceId -eq [string]$d.Number }
            if ($pd) { $bus = [string]$pd.BusType }
        } catch { }

        $rows += [pscustomobject]@{
            Num       = $d.Number
            Model     = $d.FriendlyName
            SizeBytes = $d.Size
            SizeGB    = [math]::Round($d.Size / 1GB, 2)
            Bus       = $bus
            Offline   = $d.IsOffline
            ReadOnly  = $d.IsReadOnly
            Boot      = $d.IsBoot
            System    = $d.IsSystem
            Style     = [string]$d.PartitionStyle
        }
    }
    return $rows
}

function Resolve-RescueDisk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][long]$SizeBytes,
        [switch]$Force
    )

    if ($SizeBytes -le 0) {
        throw 'SizeBytes is required and must be positive. Run Get-RescueTarget for the inventory.'
    }

    # Identity, never disk number. USB enumeration reorders between sessions, so
    # a number captured a minute ago can name a different drive now.
    $found = @(Get-Disk | Where-Object {
        $_.FriendlyName -eq $Model -and $_.Size -eq $SizeBytes
    })

    if ($found.Count -eq 0) {
        throw "No disk matches Model '$Model' at $SizeBytes bytes. Run Get-RescueTarget for the inventory."
    }
    if ($found.Count -gt 1) {
        throw "$($found.Count) disks match Model '$Model' at $SizeBytes bytes. Refusing: cannot disambiguate. Detach one."
    }

    $disk = $found[0]

    if (($disk.IsBoot -or $disk.IsSystem) -and -not $Force) {
        throw "Disk $($disk.Number) is the live boot/system disk. Refusing. Pass -Force only if you are certain."
    }
    if ($disk.Number -eq 0 -and -not $Force) {
        throw 'Disk 0 is almost never the target. Refusing without -Force.'
    }

    return $disk
}

function Set-RescueDiskIsolated {
    <#
        Force the target offline and read-only before QEMU opens it. Host and
        guest must never hold the same volume simultaneously.

        Returns the prior state so it can be restored, and throws if the disk
        will not go offline - starting anyway risks concurrent mounts.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$Number)

    $before = Get-Disk -Number $Number
    $prior = [pscustomobject]@{
        Offline  = $before.IsOffline
        ReadOnly = $before.IsReadOnly
    }

    # ReadOnly first: setting it on an already-offline disk is unreliable.
    try { Set-Disk -Number $Number -IsReadOnly $true } catch {
        Write-Warning "Could not set ReadOnly on disk ${Number}: $_"
    }
    try { Set-Disk -Number $Number -IsOffline $true } catch {
        Write-Warning "Could not set Offline on disk ${Number}: $_"
    }

    $after = Get-Disk -Number $Number
    if (-not $after.IsOffline) {
        # Restore what we changed before bailing out.
        try { Set-Disk -Number $Number -IsReadOnly $prior.ReadOnly } catch { }
        throw "Disk $Number will not go offline. Refusing to start: host and guest must not hold the same volume."
    }

    return $prior
}

function Restore-RescueDiskState {
    <#
        Put the disk back exactly as found. Reports honestly rather than
        pretending, because a half-restored disk that reads as fine is worse
        than one that is loudly wrong.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$Number,
        [Parameter(Mandatory = $true)][bool]$PriorOffline,
        [Parameter(Mandatory = $true)][bool]$PriorReadOnly
    )

    $result = [pscustomobject]@{
        Number     = $Number
        Restored   = $false
        Offline    = $null
        ReadOnly   = $null
        Message    = ''
    }

    try {
        Set-Disk -Number $Number -IsOffline $PriorOffline
        Set-Disk -Number $Number -IsReadOnly $PriorReadOnly

        $after = Get-Disk -Number $Number
        $result.Offline  = $after.IsOffline
        $result.ReadOnly = $after.IsReadOnly

        if ($after.IsOffline -eq $PriorOffline -and $after.IsReadOnly -eq $PriorReadOnly) {
            $result.Restored = $true
            $result.Message  = "Restored: Offline=$($after.IsOffline) ReadOnly=$($after.IsReadOnly)"
        } else {
            $result.Message = "MISMATCH after restore: Offline=$($after.IsOffline) (wanted $PriorOffline), ReadOnly=$($after.IsReadOnly) (wanted $PriorReadOnly)"
        }
    } catch {
        $result.Message = "TEARDOWN FAILED for disk ${Number}: $_. Restore by hand: Set-Disk -Number $Number -IsOffline `$$PriorOffline -IsReadOnly `$$PriorReadOnly"
    }

    return $result
}
