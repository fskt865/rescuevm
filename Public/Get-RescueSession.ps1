function Get-RescueSession {
    <#
    .SYNOPSIS
        Show the current rescue session and whether its guest is alive.
    .DESCRIPTION
        Session state is persisted to disk, so this works from any shell - not
        just the one that started the VM. That also means a session whose shell
        died can still be found and torn down.
    #>
    [CmdletBinding()]
    param(
        # Also return the parsed session log (the diagnostic ladder so far).
        [switch]$IncludeLog
    )

    $state = Get-RescueSessionState -Quiet
    if ($null -eq $state) {
        Write-Verbose 'No active RescueVM session.'
        return $null
    }

    $alive = Test-RescueVmAlive $state

    $out = [pscustomobject]@{
        Id             = $state.Id
        Alive          = $alive
        QemuPid        = $state.QemuPid
        SshPort        = $state.SshPort
        StartedUtc     = $state.StartedUtc
        TargetDisk     = $state.TargetDiskNumber
        TargetModel    = $state.TargetModel
        SourceWritable = $state.SourceWritable
        SerialLog      = $state.SerialLogPath
        SessionLog     = $state.LogPath
        TornDown       = $state.TornDown
    }

    if ($IncludeLog -and (Test-Path $state.LogPath)) {
        $entries = @()
        foreach ($line in (Get-Content $state.LogPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $entries += ($line | ConvertFrom-Json) } catch { }
        }
        $out | Add-Member -NotePropertyName Log -NotePropertyValue $entries
    }

    if (-not $alive -and -not $state.TornDown -and $state.TargetDiskNumber -ge 0) {
        Write-Warning "Guest is not running but disk $($state.TargetDiskNumber) has not been restored. Run Stop-RescueVM to clean up."
    }

    return $out
}
