$ErrorActionPreference = 'Stop'

$path = 'scripts/ibd-v2-candidate/apply-stage-tracking-v2.ps1'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$lines = [System.Collections.Generic.List[string]]::new()
[System.IO.File]::ReadAllLines($path) | ForEach-Object { [void]$lines.Add($_) }

function Replace-HereStringBlock(
    [System.Collections.Generic.List[string]]$List,
    [string]$Variable,
    [string[]]$ExpectedBody,
    [string]$Replacement
) {
    $start = -1
    for ($i = 0; $i -lt $List.Count; $i++) {
        if ($List[$i] -eq "$Variable = @'") {
            $start = $i
            break
        }
    }
    if ($start -lt 0) { throw "Could not find $Variable here-string" }
    $end = $start + $ExpectedBody.Count + 1
    if ($end -ge $List.Count -or $List[$end] -ne "'@") { throw "Malformed $Variable here-string" }
    for ($j = 0; $j -lt $ExpectedBody.Count; $j++) {
        if ($List[$start + 1 + $j] -ne $ExpectedBody[$j]) {
            throw "Unexpected $Variable body at line $($start + 2 + $j)"
        }
    }
    $List.RemoveRange($start, $ExpectedBody.Count + 2)
    $List.Insert($start, $Replacement)
}

Replace-HereStringBlock $lines '$oldMod' @(
    'pub mod service_state_spool;',
    'pub mod state;'
) '$oldMod = "pub mod service_state_spool;`npub mod state;"'

Replace-HereStringBlock $lines '$newMod' @(
    'pub mod service_state_spool;',
    'pub mod stage_tracking;',
    'pub mod state;'
) '$newMod = "pub mod service_state_spool;`npub mod stage_tracking;`npub mod state;"'

[System.IO.File]::WriteAllLines($path, $lines, $utf8NoBom)
Write-Host 'Normalized mod.rs anchors in Phase 3 candidate script.'
