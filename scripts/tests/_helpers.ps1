# Helpers compartilhados pelos testes Pester.
function New-PastaTeste {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Nome)
    $p = Join-Path (Join-Path $env:TEMP 'OtimizadorTeste') $Nome
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    return $p
}
