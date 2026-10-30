function Release-KeeperComObject($Value) {
    if ($null -ne $Value -and [Runtime.InteropServices.Marshal]::IsComObject($Value)) {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($Value)
    }
}

# CLI and GUI use separate shortcuts; only shortcuts owned by this installation are changed.
function Get-KeeperStartupFolder { [Environment]::GetFolderPath('Startup') }

function Get-KeeperStartupNames([string]$Kind) {
    if ($Kind -eq 'Cli') { return @('SpeakerKeeper.lnk') }
    return @('SpeakerKeeper GUI.lnk', 'NZXT Relay Keeper.lnk')
}

function Test-KeeperShortcut([string]$Path, [string]$Root, [string]$Kind) {
    if (-not [System.IO.File]::Exists($Path)) { return $false }
    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($Path)
        try {
            $file = if ($Kind -eq 'Gui') { 'Launch-GUI.vbs' } else { 'SpeakerKeeper.ps1' }
            $expected = '"' + (Join-Path $Root $file) + '"'
            $target = [System.IO.Path]::GetFileName($shortcut.TargetPath)
            return ($shortcut.Arguments.IndexOf($expected, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
                (($Kind -eq 'Gui' -and $target -eq 'wscript.exe') -or
                 ($Kind -eq 'Cli' -and $target -eq 'powershell.exe' -and $shortcut.Arguments -notmatch '-StopFile')))
        } finally { Release-KeeperComObject $shortcut }
    } finally { Release-KeeperComObject $shell }
}

function Set-KeeperStartup([string]$Root, [ValidateSet('Cli','Gui')][string]$Kind,
    [ValidateSet('add','remove')][string]$Mode, [switch]$Launch) {
    $folder = Get-KeeperStartupFolder
    $names = @(Get-KeeperStartupNames $Kind)
    if ($Mode -eq 'remove') {
        foreach ($name in $names) {
            $path = Join-Path $folder $name
            if (Test-KeeperShortcut $path $Root $Kind) { Remove-Item -LiteralPath $path -ErrorAction Stop }
        }
        return
    }
    $other = if ($Kind -eq 'Cli') { 'Gui' } else { 'Cli' }
    foreach ($name in @(Get-KeeperStartupNames $other)) {
        if (Test-Path -LiteralPath (Join-Path $folder $name)) {
            throw "Disable the $other startup shortcut first ($name). Existing shortcuts have been preserved."
        }
    }
    $path = Join-Path $folder $names[0]
    foreach ($name in $names) {
        $candidate = Join-Path $folder $name
        if (Test-Path -LiteralPath $candidate) {
            if (-not (Test-KeeperShortcut $candidate $Root $Kind)) {
                throw "Startup shortcut $name belongs to another installation. It has not been changed."
            }
            # Reuse an owned legacy GUI shortcut rather than deleting it during migration.
            $path = $candidate
        }
    }
    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($path)
        try {
            if ($Kind -eq 'Gui') {
                $launcher = Join-Path $Root 'Launch-GUI.vbs'
                if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw 'Launch-GUI.vbs is missing.' }
                $target = Join-Path $env:WINDIR 'System32\wscript.exe'
                $arguments = '"{0}" --minimized' -f $launcher
            } else {
                $target = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $Root 'SpeakerKeeper.ps1')
            }
            $shortcut.TargetPath = $target
            $shortcut.Arguments = $arguments
            $shortcut.WorkingDirectory = $Root
            $shortcut.WindowStyle = 7
            $shortcut.Save()
        } finally { Release-KeeperComObject $shortcut }
    } finally { Release-KeeperComObject $shell }
    if ($Launch) { Start-Process -FilePath $target -ArgumentList $arguments -WindowStyle Hidden }
}

function Stop-KeeperCliWorkers([string]$Root) {
    # Preserve CLI removal's stop behavior, scoped to this installation's CLI worker/children.
    # GUI workers carry -StopFile and must be stopped through their own tray menu.
    $main = '"' + (Join-Path $Root 'SpeakerKeeper.ps1') + '"'
    $workers = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($main, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and $_.CommandLine -notmatch '-StopFile' })
    foreach ($worker in $workers) {
        Get-CimInstance Win32_Process -Filter ('ParentProcessId=' + $worker.ProcessId) |
            Where-Object { $_.Name -like 'SoundKeeper*.exe' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id $worker.ProcessId -Force -ErrorAction SilentlyContinue
    }
}
