# ISO boot-file extraction, overlay management and QEMU argument construction.
#
# Booting via -kernel/-initrd rather than letting the ISO's bootloader run is
# what makes startup unattended: it is the only way to put parameters on the
# kernel command line without a human typing at the boot menu. That buys the
# firewall being off, autorun pointed at the key payload, the persistent
# overlay, and a serial console carrying the whole boot log.

function Resolve-RescueIso {
    [CmdletBinding()]
    param([string]$Path)

    if ($Path) {
        if (-not (Test-Path $Path)) { throw "ISO not found: $Path" }
        return (Resolve-Path $Path).Path
    }

    $downloads = Join-Path $env:USERPROFILE 'Downloads'
    $found = @(Get-ChildItem $downloads -Filter 'systemrescue*.iso' -ErrorAction SilentlyContinue)
    if ($found.Count -eq 1) { return $found[0].FullName }
    if ($found.Count -eq 0) { throw "No systemrescue*.iso found in $downloads. Pass -Iso." }
    throw "$($found.Count) SystemRescue ISOs in $downloads. Pass -Iso to choose."
}

function Get-RescueIsoLabel {
    <#
        Read the ISO volume label without extracting anything. Mounting
        read-only and dismounting is not a write, so -WhatIf can call this and
        still print the exact command line that will run.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$IsoPath)

    $img = $null
    try {
        $img = Mount-DiskImage -ImagePath $IsoPath -Access ReadOnly -PassThru -ErrorAction Stop
        $vol = $img | Get-Volume
        $label = $vol.FileSystemLabel
        $version = ''
        if ($vol.DriveLetter) {
            $vf = "$($vol.DriveLetter):\sysresccd\version"
            if (Test-Path $vf) { $version = (Get-Content $vf -Raw).Trim() }
        }
        return [pscustomobject]@{ Label = $label; Version = $version }
    } catch {
        return $null
    } finally {
        if ($img) { try { Dismount-DiskImage -ImagePath $IsoPath | Out-Null } catch { } }
    }
}

function Expand-RescueBootFiles {
    <#
        Mount the ISO, copy out the kernel and initramfs, and record the volume
        label and base directory that archiso needs to find its root image.

        Cached: re-extraction only happens if the ISO changes, because copying
        ~190 MB on every boot is pointless.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$IsoPath)

    Initialize-RescueDirs
    $p = Get-RescuePaths
    $manifestPath = Join-Path $p.Boot 'manifest.json'
    $iso = Get-Item $IsoPath

    if (Test-Path $manifestPath) {
        try {
            $m = Get-Content $manifestPath -Raw | ConvertFrom-Json
            $sameIso = ($m.IsoPath -eq $iso.FullName -and
                        $m.IsoLength -eq $iso.Length -and
                        (Test-Path $m.Kernel) -and (Test-Path $m.Initrd))
            if ($sameIso) { return $m }
        } catch { }
    }

    Write-Verbose "Extracting boot files from $IsoPath"
    $img = $null
    try {
        $img = Mount-DiskImage -ImagePath $iso.FullName -Access ReadOnly -PassThru -ErrorAction Stop
        $vol = $img | Get-Volume
        $label = $vol.FileSystemLabel
        $dl = $vol.DriveLetter
        if (-not $dl) { throw 'Mounted ISO has no drive letter.' }

        $srcKernel = "${dl}:\sysresccd\boot\x86_64\vmlinuz"
        $srcInitrd = "${dl}:\sysresccd\boot\x86_64\sysresccd.img"
        if (-not (Test-Path $srcKernel)) { throw "Kernel not found at $srcKernel - unexpected ISO layout." }
        if (-not (Test-Path $srcInitrd)) { throw "Initramfs not found at $srcInitrd - unexpected ISO layout." }

        $dstKernel = Join-Path $p.Boot 'vmlinuz'
        $dstInitrd = Join-Path $p.Boot 'sysresccd.img'
        Copy-Item $srcKernel $dstKernel -Force
        Copy-Item $srcInitrd $dstInitrd -Force

        $version = ''
        $vf = "${dl}:\sysresccd\version"
        if (Test-Path $vf) { $version = (Get-Content $vf -Raw).Trim() }

        $manifest = [pscustomobject]@{
            IsoPath   = $iso.FullName
            IsoLength = $iso.Length
            Label     = $label
            BaseDir   = 'sysresccd'
            Version   = $version
            Kernel    = $dstKernel
            Initrd    = $dstInitrd
        }
        $manifest | ConvertTo-Json -Depth 4 | Set-Content -Path $manifestPath -Encoding ascii
        return $manifest
    } finally {
        if ($img) {
            try { Dismount-DiskImage -ImagePath $iso.FullName | Out-Null } catch { }
        }
    }
}

function Get-RescueOverlayPath {
    $p = Get-RescuePaths
    return (Join-Path $p.Overlay 'persist.qcow2')
}

function Test-RescueOverlayReady {
    <#
        The overlay is only usable once it carries a filesystem labelled
        RESCUECOW. It is created empty, formatted on first boot from inside the
        guest, and only then can archiso mount it as a persistent upper layer.
    #>
    [CmdletBinding()]
    param()
    $p = Get-RescuePaths
    $marker = Join-Path $p.Overlay 'formatted.marker'
    return ((Test-Path (Get-RescueOverlayPath)) -and (Test-Path $marker))
}

function New-RescueOverlayDisk {
    [CmdletBinding()]
    param([int]$SizeGB = 8)

    Initialize-RescueDirs
    $p = Get-RescuePaths
    $path = Get-RescueOverlayPath
    if (-not (Test-Path $path)) {
        & $p.QemuImg create -f qcow2 $path "${SizeGB}G" | Out-Null
        if (-not (Test-Path $path)) { throw "qemu-img failed to create $path" }
    }
    return $path
}

function New-RescueQemuArgs {
    <#
        Build the full argument list. Kept separate from launching so -WhatIf
        can print exactly what would run without side effects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Boot,
        [Parameter(Mandatory = $true)][string]$IsoPath,
        [Parameter(Mandatory = $true)][string]$PayloadDir,
        [Parameter(Mandatory = $true)][string]$SerialLog,
        [int]$SshPort = 2222,
        [int]$MemoryMB = 4096,
        [int]$Cpus = 2,
        [int]$TargetDiskNumber = -1,
        [switch]$SourceWritable,
        [string]$OverlayPath = '',
        [switch]$OverlayReady,
        [string]$DestImage = '',
        [ValidateSet('none', 'gtk', 'sdl')][string]$Display = 'none',
        [string]$Accel = 'whpx,kernel-irqchip=off'
    )

    # Kernel command line. Order is not significant except for console=, where
    # the last entry becomes /dev/console.
    $cmdline = @(
        "archisobasedir=$($Boot.BaseDir)",
        "archisolabel=$($Boot.Label)",
        # SystemRescue ships an inbound firewall that drops 22. Confirmed by
        # nofirewall:false in the ISO's own 100_defaults.yaml.
        'nofirewall',
        # Point autorun at the payload drive so setup runs with no typing.
        'ar_source=/dev/disk/by-id/virtio-key',
        'ar_nowait=1',
        'console=tty0',
        'console=ttyS0,115200'
    )

    if ($OverlayReady -and $OverlayPath) {
        # archiso persistent upper layer, matched by filesystem label.
        $cmdline += @('cow_label=RESCUECOW', 'cow_persistent=P')
    }

    $qemuArgs = @(
        '-machine', 'q35',
        '-accel',   $Accel,
        '-m',       "$MemoryMB",
        '-smp',     "$Cpus",
        '-kernel',  $Boot.Kernel,
        '-initrd',  $Boot.Initrd,
        '-append',  ($cmdline -join ' '),
        # The ISO must still be attached: archiso locates airootfs.sfs by label.
        '-drive',   "file=$IsoPath,media=cdrom,readonly=on",
        # restrict=on isolates the guest from every network except the single
        # forwarded port on loopback. This is not a LAN.
        '-nic',     "user,restrict=on,hostfwd=tcp::${SshPort}-:22",
        # serial= gives stable /dev/disk/by-id names. Never address disks as
        # vdX: drive order decides those, and the disk beside the payload is
        # the customer's.
        '-drive',   "file=fat:ro:$PayloadDir,if=virtio,serial=key",
        '-serial',  "file:$SerialLog",
        '-display', $Display
    )

    if ($OverlayPath) {
        $qemuArgs += @('-drive', "file=$OverlayPath,format=qcow2,if=virtio,serial=cow")
    }

    if ($TargetDiskNumber -ge 0) {
        $src = "file=\\.\PhysicalDrive$TargetDiskNumber,format=raw,if=virtio,serial=source"
        if (-not $SourceWritable) { $src += ',readonly=on' }
        $qemuArgs += @('-drive', $src)
    }

    if ($DestImage) {
        $qemuArgs += @('-drive', "file=$DestImage,format=qcow2,if=virtio,serial=dest")
    }

    return $qemuArgs
}

function Start-RescueQemuProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$QemuArgs
    )
    $p = Get-RescuePaths
    $proc = Start-Process -FilePath $p.QemuExe -ArgumentList $QemuArgs -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 750
    if ($proc.HasExited) {
        throw "QEMU exited immediately with code $($proc.ExitCode). Check the serial log and the argument list."
    }
    return $proc
}
