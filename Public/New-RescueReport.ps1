function New-RescueReport {
    <#
    .SYNOPSIS
        Turn a session log into a repair-report draft in ~\Work\repair-reports.
    .DESCRIPTION
        Emits the diagnostic ladder exactly as it happened - in order, with the
        failures left in - because reconstructing that afterwards is where
        reports go wrong. Dead ends teach more than the path that worked, so
        they are never tidied out.

        This produces the factual spine, not the finished report. The judgement
        sections are left as explicit prompts: which layer the fault was at,
        what the evidence supported versus what was inference, and where the
        Level 1 line fell. Fill those in, then convert to PDF with the pdf
        skill.

        Output is named by failure class, never by machine, and every field is
        passed through redaction on the way out. Reports are gitignored from the
        parent and never pushed - see ~\Work\CLAUDE.md.
    .EXAMPLE
        New-RescueReport -FailureClass usb-bridge-enumeration-loss
    #>
    [CmdletBinding()]
    param(
        # Kebab-case name of the failure CLASS. Never a customer or machine.
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[a-z0-9]+(-[a-z0-9]+)*$')]
        [string]$FailureClass,

        # Session id to report on. Defaults to the current or most recent.
        [string]$SessionId,

        [string]$OutputDir = (Join-Path $env:USERPROFILE 'Work\repair-reports')
    )

    $paths = Get-RescuePaths

    # Resolve the session log: current session first, then the newest archived.
    $logPath = $null
    if ($SessionId) {
        $logPath = Join-Path $paths.Logs "session-$SessionId.jsonl"
    } else {
        $cur = Get-RescueSessionState -Quiet
        if ($cur) {
            $logPath = $cur.LogPath
            $SessionId = $cur.Id
        } else {
            $newest = Get-ChildItem $paths.Logs -Filter 'session-*.jsonl' -ErrorAction SilentlyContinue |
                      Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($newest) {
                $logPath = $newest.FullName
                $SessionId = $newest.BaseName -replace '^session-', ''
            }
        }
    }

    if (-not $logPath -or -not (Test-Path $logPath)) {
        throw 'No session log found. Nothing to report on.'
    }

    $entries = @()
    foreach ($line in (Get-Content $logPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $entries += ($line | ConvertFrom-Json) } catch { }
    }
    if ($entries.Count -eq 0) { throw "Session log $logPath contains no readable entries." }

    if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }
    $date = (Get-Date).ToString('yyyy-MM-dd')
    $mdPath = Join-Path $OutputDir "$date-$FailureClass.md"

    $sb = New-Object Text.StringBuilder
    $null = $sb.AppendLine("# $FailureClass")
    $null = $sb.AppendLine()
    $null = $sb.AppendLine("A study of a failure class, not of a machine. Session $SessionId.")
    $null = $sb.AppendLine()

    $null = $sb.AppendLine('## Presenting symptoms')
    $null = $sb.AppendLine()
    $null = $sb.AppendLine('> TO COMPLETE: what was observed on arrival, and specifically what those')
    $null = $sb.AppendLine('> symptoms did and did not prove. Resist writing the conclusion here.')
    $null = $sb.AppendLine()

    $null = $sb.AppendLine('## Diagnostic ladder, in the order actually followed')
    $null = $sb.AppendLine()
    $null = $sb.AppendLine('Recorded live, including the probes that failed and the guesses that were')
    $null = $sb.AppendLine('wrong. Those are kept deliberately.')
    $null = $sb.AppendLine()
    $null = $sb.AppendLine('| # | Phase | Layer | Step | Result |')
    $null = $sb.AppendLine('|---|---|---|---|---|')

    $i = 0
    foreach ($e in $entries) {
        $i++
        $layer = ''
        if ($e.PSObject.Properties.Name -contains 'data' -and $e.data -and
            $e.data.PSObject.Properties.Name -contains 'layer') { $layer = $e.data.layer }
        $action = (Protect-RescueText ([string]$e.action)) -replace '\|', '\|'
        if ($action.Length -gt 90) { $action = $action.Substring(0, 87) + '...' }
        $null = $sb.AppendLine("| $i | $($e.phase) | $layer | ``$action`` | $($e.result) |")
    }
    $null = $sb.AppendLine()

    $failures = @($entries | Where-Object { $_.result -eq 'fail' })
    $null = $sb.AppendLine('## What did not work')
    $null = $sb.AppendLine()
    if ($failures.Count -eq 0) {
        $null = $sb.AppendLine('No step in this session failed. That is unusual; consider whether the')
        $null = $sb.AppendLine('ladder was started high enough to have been able to fail.')
    } else {
        foreach ($f in $failures) {
            $null = $sb.AppendLine("- **$(Protect-RescueText ([string]$f.action))**")
            if ($f.detail) {
                $d = (Protect-RescueText ([string]$f.detail)).Trim()
                if ($d.Length -gt 400) { $d = $d.Substring(0, 400) + '...' }
                foreach ($dl in ($d -split "`n")) { $null = $sb.AppendLine("  > $dl") }
            }
        }
    }
    $null = $sb.AppendLine()

    $null = $sb.AppendLine('## Detailed observations')
    $null = $sb.AppendLine()
    foreach ($e in $entries) {
        if (-not $e.detail) { continue }
        if ($e.phase -notin @('triage', 'image')) { continue }
        $null = $sb.AppendLine("### $(Protect-RescueText ([string]$e.action)) [$($e.result)]")
        $null = $sb.AppendLine()
        if ($e.data -and $e.data.PSObject.Properties.Name -contains 'means') {
            $null = $sb.AppendLine("*What this establishes:* $($e.data.means)")
            $null = $sb.AppendLine()
        }
        $null = $sb.AppendLine('```')
        $null = $sb.AppendLine((Protect-RescueText ([string]$e.detail)).TrimEnd())
        $null = $sb.AppendLine('```')
        $null = $sb.AppendLine()
    }

    foreach ($section in @(
        @('Which layer the fault was at', 'TO COMPLETE: name the layer - host config, bridge/adapter, controller, media, filesystem, boot config - and quote the single observation above that established it. If two layers remain possible, say so rather than picking.'),
        @('Evidence versus inference', 'TO COMPLETE: separate what the output actually proved from what was reasonably concluded. Presence of a file is not proof it executes.'),
        @('Where the Level 1 line was', 'TO COMPLETE: if the job stopped, say what would have been the next step and why it was above the line. If it did not stop, say why it stayed below.')
    )) {
        $null = $sb.AppendLine("## $($section[0])")
        $null = $sb.AppendLine()
        $null = $sb.AppendLine("> $($section[1])")
        $null = $sb.AppendLine()
    }

    $text = $sb.ToString()
    [IO.File]::WriteAllText($mdPath, $text)

    # ------------------------------------------------------ redaction audit --
    #
    # Redaction already ran per field. This is a second look at the assembled
    # document, because the rule it enforces has no acceptable failure rate.

    $suspects = @()
    if ($text -match '(?im)^\s*(serial|wwn)\s*[:=]\s*(?!\[redacted\])\S+') { $suspects += 'a serial-like field' }
    if ($text -match '(?i)LABEL="(?!\[redacted\])[^"]+"') { $suspects += 'a filesystem label' }
    if ($text -match '(?i)[A-Z]:\\Users\\(?!\[user\])[^\\\s]+') { $suspects += 'a Windows profile path' }
    if ($text -match '\b\d{3}-\d{2}-\d{4}\b') { $suspects += 'a number shaped like an SSN' }
    if ($text -match '(?i)\b(ticket|work[ -]?order|wo)\s*#?\s*\d{4,}') { $suspects += 'a ticket or work-order number' }

    Write-Host ''
    Write-Host "Draft written: $mdPath" -ForegroundColor Green
    Write-Host "Steps recorded: $($entries.Count)  (failures kept: $($failures.Count))"

    if ($suspects.Count -gt 0) {
        Write-Warning "Redaction audit flagged $($suspects.Count) item(s): $($suspects -join ', '). Read the draft before converting it."
    } else {
        Write-Host 'Redaction audit: nothing flagged.' -ForegroundColor Green
    }

    Write-Host ''
    Write-Host 'Next: fill in the TO COMPLETE sections, then convert with the pdf skill.' -ForegroundColor Yellow
    Write-Host 'Reports are gitignored from the parent and are not pushed anywhere.'

    return (Get-Item $mdPath)
}
