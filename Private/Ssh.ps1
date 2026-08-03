# SSH plumbing. The guest is a live ISO on loopback, so host keys change on
# every boot and a persistent known_hosts would fail every single time. The
# throwaway options below are deliberate, not sloppy: the connection is to
# 127.0.0.1 through a port QEMU forwards into one process we started.

function Get-RescueSshBaseArgs {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$State)

    return @(
        '-i', $State.KeyPath,
        '-p', [string]$State.SshPort,
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=NUL',
        '-o', 'LogLevel=ERROR',
        '-o', 'ConnectTimeout=5',
        '-o', 'BatchMode=yes'
    )
}

function Initialize-RescueKey {
    <#
        Generate the rescue keypair if absent and return the public key text.
        The private key lives in ~\.ssh, deliberately outside the repo, so it
        cannot be committed by accident.
    #>
    [CmdletBinding()]
    param()

    $p = Get-RescuePaths
    $sshDir = Split-Path -Parent $p.KeyPath
    if (-not (Test-Path $sshDir)) {
        New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
    }

    if (-not (Test-Path $p.KeyPath)) {
        # Empty passphrase: this authenticates only to a loopback-bound
        # throwaway guest, and the calling shell is non-interactive.
        & ssh-keygen -t ed25519 -f $p.KeyPath -N '""' -C 'rescuevm' -q
        if (-not (Test-Path $p.KeyPath)) {
            throw "ssh-keygen did not produce $($p.KeyPath)"
        }
    }

    return (Get-Content "$($p.KeyPath).pub" -Raw).Trim()
}

function Invoke-RescueSshRaw {
    <#
        Run one command in the guest and return stdout, stderr and exit code.
        Never throws on a non-zero guest exit - that is data, not an error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$Command,
        [int]$TimeoutSec = 0
    )

    $args = Get-RescueSshBaseArgs $State
    $args += @("root@127.0.0.1", $Command)

    $outFile = [IO.Path]::GetTempFileName()
    $errFile = [IO.Path]::GetTempFileName()

    try {
        $proc = Start-Process -FilePath 'ssh' -ArgumentList $args -NoNewWindow -PassThru `
                    -RedirectStandardOutput $outFile -RedirectStandardError $errFile

        if ($TimeoutSec -gt 0) {
            if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
                try { $proc.Kill() } catch { }
                return [pscustomobject]@{
                    Command  = $Command
                    ExitCode = -1
                    Stdout   = ''
                    Stderr   = "Timed out after ${TimeoutSec}s"
                    TimedOut = $true
                }
            }
        } else {
            $proc.WaitForExit()
        }

        $stdout = ''
        $stderr = ''
        if (Test-Path $outFile) { $stdout = (Get-Content $outFile -Raw) }
        if (Test-Path $errFile) { $stderr = (Get-Content $errFile -Raw) }
        if ($null -eq $stdout) { $stdout = '' }
        if ($null -eq $stderr) { $stderr = '' }

        return [pscustomobject]@{
            Command  = $Command
            ExitCode = $proc.ExitCode
            Stdout   = $stdout.TrimEnd()
            Stderr   = $stderr.TrimEnd()
            TimedOut = $false
        }
    } finally {
        Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Wait-RescueSsh {
    <#
        Poll until the guest answers on the forwarded port. Gives up rather than
        hanging, and reports how long it waited so a slow tcg boot is
        distinguishable from a broken one.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [int]$TimeoutSec = 180,
        [int]$IntervalSec = 5
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $attempt = 0

    while ((Get-Date) -lt $deadline) {
        $attempt++

        if (-not (Test-RescueVmAlive $State)) {
            return [pscustomobject]@{
                Ready    = $false
                Attempts = $attempt
                Message  = 'QEMU process is not running. The guest died or never started; check the serial log.'
            }
        }

        $probe = Invoke-RescueSshRaw -State $State -Command 'echo RESCUEVM_OK' -TimeoutSec 10
        if ($probe.ExitCode -eq 0 -and $probe.Stdout -match 'RESCUEVM_OK') {
            return [pscustomobject]@{
                Ready    = $true
                Attempts = $attempt
                Message  = "Guest reachable after $attempt attempt(s)."
            }
        }

        Start-Sleep -Seconds $IntervalSec
    }

    return [pscustomobject]@{
        Ready    = $false
        Attempts = $attempt
        Message  = "Guest did not answer SSH within ${TimeoutSec}s. If acceleration fell back to tcg this may just be slow; check the serial log."
    }
}
