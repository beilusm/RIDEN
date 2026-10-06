param([Parameter(Mandatory = $true)][string]$Installer)

$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'Installation verification must run on a disposable CI runner' }
$Installer = (Resolve-Path $Installer).Path
$logs = Join-Path $env:GITHUB_WORKSPACE 'composeApp/build/reports/windows-install'
New-Item -ItemType Directory -Path $logs -Force | Out-Null
$shell = New-Object -ComObject WScript.Shell
$desktopLink = Join-Path $shell.SpecialFolders.Item('Desktop') 'RIDEN.lnk'
$menuLink = Join-Path $shell.SpecialFolders.Item('Programs') 'RIDEN/RIDEN.lnk'
$expectedExe = Join-Path $env:LOCALAPPDATA 'RIDEN/RIDEN.exe'

function Invoke-Installer([string]$Operation, [string]$Package, [string]$Name) {
    $log = Join-Path $logs "$Name.log"
    $process = Start-Process msiexec.exe -ArgumentList "$Operation `"$Package`" /qn /norestart /L*v `"$log`"" -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) { throw "Installer $Name failed: $($process.ExitCode); see $log" }
}

function Assert-Shortcuts {
    if (-not (Test-Path $expectedExe)) { throw 'Missing installed RIDEN.exe' }
    foreach ($path in @($desktopLink, $menuLink)) {
        if (-not (Test-Path $path)) { throw "Missing shortcut: $path" }
        $shortcut = $shell.CreateShortcut($path)
        if ($shortcut.TargetPath -ne $expectedExe) { throw "Wrong shortcut target: $($shortcut.TargetPath)" }
        Write-Output "Verified $path -> $($shortcut.TargetPath)"
    }
    $config = Get-Content (Join-Path $env:LOCALAPPDATA 'RIDEN/app/RIDEN.cfg') -Raw
    if ($config -notmatch 'java-options=-Dskiko.renderApi=SOFTWARE') { throw 'Packaged launcher does not select software rendering' }
    if ($config -notmatch 'java-options=-Dsun.java2d.d3d=false') { throw 'Packaged launcher does not disable Java2D Direct3D' }
}

Invoke-Installer '/i' $Installer 'fresh-install'
Assert-Shortcuts
Remove-Item $desktopLink, $menuLink
Invoke-Installer '/fas' $Installer 'repair'
Assert-Shortcuts
Invoke-Installer '/x' $Installer 'uninstall'
foreach ($path in @($desktopLink, $menuLink)) {
    if (Test-Path $path) { throw "Shortcut remained after uninstall: $path" }
}

$previous = Join-Path $env:RUNNER_TEMP 'RIDEN-2.0.0.msi'
Invoke-WebRequest 'https://github.com/beilusm/RIDEN/releases/download/v2.0.0/RIDEN-2.0.0-windows-x64.msi' -OutFile $previous
Invoke-Installer '/i' $previous 'previous-install'
# Simulate the reported installation where the application exists without links.
Remove-Item $desktopLink, $menuLink -ErrorAction SilentlyContinue
Invoke-Installer '/i' $Installer 'upgrade'
Assert-Shortcuts
Invoke-Installer '/x' $Installer 'upgrade-uninstall'
