# RescueVM

Drive a SystemRescue guest from Windows without leaving the session. The rescue
environment runs as a QEMU guest with a customer disk attached read-only, so
terminal output is read directly instead of photographed.

    Import-Module ~\Work\rescuevm\RescueVM.psd1

## Why not dual-boot SystemRescue

Because then Windows is not running, and neither is anything on it. Dual-boot is
the right answer only for work that must touch this machine's own system disk or
issue real ATA commands - secure erase, HPA/DCO, unfreezing a drive. For
everything else it costs the session and buys nothing.

## Why this is not "over the LAN"

    -nic user,restrict=on,hostfwd=tcp::2222-:22

An emulated NAT inside the QEMU process. No physical NIC, no LAN, no internet
for the guest, and SSH bound to loopback.

## Commands

| Cmdlet | Purpose |
|---|---|
| `Get-RescueTarget` | Disk inventory. Read-only. |
| `Start-RescueVM` | Boot the guest. `-WhatIf` writes nothing. |
| `Invoke-RescueCommand` | Run a command in the guest, get Stdout/Stderr/ExitCode back. |
| `Invoke-RescueTriage` | Read-only boot-chain walk, lowest layer first. |
| `Invoke-RescueImage` | ddrescue with a resumable mapfile. |
| `Copy-FromRescue` | Pull a file out of the guest. |
| `Get-RescueSession` | Session state and liveness, from any shell. |
| `Stop-RescueVM` | Halt the guest and restore host disk state. |
| `New-RescueReport` | Session log to a repair-report draft. |

## Typical run

```powershell
Get-RescueTarget -ExcludeSystem

# Plan first. Works unelevated and writes nothing.
Start-RescueVM -Model 'WDC WD10SPZX-22Z10T0' -SizeBytes 1000204886016 -WhatIf

# Execute. Needs an elevated PowerShell.
Start-RescueVM -Model 'WDC WD10SPZX-22Z10T0' -SizeBytes 1000204886016 `
    -DestImage D:\recovery\job.qcow2 -DestSizeGB 1200

Invoke-RescueTriage
Invoke-RescueImage -Name job -FastPassOnly

Stop-RescueVM
New-RescueReport -FailureClass ntfs-metadata-corruption
```

## Unattended boot

Boot goes through an extracted kernel and initramfs rather than the ISO's
bootloader. That is the only way to set the kernel command line without someone
typing at a boot menu, and it is what buys:

- `nofirewall` - SystemRescue ships an inbound firewall that drops 22. Confirmed
  by `nofirewall: false` in the ISO's own `100_defaults.yaml`.
- `ar_source=/dev/disk/by-id/virtio-key` - autorun runs `autorun0` from the
  payload drive, which installs the key and starts sshd.
- `cow_label=RESCUECOW` - the persistence overlay, once formatted.
- `console=ttyS0` - the entire boot log to a file on the host, so a guest that
  never comes up can still be diagnosed.

The ISO stays attached because archiso locates `airootfs.sfs` by volume label.

## Never address disks as /dev/vdX

Drive order decides those letters, and the disk beside the key payload is the
customer's. Every virtio drive carries a `serial=`, so use the stable names:

| Name | What it is |
|---|---|
| `/dev/disk/by-id/virtio-source` | the customer disk, `readonly=on` |
| `/dev/disk/by-id/virtio-dest` | destination for recovered images |
| `/dev/disk/by-id/virtio-key` | read-only key payload |
| `/dev/disk/by-id/virtio-cow` | persistence overlay |

## Safety behaviour

- **Inventory is the default.** No target, no action.
- **`-WhatIf` writes nothing at all**, including the keypair, boot extraction
  and overlay. It lists what it would write, in order.
- **Targets match on model plus exact byte size**, never disk number. USB
  enumeration reorders between sessions. Two matches is a refusal, not a guess.
- **`IsBoot`/`IsSystem`/disk 0 refused** without `-Force`.
- **Source attaches `readonly=on`** unless `-AllowSourceWrites`.
- **Host disk forced Offline + ReadOnly before start**, and the run aborts if it
  will not go offline. Host and guest must never hold the same volume.
- **Teardown state lives on disk, not in a `finally` block**, so a session whose
  shell died can still be cleaned up by `Stop-RescueVM`.
- **Formatting only ever targets `virtio-cow` or `virtio-dest`**, and only when
  the device carries no filesystem at all.
- Nothing is partitioned, resized or deleted. Ever.

## Customer data

Triage collects by class. It never lists directory contents and never records
volume labels, so identifying data is not gathered in the first place rather
than gathered and then scrubbed. Well-known boot paths (`bootmgr`, `BCD`,
`winload.efi`) are probed by existence only.

Everything written to a report passes through redaction - serials, WWNs,
filesystem labels, Windows profile paths - and the assembled document gets a
second audit pass before it lands. Reports go to `~\Work\repair-reports\`, which
is gitignored from the parent and pushed nowhere.

Session logs and serial logs are gitignored here for the same reason.

## What this does not get you

SMART and ATA pass-through **do not survive virtualization**. `smartctl` in the
guest sees a virtio device, not the real drive. Media health belongs on the
Windows side with native smartmontools, where the controller is real.

Good for: partition tables, filesystems, testdisk, photorec, ddrescue, ntfsfix,
e2fsck. For boot-chain *execution* testing use the qcow2 overlay method instead
- that one needs legacy BIOS and IDE emulation, not this.

## Host prerequisite

Windows auto-mounts drives on insertion, and mounting NTFS is a write - journal
replay, `$LogFile`, restore points. Once, elevated:

    mountvol /N
    'san policy=offlineall' | Out-File "$env:TEMP\san.txt" -Encoding ascii; diskpart /s "$env:TEMP\san.txt"

Drives should then arrive `Offline=True ReadOnly=True`. Verify with
`Get-RescueTarget` after plugging something in; do not assume.

Note that Windows classes a USB flash stick as *removable* and a drive in an
enclosure as *fixed*, and the policy treats them differently. Confirm the
behaviour with an enclosure before trusting it on a customer's drive.

A hardware write blocker remains the correct tool for irreplaceable data.
Nothing here substitutes for one.

## Status

The module loads, and every path that can be tested without a running guest has
been: inventory, planning, refusals, the no-write guarantee of `-WhatIf`, report
generation and redaction.

**Nothing involving a running guest has been executed yet.** Unverified:
`whpx` acceleration, the `-kernel`/`-initrd` boot, autorun firing via
`ar_source`, sshd on the forwarded port, overlay formatting and persistence,
the triage probes, and ddrescue launch and resume.
