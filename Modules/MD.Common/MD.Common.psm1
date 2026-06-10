function Esc {
    param([AllowEmptyString()][AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }

    return Get-SpectreEscapedText -Text $Text
}

Export-ModuleMember -Function Esc
