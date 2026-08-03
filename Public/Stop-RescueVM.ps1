function Stop-RescueVM {
    <#
    .SYNOPSIS
        Shut down the rescue guest and restore host disk state.
    .DESCRIPTION
        Restoring the host disk is the part that matters, and it runs even when
        the guest already died or the shell that started it is gone - which is
        exactly why session state lives on disk rather than in a finally block.

        Safe to run when nothing is running: it will still restore a disk left
        offline by an interrupted session.
    .EXAMPLE
        Stop-RescueVM
    .EXAMPLE
        Stop-RescueVM -Force
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        # Kill immediately instead of asking the guest to shut down first.
        [switch]$Force,
        [int]$ShutdownTimeoutSec = 45
    )

    $state = Get-RescueSessionState -Quiet
    if ($null -eq $state) {
        Write-Host 'No RescueVM session to stop.'
        return
    }

    $alive = Test-RescueVmAlive $state

    Write-Host ''
    Write-Host 'Teardown plan' -ForegroundColor Cyan
    Write-Host '-------------' -ForegroundColor Cyan
    Write-Host "Session        : $($state.Id)"
    Write-Host "Guest          : $(if ($alive) { "running (pid $($state.QemuPid))" } else { 'not running' })"
    if ($state.TargetDiskNumber -ge 0) {
        Write-Host "Restore disk   : #$($state.TargetDiskNumber) -> Offline=$($state.PriorOffline) ReadOnly=$($state.PriorReadOnly)"
    } else {
        Write-Host 'Restore disk   : none attached'
    }

    if ($WhatIfPreference) {
        Write-Host ''
        Write-Host 'WhatIf: exiting before any change.' -ForegroundColor Green
        return
    }

    if ($state.TargetDiskNumber -ge 0) { Assert-RescueAdmin 'restoring host disk state' }

    # --------------------------------------------------------- stop guest ---

    if ($alive) {
        if (-not $Force) {
            # Ask the guest to flush and halt. An unclean kill is safe for the
            # customer disk (attached read-only) but can corrupt the overlay.
            Write-Host 'Asking the guest to shut down...' -ForegroundColor Yellow
            $null = Invoke-RescueSshRaw -State $state -Command 'sync; systemctl poweroff' -TimeoutSec 15

            $deadline = (Get-Date).AddSeconds($ShutdownTimeoutSec)
            while ((Get-Date) -lt $deadline -and (Test-RescueVmAlive $state)) {
                Start-Sleep -Seconds 2
            }
        }

        if (Test-RescueVmAlive $state) {
            Write-Warning 'Guest did not halt in time; killing the QEMU process.'
            Write-RescueLog -Phase 'stop' -Action 'kill qemu' -Result 'note' -Detail 'graceful shutdown timed out'
            try { Stop-Process -Id $state.QemuPid -Force -ErrorAction Stop } catch {
                Write-Warning "Could not kill pid $($state.QemuPid): $_"
            }
            Start-Sleep -Seconds 2
        } else {
            Write-RescueLog -Phase 'stop' -Action 'guest halted' -Result 'ok' -Detail 'clean poweroff'
        }
    }

    # ------------------------------------------------------- restore disk ---

    $restoreOk = $true
    if ($state.TargetDiskNumber -ge 0 -and -not $state.TornDown) {
        $prior = Get-Disk -Number $state.TargetDiskNumber -ErrorAction SilentlyContinue
        if ($null -eq $prior) {
            Write-Warning "Disk $($state.TargetDiskNumber) is no longer attached. Nothing to restore - if it was pulled while offline, reattaching it will pick up current policy."
            Write-RescueLog -Phase 'stop' -Action 'restore disk' -Result 'skip' -Detail 'disk no longer present'
        } else {
            $r = Restore-RescueDiskState -Number $state.TargetDiskNumber `
                    -PriorOffline ([bool]$state.PriorOffline) `
                    -PriorReadOnly ([bool]$state.PriorReadOnly)
            if ($r.Restored) {
                Write-Host $r.Message -ForegroundColor Green
                Write-RescueLog -Phase 'stop' -Action 'restore disk' -Result 'ok' -Detail $r.Message
            } else {
                $restoreOk = $false
                Write-Warning $r.Message
                Write-RescueLog -Phase 'stop' -Action 'restore disk' -Result 'fail' -Detail $r.Message
            }
        }
    }

    $state.TornDown = $true
    Save-RescueSessionState $state

    # ------------------------------------------------------------ report ----

    if (Test-Path $state.SerialLogPath) {
        $len = (Get-Item $state.SerialLogPath).Length
        Write-Host "Serial log : $($state.SerialLogPath) ($len bytes)"
    }
    Write-Host "Session log: $($state.LogPath)"

    Remove-RescueSessionState

    if (-not $restoreOk) {
        Write-Warning 'Host disk state was NOT fully restored. Verify with Get-Disk before pulling the drive.'
    }
}
