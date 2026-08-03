function Copy-FromRescue {
    <#
    .SYNOPSIS
        Copy a file out of the rescue guest to the host.
    .DESCRIPTION
        For pulling logs, mapfiles and tool output back for inspection.

        Deliberately one-directional and deliberately not used for recovered
        customer files: those belong on the destination volume the tech chose,
        not scattered into the tooling tree. See the customer-data rule in
        ~\Work\CLAUDE.md.
    .EXAMPLE
        Copy-FromRescue -GuestPath /var/log/rescuevm-autorun.log -Destination .\autorun.log
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$GuestPath,
        [Parameter(Mandatory = $true, Position = 1)][string]$Destination
    )

    $state = Get-RescueSessionState
    if (-not (Test-RescueVmAlive $state)) {
        throw 'The rescue guest is not running.'
    }

    $args = @(
        '-i', $state.KeyPath,
        '-P', [string]$state.SshPort,
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=NUL',
        '-o', 'LogLevel=ERROR',
        '-o', 'BatchMode=yes',
        "root@127.0.0.1:$GuestPath",
        $Destination
    )

    & scp @args
    $code = $LASTEXITCODE

    Write-RescueLog -Phase 'guest' -Action "scp $GuestPath" `
                    -Result $(if ($code -eq 0) { 'ok' } else { 'fail' }) `
                    -Detail "-> $Destination"

    if ($code -ne 0) { throw "scp failed with exit code $code" }
    return (Get-Item $Destination)
}
