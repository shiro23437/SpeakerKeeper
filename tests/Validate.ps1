# Isolated checks; no WPF, audio hardware, real startup shortcuts, or child monitoring.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Import-Functions([string]$Path, [string[]]$Names) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    Assert ($errors.Count -eq 0) "PowerShell syntax errors: $Path"
    foreach ($name in $Names) {
        $node = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }.GetNewClosure(), $true)
        Assert ($null -ne $node) "Missing function: $name"
        # Return definitions to dot-source in the caller's scope.
        $node.Extent.Text
    }
}
Get-ChildItem -LiteralPath $root -Recurse -Filter *.ps1 | ForEach-Object {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
    Assert ($errors.Count -eq 0) "Syntax errors: $($_.Name)"
}
foreach ($file in @('SpeakerKeeper.ps1','SpeakerKeeper-GUI.ps1')) {
    $source = [System.IO.File]::ReadAllText((Join-Path $root $file))
    foreach ($block in [regex]::Matches($source, "(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@")) {
        Add-Type -TypeDefinition $block.Groups[1].Value
    }
}
. (Join-Path $root 'tools/Settings.ps1')
. ([scriptblock]::Create((Import-Functions (Join-Path $root 'SpeakerKeeper-GUI.ps1') @('Write-KeeperSettings','Read-KeeperSettings')) -join "`n"))
. ([scriptblock]::Create((Import-Functions (Join-Path $root 'SpeakerKeeper.ps1') @('Get-Inv','Set-KeeperFailure','Start-Keeper')) -join "`n"))
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('speakerkeeper-check-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $script:settingsFile = Join-Path $temp 'settings.txt'
    $s = Read-KeeperConfiguration $script:settingsFile
    Assert ($s.Frequency -eq 300 -and $s.Amplitude -eq 0.1 -and $s.LingerSeconds -eq 30) 'Incorrect first-run defaults'
    Assert (-not (Test-Path $script:settingsFile)) 'Reading configuration created a personal file'
    Write-KeeperSettings @{ Frequency='750'; Amplitude='0.2'; DeviceName='Speakers [USB]'; AppName='player' }
    $s = Read-KeeperConfiguration $script:settingsFile
    Assert ($s.Frequency -eq 750 -and $s.Amplitude -eq 0.2 -and $s.AppName -eq 'player') 'First save/reload failed'
    Add-Content -LiteralPath $script:settingsFile -Value "# Keep my comment`nCustomKey=untouched`nSoundKeeper=custom.exe"
    Write-KeeperSettings @{ Frequency='900'; DeviceName='' }
    $s = Read-KeeperConfiguration $script:settingsFile
    Assert ($s.Frequency -eq 900 -and $s.SoundKeeper -eq 'custom.exe' -and $s.DeviceName -eq '') 'Replacement save did not preserve settings'
    $text = [System.IO.File]::ReadAllText($script:settingsFile)
    Assert ($text.Contains('# Keep my comment') -and $text.Contains('CustomKey=untouched')) 'Save removed unrelated configuration'
    [System.IO.File]::WriteAllText($script:settingsFile, "Frequency=NaN`nAmplitude=Infinity`nLingerSeconds=-1`nThreshold=2")
    $s = Read-KeeperConfiguration $script:settingsFile -WarningAction SilentlyContinue
    Assert ($s.Frequency -eq 300 -and $s.Amplitude -eq 0.1 -and $s.LingerSeconds -eq 30 -and $s.Threshold -eq 0.001) 'Invalid values were accepted'
    $previousCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
        $s = Read-KeeperSettings
        Assert ($s.Amplitude -eq '0.1') 'GUI values depend on locale'
    } finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $previousCulture }

    # Missing dependency, throttled attempts/logs, launch failure, and recovery without sleeping.
    $script:events = New-Object 'System.Collections.Generic.List[string]'
    function Write-Event([string]$Message) { $script:events.Add($Message) }
    $script:launches = 0
    $script:failLaunch = $true
    function Start-Process { param($FilePath,$ArgumentList,$WindowStyle,[switch]$PassThru)
        $script:launches++
        if ($script:failLaunch) { throw 'Access denied (simulated)' }
        [pscustomobject]@{ Id=123; HasExited=$false }
    }
    $s = @{ SoundKeeperPath=(Join-Path $temp 'missing.exe'); Frequency=300; Amplitude=0.1 }
    $script:nextKeeperAttempt = [datetime]::MinValue; $script:keeperFailure = ''
    1..100 | ForEach-Object { $null = Start-Keeper $s }
    Assert ($script:events.Count -eq 1 -and $script:launches -eq 0) 'Missing dependency caused repeated logging/launches'
    $script:nextKeeperAttempt = [datetime]::MinValue
    $null = Start-Keeper $s
    Assert ($script:events.Count -eq 1) 'Identical missing-dependency error was repeated'
    [System.IO.File]::WriteAllText($s.SoundKeeperPath,'mock')
    $script:nextKeeperAttempt = [datetime]::MinValue
    1..100 | ForEach-Object { $null = Start-Keeper $s }
    Assert ($script:launches -eq 1 -and $script:events.Count -eq 2) 'Launch failures were not throttled'
    $script:failLaunch = $false; $script:nextKeeperAttempt = [datetime]::MinValue
    $proc = Start-Keeper $s
    Assert ($proc.Id -eq 123 -and $script:keeperFailure -eq '') 'Dependency recovery failed'

    # Exercise actual log rotation using temporary files, without launching the engine.
    . ([scriptblock]::Create((Import-Functions (Join-Path $root 'SpeakerKeeper.ps1') @('Write-Event')) -join "`n"))
    $LogFile = Join-Path $temp 'engine.log'
    [System.IO.File]::WriteAllText($LogFile, ('x' * 1MB))
    Write-Event 'rotation check'
    Assert ((Test-Path ($LogFile + '.old')) -and (Get-Item $LogFile).Length -lt 1KB) 'Log did not rotate'
    [System.IO.File]::WriteAllText($LogFile, ('y' * 1MB))
    Write-Event 'second rotation'
    Assert ((Get-Item ($LogFile + '.old')).Length -eq 1MB) 'Rotated log was not replaced'

    # Exercise shortcut policy with a fake shell. Nothing touches the actual Startup folder.
    . (Join-Path $root 'tools/Startup.Common.ps1')
    function Get-KeeperStartupFolder { $temp }
    $script:shortcuts = @{}
    function New-Object { param([string]$ComObject)
        Assert ($ComObject -eq 'WScript.Shell') 'Unexpected COM activation in shortcut tests'
        $shell = [pscustomobject]@{}
        $shell | Add-Member ScriptMethod CreateShortcut {
            param($path)
            if (-not $script:shortcuts.ContainsKey($path)) {
                $item = [pscustomobject]@{ Path=$path; TargetPath=''; Arguments=''; WorkingDirectory=''; WindowStyle=0 }
                $item | Add-Member ScriptMethod Save { [System.IO.File]::WriteAllText($this.Path,'mock shortcut') }
                $script:shortcuts[$path]=$item
            }
            return $script:shortcuts[$path]
        }
        return $shell
    }
    $previousWindir = $env:WINDIR
    $env:WINDIR = $temp
    try {
        Set-KeeperStartup -Root $root -Kind Cli -Mode add
        $cli = Join-Path $temp 'SpeakerKeeper.lnk'
        Assert (Test-KeeperShortcut $cli $root 'Cli') 'CLI startup did not target the CLI engine'
        $blocked = $false
        try { Set-KeeperStartup -Root $root -Kind Gui -Mode add } catch { $blocked=$true }
        Assert ($blocked -and (Test-Path $cli)) 'GUI startup replaced the CLI shortcut'
        Set-KeeperStartup -Root $root -Kind Gui -Mode remove
        Assert (Test-Path $cli) 'GUI removal deleted CLI startup'
        Set-KeeperStartup -Root $root -Kind Cli -Mode remove
        Assert (-not (Test-Path $cli)) 'CLI shortcut was not removed'
        Set-KeeperStartup -Root $root -Kind Gui -Mode add
        $gui = Join-Path $temp 'SpeakerKeeper GUI.lnk'
        Assert (Test-KeeperShortcut $gui $root 'Gui') 'GUI startup did not target the VBS launcher'
        Set-KeeperStartup -Root $root -Kind Cli -Mode remove
        Assert (Test-Path $gui) 'CLI removal deleted GUI startup'
        Set-KeeperStartup -Root $root -Kind Gui -Mode remove
        Assert (-not (Test-Path $gui)) 'GUI shortcut was not removed'
        # Never overwrite/remove a same-name shortcut owned by another installation.
        $script:shortcuts[$cli].Arguments='-File "other.ps1"'
        [System.IO.File]::WriteAllText($cli,'foreign')
        $blocked=$false
        try { Set-KeeperStartup -Root $root -Kind Cli -Mode add } catch { $blocked=$true }
        Assert $blocked 'Foreign shortcut was overwritten'
        Set-KeeperStartup -Root $root -Kind Cli -Mode remove
        Assert ([System.IO.File]::ReadAllText($cli) -eq 'foreign') 'Foreign shortcut was removed'
    } finally { $env:WINDIR=$previousWindir }
    # CLI removal stops only its engine and SoundKeeper children, never the GUI or other installs.
    $script:stopped = [System.Collections.Generic.List[int]]::new()
    function Get-CimInstance { param($ClassName, $Filter)
        if ($Filter -eq "Name='powershell.exe'") {
            [pscustomobject]@{ ProcessId=10; CommandLine=('powershell -File "' + (Join-Path $root 'SpeakerKeeper.ps1') + '"') }
            [pscustomobject]@{ ProcessId=20; CommandLine=('powershell -File "' + (Join-Path $root 'SpeakerKeeper.ps1') + '" -StopFile "gui.signal"') }
            [pscustomobject]@{ ProcessId=30; CommandLine='powershell -File "another-install/SpeakerKeeper.ps1"' }
        } elseif ($Filter -eq 'ParentProcessId=10') {
            [pscustomobject]@{ ProcessId=100; Name='SoundKeeper64.exe' }
            [pscustomobject]@{ ProcessId=101; Name='unrelated.exe' }
        } else { throw "Unexpected worker query: $Filter" }
    }
    function Stop-Process { param([int]$Id,[switch]$Force,$ErrorAction) $script:stopped.Add($Id) }
    Stop-KeeperCliWorkers -Root $root
    Assert (($script:stopped -join ',') -eq '100,10') 'CLI removal touched an unrelated process'
    Write-Host 'PASS: syntax; first-run/defaults; save/reload/preservation/locale; dependency retry/recovery; log rotation; mocked CLI/GUI shortcut ownership and CLI child cleanup.'
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
