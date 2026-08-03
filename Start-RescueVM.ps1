<#
.SYNOPSIS
    Boot SystemRescue as a QEMU guest with a customer disk attached read-only,
    reachable over SSH on loopback only.

.DESCRIPTION
    Keeps Windows (and the Claude session) running while giving a real Linux
    rescue environment access to a physical disk. Networking is QEMU user-mode
    with restrict=on, so the guest touches no physical NIC and reaches nothing
    except the forwarded SSH port on 127.0.0.1.

    Run with no arguments for a read-only inventory. Nothing is changed until
    you name a target by -Model and -SizeBytes.

.EXAMPLE
    .\Start-RescueVM.ps1
    Inventory only. Changes nothing.

.EXAMPLE
    .\Start-RescueVM.ps1 -Model 'Samsung SSD 860 EVO 500GB' -SizeBytes 500107862016 -WhatIf
    Prints the full plan, including the exact QEMU command line, and exits.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Exact FriendlyName of the source disk, from the inventory output.
    [string]$Model,

    # Exact size in bytes, from the inventory output. Guards against a model
    # collision when two identical drives are attached.
    [long]$SizeBytes = 0,

    # SystemRescue ISO. Auto-discovered in Downloads if exactly one matches.
    [string]$Iso,

    # Optional writable qcow2 for ddrescue output. Created if absent.
    [string]$DestImage,
    [int]$DestSizeGB = 0,

    [int]$MemoryMB = 4096,
    [int]$Cpus = 2,
    [int]$SshPort = 2222,

    # Drop readonly=on from the source drive. Read the warning it prints.
    [switch]$AllowSourceWrites,

    # Permit a disk marked IsBoot/IsSystem. Refused otherwise.
    [switch]$Force,

    # Boot the rescue environment with no customer disk attached.
    [switch]$NoSourceDisk
)

$ErrorActionPreference = 'Stop'

$Root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$PayloadDir = Join-Path $Root 'payload'
$LogDir     = Join-Path $Root 'logs'
$QemuDir    = 'C:\Program Files\qemu'
$QemuExe    = Join-Path $QemuDir 'qemu-system-x86_64.exe'
$QemuImg    = Join-Path $QemuDir 'qemu-img.exe'
$KeyPath    = Join-Path $env:USERPROFILE '.ssh\rescuevm_ed25519'

function Write-Section($text) {
    Write-Host ''
    Write-Host $text -ForegroundColor Cyan
    Write-Host ('-' * $text.Length) -ForegroundColor Cyan
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DiskInventory {
    $rows = @()
    foreach ($d in (Get-Disk | Sort-Object Number)) {
        $bus = ''
        try {
            $pd = Get-PhysicalDisk -ErrorAction Stop |
                  Where-Object { $_.DeviceId -eq [string]$d.Number }
            if ($pd) { $bus = $pd.BusType }
        } catch { $bus = '?' }

        $rows += [pscustomobject]@{
            Num       = $d.Number
            Model     = $d.FriendlyName
            SizeBytes = $d.Size
            SizeGB    = [math]::Round($d.Size / 1GB, 2)
            Bus       = $bus
            Offline   = $d.IsOffline
            ReadOnly  = $d.IsReadOnly
            Boot      = $d.IsBoot
            System    = $d.IsSystem
            Style     = $d.PartitionStyle
        }
    }
    return $rows
}

function Resolve-TargetDisk($model, $sizeBytes) {
    # Identity match, never disk number. USB enumeration reorders between
    # sessions; a stale number is how you image the wrong drive.
    $matches = @(Get-Disk | Where-Object {
        $_.FriendlyName -eq $model -and $_.Size -eq $sizeBytes
    })
    if ($matches.Count -eq 0) {
        throw "No disk matches Model '$model' with size $sizeBytes bytes. Run with no arguments for the inventory."
    }
    if ($matches.Count -gt 1) {
        throw "$($matches.Count) disks match Model '$model' at $sizeBytes bytes. Refusing: cannot disambiguate. Detach one."
    }
    return $matches[0]
}

function Initialize-SshKey {
    $sshDir = Split-Path -Parent $KeyPath
    if (-not (Test-Path $sshDir)) {
        New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
    }
    if (-not (Test-Path $KeyPath)) {
        Write-Host "Generating rescue keypair at $KeyPath" -ForegroundColor Yellow
        # Empty passphrase: the shell tool is non-interactive and this key only
        # ever authenticates to a loopback-bound throwaway guest.
        & ssh-keygen -t ed25519 -f $KeyPath -N '""' -C 'rescuevm' -q
        if (-not (Test-Path $KeyPath)) { throw "ssh-keygen did not produce $KeyPath" }
    }
    return (Get-Content "$KeyPath.pub" -Raw).Trim()
}

function Write-Payload($pubKey) {
    if (-not (Test-Path $PayloadDir)) {
        New-Item -ItemType Directory -Force -Path $PayloadDir | Out-Null
    }
    Set-Content -Path (Join-Path $PayloadDir 'authorized_keys') `
                -Value $pubKey -Encoding ascii -NoNewline

    # LF endings required: this is a shell script read by the guest.
    $setup = @(
        '#!/bin/sh',
        '# Injected by Start-RescueVM.ps1. Runs inside the SystemRescue guest.',
        'set -e',
        'mkdir -p /root/.ssh',
        'cp /mnt/authorized_keys /root/.ssh/authorized_keys',
        'chmod 700 /root/.ssh',
        'chmod 600 /root/.ssh/authorized_keys',
        '# SystemRescue refuses SSH login while the root account is locked,',
        '# even with a valid key. Password auth stays off via sshd_config.',
        "echo 'root:rescue' | chpasswd",
        "sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config",
        "sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config",
        '# Recent SystemRescue ships an inbound firewall that drops 22.',
        'iptables -F 2>/dev/null || true',
        'systemctl restart sshd',
        'echo RESCUEVM_READY',
        'ip -4 -br a'
    ) -join "`n"
    [IO.File]::WriteAllText((Join-Path $PayloadDir 'setup.sh'), $setup + "`n")
}

function Resolve-Iso($explicit) {
    if ($explicit) {
        if (-not (Test-Path $explicit)) { throw "ISO not found: $explicit" }
        return (Resolve-Path $explicit).Path
    }
    $found = @(Get-ChildItem (Join-Path $env:USERPROFILE 'Downloads') `
               -Filter 'systemrescue*.iso' -ErrorAction SilentlyContinue)
    if ($found.Count -eq 1) { return $found[0].FullName }
    if ($found.Count -eq 0) { throw "No systemrescue*.iso in Downloads. Pass -Iso." }
    throw "$($found.Count) SystemRescue ISOs in Downloads. Pass -Iso to choose."
}

# ---------------------------------------------------------------- inventory --

if (-not $Model -and -not $NoSourceDisk) {
    Write-Section 'Attached disks (read-only inventory - nothing changed)'
    Get-DiskInventory | Format-Table -AutoSize
    Write-Host ''
    Write-Host 'To target one, copy its exact Model and SizeBytes:' -ForegroundColor Yellow
    Write-Host '  .\Start-RescueVM.ps1 -Model ''<Model>'' -SizeBytes <SizeBytes> -WhatIf'
    Write-Host ''
    Write-Host 'Add -WhatIf to see the full plan without starting anything.'
    return
}

# ------------------------------------------------------------------- checks --

if (-not (Test-Path $QemuExe)) { throw "QEMU not found at $QemuExe" }

# Elevation is only required to act. Planning with -WhatIf must work unelevated,
# otherwise you cannot review the plan before granting the rights to run it.
if (-not $WhatIfPreference -and -not (Test-Admin)) {
    throw 'Elevation required: raw physical-disk access and Set-Disk both need Administrator. Re-run from an elevated PowerShell.'
}

$target = $null
if (-not $NoSourceDisk) {
    if ($SizeBytes -le 0) { throw '-SizeBytes is required with -Model. Run with no arguments for the inventory.' }
    $target = Resolve-TargetDisk $Model $SizeBytes

    if (($target.IsBoot -or $target.IsSystem) -and -not $Force) {
        throw "Disk $($target.Number) is the live boot/system disk. Refusing. Pass -Force only if you are certain."
    }
    if ($target.Number -eq 0 -and -not $Force) {
        throw 'Disk 0 is almost never the target. Refusing without -Force.'
    }
}

$isoPath = Resolve-Iso $Iso

# Deferred until after the -WhatIf gate: all three of these write to disk.
$pendingKey     = -not (Test-Path $KeyPath)
$pendingPayload = $true

$stamp     = Get-Date -Format 'yyyy-MM-dd-HHmmss'
$serialLog = Join-Path $LogDir "serial-$stamp.log"

# --------------------------------------------------------------- qemu args ---

$qemuArgs = @(
    '-machine', 'q35',
    '-accel',   'whpx,kernel-irqchip=off',
    '-m',       "$MemoryMB",
    '-smp',     "$Cpus",
    '-cdrom',   $isoPath,
    '-boot',    'd',
    # restrict=on: guest reaches nothing but the forwarded port. Not a LAN.
    '-nic',     "user,restrict=on,hostfwd=tcp::${SshPort}-:22",
    # Read-only vvfat carries the pubkey and setup script into the live ISO.
    '-drive',   "file=fat:ro:$PayloadDir,format=raw,if=virtio",
    '-serial',  "file:$serialLog",
    '-display', 'gtk'
)

if ($target) {
    $srcOpts = "file=\\.\PhysicalDrive$($target.Number),format=raw,if=virtio"
    if ($AllowSourceWrites) {
        Write-Warning 'SOURCE DISK IS WRITABLE. The guest can modify customer media.'
    } else {
        $srcOpts += ',readonly=on'
    }
    $qemuArgs += @('-drive', $srcOpts)
}

if ($DestImage) {
    $qemuArgs += @('-drive', "file=$DestImage,format=qcow2,if=virtio")
}

# ------------------------------------------------------------------ whatif ---

Write-Section 'Plan'
if ($target) {
    Write-Host "Source disk    : #$($target.Number)  $($target.FriendlyName)"
    Write-Host "Size           : $($target.Size) bytes"
    Write-Host "Current state  : Offline=$($target.IsOffline) ReadOnly=$($target.IsReadOnly)"
    Write-Host "Attached as    : virtio, $(if ($AllowSourceWrites) { 'WRITABLE' } else { 'readonly=on' })"
    Write-Host "Host will be   : set Offline=True, ReadOnly=True, then restored on exit"
} else {
    Write-Host 'Source disk    : none (-NoSourceDisk)'
}
Write-Host "ISO            : $isoPath"
Write-Host "Dest image     : $(if ($DestImage) { $DestImage } else { '<none>' })"
Write-Host "Serial log     : $serialLog"
Write-Host "SSH            : 127.0.0.1:$SshPort  (loopback only)"
Write-Host ''
Write-Host 'QEMU command line:' -ForegroundColor Yellow
Write-Host "`"$QemuExe`" $($qemuArgs -join ' ')"

if ($DestImage -and -not (Test-Path $DestImage)) {
    if ($DestSizeGB -le 0) { throw '-DestImage does not exist and -DestSizeGB was not given.' }
    Write-Host ''
    Write-Host "Will create destination image: $DestImage (${DestSizeGB}G)" -ForegroundColor Yellow
}

if ($WhatIfPreference) {
    Write-Host ''
    Write-Host 'Would write, in this order:' -ForegroundColor Yellow
    if ($pendingKey) { Write-Host "  1. new ed25519 keypair  -> $KeyPath" }
    else             { Write-Host "  1. (keypair already exists at $KeyPath - reused)" }
    Write-Host "  2. authorized_keys + setup.sh -> $PayloadDir"
    Write-Host "  3. serial log           -> $serialLog"
    if ($target) {
        Write-Host "  4. Set-Disk $($target.Number): ReadOnly=True, then Offline=True"
    }
    Write-Host ''
    Write-Host 'WhatIf: exiting before any change. Nothing was written.' -ForegroundColor Green
    return
}

$pubKey = Initialize-SshKey
Write-Payload $pubKey
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

# ------------------------------------------------------------------- act -----

$priorOffline  = $null
$priorReadOnly = $null

try {
    if ($DestImage -and -not (Test-Path $DestImage)) {
        & $QemuImg create -f qcow2 $DestImage "${DestSizeGB}G" | Out-Null
    }

    if ($target) {
        $priorOffline  = $target.IsOffline
        $priorReadOnly = $target.IsReadOnly

        # ReadOnly first: setting it on an already-offline disk is unreliable.
        try { Set-Disk -Number $target.Number -IsReadOnly $true } catch {
            Write-Warning "Could not set ReadOnly on disk $($target.Number): $_"
        }
        try { Set-Disk -Number $target.Number -IsOffline $true } catch {
            Write-Warning "Could not set Offline on disk $($target.Number): $_"
        }

        $now = Get-Disk -Number $target.Number
        Write-Host ''
        Write-Host "Host disk state: Offline=$($now.IsOffline) ReadOnly=$($now.IsReadOnly)" -ForegroundColor Green
        if (-not $now.IsOffline) {
            throw 'Refusing to start: the source disk is still online on the host. Host and guest must never hold the same volume.'
        }
    }

    Write-Host ''
    Write-Host 'Starting QEMU. In the guest window, type:' -ForegroundColor Yellow
    Write-Host '  mount /dev/vdb1 /mnt || mount /dev/vdb /mnt; sh /mnt/setup.sh'
    Write-Host ''
    Write-Host 'Then from Windows:' -ForegroundColor Yellow
    Write-Host "  ssh -i `"$KeyPath`" -p $SshPort -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL root@127.0.0.1"
    Write-Host ''

    & $QemuExe @qemuArgs
    $exit = $LASTEXITCODE
    Write-Host "QEMU exited with code $exit"
}
finally {
    # Teardown runs even if the guest dies or the user aborts.
    if ($target -ne $null) {
        Write-Section 'Teardown'
        try {
            Set-Disk -Number $target.Number -IsOffline $priorOffline
            Set-Disk -Number $target.Number -IsReadOnly $priorReadOnly
            $after = Get-Disk -Number $target.Number
            Write-Host "Restored: Offline=$($after.IsOffline) ReadOnly=$($after.IsReadOnly)"
            if ($after.IsOffline -ne $priorOffline -or $after.IsReadOnly -ne $priorReadOnly) {
                Write-Warning 'Restore did not match the prior state. Verify manually with Get-Disk.'
            }
        } catch {
            Write-Warning "TEARDOWN FAILED for disk $($target.Number): $_"
            Write-Warning "Restore by hand: Set-Disk -Number $($target.Number) -IsOffline `$$priorOffline"
        }
    }
    if (Test-Path $serialLog) {
        $len = (Get-Item $serialLog).Length
        Write-Host "Serial log: $serialLog ($len bytes)"
        if ($len -eq 0) {
            Write-Host 'Serial log is empty. That is normal when the guest booted to the graphical console.'
        }
    }
}
