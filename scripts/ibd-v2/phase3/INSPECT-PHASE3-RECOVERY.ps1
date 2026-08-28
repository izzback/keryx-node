[CmdletBinding()]
param(
    [string]$DataDir = 'E:\datanode\keryx-ibd-v2-phase3-realtest',
    [string]$ResultsRoot = (Join-Path $PSScriptRoot 'results-phase3')
)
$patterns = @('IBD v2 fault injection','resuming durable service-state','replaying locally verified service-state spool','service-state wire mode=','IBD-V2-METRICS: stage=service-state','imported ','IBD with peer','completed successfully')
$files = @()
if (Test-Path $ResultsRoot) { $files += Get-ChildItem $ResultsRoot -Recurse -File -Filter '*.log' -ErrorAction SilentlyContinue }
if (Test-Path $DataDir) { $files += Get-ChildItem $DataDir -Recurse -File -Filter '*.log' -ErrorAction SilentlyContinue }
$files = $files | Sort-Object FullName -Unique
if (!$files) { throw 'No log files were found.' }
foreach ($file in $files) {
    $matches = Select-String -LiteralPath $file.FullName -Pattern $patterns -SimpleMatch -ErrorAction SilentlyContinue
    if ($matches) {
        Write-Host "`n=== $($file.FullName) ===" -ForegroundColor Cyan
        $matches | Select-Object -Last 100 | ForEach-Object { $_.Line }
    }
}