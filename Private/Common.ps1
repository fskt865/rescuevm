# Shared paths, elevation checks, structured logging and redaction.
# Dot-sourced by RescueVM.psm1. Nothing here is exported.

function Get-RescuePaths {
    [CmdletBinding()]
    param()

    $root = $script:RescueModuleRoot
    return [pscustomobject]@{
        Root      = $root
        Payload   = Join-Path $root 'payload'
        Logs      = Join-Path $root 'logs'
        Sessions  = Join-Path $root 'sessions'
        Boot      = Join-Path $root 'boot'
        Overlay   = Join-Path $root 'overlay'
        QemuDir   = 'C:\Program Files\qemu'
        QemuExe   = 'C:\Program Files\qemu\qemu-system-x86_64.exe'
        QemuImg   = 'C:\Program Files\qemu\qemu-img.exe'
        KeyPath   = Join-Path $env:USERPROFILE '.ssh\rescuevm_ed25519'
    }
}

function Initialize-RescueDirs {
    [CmdletBinding()]
    param()
    $p = Get-RescuePaths
    foreach ($d in @($p.Payload, $p.Logs, $p.Sessions, $p.Boot, $p.Overlay)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }
}

function Test-RescueAdmin {
    [CmdletBinding()]
    param()
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-RescueAdmin {
    [CmdletBinding()]
    param([string]$Because = 'this operation')
    if (-not (Test-RescueAdmin)) {
        throw "Elevation required for ${Because}: raw physical-disk access and Set-Disk both need Administrator. Re-run from an elevated PowerShell."
    }
}

function Test-RescueQemu {
    [CmdletBinding()]
    param()
    $p = Get-RescuePaths
    if (-not (Test-Path $p.QemuExe)) { throw "QEMU not found at $($p.QemuExe)" }
    if (-not (Test-Path $p.QemuImg)) { throw "qemu-img not found at $($p.QemuImg)" }
}

# -------------------------------------------------------------- redaction ---
#
# The primary defence is not collecting identifying data at all - the triage
# workflow gathers by class and never lists files. This is the second line, for
# text that arrives from a tool whose output we do not fully control.

function Protect-RescueText {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)][string]$Text)

    process {
        if ([string]::IsNullOrEmpty($Text)) { return $Text }
        $t = $Text

        # Drive and enclosure identifiers.
        $t = $t -replace '(?im)^(\s*(?:Serial Number|Serial|WWN|LU WWN Device Id)\s*[:=]\s*).+$', '$1[redacted]'
        $t = $t -replace '(?i)\bserial\s*=\s*[A-Z0-9\-]{6,}', 'serial=[redacted]'

        # Filesystem labels are frequently a person's name.
        $t = $t -replace '(?i)\bLABEL="[^"]*"', 'LABEL="[redacted]"'
        $t = $t -replace '(?i)\bPARTLABEL="[^"]*"', 'PARTLABEL="[redacted]"'
        $t = $t -replace '(?im)^(\s*Volume label\s*[:=]\s*).+$', '$1[redacted]'

        # Windows profile paths carry the account name.
        $t = $t -replace '(?i)([A-Z]:\\Users\\)[^\\\r\n]+', '$1[user]'
        $t = $t -replace '(?i)(/home/)[^/\r\n]+', '$1[user]'

        return $t
    }
}

# ---------------------------------------------------------------- logging ---
#
# Every step appends a JSONL record, including the ones that fail. The report
# generator reads this back as the diagnostic ladder actually followed, which is
# the part CLAUDE.md asks for and the part nobody reconstructs correctly after
# the fact.

function Write-RescueLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][string]$Action,
        [ValidateSet('start', 'ok', 'fail', 'skip', 'note')]
        [string]$Result = 'note',
        [string]$Detail = '',
        [hashtable]$Data
    )

    $session = Get-RescueSessionState -Quiet
    if ($null -eq $session) { return }

    $record = [ordered]@{
        ts     = (Get-Date).ToString('o')
        phase  = $Phase
        action = $Action
        result = $Result
        detail = (Protect-RescueText $Detail)
    }
    if ($Data) { $record.data = $Data }

    $line = ($record | ConvertTo-Json -Compress -Depth 6)
    Add-Content -Path $session.LogPath -Value $line -Encoding ascii
}
