function Invoke-RescueTriage {
    <#
    .SYNOPSIS
        Read-only inspection of the attached source disk, layer by layer.
    .DESCRIPTION
        Walks the boot chain from the bottom up - sector 0, partition table,
        filesystem superblocks, then boot artefacts - and records what each
        probe did and did not establish. Every probe is logged including the
        ones that fail, because the dead ends are what make the eventual report
        worth reading.

        Collects by class only. It never lists directory contents and never
        records volume labels, so customer data is not gathered in the first
        place rather than gathered and then scrubbed.

        Nothing here writes to the source. Filesystems are mounted read-only,
        and the disk is attached readonly=on beneath that anyway.
    .EXAMPLE
        $t = Invoke-RescueTriage
        $t.Probes | Format-Table Name, Result
    #>
    [CmdletBinding()]
    param(
        # Skip the read-only mount attempts (fastest, least invasive).
        [switch]$NoMount,
        [int]$TimeoutSec = 90
    )

    $state = Get-RescueSessionState
    if (-not (Test-RescueVmAlive $state)) {
        throw 'The rescue guest is not running. Start it with Start-RescueVM.'
    }
    if ($state.TargetDiskNumber -lt 0) {
        throw 'This session has no source disk attached.'
    }

    $DEV = '/dev/disk/by-id/virtio-source'

    # Ordered lowest layer first. Each probe states what a failure would mean,
    # which is the part that turns output into a diagnosis.
    $probes = @(
        @{ Name = 'device-present'
           Layer = 'controller'
           Cmd = "test -b $DEV && echo present"
           Means = 'Absent means the passthrough never attached; nothing below this is testable.' },

        @{ Name = 'capacity'
           Layer = 'media'
           Cmd = "blockdev --getsize64 $DEV"
           Means = 'A capacity of 0 points at the bridge or enclosure, not the media.' },

        @{ Name = 'sector0-readable'
           Layer = 'media'
           Cmd = "dd if=$DEV bs=512 count=1 status=none | wc -c"
           Means = 'A read error at LBA 0 with a sane capacity suggests media, not partitioning.' },

        @{ Name = 'mbr-signature'
           Layer = 'partition'
           Cmd = "dd if=$DEV bs=1 skip=510 count=2 status=none | od -An -tx1 | tr -d ' '"
           Means = '55aa present means a partition table claims to exist. Absence means sector 0 is blank or overwritten.' },

        @{ Name = 'mbr-bootcode'
           Layer = 'boot'
           Cmd = "dd if=$DEV bs=446 count=1 status=none | od -An -tx1 | tr -d ' \n' | grep -qv '^0*$' && echo bootcode-present || echo bootcode-blank"
           Means = 'Blank bootcode on an MBR disk means nothing executes at handoff, even with valid partitions.' },

        @{ Name = 'partition-table'
           Layer = 'partition'
           Cmd = "sfdisk -d $DEV 2>&1 | grep -v -i 'name='"
           Means = 'The declared layout. Compare start offsets against the filesystems actually found.' },

        @{ Name = 'partition-scan'
           Layer = 'partition'
           Cmd = "lsblk -n -o NAME,SIZE,TYPE,FSTYPE,RO $DEV"
           Means = 'Partitions the kernel actually enumerated, which can differ from what the table declares.' },

        @{ Name = 'filesystem-types'
           Layer = 'filesystem'
           Cmd = "for p in ${DEV}-part*; do [ -b `"`$p`" ] && echo `"`$(basename `$p) `$(blkid -o value -s TYPE `"`$p`" 2>/dev/null || echo none)`"; done"
           Means = 'A partition the table declares but blkid cannot type has a damaged or absent superblock.' }
    )

    if (-not $NoMount) {
        $probes += @(
            @{ Name = 'readonly-mountable'
               Layer = 'filesystem'
               Cmd = "for p in ${DEV}-part*; do [ -b `"`$p`" ] || continue; m=/mnt/probe; mkdir -p `$m; if mount -o ro,noload `"`$p`" `$m 2>/dev/null || mount -o ro `"`$p`" `$m 2>/dev/null; then echo `"`$(basename `$p) mount-ok`"; umount `$m 2>/dev/null; else echo `"`$(basename `$p) mount-failed`"; fi; done"
               Means = 'Mountable read-only means the superblock and metadata are coherent enough to read. Failure here with a valid type points at journal or metadata damage.' },

            @{ Name = 'windows-boot-artefacts'
               Layer = 'boot'
               Cmd = "for p in ${DEV}-part*; do [ -b `"`$p`" ] || continue; m=/mnt/probe; mkdir -p `$m; mount -o ro `"`$p`" `$m 2>/dev/null || continue; for f in bootmgr Boot/BCD EFI/Microsoft/Boot/BCD Windows/System32/winload.exe Windows/System32/winload.efi; do [ -e `"`$m/`$f`" ] && echo `"`$(basename `$p) `$f`"; done; umount `$m 2>/dev/null; done"
               Means = 'Presence proves the files exist, not that they execute. Only a boot test proves execution.' }
        )
    }

    Write-RescueLog -Phase 'triage' -Action 'begin' -Result 'start' `
                    -Detail "$($probes.Count) probes, lowest layer first"

    $results = @()
    foreach ($probe in $probes) {
        $r = Invoke-RescueSshRaw -State $state -Command $probe.Cmd -TimeoutSec $TimeoutSec

        $outcome = 'ok'
        if ($r.TimedOut -or $r.ExitCode -ne 0) { $outcome = 'fail' }
        if ([string]::IsNullOrWhiteSpace($r.Stdout) -and $outcome -eq 'ok') { $outcome = 'skip' }

        $clean = Protect-RescueText $r.Stdout

        Write-RescueLog -Phase 'triage' -Action $probe.Name -Result $outcome `
                        -Detail $clean -Data @{ layer = $probe.Layer; means = $probe.Means }

        $results += [pscustomobject]@{
            Name     = $probe.Name
            Layer    = $probe.Layer
            Result   = $outcome
            Output   = $clean
            Means    = $probe.Means
            ExitCode = $r.ExitCode
        }

        Write-Host ("{0,-24} {1,-12} {2}" -f $probe.Name, $probe.Layer, $outcome) `
            -ForegroundColor $(if ($outcome -eq 'ok') { 'Green' } elseif ($outcome -eq 'fail') { 'Red' } else { 'DarkGray' })
    }

    Write-RescueLog -Phase 'triage' -Action 'complete' -Result 'ok' `
                    -Detail "$(@($results | Where-Object { $_.Result -eq 'ok' }).Count)/$($results.Count) probes returned data"

    return [pscustomobject]@{
        SessionId = $state.Id
        Device    = $DEV
        Probes    = $results
    }
}
