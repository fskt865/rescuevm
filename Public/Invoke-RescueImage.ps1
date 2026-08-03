function Invoke-RescueImage {
    <#
    .SYNOPSIS
        Image the source disk with ddrescue, resuming automatically if a
        previous run was interrupted.
    .DESCRIPTION
        Two passes: a fast one that copies everything readable without
        retrying, then a scraping pass that works the bad areas. That order
        matters on failing media - get the readable majority off first, because
        the drive may not survive the retries.

        The mapfile lives beside the image on the destination, so an interrupted
        run resumes where it stopped instead of starting over. Killing this
        cmdlet does not lose progress.

        Direction is asserted before running: the source is the input. It is
        also attached readonly=on beneath this, so a reversed argument order
        fails rather than destroying the evidence.
    .EXAMPLE
        Invoke-RescueImage -Name recovery
    .EXAMPLE
        Invoke-RescueImage -Name recovery -FastPassOnly
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        # Base name for the image and its mapfile on the destination volume.
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Name,
        # Stop after the no-retry pass. Correct when the drive is degrading and
        # you want the readable majority off before risking more head time.
        [switch]$FastPassOnly,
        [int]$Retries = 3,
        [int]$PollSeconds = 15,
        # Return immediately after launching instead of following progress.
        [switch]$NoWait
    )

    $state = Get-RescueSessionState
    if (-not (Test-RescueVmAlive $state)) { throw 'The rescue guest is not running.' }
    if ($state.TargetDiskNumber -lt 0) { throw 'This session has no source disk attached.' }

    $SRC  = '/dev/disk/by-id/virtio-source'
    $DEST = '/dev/disk/by-id/virtio-dest'
    $MNT  = '/mnt/dest'
    $img  = "$MNT/$Name.img"
    $map  = "$MNT/$Name.map"

    if ($state.SourceWritable) {
        Write-Warning 'This session attached the source WRITABLE. Imaging is still read-only, but the guest could modify the source by other means.'
    }

    $check = Invoke-RescueSshRaw -State $state -Command "test -b $DEST && echo ok" -TimeoutSec 20
    if ($check.Stdout -notmatch 'ok') {
        throw "No destination disk in this session. Restart with -DestImage <path> -DestSizeGB <n> so there is somewhere to write."
    }

    if ($WhatIfPreference) {
        Write-Host ''
        Write-Host 'Plan' -ForegroundColor Cyan
        Write-Host "  source : $SRC (read)"
        Write-Host "  image  : $img"
        Write-Host "  mapfile: $map (resume point)"
        Write-Host "  pass 1 : ddrescue -f -n  (no scraping)"
        if (-not $FastPassOnly) { Write-Host "  pass 2 : ddrescue -f -d -r$Retries  (scrape bad areas)" }
        Write-Host ''
        Write-Host 'WhatIf: exiting before any change.' -ForegroundColor Green
        return
    }

    # Prepare the destination. Format ONLY when it carries no filesystem, and
    # only ever virtio-dest.
    $prep = @"
set -e
if [ -z "`$(blkid -o value -s TYPE $DEST 2>/dev/null)" ]; then
    mkfs.ext4 -F -L RESCUEDEST $DEST >/dev/null 2>&1
fi
mkdir -p $MNT
mountpoint -q $MNT || mount $DEST $MNT
df -h $MNT | tail -1
"@
    $p = Invoke-RescueSshRaw -State $state -Command $prep -TimeoutSec 180
    if ($p.ExitCode -ne 0) {
        Write-RescueLog -Phase 'image' -Action 'prepare destination' -Result 'fail' -Detail $p.Stderr
        throw "Could not prepare the destination volume: $($p.Stderr)"
    }
    Write-RescueLog -Phase 'image' -Action 'prepare destination' -Result 'ok' -Detail $p.Stdout

    $resuming = (Invoke-RescueSshRaw -State $state -Command "test -f $map && echo resume" -TimeoutSec 20).Stdout -match 'resume'
    if ($resuming) {
        Write-Host 'Existing mapfile found - resuming from the previous run.' -ForegroundColor Yellow
        Write-RescueLog -Phase 'image' -Action 'resume detected' -Result 'note' -Detail $map
    }

    # Detached so the copy survives this SSH connection ending.
    $passes = "ddrescue -f -n $SRC $img $map"
    if (-not $FastPassOnly) {
        $passes += " && ddrescue -f -d -r$Retries $SRC $img $map"
    }
    $launch = "setsid nohup sh -c '$passes' >$MNT/$Name.log 2>&1 & echo `$!"

    $l = Invoke-RescueSshRaw -State $state -Command $launch -TimeoutSec 30
    if ($l.ExitCode -ne 0) {
        Write-RescueLog -Phase 'image' -Action 'launch ddrescue' -Result 'fail' -Detail $l.Stderr
        throw "Failed to launch ddrescue: $($l.Stderr)"
    }
    Write-RescueLog -Phase 'image' -Action 'launch ddrescue' -Result 'ok' `
                    -Detail "$passes (resuming=$resuming)"
    Write-Host "ddrescue running in the guest. Mapfile: $map" -ForegroundColor Green

    if ($NoWait) {
        return [pscustomobject]@{ Started = $true; Image = $img; Mapfile = $map; Waited = $false }
    }

    # ------------------------------------------------------------ follow ----

    $last = ''
    while ($true) {
        Start-Sleep -Seconds $PollSeconds

        if (-not (Test-RescueVmAlive $state)) {
            Write-RescueLog -Phase 'image' -Action 'follow' -Result 'fail' -Detail 'guest died mid-copy'
            throw 'The guest stopped while imaging. The mapfile on the destination preserves progress; restart and rerun to resume.'
        }

        $running = (Invoke-RescueSshRaw -State $state -Command 'pgrep -x ddrescue >/dev/null && echo running' -TimeoutSec 20 ).Stdout -match 'running'
        $status  = Invoke-RescueSshRaw -State $state -Command "ddrescuelog -t $map 2>/dev/null | head -20" -TimeoutSec 30

        if ($status.Stdout -and $status.Stdout -ne $last) {
            $last = $status.Stdout
            Write-Host ''
            Write-Host $status.Stdout
        }

        if (-not $running) { break }
    }

    $final = Invoke-RescueSshRaw -State $state -Command "ddrescuelog -t $map 2>/dev/null" -TimeoutSec 30
    $tail  = Invoke-RescueSshRaw -State $state -Command "tail -5 $MNT/$Name.log" -TimeoutSec 20

    Write-RescueLog -Phase 'image' -Action 'complete' -Result 'ok' `
                    -Detail (Protect-RescueText "$($final.Stdout)`n$($tail.Stdout)")

    Write-Host ''
    Write-Host 'ddrescue finished.' -ForegroundColor Green
    Write-Host $final.Stdout

    return [pscustomobject]@{
        Started = $true
        Waited  = $true
        Image   = $img
        Mapfile = $map
        Status  = $final.Stdout
        Tail    = $tail.Stdout
    }
}
