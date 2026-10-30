# Shared defaults and parsing for the CLI and optional GUI. No file is created on read.
function Read-KeeperConfiguration([string]$Path) {
    $settings = @{
        Frequency = 300.0; Amplitude = 0.1; LingerSeconds = 30.0; Threshold = 0.001
        SoundKeeper = 'SoundKeeper64.exe'; DeviceName = ''; AppName = ''
    }
    $ranges = @{ Frequency = @(1, 20000); Amplitude = @(0, 100); LingerSeconds = @(0, 3600); Threshold = @(0, 1) }
    if ([System.IO.File]::Exists($Path)) {
        foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
            if ($line -notmatch '^\s*([A-Za-z]+)\s*=(.*)$') { continue }
            $key = $Matches[1]; $value = $Matches[2].Trim()
            if (-not $settings.ContainsKey($key)) { continue }
            if (-not $ranges.ContainsKey($key)) { $settings[$key] = $value; continue }
            $number = 0.0
            if ([double]::TryParse($value, [System.Globalization.NumberStyles]::Float,
                    [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number) -and
                -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number) -and
                $number -ge $ranges[$key][0] -and $number -le $ranges[$key][1]) {
                $settings[$key] = $number
            } else { Write-Warning "Invalid $key in settings.txt; using the default value." }
        }
    }
    return $settings
}
