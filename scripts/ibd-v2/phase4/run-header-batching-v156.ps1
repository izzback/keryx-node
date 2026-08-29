$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$sourcePath = 'scripts/ibd-v2/phase4/apply-header-batching-v156.ps1'
$source = [IO.File]::ReadAllText((Resolve-Path $sourcePath))
$source = $source.Replace('throw "$Label: source marker not found in $Path"', 'throw "${Label}: source marker not found in $Path"')
$source = $source.Replace('throw "$Label: source marker occurs more than once in $Path"', 'throw "${Label}: source marker occurs more than once in $Path"')

$temp = Join-Path $env:RUNNER_TEMP 'apply-header-batching-v156-fixed.ps1'
[IO.File]::WriteAllText($temp, $source, $utf8NoBom)
& $temp
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
