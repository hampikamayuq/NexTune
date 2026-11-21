BeforeAll {
    . "$PSScriptRoot\..\common.ps1"
    . "$PSScriptRoot\..\modojogo.ps1"
    . "$PSScriptRoot\_helpers.ps1"
    $Script:Script = Join-Path (Split-Path -Parent $PSScriptRoot) 'desinstalar.ps1'
    $Script:Base = (Get-AppPastas $true).Base
    $Script:Marcadores = Join-Path $Script:Base 'modojogo'
    $Script:Fora = Join-Path $env:TEMP 'NexTuneForaTeste'
    $Script:Guid = '381b4222-f694-41f0-9685-ff5bb260df2e'
    # O script sobrescreve PSModulePath no processo (roda aqui mesmo, nao em processo filho).
    $Script:ModulePathAntes = $env:PSModulePath
    function Write-EstadoFalso {
        $e = [ordered]@{ ativo = $true; preset = 'suave'; desde = '2026-11-21T10:00:00'; fechados = @(); naoFechados = @(); servicosPausados = @(); planoAplicado = $true; planoAnterior = $Script:Guid; notificacoesAplicadas = $false }
        Write-JsonAtomico (Join-Path (Get-AppPastas $true).Estado 'modojogo.json') $e
    }
}

AfterAll {
    $env:PSModulePath = $Script:ModulePathAntes
    foreach ($p in @((Join-Path $env:TEMP 'NexTuneTeste'), $Script:Fora)) {
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'desinstalar.ps1' {
    BeforeEach {
        if (Test-Path -LiteralPath $Script:Base) { Remove-Item -LiteralPath $Script:Base -Recurse -Force -ErrorAction SilentlyContinue }
        $null = Get-AppPastas $true
    }

    It 'desfaz o Modo Jogo pendente e remove a tarefa de inicio' {
        Write-EstadoFalso
        & $Script:Script -Teste
        (Join-Path (Get-AppPastas $true).Estado 'modojogo.json') | Should -Not -Exist
        (Join-Path $Script:Marcadores ('powercfg-' + $Script:Guid + '.txt')) | Should -Exist
        (Join-Path $Script:Marcadores 'schtasks-delete.txt') | Should -Exist
        (Join-Path $Script:Base 'Quarentena') | Should -Exist
    }

    It 'sem estado so remove a tarefa e mantem os dados' {
        & $Script:Script -Teste
        (Join-Path $Script:Marcadores 'schtasks-delete.txt') | Should -Exist
        (Join-Path $Script:Base 'Quarentena') | Should -Exist
    }

    It 'com -ApagarDados apaga a pasta de dados sem entrar em junctions' {
        New-Item -ItemType Directory -Path $Script:Fora -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Script:Fora 'alvo.txt') -Value 'fica'
        New-Juncao (Join-Path $Script:Base 'Quarentena\link') $Script:Fora
        & $Script:Script -Teste -ApagarDados
        $Script:Base | Should -Not -Exist
        (Join-Path $Script:Fora 'alvo.txt') | Should -Exist
    }
}
