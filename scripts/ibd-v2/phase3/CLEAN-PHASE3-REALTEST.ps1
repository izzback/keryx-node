[CmdletBinding()]
param([string]$DataDir = 'E:\datanode\keryx-ibd-v2-phase3-realtest')
$expected = 'E:\datanode\keryx-ibd-v2-phase3-realtest'
if (![string]::Equals([IO.Path]::GetFullPath($DataDir).TrimEnd('\'), [IO.Path]::GetFullPath($expected).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw "Safety refusal: this cleaner only deletes $expected"
}
if (Get-Process -Name keryxd -ErrorAction SilentlyContinue) { throw 'Stop keryxd before cleaning.' }
$confirmation = Read-Host "Type DELETE-PHASE3 to delete $expected"
if ($confirmation -ne 'DELETE-PHASE3') { Write-Host 'Cancelled.'; exit 1 }
if (Test-Path -LiteralPath $expected) { Remove-Item -LiteralPath $expected -Recurse -Force }
New-Item -ItemType Directory -Path $expected -Force | Out-Null
Write-Host "Clean test datadir ready: $expected" -ForegroundColor Green