# RescueVM - drive a SystemRescue guest from Windows without leaving the session.

$script:RescueModuleRoot = $PSScriptRoot

# Private first: public cmdlets depend on these at load time.
foreach ($dir in @('Private', 'Public')) {
    $path = Join-Path $PSScriptRoot $dir
    if (-not (Test-Path $path)) { continue }
    foreach ($file in (Get-ChildItem -Path $path -Filter '*.ps1' | Sort-Object Name)) {
        . $file.FullName
    }
}

Export-ModuleMember -Function @(
    'Get-RescueTarget',
    'Start-RescueVM',
    'Stop-RescueVM',
    'Get-RescueSession',
    'Invoke-RescueCommand',
    'Copy-FromRescue',
    'Invoke-RescueTriage',
    'Invoke-RescueImage',
    'New-RescueReport'
)
