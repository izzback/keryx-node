[CmdletBinding()]
param(
    [ValidateSet('service-state-after-spool-fsync','service-state-after-checkpoint','service-state-after-verified','service-state-after-import')]
    [string]$FaultPoint = 'service-state-after-import',
    [string]$NodePath = (Join-Path $PSScriptRoot 'keryxd.exe'),
    [string]$DataDir = 'E:\datanode\keryx-ibd-v2-phase3-realtest',
    [string]$ResultsRoot = (Join-Path $PSScriptRoot 'results-phase3')
)
$ErrorActionPreference = 'Stop'
if (!(Test-Path -LiteralPath $NodePath -PathType Leaf)) { throw "Node not found: $NodePath" }
if (Get-Process -Name keryxd -ErrorAction SilentlyContinue) { throw 'Another keryxd process is already running. Stop it first.' }
if (Test-Path -LiteralPath $DataDir) {
    if (Get-ChildItem -LiteralPath $DataDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1) {
        throw "Crash-test datadir is not empty: $DataDir"
    }
} else { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
New-Item -ItemType Directory -Path $ResultsRoot -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$resultDir = Join-Path $ResultsRoot "crash-$FaultPoint-$stamp"
New-Item -ItemType Directory -Path $resultDir -Force | Out-Null
$stdout = Join-Path $resultDir 'node.stdout.log'
$stderr = Join-Path $resultDir 'node.stderr.log'
@("fault_point=$FaultPoint","datadir=$DataDir","node=$NodePath","started_utc=$([DateTime]::UtcNow.ToString('o'))") | Set-Content -Encoding ASCII (Join-Path $resultDir 'TEST-METADATA.txt')
$old = @{
    Ibd = $env:KERYX_IBD_V2
    Metrics = $env:KERYX_IBD_V2_METRICS
    Fault = $env:KERYX_IBD_V2_FAULT_INJECTION
    Point = $env:KERYX_IBD_V2_FAULT_POINT
}
try {
    $env:KERYX_IBD_V2 = '1'
    $env:KERYX_IBD_V2_METRICS = '1'
    $env:KERYX_IBD_V2_FAULT_INJECTION = '1'
    $env:KERYX_IBD_V2_FAULT_POINT = $FaultPoint
    Write-Host "Starting hard-crash test at $FaultPoint" -ForegroundColor Yellow
    Write-Host "Datadir: $DataDir"
    $process = Start-Process -FilePath $NodePath -ArgumentList @("--appdir=$DataDir") -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
} finally {
    $env:KERYX_IBD_V2 = $old.Ibd
    $env:KERYX_IBD_V2_METRICS = $old.Metrics
    $env:KERYX_IBD_V2_FAULT_INJECTION = $old.Fault
    $env:KERYX_IBD_V2_FAULT_POINT = $old.Point
}
$process.WaitForExit()
Add-Content -Encoding ASCII (Join-Path $resultDir 'TEST-METADATA.txt') "exit_code=$($process.ExitCode)"
Add-Content -Encoding ASCII (Join-Path $resultDir 'TEST-METADATA.txt') "ended_utc=$([DateTime]::UtcNow.ToString('o'))"
$marker = "IBD v2 fault injection: aborting at $FaultPoint"
$found = (Select-String -LiteralPath $stdout,$stderr -SimpleMatch $marker -ErrorAction SilentlyContinue) -ne $null
if ($found) { Write-Host "Expected hard crash observed at $FaultPoint." -ForegroundColor Green }
else { Write-Warning "Process exited but the expected fault marker was not found. Inspect $resultDir." }
Write-Host "NEXT: .\RESUME-SERVICE-STATE-CRASH-TEST.ps1 -DataDir '$DataDir'" -ForegroundColor Cyan
Write-Host "Evidence: $resultDir"