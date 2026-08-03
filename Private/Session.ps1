# Session state shared across cmdlets and across separate PowerShell processes.
#
# The single-script version restored host disk state in a finally block, which
# only runs if the launching shell survives. Persisting state to disk means a
# crashed or closed shell can still be cleaned up by Stop-RescueVM later, and
# that matters because the state being restored is a customer disk's.

function Get-RescueSessionPath {
    $p = Get-RescuePaths
    return Join-Path $p.Sessions 'current.json'
}

function New-RescueSessionState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [int]$SshPort,
        [string]$IsoPath,
        [int]$TargetDiskNumber = -1,
        [string]$TargetModel = '',
        [long]$TargetSize = 0,
        [object]$PriorOffline = $null,
        [object]$PriorReadOnly = $null,
        [string]$OverlayPath = '',
        [bool]$SourceWritable = $false
    )

    Initialize-RescueDirs
    $p = Get-RescuePaths

    $state = [pscustomobject]@{
        Id               = $Id
        StartedUtc       = (Get-Date).ToUniversalTime().ToString('o')
        SshPort          = $SshPort
        IsoPath          = $IsoPath
        QemuPid          = 0
        TargetDiskNumber = $TargetDiskNumber
        TargetModel      = $TargetModel
        TargetSize       = $TargetSize
        PriorOffline     = $PriorOffline
        PriorReadOnly    = $PriorReadOnly
        OverlayPath      = $OverlayPath
        SourceWritable   = $SourceWritable
        SerialLogPath    = (Join-Path $p.Logs "serial-$Id.log")
        LogPath          = (Join-Path $p.Logs "session-$Id.jsonl")
        KeyPath          = $p.KeyPath
        TornDown         = $false
    }

    Save-RescueSessionState $state
    return $state
}

function Save-RescueSessionState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$State)
    Initialize-RescueDirs
    $json = $State | ConvertTo-Json -Depth 6
    Set-Content -Path (Get-RescueSessionPath) -Value $json -Encoding ascii
}

function Get-RescueSessionState {
    [CmdletBinding()]
    param([switch]$Quiet)

    $path = Get-RescueSessionPath
    if (-not (Test-Path $path)) {
        if ($Quiet) { return $null }
        throw 'No RescueVM session. Start one with Start-RescueVM.'
    }
    try {
        return (Get-Content $path -Raw | ConvertFrom-Json)
    } catch {
        if ($Quiet) { return $null }
        throw "Session file at $path is unreadable: $_"
    }
}

function Remove-RescueSessionState {
    [CmdletBinding()]
    param()
    $path = Get-RescueSessionPath
    if (Test-Path $path) {
        # Keep it as a dated artefact rather than deleting: the log it points at
        # is the raw material for the repair report.
        $p = Get-RescuePaths
        $state = Get-RescueSessionState -Quiet
        if ($state) {
            $archive = Join-Path $p.Sessions "session-$($state.Id).json"
            Move-Item -Path $path -Destination $archive -Force
        } else {
            Remove-Item $path -Force
        }
    }
}

function Test-RescueVmAlive {
    [CmdletBinding()]
    param([object]$State)

    if ($null -eq $State) { return $false }
    if ($State.QemuPid -le 0) { return $false }
    $proc = Get-Process -Id $State.QemuPid -ErrorAction SilentlyContinue
    if ($null -eq $proc) { return $false }
    # A recycled PID belonging to something else must not read as alive.
    if ($proc.ProcessName -notlike 'qemu-system*') { return $false }
    return $true
}
