BeforeAll {
    . "$PSScriptRoot\..\common.ps1"
    . "$PSScriptRoot\..\sistema.ps1"
    . "$PSScriptRoot\_helpers.ps1"
    $Script:ChaveT = 'HKCU:\Software\NexTuneTeste\SystemRestore'
    $Script:PastaT = Join-Path (Join-Path $env:TEMP 'NexTuneTeste') 'sistema'
    $Script:NomeFreq = 'SystemRestorePointCreationFrequency'

    # Executa uma acao do modulo capturando o protocolo; devolve o @@RESULT (objeto) ou $null.
    function Invoke-Sistema {
        param([string]$Acao, $Params = @{}, [bool]$Teste = $true)
        $sw = New-Object System.IO.StringWriter
        Set-Saida $sw
        try { Invoke-Acao 'a1' $Acao $Params $Teste } finally { Set-Saida $null }
        $Script:UltimaSaida = $sw.ToString()
        $linhas = @($sw.ToString() -split "`r?`n" | Where-Object { $_.StartsWith('@@RESULT ') })
        if ($linhas.Count -ne 1) { return $null }
        return $linhas[0].Substring(9) | ConvertFrom-Json
    }
    function Get-FrequenciaTeste {
        try { return (Get-ItemProperty -LiteralPath $Script:ChaveT -Name $Script:NomeFreq -ErrorAction Stop).$Script:NomeFreq }
        catch { return $null }
    }
    function Set-RegistroTeste {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param($Intervalo = $null, $Frequencia = $null)
        New-Item -Path $Script:ChaveT -Force | Out-Null
        if ($null -ne $Intervalo) { Set-ItemProperty -LiteralPath $Script:ChaveT -Name 'RPSessionInterval' -Value $Intervalo -Type DWord }
        if ($null -ne $Frequencia) { Set-ItemProperty -LiteralPath $Script:ChaveT -Name $Script:NomeFreq -Value $Frequencia -Type DWord }
    }
    function Get-Marcadores {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
        [CmdletBinding()]
        param([string]$Filtro = 'ponto-*.txt')
        if (-not (Test-Path -LiteralPath $Script:PastaT)) { return @() }
        return @(Get-ChildItem -LiteralPath $Script:PastaT -Filter $Filtro -File)
    }
}

AfterAll {
    Remove-Item -LiteralPath 'HKCU:\Software\NexTuneTeste\SystemRestore' -Recurse -Force -ErrorAction SilentlyContinue
    $t = Join-Path $env:TEMP 'NexTuneTeste'
    if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'sistema.ps1' {
    BeforeEach {
        Remove-Item -LiteralPath 'HKCU:\Software\NexTuneTeste\SystemRestore' -Recurse -Force -ErrorAction SilentlyContinue
        $p = Join-Path (Join-Path $env:TEMP 'NexTuneTeste') 'sistema'
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Context 'protecaoEstado' {
        It 'chave ausente: ativa false, frequencia e ultimo ponto nulos, unidade do sistema' {
            $r = Invoke-Sistema 'protecaoEstado'
            $r.ok | Should -BeTrue
            $r.dados.ativa | Should -BeFalse
            $r.dados.frequenciaMin | Should -BeNullOrEmpty
            $r.dados.ultimoPonto | Should -BeNullOrEmpty
            $r.dados.unidade | Should -Be $env:SystemDrive
            $Script:UltimaSaida | Should -Match '"ultimoPonto":null'
            $Script:UltimaSaida | Should -Match '"frequenciaMin":null'
        }
        It 'RPSessionInterval=1 e frequencia 1440: ativa true e frequenciaMin 1440' {
            Set-RegistroTeste 1 1440
            $r = Invoke-Sistema 'protecaoEstado'
            $r.ok | Should -BeTrue
            $r.dados.ativa | Should -BeTrue
            $r.dados.frequenciaMin | Should -Be 1440
        }
        It 'RPSessionInterval=0: ativa false' {
            Set-RegistroTeste 0 1440
            (Invoke-Sistema 'protecaoEstado').dados.ativa | Should -BeFalse
        }
        It 'ultimoPonto e a data do marcador mais novo' {
            (Invoke-Sistema 'criarPonto').dados.criado | Should -BeTrue
            $r = Invoke-Sistema 'protecaoEstado'
            $r.dados.ultimoPonto | Should -Not -BeNullOrEmpty
            $d = [DateTime]::Parse([string]$r.dados.ultimoPonto)
            $d | Should -BeGreaterThan (Get-Date).AddMinutes(-5)
            $d | Should -BeLessThan (Get-Date).AddMinutes(5)
        }
    }

    Context 'criarPonto' {
        It 'em teste grava o marcador ponto-<n>.txt e devolve criado true com mensagem' {
            $r = Invoke-Sistema 'criarPonto'
            $r.ok | Should -BeTrue
            $r.dados.criado | Should -BeTrue
            $r.dados.mensagem | Should -Match 'NexTune'
            $m = Get-Marcadores
            $m.Count | Should -Be 1
            $m[0].Name | Should -Match '^ponto-\d{17}\.txt$'
        }
        It 'descricao do usuario entra no marcador, cortada em 80 caracteres e sem controle' {
            $longa = ('x' * 100) + "`t`n"
            $r = Invoke-Sistema 'criarPonto' @{ descricao = $longa }
            $r.dados.criado | Should -BeTrue
            $conteudo = Get-Content -LiteralPath (Get-Marcadores)[0].FullName -Raw -Encoding UTF8
            $conteudo | Should -Match '^NexTune \d{2}/\d{2} \d{2}:\d{2} - x{80}$'
            $conteudo | Should -Not -Match "`t"
        }
        It 'Get-DescricaoPonto e puro: sem descricao, so o carimbo' {
            $agora = Get-Date -Year 2026 -Month 11 -Day 20 -Hour 15 -Minute 30 -Second 0
            Get-DescricaoPonto @{} $agora | Should -BeExactly 'NexTune 20/11 15:30'
            Get-DescricaoPonto @{ descricao = '   ' } $agora | Should -BeExactly 'NexTune 20/11 15:30'
            Get-DescricaoPonto @{ descricao = 'antes da limpeza' } $agora | Should -BeExactly 'NexTune 20/11 15:30 - antes da limpeza'
        }
        It 'zera a frequencia durante a criacao e devolve 1440 depois' {
            Set-RegistroTeste 1 1440
            $Script:Obs = $null
            Mock New-PontoRestauracao { $Script:Obs = Get-FrequenciaTeste }
            $r = Invoke-Sistema 'criarPonto'
            $r.dados.criado | Should -BeTrue
            $Script:Obs | Should -Be 0
            Get-FrequenciaTeste | Should -Be 1440
        }
        It 'Review Focus 3: frequencia volta a 1440 apos falha de criacao' {
            Set-RegistroTeste 1 1440
            $r = Invoke-Sistema 'criarPonto' @{ simular = @{ falharCriar = $true } }
            $r | Should -Not -BeNullOrEmpty
            $r.ok | Should -BeTrue
            $r.dados.criado | Should -BeFalse
            $r.dados.mensagem | Should -Not -BeNullOrEmpty
            $r.dados.mensagem | Should -Match 'simulada'
            Get-FrequenciaTeste | Should -Be 1440
            (Get-Marcadores).Count | Should -Be 0
        }
        It 'Review Focus 3: frequencia ausente continua ausente apos falha (chave sem o valor)' {
            Set-RegistroTeste 1
            Get-FrequenciaTeste | Should -BeNullOrEmpty
            $r = Invoke-Sistema 'criarPonto' @{ simular = @{ falharCriar = $true } }
            $r.dados.criado | Should -BeFalse
            Get-FrequenciaTeste | Should -BeNullOrEmpty
            (Get-ItemProperty -LiteralPath $Script:ChaveT).RPSessionInterval | Should -Be 1
        }
        It 'Review Focus 3: chave inteira ausente continua ausente apos falha' {
            Test-Path -LiteralPath $Script:ChaveT | Should -BeFalse
            $r = Invoke-Sistema 'criarPonto' @{ simular = @{ falharCriar = $true } }
            $r.dados.criado | Should -BeFalse
            Get-FrequenciaTeste | Should -BeNullOrEmpty
            Test-Path -LiteralPath $Script:ChaveT | Should -BeFalse
        }
        It 'frequencia ausente continua ausente tambem quando a criacao da certo' {
            Set-RegistroTeste 1
            (Invoke-Sistema 'criarPonto').dados.criado | Should -BeTrue
            Get-FrequenciaTeste | Should -BeNullOrEmpty
        }
        It 'falharCriar so vale como booleano' {
            $r = Invoke-Sistema 'criarPonto' @{ simular = @{ falharCriar = 'true' } }
            $r.dados.criado | Should -BeTrue
        }
        It 'simular e ignorado fora do modo de teste (Get-Simulacao)' {
            Get-Simulacao @{ simular = @{ falharCriar = $true } } $false | Should -BeNullOrEmpty
            (Get-Simulacao @{ simular = @{ falharCriar = $true } } $true).falharCriar | Should -BeTrue
        }
    }

    Context 'ligarProtecao' {
        It 'em teste grava RPSessionInterval=1 e o marcador protecao-ligada.txt' {
            $r = Invoke-Sistema 'ligarProtecao'
            $r.ok | Should -BeTrue
            $r.dados.ligada | Should -BeTrue
            $r.dados.mensagem | Should -Not -BeNullOrEmpty
            (Get-ItemProperty -LiteralPath $Script:ChaveT).RPSessionInterval | Should -Be 1
            (Get-Marcadores 'protecao-ligada.txt').Count | Should -Be 1
            (Invoke-Sistema 'protecaoEstado').dados.ativa | Should -BeTrue
        }
    }

    Context 'sessao' {
        It 'mesmo usuario com caixa diferente: mesmo true' {
            $r = Invoke-Sistema 'sessao' @{ simular = @{ usuarioProcesso = 'PC\Fulano'; usuarioConsole = 'pc\FULANO' } }
            $r.ok | Should -BeTrue
            $r.dados.usuarioProcesso | Should -Be 'PC\Fulano'
            $r.dados.usuarioConsole | Should -Be 'pc\FULANO'
            $r.dados.mesmo | Should -BeTrue
            $r.dados.desconhecido | Should -BeFalse
        }
        It 'usuario diferente: mesmo false' {
            $r = Invoke-Sistema 'sessao' @{ simular = @{ usuarioProcesso = 'PC\Fulano'; usuarioConsole = 'PC\Outro' } }
            $r.dados.mesmo | Should -BeFalse
            $r.dados.desconhecido | Should -BeFalse
        }
        It 'console sem usuario ($null): desconhecido true e mesmo true' {
            $r = Invoke-Sistema 'sessao' @{ simular = @{ usuarioProcesso = 'PC\Fulano'; usuarioConsole = $null } }
            $r.dados.usuarioConsole | Should -BeNullOrEmpty
            $r.dados.desconhecido | Should -BeTrue
            $r.dados.mesmo | Should -BeTrue
            $Script:UltimaSaida | Should -Match '"usuarioConsole":null'
        }
        It 'console em branco tambem e desconhecido' {
            $r = Invoke-Sistema 'sessao' @{ simular = @{ usuarioConsole = '   ' } }
            $r.dados.desconhecido | Should -BeTrue
            $r.dados.mesmo | Should -BeTrue
            $r.dados.usuarioConsole | Should -BeNullOrEmpty
        }
        It 'sem usuarioProcesso simulado usa o usuario real do processo' {
            $r = Invoke-Sistema 'sessao' @{ simular = @{ usuarioConsole = 'PC\Outro' } }
            $r.dados.usuarioProcesso | Should -Be ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
        }
        It 'simular fora do modo de teste e ignorado' {
            $r = Invoke-Sistema 'sessao' @{ simular = @{ usuarioProcesso = 'OUTRO\processo'; usuarioConsole = 'OUTRO\console' } } $false
            $r.ok | Should -BeTrue
            $r.dados.usuarioProcesso | Should -Be ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
            $r.dados.usuarioConsole | Should -Not -Be 'OUTRO\console'
            $r.dados.mesmo | Should -BeOfType [bool]
            $r.dados.desconhecido | Should -BeOfType [bool]
        }
        It 'Get-Sessao e puro' {
            (Get-Sessao 'PC\a' 'pc\A').mesmo | Should -BeTrue
            (Get-Sessao 'PC\a' 'PC\b').mesmo | Should -BeFalse
            $d = Get-Sessao 'PC\a' $null
            $d.desconhecido | Should -BeTrue
            $d.mesmo | Should -BeTrue
            $d.usuarioConsole | Should -BeNullOrEmpty
        }
    }

    Context 'Invoke-Acao' {
        It 'acao desconhecida devolve erro' {
            $r = Invoke-Sistema 'xyz'
            $r.ok | Should -BeFalse
            $r.erro | Should -Be 'ação desconhecida'
        }
        It 'criarPonto com falha simulada ainda devolve exatamente um resultado ok:true' {
            $r = Invoke-Sistema 'criarPonto' @{ simular = @{ falharCriar = $true } }
            $r | Should -Not -BeNullOrEmpty
            $r.ok | Should -BeTrue
            @($Script:UltimaSaida -split "`r?`n" | Where-Object { $_.StartsWith('@@RESULT ') }).Count | Should -Be 1
        }
    }
}
