param([Parameter(Mandatory=$true)][ValidateSet('add','remove')][string]$Mode, [switch]$Launch)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Startup.Common.ps1')
Set-KeeperStartup -Root (Split-Path -Parent $PSScriptRoot) -Kind Gui -Mode $Mode -Launch:$Launch
Write-Host "GUI startup: $Mode. To stop a running GUI, choose Exit from its tray menu."
