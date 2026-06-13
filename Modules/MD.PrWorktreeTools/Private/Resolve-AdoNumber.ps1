
function Resolve-AdoNumber {
    <#
    .SYNOPSIS
        Zwraca oczyszczony numer ADO lub $null.
    .DESCRIPTION
        Jeśli Value jest niepuste — czyści go (tylko cyfry) i zwraca.
        Jeśli Value jest puste:
          - ZTR_ADO_REQUIRED=false → zwraca $null
          - ZTR_ADO_REQUIRED=true (lub brak zmiennej) → pyta interaktywnie
            jeśli sesja jest interaktywna, w przeciwnym razie rzuca wyjątek.
        Wyświetla HINT raz na sesję gdy ZTR_ADO_REQUIRED nie jest ustawiona.
    #>
    param(
        [string]$Value,
        [string]$Context = ''
    )
    
    function Sanitize-AdoNumber($value) {
        $c = ($value -replace '[^0-9]', '')
        return $c
    }

    if ($null -eq $env:ZTR_ADO_REQUIRED -and -not $script:ZtrAdoRequiredHintShown) {
        Write-Host "HINT: Numer ADO jest domyslnie wymagany. Mozesz to zmienic ustawiajac `$env:ZTR_ADO_REQUIRED = 'false' lub uruchamiajac setup.ps1." -ForegroundColor Yellow
        $script:ZtrAdoRequiredHintShown = $true
    }

    $adoRequired = Is-True $env:ZTR_ADO_REQUIRED
    
    $Value = Sanitize-AdoNumber $Value

    if ([string]::IsNullOrWhiteSpace($Value) -and $adoRequired) {

        $isInteractive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
        if (-not $isInteractive) {
            throw "Numer ADO jest wymagany (ZTR_ADO_REQUIRED=true), ale sesja nie jest interaktywna."
        }

        $prompt = "Podaj numer ADO" + $(if ($Context) { " (kontekst: $Context)" } else { "" })
        $raw = Read-Host $prompt
        if ([string]::IsNullOrWhiteSpace($raw)) { throw "Numer ADO nie moze byc pusty." }

        $Value = Sanitize-AdoNumber $raw
        if ([string]::IsNullOrWhiteSpace($Value)) { throw "Numer ADO musi zawierac cyfry." }
    }

    return $Value
}