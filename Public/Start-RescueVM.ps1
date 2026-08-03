function Start-RescueVM {
    <#
    .SYNOPSIS
        Boot SystemRescue as a guest with a disk attached read-only, reachable
        over SSH on loopback.
    .DESCRIPTION
        Boots via an extracted kernel and initramfs so the kernel command line
        can be set without anyone typing at a boot menu. That is what makes
        startup unattended: firewall off, autorun pointed at the key payload,
        persistent overlay selected, and the whole boot log on a serial file.

        Networking is QEMU user-mode with restrict=on and one forwarded port.
        No physical NIC is involved and the guest can reach nothing else.

        Run Get-RescueTarget first for the inventory. -WhatIf prints the full
        plan, including the exact QEMU command line, and writes nothing at all.
    .EXAMPLE
        Start-RescueVM -Model 'PNY USB 3.2.1 FD' -SizeBytes 30979129856 -WhatIf
    .EXAMPLE
        Start-RescueVM -Model 'PNY USB 3.2.1 FD' -SizeBytes 30979129856
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$Model,
        [long]$SizeBytes = 0,
        [string]$Iso,
        [string]$DestImage,
        [int]$DestSizeGB = 0,
        [int]$MemoryMB = 4096,
        [int]$Cpus = 2,
        [int]$SshPort = 2222,
        [int]$OverlaySizeGB = 8,
        [int]$WaitTimeoutSec = 240,
        # Attach the source disk writable. Read the warning it prints.
        [switch]$AllowSourceWrites,
        # Permit a disk marked IsBoot/IsSystem.
        [switch]$Force,
        # Boot with no disk attached.
        [switch]$NoSourceDisk,
        # Skip the persistent overlay; every boot starts clean.
        [switch]$NoPersist,
        # Headless by default: the session drives it over SSH. 'gtk' opens a
        # window for a tech who wants to watch.
        [ValidateSet('none', 'gtk', 'sdl')][string]$Display = 'none',
        [string]$Accel = 'whpx,kernel-irqchip=off'
    )

    Test-RescueQemu

    if (-not $NoSourceDisk -and -not $Model) {
        throw 'Specify -Model and -SizeBytes, or -NoSourceDisk. Run Get-RescueTarget for the inventory.'
    }

    # Planning must work unelevated, or you cannot review a plan before granting
    # the rights to run it.
    if (-not $WhatIfPreference) {
        Assert-RescueAdmin 'starting the rescue guest'
    }

    $existing = Get-RescueSessionState -Quiet
    if ($existing -and (Test-RescueVmAlive $existing) -and -not $WhatIfPreference) {
        throw "A rescue guest is already running (pid $($existing.QemuPid), session $($existing.Id)). Stop it with Stop-RescueVM."
    }

    $isoPath = Resolve-RescueIso $Iso
    $paths   = Get-RescuePaths

    $target = $null
    if (-not $NoSourceDisk) {
        $target = Resolve-RescueDisk -Model $Model -SizeBytes $SizeBytes -Force:$Force
    }

    # Cached boot manifest if present; otherwise describe what will be read.
    $bootManifest = $null
    $manifestPath = Join-Path $paths.Boot 'manifest.json'
    if (Test-Path $manifestPath) {
        try { $bootManifest = Get-Content $manifestPath -Raw | ConvertFrom-Json } catch { }
    }
    $planBoot = $bootManifest
    if ($null -eq $planBoot) {
        # Read the label now so the plan prints the real command line rather
        # than a placeholder. Read-only mount; nothing is written.
        $probe = Get-RescueIsoLabel -IsoPath $isoPath
        if ($null -eq $probe) { throw "Could not read the volume label from $isoPath. Is it a valid ISO?" }
        $planBoot = [pscustomobject]@{
            Label   = $probe.Label
            BaseDir = 'sysresccd'
            Kernel  = (Join-Path $paths.Boot 'vmlinuz')
            Initrd  = (Join-Path $paths.Boot 'sysresccd.img')
            Version = $probe.Version
        }
    }

    $overlayPath  = ''
    $overlayReady = $false
    if (-not $NoPersist) {
        $overlayPath  = Get-RescueOverlayPath
        $overlayReady = Test-RescueOverlayReady
    }

    $sessionId = Get-Date -Format 'yyyy-MM-dd-HHmmss'
    $serialLog = Join-Path $paths.Logs "serial-$sessionId.log"

    $qemuArgs = New-RescueQemuArgs -Boot $planBoot -IsoPath $isoPath `
        -PayloadDir $paths.Payload -SerialLog $serialLog -SshPort $SshPort `
        -MemoryMB $MemoryMB -Cpus $Cpus `
        -TargetDiskNumber $(if ($target) { $target.Number } else { -1 }) `
        -SourceWritable:$AllowSourceWrites -OverlayPath $overlayPath `
        -OverlayReady:$overlayReady -DestImage $DestImage -Display $Display -Accel $Accel

    # ------------------------------------------------------------- plan -----

    Write-Host ''
    Write-Host 'Plan' -ForegroundColor Cyan
    Write-Host '----' -ForegroundColor Cyan
    if ($target) {
        Write-Host "Source disk    : #$($target.Number)  $($target.FriendlyName)"
        Write-Host "Size           : $($target.Size) bytes"
        Write-Host "Current state  : Offline=$($target.IsOffline) ReadOnly=$($target.IsReadOnly)"
        if ($AllowSourceWrites) {
            Write-Warning 'SOURCE DISK WILL BE WRITABLE. The guest can modify customer media.'
        } else {
            Write-Host "Attached as    : virtio-source, readonly=on"
        }
    } else {
        Write-Host 'Source disk    : none'
    }
    Write-Host "ISO            : $isoPath  (SystemRescue $($planBoot.Version))"
    Write-Host "archisolabel   : $($planBoot.Label)"
    Write-Host "Persistence    : $(if ($NoPersist) { 'disabled' } elseif ($overlayReady) { "overlay $overlayPath" } else { 'overlay will be created and formatted on first boot' })"
    Write-Host "Destination    : $(if ($DestImage) { $DestImage } else { '<none>' })"
    Write-Host "Serial log     : $serialLog"
    Write-Host "SSH            : 127.0.0.1:$SshPort  (loopback only)"
    Write-Host ''
    Write-Host 'QEMU command line:' -ForegroundColor Yellow
    Write-Host "`"$($paths.QemuExe)`" $($qemuArgs -join ' ')"

    if ($WhatIfPreference) {
        Write-Host ''
        Write-Host 'Would write, in this order:' -ForegroundColor Yellow
        $n = 1
        if (-not (Test-Path $paths.KeyPath)) { Write-Host "  $n. ed25519 keypair -> $($paths.KeyPath)"; $n++ }
        if ($null -eq $bootManifest) { Write-Host "  $n. extract vmlinuz + sysresccd.img (~190 MB) -> $($paths.Boot)"; $n++ }
        Write-Host "  $n. autorun0 + authorized_keys -> $($paths.Payload)"; $n++
        if ($overlayPath -and -not (Test-Path $overlayPath)) { Write-Host "  $n. overlay qcow2 (${OverlaySizeGB}G) -> $overlayPath"; $n++ }
        if ($DestImage -and -not (Test-Path $DestImage)) { Write-Host "  $n. destination image (${DestSizeGB}G) -> $DestImage"; $n++ }
        Write-Host "  $n. session state + logs -> $($paths.Sessions), $($paths.Logs)"; $n++
        if ($target) { Write-Host "  $n. Set-Disk $($target.Number): ReadOnly=True, then Offline=True" }
        Write-Host ''
        Write-Host 'WhatIf: exiting before any change. Nothing was written.' -ForegroundColor Green
        return
    }

    # -------------------------------------------------------------- act -----

    if ($DestImage -and -not (Test-Path $DestImage)) {
        if ($DestSizeGB -le 0) { throw '-DestImage does not exist and -DestSizeGB was not given.' }
        & $paths.QemuImg create -f qcow2 $DestImage "${DestSizeGB}G" | Out-Null
    }

    $pubKey = Initialize-RescueKey
    Write-RescuePayload -PublicKey $pubKey

    $boot = Expand-RescueBootFiles -IsoPath $isoPath
    if (-not $NoPersist) { $overlayPath = New-RescueOverlayDisk -SizeGB $OverlaySizeGB }

    # Rebuild args now that the real label and paths are known.
    $qemuArgs = New-RescueQemuArgs -Boot $boot -IsoPath $isoPath `
        -PayloadDir $paths.Payload -SerialLog $serialLog -SshPort $SshPort `
        -MemoryMB $MemoryMB -Cpus $Cpus `
        -TargetDiskNumber $(if ($target) { $target.Number } else { -1 }) `
        -SourceWritable:$AllowSourceWrites -OverlayPath $overlayPath `
        -OverlayReady:$overlayReady -DestImage $DestImage -Display $Display -Accel $Accel

    $state = New-RescueSessionState -Id $sessionId -SshPort $SshPort -IsoPath $isoPath `
        -TargetDiskNumber $(if ($target) { $target.Number } else { -1 }) `
        -TargetModel $(if ($target) { $target.FriendlyName } else { '' }) `
        -TargetSize $(if ($target) { $target.Size } else { 0 }) `
        -OverlayPath $overlayPath -SourceWritable ([bool]$AllowSourceWrites)

    Write-RescueLog -Phase 'start' -Action 'session opened' -Result 'start' `
                    -Detail "SystemRescue $($boot.Version), accel $Accel"

    if ($target) {
        $prior = Set-RescueDiskIsolated -Number $target.Number
        $state.PriorOffline  = $prior.Offline
        $state.PriorReadOnly = $prior.ReadOnly
        Save-RescueSessionState $state
        Write-RescueLog -Phase 'start' -Action 'host disk isolated' -Result 'ok' `
                        -Detail "disk $($target.Number) offline+readonly; prior Offline=$($prior.Offline) ReadOnly=$($prior.ReadOnly)"
        Write-Host ''
        Write-Host "Host disk $($target.Number): Offline=True ReadOnly=True (prior state recorded for teardown)" -ForegroundColor Green
    }

    try {
        $proc = Start-RescueQemuProcess -QemuArgs $qemuArgs
        $state.QemuPid = $proc.Id
        Save-RescueSessionState $state
        Write-RescueLog -Phase 'start' -Action 'qemu launched' -Result 'ok' -Detail "pid $($proc.Id)"
    } catch {
        Write-RescueLog -Phase 'start' -Action 'qemu launch' -Result 'fail' -Detail "$_"
        if ($target) {
            $r = Restore-RescueDiskState -Number $target.Number `
                    -PriorOffline ([bool]$state.PriorOffline) -PriorReadOnly ([bool]$state.PriorReadOnly)
            Write-Warning $r.Message
        }
        Remove-RescueSessionState
        throw
    }

    Write-Host ''
    Write-Host "QEMU running (pid $($proc.Id)). Waiting for the guest to answer SSH..." -ForegroundColor Yellow

    $wait = Wait-RescueSsh -State $state -TimeoutSec $WaitTimeoutSec
    Write-RescueLog -Phase 'start' -Action 'wait for sshd' `
                    -Result $(if ($wait.Ready) { 'ok' } else { 'fail' }) -Detail $wait.Message

    if (-not $wait.Ready) {
        Write-Warning $wait.Message
        Write-Warning "Serial log: $serialLog"
        Write-Warning 'The guest is still running. Inspect the serial log, then Stop-RescueVM to clean up.'
        return (Get-RescueSession)
    }

    Write-Host $wait.Message -ForegroundColor Green

    # Confirm the overlay actually formatted, rather than assuming autorun did.
    if ($overlayPath -and -not $overlayReady) {
        $check = Invoke-RescueSshRaw -State $state -Command 'blkid -L RESCUECOW' -TimeoutSec 20
        if ($check.ExitCode -eq 0 -and $check.Stdout) {
            $marker = Join-Path (Get-RescuePaths).Overlay 'formatted.marker'
            Set-Content -Path $marker -Value $check.Stdout -Encoding ascii
            Write-RescueLog -Phase 'start' -Action 'overlay formatted' -Result 'ok' `
                            -Detail 'RESCUECOW present; persistence active from next boot'
            Write-Host 'Persistence overlay formatted. It takes effect from the next boot.' -ForegroundColor Green
        } else {
            Write-RescueLog -Phase 'start' -Action 'overlay format' -Result 'fail' `
                            -Detail 'RESCUECOW label not found after boot'
            Write-Warning 'Overlay did not format. Persistence is inactive; the guest is otherwise fine.'
        }
    }

    return (Get-RescueSession)
}
