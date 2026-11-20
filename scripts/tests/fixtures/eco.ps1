# eco.ps1 - modulo de teste do host (copiado para scripts/ apenas durante os testes).
. "$PSScriptRoot\common.ps1"

function Invoke-Acao {
    param([string]$Id, [string]$Acao, $Params, [bool]$Teste)
    switch ($Acao) {
        'eco' { Send-Result $Id $Params }
        'demorar' {
            $seg = 30.0
            if ($null -ne $Params -and $null -ne $Params.segundos) { $seg = [double]$Params.segundos }
            Send-Progress $Id 0 'iniciado'
            Start-Sleep -Milliseconds ([int]($seg * 1000))
            Send-Result $Id @{ terminou = $true }
        }
        'teste' { Send-Result $Id @{ teste = $Teste } }
        'falhar' { throw 'falha de proposito' }
        default { Send-Result $Id $null $false 'acao desconhecida' }
    }
}
