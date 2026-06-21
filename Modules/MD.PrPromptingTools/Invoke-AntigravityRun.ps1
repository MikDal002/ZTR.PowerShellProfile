function Invoke-AntigravityRun {
    <#
    .SYNOPSIS
        Uruchamia agy CLI (Antigravity) z podanym promptem i zwraca wynik.
    .DESCRIPTION
        Czyta prompt z podanego pliku, wywołuje agy CLI w trybie --print
        (nieinteraktywny, jednorazowy prompt),
        parsuje wynik i zwraca PSCustomObject z polami SessionId, Output, DurationMs.
    .PARAMETER PromptFilePath
        Ścieżka do pliku z promptem (markdown/text).
    .PARAMETER WorkingDirectory
        Katalog roboczy, w którym agy ma działać.
    .OUTPUTS
        PSCustomObject z polami: SessionId, Output, DurationMs
    .EXAMPLE
        Invoke-AntigravityRun -PromptFilePath ".\prompt.md" -WorkingDirectory "."
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PromptFilePath,

        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory
    )

    if ($null -eq (Get-Command agy -ErrorAction SilentlyContinue)) {
        throw "Brak komendy 'agy'. Zainstaluj Antigravity CLI (agy)."
    }

    if (-not (Test-Path -LiteralPath $PromptFilePath -PathType Leaf)) {
        throw "Plik promptu nie istnieje: $PromptFilePath"
    }

    if (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
        throw "WorkingDirectory nie istnieje: $WorkingDirectory"
    }

    Write-SpectreHost "[cyan]Start agy CLI: cwd=$WorkingDirectory[/]"

    $startedAt = Get-Date

    $promptText = Get-Content -LiteralPath $PromptFilePath -Raw

    # agy --print uruchamia jednorazowy prompt nieinteraktywnie i wypisuje odpowiedź na stdout.
    $agyArgs = @(
        '--print', $promptText
    )

    $statusResult = Invoke-SpectreCommandWithStatus `
        -Title "Antigravity (agy) run" `
        -Spinner "Dots" `
        -ScriptBlock ({
            Push-Location -LiteralPath $WorkingDirectory
            try {
                $output = & agy @agyArgs
                return [pscustomobject]@{
                    Output   = $output
                    ExitCode = $LASTEXITCODE
                }
            }
            finally {
                Pop-Location
            }
        }.GetNewClosure())

    $rawLines = $statusResult.Output | ForEach-Object { "$_" }
    $rawText = $rawLines -join "`n"

    if ($statusResult.ExitCode -ne 0) {
        $cleanMsg = $rawText -replace '(?s)\s+at (file|node):.*?\n', "`n"
        throw "agy CLI zakonczyl sie bledem (exit code $($statusResult.ExitCode)).`nRaw output:`n$($cleanMsg.Trim())"
    }

    $elapsedSec = [Math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)
    Write-SpectreHost "[green]Koniec agy CLI: czas=${elapsedSec}s[/]"

    # agy --print zwraca plain-text odpowiedź (nie JSON),
    # więc cały stdout to treść odpowiedzi.
    return [pscustomobject]@{
        SessionId  = $null
        Output     = [string]$rawText
        DurationMs = [int]((Get-Date) - $startedAt).TotalMilliseconds
    }
}
