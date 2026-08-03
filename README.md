# rescuevm

Boot SystemRescue as a QEMU guest with a customer disk attached read-only, so a
Linux rescue environment is usable **without leaving Windows**. The session on
the host stays alive, which means terminal output can be read directly instead
of photographed.

## Why not just dual-boot SystemRescue

Because then Windows is not running, and neither is anything on it. Dual-boot is
the right answer only for work that must touch this machine's own system disk or
issue real ATA commands (secure erase, HPA/DCO, unfreezing). For everything else
it costs the session and buys nothing.

## Why this is not "over the LAN"

Networking is QEMU user-mode with `restrict=on` and a single forwarded port:

    -nic user,restrict=on,hostfwd=tcp::2222-:22

That is an emulated NAT inside the QEMU process. No physical NIC is involved,
the guest cannot reach the LAN or the internet, and SSH is bound to loopback.

## Usage

Inventory. Changes nothing, and it is what you get if you forget an argument:

    .\Start-RescueVM.ps1

Plan a run. Prints the full QEMU command line and every write it would make,
then exits. Works unelevated:

    .\Start-RescueVM.ps1 -Model '<Model>' -SizeBytes <bytes> -WhatIf

Execute. Needs an elevated PowerShell (raw disk access and `Set-Disk`):

    .\Start-RescueVM.ps1 -Model '<Model>' -SizeBytes <bytes>

With a destination image for `ddrescue` output:

    .\Start-RescueVM.ps1 -Model '<Model>' -SizeBytes <bytes> `
        -DestImage D:\work\recovery.qcow2 -DestSizeGB 500

Once the guest is up, type this in the QEMU window (one line, once per boot):

    K=/dev/disk/by-id/virtio-key; mount ${K}-part1 /mnt 2>/dev/null || mount $K /mnt; sh /mnt/setup.sh

**Never address disks as `/dev/vdX` here.** Drive order decides those letters,
so adding or removing a drive silently repoints them - and the disk next to the
key payload is the customer's. Both virtio drives carry a `serial=`, so use the
stable names: the key payload is `virtio-key`, the customer disk is
`virtio-source`.

Then from Windows:

    ssh -i "$env:USERPROFILE\.ssh\rescuevm_ed25519" -p 2222 `
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL root@127.0.0.1

Host keys regenerate on every boot of a live ISO, so the throwaway known-hosts
options are not laziness - a persistent known_hosts would fail every time.

## Safety behaviour

- **Inventory is the default mode.** No target, no action.
- **`-WhatIf` writes nothing at all**, including the keypair and payload.
- **Targets are matched by model plus exact byte size**, never by disk number.
  USB enumeration reorders between sessions. Two matches is a refusal, not a
  guess.
- **`IsBoot`/`IsSystem`/disk 0 are refused** unless `-Force`.
- **Source disk is attached `readonly=on`** unless `-AllowSourceWrites`.
- **Host disk is forced Offline + ReadOnly before start**, and the run aborts if
  it will not go offline. Host and guest must never hold the same volume.
- **Teardown restores prior disk state in a `finally`**, so it runs even if the
  guest dies, and warns loudly with the manual fix if restore fails.
- Nothing is partitioned, formatted, or resized. Ever.

## What this does not get you

SMART and ATA pass-through **do not survive virtualization**. `smartctl` in the
guest sees a QEMU virtio device, not the real drive. Media health belongs on the
Windows side with native smartmontools, where the controller is real.

The layers this *is* good for: partition tables, filesystems, `testdisk`,
`photorec`, `ddrescue`, `ntfsfix`, `e2fsck`.

For boot-chain execution testing on a customer disk, use the qcow2 overlay
method instead - that one needs legacy BIOS and IDE emulation, not this.

## Host prerequisite

Windows auto-mounts drives on insertion, and mounting NTFS is a write - journal
replay, `$LogFile`, restore points. Disable drive-letter assignment once,
elevated:

    mountvol /N

`diskpart san policy=offlineall` is worth trying as a second layer but does not
appear to take on Windows 11 client. The launcher does not depend on it; it
forces the target offline itself before QEMU opens the device.

A hardware write blocker remains the correct tool for irreplaceable data. None
of this substitutes for one.
