function Get-RescueTarget {
    <#
    .SYNOPSIS
        List attached disks. Read-only; changes nothing.
    .DESCRIPTION
        The inventory you copy Model and SizeBytes out of. Targets are always
        named by identity rather than disk number, because USB enumeration
        reorders between sessions and a stale number names a different drive.
    .EXAMPLE
        Get-RescueTarget
    .EXAMPLE
        Get-RescueTarget -Removable
    #>
    [CmdletBinding()]
    param(
        # Hide the boot/system disk, which is never a valid target.
        [switch]$ExcludeSystem,
        # Show only USB-attached disks.
        [switch]$Removable
    )

    $rows = Get-RescueDiskInventory

    if ($ExcludeSystem) {
        $rows = $rows | Where-Object { -not $_.Boot -and -not $_.System }
    }
    if ($Removable) {
        $rows = $rows | Where-Object { $_.Bus -eq 'USB' }
    }

    return $rows
}
