[CmdletBinding()]
param(
    [string]$NodePath = (Join-Path $PSScriptRoot 'keryxd.exe'),
    [string]$DataDir = 'E:\datanode\keryx-ibd-v2-phase3-realtest'
)
$ErrorActionPreference = 'Stop'
if (!(Test-Path -LiteralPath $NodePath -PathType Leaf)) { throw "Node not found: $NodePath" }
if (!(Test-Path -LiteralPath $DataDir -PathType Container)) { throw "Datadir not found: $DataDir" }
if (!(Get-ChildItem -LiteralPath $DataDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { throw 'The datadir is empty; nothing to resume.' }
if (Get-Process -Name keryxd -ErrorAction SilentlyContinue) { throw 'Another keryxd process is already running.' }
$env:KERYX_IBD_V2 = '1'
$env:KERYX_IBD_V2_METRICS = '1'
Remove-Item Env:KERYX_IBD_V2_FAULT_INJECTION -ErrorAction SilentlyContinue
Remove-Item Env:KERYX_IBD_V2_FAULT_POINT -ErrorAction SilentlyContinue
Write-Host 'Resuming SAME datadir with fault injection disabled.' -ForegroundColor Green
Write-Host 'Expected: durable cursor resume or local replay of the Verified spool.'
& $NodePath "--appdir=$DataDir"
exit $LASTEXITCODE