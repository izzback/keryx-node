$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$sourcePath = 'scripts/ibd-v2/phase4/apply-header-batching-v156.ps1'
$source = [IO.File]::ReadAllText((Resolve-Path $sourcePath))

# PowerShell 5.1 parses "$Variable:" as a scoped/drive reference. Delimit the variable name.
$source = $source.Replace('throw "$Label: source marker not found in $Path"', 'throw "${Label}: source marker not found in $Path"')
$source = $source.Replace('throw "$Label: source marker occurs more than once in $Path"', 'throw "${Label}: source marker occurs more than once in $Path"')

# Git on the Windows runner may materialize Rust sources with CRLF while the reviewed here-string
# markers are LF. Normalize only for matching/replacement, then restore the target file's EOL style.
$replaceOnce = @'
function Replace-Once([string]$Path, [string]$Old, [string]$New, [string]$Label) {
    $raw = Read-Text $Path
    $usesCrlf = $raw.Contains("`r`n")
    $text = $raw.Replace("`r`n", "`n")
    $oldNormalized = $Old.Replace("`r`n", "`n")
    $newNormalized = $New.Replace("`r`n", "`n")
    $first = $text.IndexOf($oldNormalized, [StringComparison]::Ordinal)
    if ($first -lt 0) { throw "${Label}: source marker not found in $Path" }
    $second = $text.IndexOf($oldNormalized, $first + $oldNormalized.Length, [StringComparison]::Ordinal)
    if ($second -ge 0) { throw "${Label}: source marker occurs more than once in $Path" }
    $text = $text.Substring(0, $first) + $newNormalized + $text.Substring($first + $oldNormalized.Length)
    if ($usesCrlf) {
        $text = $text.Replace("`n", "`r`n")
    }
    Write-Text $Path $text
}

$head =
'@
$pattern = '(?s)function Replace-Once\(\[string\]\$Path, \[string\]\$Old, \[string\]\$New, \[string\]\$Label\) \{.*?\r?\n\}\r?\n\r?\n\$head ='
$matches = [regex]::Matches($source, $pattern)
if ($matches.Count -ne 1) { throw "expected one Replace-Once function, found $($matches.Count)" }
$source = [regex]::Replace($source, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replaceOnce }, 1)

$temp = Join-Path $env:RUNNER_TEMP 'apply-header-batching-v156-fixed.ps1'
[IO.File]::WriteAllText($temp, $source, $utf8NoBom)
& $temp
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
