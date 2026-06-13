$script:ZtrAdoRequiredHintShown = $false

$commonModulePath = Join-Path -Path $PSScriptRoot -ChildPath "../MD.Common/MD.Common.psm1"
Import-Module $commonModulePath -ErrorAction Stop

# ---- Dynamic Loader ----
$privateDir = Join-Path -Path $PSScriptRoot -ChildPath "Private"
if (Test-Path $privateDir) {
    Get-ChildItem -Path $privateDir -Filter *.ps1 | ForEach-Object {
        . $_.FullName
    }
}

$publicDir = Join-Path -Path $PSScriptRoot -ChildPath "Public"
if (Test-Path $publicDir) {
    Get-ChildItem -Path $publicDir -Filter *.ps1 | ForEach-Object {
        . $_.FullName
        Export-ModuleMember -Function $_.BaseName
    }
}
