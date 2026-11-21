BeforeAll {
    . "$PSScriptRoot\..\common.ps1"
    . "$PSScriptRoot\..\disco.ps1"
    . "$PSScriptRoot\_helpers.ps1"
    $Script:PastaT = Join-Path (Join-Path $env:TEMP 'NexTuneTeste') 'disco'
    $Script:Registro = Join-Path (Get-AppPastas $true).Estado 'disco.json'

    function Invoke-Disco {
        param([string]$Acao, $Params = @{}, [bool]$Teste = $true)
        $sw = New-Object System.IO.StringWriter
        Set-Saida $sw
        try { Invoke-Acao 'd1' $Acao $Params $Teste } finally { Set-Saida $null }
        $Script:UltimaSaida = $sw.ToString()
        $linhas = @($sw.ToString() -split "`r?`n" | Where-Object { $_.StartsWith('@@RESULT ') })
        if ($linhas.Count -ne 1) { return $null }
        return $linhas[0].Substring(9) | ConvertFrom-Json
    }
    function New-Sim {
        param([bool]$SujoC = $false)
        return @{
            unidades     = @(
                @{ letra = 'C:'; rotulo = 'Windows'; total = 1000GB; livre = 400GB; tipoDisco = 'hdd'; sistema = $true; sujo = $SujoC; agendada = $false },
                @{ letra = 'D:'; rotulo = 'Dados'; total = 500GB; livre = 200GB; tipoDisco = 'ssd'; sistema = $false; sujo = $false; agendada = $false }
            )
            inicioRapido = $true
        }
    }
    function Get-Un { param($R, [string]$Letra) return @($R.dados.unidades | Where-Object { $_.letra -eq $Letra })[0] }
    function Test-Marcador { param([string]$Nome) return (Test-Path -LiteralPath (Join-Path $Script:PastaT $Nome)) }
}

AfterAll {
    $t = Join-Path $env:TEMP 'NexTuneTeste'
    if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'disco.ps1' {
    BeforeEach {
        if (Test-Path -LiteralPath $Script:PastaT) { Remove-Item -LiteralPath $Script:PastaT -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $Script:Registro) { Remove-Item -LiteralPath $Script:Registro -Force -ErrorAction SilentlyContinue }
        $Script:Sim = New-Sim
    }

    Context 'funcoes puras' {
        It 'Test-UnidadeAgendada acha a letra no BootExecute sem diferenciar caixa' {
            $be = @('autocheck autochk *', 'autocheck autochk /p \??\C:')
            Test-UnidadeAgendada $be 'C:' | Should -BeTrue
            Test-UnidadeAgendada $be 'D:' | Should -BeFalse
            Test-UnidadeAgendada @('autocheck autochk /p \??\c:') 'C:' | Should -BeTrue
            Test-UnidadeAgendada @() 'C:' | Should -BeFalse
            Test-UnidadeAgendada $null 'C:' | Should -BeFalse
        }
        It 'Review Focus 1: Get-OperacaoOtimizar: hdd desfragmenta, ssd faz TRIM, desconhecido e conservador' {
            Get-OperacaoOtimizar 'hdd' | Should -Be 'desfragmentar'
            Get-OperacaoOtimizar 'ssd' | Should -Be 'trim'
            Get-OperacaoOtimizar 'xyz' | Should -Be 'desfragmentar'
        }
        It 'Get-DiasDesde conta dias inteiros e devolve null para lixo' {
            $agora = Get-Date
            Get-DiasDesde ($agora.AddDays(-10).ToString('o')) $agora | Should -Be 10
            Get-DiasDesde ($agora.AddHours(-30).ToString('o')) $agora | Should -Be 1
            Get-DiasDesde $null $agora | Should -BeNullOrEmpty
            Get-DiasDesde '' $agora | Should -BeNullOrEmpty
            Get-DiasDesde 'lixo' $agora | Should -BeNullOrEmpty
        }
        It 'Test-PodeOtimizar exige bit sujo desligado e verificacao sem erros' {
            $r = Test-PodeOtimizar @{ sujo = $true; semErros = $true }
            $r.pode | Should -BeFalse
            $r.motivo | Should -Match 'verifica'
            $r2 = Test-PodeOtimizar @{ sujo = $false; semErros = $null }
            $r2.pode | Should -BeFalse
            $r2.motivo | Should -Match 'erifique'
            (Test-PodeOtimizar @{ sujo = $false; semErros = $false }).pode | Should -BeFalse
            (Test-PodeOtimizar @{ sujo = $false; semErros = $true }).pode | Should -BeTrue
        }
    }

    Context 'estado' {
        It 'sem simular em teste devolve lista vazia' {
            $r = Invoke-Disco 'estado'
            $r.ok | Should -BeTrue
            @($r.dados.unidades).Count | Should -Be 0
        }
        It 'com simulado devolve as unidades, nunca verificadas, e inicioRapido' {
            $r = Invoke-Disco 'estado' @{ simular = $Script:Sim }
            $r.ok | Should -BeTrue
            @($r.dados.unidades | ForEach-Object { $_.letra }) | Should -Be @('C:', 'D:')
            $r.dados.inicioRapido | Should -BeTrue
            $c = Get-Un $r 'C:'
            $c.tipoDisco | Should -Be 'hdd'
            $c.sistema | Should -BeTrue
            $c.ultimaVerificacao | Should -BeNullOrEmpty
            $c.semErros | Should -BeNullOrEmpty
            $c.diasSemVerificar | Should -BeNullOrEmpty
            $c.agendada | Should -BeFalse
        }
        It 'Review Focus 7: disco.json corrompido conta como nunca verificado e a proxima verificacao regrava' {
            $pasta = Split-Path -Parent $Script:Registro
            if (-not (Test-Path -LiteralPath $pasta)) { New-Item -ItemType Directory -Path $pasta -Force | Out-Null }
            [IO.File]::WriteAllText($Script:Registro, '{ nao e json', (New-Object System.Text.UTF8Encoding $false))
            $r = Invoke-Disco 'estado' @{ simular = $Script:Sim }
            $r.ok | Should -BeTrue
            (Get-Un $r 'C:').ultimaVerificacao | Should -BeNullOrEmpty
            (Invoke-Disco 'verificar' @{ letra = 'C:'; simular = $Script:Sim }).ok | Should -BeTrue
            { Get-Content -LiteralPath $Script:Registro -Raw | ConvertFrom-Json } | Should -Not -Throw
            (Get-Un (Invoke-Disco 'estado' @{ simular = $Script:Sim }) 'C:').semErros | Should -BeTrue
        }
    }

    Context 'verificar' {
        It 'registra a verificacao e o estado passa a mostrar a data' {
            $r = Invoke-Disco 'verificar' @{ letra = 'C:'; simular = $Script:Sim }
            $r.ok | Should -BeTrue
            $r.dados.letra | Should -Be 'C:'
            $r.dados.resultado | Should -Be 'NoErrorsFound'
            $r.dados.semErros | Should -BeTrue
            $r.dados.verificadoEm | Should -Not -BeNullOrEmpty
            Test-Marcador 'verificar-C.txt' | Should -BeTrue
            $c = Get-Un (Invoke-Disco 'estado' @{ simular = $Script:Sim }) 'C:'
            $c.ultimaVerificacao | Should -Not -BeNullOrEmpty
            $c.semErros | Should -BeTrue
            $c.diasSemVerificar | Should -Be 0
            (Get-Un (Invoke-Disco 'estado' @{ simular = $Script:Sim }) 'D:').ultimaVerificacao | Should -BeNullOrEmpty
        }
        It 'resultado com erros fica registrado como semErros false' {
            $sim = New-Sim
            $sim.resultado = 'ErrorsFound'
            $r = Invoke-Disco 'verificar' @{ letra = 'C:'; simular = $sim }
            $r.dados.semErros | Should -BeFalse
            (Get-Un (Invoke-Disco 'estado' @{ simular = $Script:Sim }) 'C:').semErros | Should -BeFalse
        }
        It 'Review Focus 2: letra fora da lista e recusada em verificar, corrigir e otimizar' {
            foreach ($acao in @('verificar', 'corrigir', 'otimizar')) {
                $r = Invoke-Disco $acao @{ letra = 'Z:'; confirmado = $true; simular = $Script:Sim }
                $r.ok | Should -BeFalse
                $r.erro | Should -Match 'não encontrada'
            }
            Test-Path -LiteralPath $Script:PastaT | Should -BeFalse
            Test-Path -LiteralPath $Script:Registro | Should -BeFalse
        }
    }

    Context 'corrigir e reiniciar' {
        It 'Review Focus 3: corrigir agenda e devolve inicioRapido; estado com bit sujo mostra agendada' {
            $r = Invoke-Disco 'corrigir' @{ letra = 'C:'; confirmado = $true; simular = $Script:Sim }
            $r.ok | Should -BeTrue
            $r.dados.agendada | Should -BeTrue
            $r.dados.inicioRapido | Should -BeTrue
            Test-Marcador 'corrigir-C.txt' | Should -BeTrue
            $c = Get-Un (Invoke-Disco 'estado' @{ simular = (New-Sim -SujoC $true) }) 'C:'
            $c.sujo | Should -BeTrue
            $c.agendada | Should -BeTrue
        }
        It 'corrigir sem confirmado recusa e nao grava' {
            (Invoke-Disco 'corrigir' @{ letra = 'C:'; simular = $Script:Sim }).ok | Should -BeFalse
            (Invoke-Disco 'corrigir' @{ letra = 'C:'; confirmado = 'true'; simular = $Script:Sim }).ok | Should -BeFalse
            Test-Marcador 'corrigir-C.txt' | Should -BeFalse
        }
        It 'reiniciar exige confirmado e grava o marcador' {
            (Invoke-Disco 'reiniciar' @{ simular = $Script:Sim }).ok | Should -BeFalse
            Test-Marcador 'reiniciar.txt' | Should -BeFalse
            $r = Invoke-Disco 'reiniciar' @{ confirmado = $true; simular = $Script:Sim }
            $r.ok | Should -BeTrue
            $r.dados.agendado | Should -BeTrue
            Test-Marcador 'reiniciar.txt' | Should -BeTrue
        }
    }

    Context 'otimizar' {
        It 'Review Focus 1: sem verificacao recusa; HDD desfragmenta; SSD faz TRIM; nunca o inverso' {
            $r = Invoke-Disco 'otimizar' @{ letra = 'C:'; confirmado = $true; simular = $Script:Sim }
            $r.ok | Should -BeFalse
            $r.erro | Should -Match 'erifique'
            Test-Marcador 'otimizar-C.txt' | Should -BeFalse

            Invoke-Disco 'verificar' @{ letra = 'C:'; simular = $Script:Sim } | Out-Null
            $r2 = Invoke-Disco 'otimizar' @{ letra = 'C:'; confirmado = $true; simular = $Script:Sim }
            $r2.ok | Should -BeTrue
            $r2.dados.operacao | Should -Be 'desfragmentar'
            Get-Content -LiteralPath (Join-Path $Script:PastaT 'otimizar-C.txt') -Raw | Should -Match 'desfragmentar'

            Invoke-Disco 'verificar' @{ letra = 'D:'; simular = $Script:Sim } | Out-Null
            $r3 = Invoke-Disco 'otimizar' @{ letra = 'D:'; confirmado = $true; simular = $Script:Sim }
            $r3.dados.operacao | Should -Be 'trim'
            Get-Content -LiteralPath (Join-Path $Script:PastaT 'otimizar-D.txt') -Raw | Should -Match 'trim'
        }
        It 'Review Focus 1: verificacao com erros ou bit sujo impedem otimizar' {
            $sim = New-Sim
            $sim.resultado = 'ErrorsFound'
            Invoke-Disco 'verificar' @{ letra = 'C:'; simular = $sim } | Out-Null
            (Invoke-Disco 'otimizar' @{ letra = 'C:'; confirmado = $true; simular = $Script:Sim }).ok | Should -BeFalse

            Invoke-Disco 'verificar' @{ letra = 'C:'; simular = $Script:Sim } | Out-Null
            $r = Invoke-Disco 'otimizar' @{ letra = 'C:'; confirmado = $true; simular = (New-Sim -SujoC $true) }
            $r.ok | Should -BeFalse
            $r.erro | Should -Match 'einicie'
            Test-Marcador 'otimizar-C.txt' | Should -BeFalse
        }
        It 'otimizar sem confirmado recusa' {
            Invoke-Disco 'verificar' @{ letra = 'C:'; simular = $Script:Sim } | Out-Null
            (Invoke-Disco 'otimizar' @{ letra = 'C:'; simular = $Script:Sim }).ok | Should -BeFalse
            Test-Marcador 'otimizar-C.txt' | Should -BeFalse
        }
    }

    Context 'Invoke-Acao' {
        It 'acao desconhecida devolve erro' {
            $r = Invoke-Disco 'xyz'
            $r.ok | Should -BeFalse
            $r.erro | Should -Be 'ação desconhecida'
        }
    }
}
