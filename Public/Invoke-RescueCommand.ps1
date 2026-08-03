function Invoke-RescueCommand {
    <#
    .SYNOPSIS
        Run a command inside the running rescue guest and return its output.
    .DESCRIPTION
        The layer that makes the guest drivable from Windows. Returns an object
        with Stdout, Stderr and ExitCode rather than printing, so results can be
        tested and composed.

        A non-zero guest exit code is returned, not thrown - a failing probe is
        frequently the informative result during diagnosis. Pass -ThrowOnError
        when a failure genuinely should stop a script.
    .EXAMPLE
        Invoke-RescueCommand 'lsblk -o NAME,SIZE,TYPE,FSTYPE'
    .EXAMPLE
        (Invoke-RescueCommand 'blkid -L RESCUECOW').ExitCode -eq 0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Command,
        [int]$TimeoutSec = 120,
        [switch]$ThrowOnError,
        # Do not write this command to the session log. For noisy polling only;
        # the log is the raw material for the repair report.
        [switch]$NoLog
    )

    $state = Get-RescueSessionState
    if (-not (Test-RescueVmAlive $state)) {
        throw 'The rescue guest is not running. Start it with Start-RescueVM.'
    }

    $result = Invoke-RescueSshRaw -State $state -Command $Command -TimeoutSec $TimeoutSec

    if (-not $NoLog) {
        $outcome = 'ok'
        if ($result.TimedOut) { $outcome = 'fail' }
        elseif ($result.ExitCode -ne 0) { $outcome = 'fail' }

        $detail = $result.Stdout
        if ($result.Stderr) { $detail = "$detail`n$($result.Stderr)" }

        Write-RescueLog -Phase 'guest' -Action $Command -Result $outcome `
                        -Detail $detail -Data @{ exit = $result.ExitCode }
    }

    if ($ThrowOnError -and $result.ExitCode -ne 0) {
        throw "Guest command failed (exit $($result.ExitCode)): $Command`n$($result.Stderr)"
    }

    return $result
}
