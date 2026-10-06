param([Parameter(Mandatory = $true)][string]$Installer)

$ErrorActionPreference = 'Stop'
$engine = New-Object -ComObject WindowsInstaller.Installer
$database = $engine.OpenDatabase((Resolve-Path $Installer).Path, 1)

function Invoke-MsiQuery([string]$Sql) {
    $view = $database.OpenView($Sql)
    try { $view.Execute() } finally { $view.Close() }
}

# No shortcut selection is exposed by this installer. Make their components
# unconditional, including during repair and upgrades from an earlier install.
$view = $database.OpenView('SELECT `Component_`, `Name` FROM `Shortcut`')
$view.Execute()
$count = 0
while ($row = $view.Fetch()) {
    if ($row.StringData(2) -ne 'RIDEN') { throw 'Unexpected shortcut in RIDEN installer' }
    $component = $row.StringData(1).Replace("'", "''")
    Invoke-MsiQuery "UPDATE ``Component`` SET ``Condition`` = '' WHERE ``Component`` = '$component'"
    $count++
}
$view.Close()
if ($count -ne 2) { throw "Expected desktop and Start menu shortcuts, found $count" }
$database.Commit()
Write-Output 'MSI desktop and Start menu shortcuts are unconditional.'
