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
        'comFinally' {
            # Simula a limpeza que religa servicos no finally: o finally demora (sleep .NET, que o
            # Stop do pipeline nao interrompe) e no fim grava um marcador.
            Send-Progress $Id 0 'iniciado'
            try { Start-Sleep -Seconds 30; Send-Result $Id @{ terminou = $true } }
            finally {
                [Threading.Thread]::Sleep([int]$Params.esperaFinal)
                [IO.File]::WriteAllText([string]$Params.arquivo, 'restaurado')
            }
        }
        'modulos' { Send-Result $Id @{ psModulePath = $env:PSModulePath } }
        'teste' { Send-Result $Id @{ teste = $Teste } }
        'falhar' { throw 'falha de proposito' }
        'nativo' { $s = cmd.exe /c echo ola; Send-Result $Id @{ saida = (($s | Out-String).Trim()) } }
        'semResultado' { return }
        default { Send-Result $Id $null $false 'acao desconhecida' }
    }
}
