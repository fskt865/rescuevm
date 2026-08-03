# The vvfat payload handed to the guest read-only: the public key plus an
# autorun script SystemRescue executes unattended.
#
# ar_suffixes in the ISO's 100_defaults.yaml confirms autorun looks for files
# named autorun0..autorunF, so the script must be called exactly "autorun0".

function Write-RescuePayload {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$PublicKey)

    Initialize-RescueDirs
    $p = Get-RescuePaths

    Set-Content -Path (Join-Path $p.Payload 'authorized_keys') `
                -Value $PublicKey -Encoding ascii

    # POSIX sh, LF endings. Runs as root inside the guest.
    $script = @'
#!/bin/sh
# autorun0 - written by RescueVM. Runs unattended at guest boot.
# Purpose: make the guest reachable over the forwarded loopback SSH port.

KEYDEV=/dev/disk/by-id/virtio-key
COWDEV=/dev/disk/by-id/virtio-cow
MNT=/run/rescuevm
LOG=/var/log/rescuevm-autorun.log

exec >>"$LOG" 2>&1
set -x

mkdir -p "$MNT"

# autorun may have mounted its source already; accept it wherever it landed
# rather than assuming, then fall back to mounting the payload ourselves.
AK=""
for c in "$(dirname "$0")/authorized_keys" \
         /run/archiso/ar_source/authorized_keys \
         "$MNT/authorized_keys"; do
    if [ -f "$c" ]; then AK="$c"; break; fi
done

if [ -z "$AK" ]; then
    mount "${KEYDEV}-part1" "$MNT" 2>/dev/null || mount "$KEYDEV" "$MNT" 2>/dev/null
    if [ -f "$MNT/authorized_keys" ]; then AK="$MNT/authorized_keys"; fi
fi

if [ -z "$AK" ]; then
    echo "RESCUEVM_FAIL no authorized_keys found"
    exit 1
fi

mkdir -p /root/.ssh
cp "$AK" /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

# SystemRescue refuses SSH login while the root account is locked, even with a
# valid key. Password auth is then explicitly disabled below, so this password
# never grants access over the network.
echo 'root:rescue' | chpasswd
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

# nofirewall is on the kernel cmdline, but flush anyway in case a rule survived.
iptables -F 2>/dev/null

systemctl restart sshd

# Bootstrap the persistence overlay. Format ONLY when the device carries no
# filesystem at all, and only ever the device named virtio-cow. The customer
# disk is virtio-source and is never touched here.
if [ -b "$COWDEV" ]; then
    if [ -z "$(blkid -o value -s TYPE "$COWDEV" 2>/dev/null)" ]; then
        mkfs.ext4 -F -L RESCUECOW "$COWDEV" && echo "RESCUEVM_COW_FORMATTED"
    fi
fi

echo "RESCUEVM_READY"
ip -4 -br a
'@

    $path = Join-Path $p.Payload 'autorun0'
    [IO.File]::WriteAllText($path, ($script -replace "`r`n", "`n"))
}
