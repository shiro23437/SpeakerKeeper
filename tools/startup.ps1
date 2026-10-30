param([Parameter(Mandatory=$true)][ValidateSet('add','remove')][string]$Mode)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'Startup.Common.ps1')
Set-KeeperStartup -Root $root -Kind Cli -Mode $Mode -Launch:($Mode -eq 'add')
if ($Mode -eq 'remove') {
    Stop-KeeperCliWorkers -Root $root
}
Write-Host "CLI startup: $Mode. GUI startup shortcuts were not changed."
