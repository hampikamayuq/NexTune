BeforeAll {
    . "$PSScriptRoot\..\common.ps1"
    . "$PSScriptRoot\..\diagnostico.ps1"
    . "$PSScriptRoot\_helpers.ps1"
    $Script:Regras = Get-RegrasPerfil (Join-Path $PSScriptRoot '..\..\data')

    # Executa uma acao do modulo capturando o protocolo; devolve o @@RESULT (objeto) ou $null.
    function Invoke-Coleta {
        param([string]$Acao = 'coletar', $Params = @{})
        $sw = New-Object System.IO.StringWriter
        Set-Saida $sw
        try { Invoke-Acao 'a1' $Acao $Params $true } finally { Set-Saida $null }
        $Script:UltimaSaida = $sw.ToString()
        $linhas = @($sw.ToString() -split "`r?`n" | Where-Object { $_.StartsWith('@@RESULT ') })
        if ($linhas.Count -ne 1) { return $null }
        return $linhas[0].Substring(9) | ConvertFrom-Json
    }
    function Get-BrutoFalso {
        param($Ram, $Nucleos, $Gpu, $Media, $Bus = $null)
        return @{ ramGb = $Ram; nucleos = $Nucleos; gpuDedicada = $Gpu; discoSistemaMediaType = $Media; discoSistemaBusType = $Bus }
    }
}

AfterAll {
    $t = Join-Path $env:TEMP 'NexTuneTeste'
    if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'diagnostico.ps1' {
    BeforeEach {
        $t = Join-Path $env:TEMP 'NexTuneTeste'
        if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Context 'Get-ClasseEDisco' {
        It 'pouca RAM e HDD: basico/hdd' {
            $r = Get-ClasseEDisco (Get-BrutoFalso 4 4 $false 'HDD') $Script:Regras
            $r.classe | Should -Be 'basico'
            $r.disco | Should -Be 'hdd'
        }
        It '8 GB e SSD: medio/ssd' {
            $r = Get-ClasseEDisco (Get-BrutoFalso 8 4 $false 'SSD') $Script:Regras
            $r.classe | Should -Be 'medio'
            $r.disco | Should -Be 'ssd'
        }
        It 'gamer com HDD: duas dimensoes' {
            $r = Get-ClasseEDisco (Get-BrutoFalso 16 8 $true 'HDD') $Script:Regras
            $r.classe | Should -Be 'gamer'
            $r.disco | Should -Be 'hdd'
        }
        It 'basico prevalece sobre gamer' {
            $r = Get-ClasseEDisco (Get-BrutoFalso 16 2 $true 'SSD') $Script:Regras
            $r.classe | Should -Be 'basico'
        }
        It 'Unspecified com NVMe e ssd' {
            $r = Get-ClasseEDisco (Get-BrutoFalso 32 8 $true 'Unspecified' 'NVMe') $Script:Regras
            $r.disco | Should -Be 'ssd'
        }
        It 'MediaType nulo e hdd (conservador)' {
            $r = Get-ClasseEDisco (Get-BrutoFalso 8 4 $false $null) $Script:Regras
            $r.disco | Should -Be 'hdd'
        }
    }

    Context 'Get-BrutoSimulado' {
        It 'devolve o objeto simulado em modo de teste' {
            $b = Get-BrutoSimulado @{ simular = @{ ramGb = 2 } } $true
            $b.ramGb | Should -Be 2
        }
        It 'ignora simular fora do modo de teste' {
            Get-BrutoSimulado @{ simular = @{ ramGb = 2 } } $false | Should -BeNullOrEmpty
        }
    }

    Context 'coletar' {
        It 'simulacao basico/hdd grava perfil.json e preserva perfil manual' {
            $sim = @{ ramGb = 4; nucleos = 2; gpuDedicada = $false; discoSistemaMediaType = 'HDD'; discoSistemaBusType = 'SATA' }
            $r = Invoke-Coleta 'coletar' @{ simular = $sim }
            $r.ok | Should -BeTrue
            (Get-Perfil $true).classe | Should -Be 'basico'
            Set-Perfil @{ classe = 'gamer'; disco = 'ssd'; manual = $true } $true
            $r2 = Invoke-Coleta 'coletar' @{ simular = $sim }
            $r2.ok | Should -BeTrue
            $p = Get-Perfil $true
            $p.classe | Should -Be 'gamer'
            $p.disco | Should -Be 'ssd'
            $p.manual | Should -BeTrue
            $r2.dados.perfil.classe | Should -Be 'gamer'
        }
        It 'forcarPerfil grava manual=true e persiste em coletas seguintes' {
            $r = Invoke-Coleta 'coletar' @{ forcarPerfil = @{ classe = 'gamer'; disco = 'ssd' } }
            $r.ok | Should -BeTrue
            $r.dados.perfil.classe | Should -Be 'gamer'
            $p = Get-Perfil $true
            $p.classe | Should -Be 'gamer'
            $p.disco | Should -Be 'ssd'
            $p.manual | Should -BeTrue
            $r2 = Invoke-Coleta 'coletar' @{}
            $r2.ok | Should -BeTrue
            $r2.dados.perfil.classe | Should -Be 'gamer'
            $r2.dados.perfil.disco | Should -Be 'ssd'
            $r2.dados.cpu.nucleos | Should -BeGreaterThan 0
            $p2 = Get-Perfil $true
            $p2.classe | Should -Be 'gamer'
            $p2.manual | Should -BeTrue
        }
        It 'resetarPerfil volta do perfil manual ao detectado automaticamente' {
            $sim = @{ ramGb = 4; nucleos = 2; gpuDedicada = $false; discoSistemaMediaType = 'HDD'; discoSistemaBusType = 'SATA' }
            (Invoke-Coleta 'coletar' @{ forcarPerfil = @{ classe = 'gamer'; disco = 'ssd' } }).ok | Should -BeTrue
            (Get-Perfil $true).manual | Should -BeTrue
            $r = Invoke-Coleta 'coletar' @{ simular = $sim; resetarPerfil = $true }
            $r.ok | Should -BeTrue
            $r.dados.perfil.classe | Should -Be 'basico'
            $r.dados.perfil.disco | Should -Be 'hdd'
            $r.dados.perfil.manual | Should -BeFalse
            $p = Get-Perfil $true
            $p.classe | Should -Be 'basico'
            $p.manual | Should -BeFalse
        }
        It 'resetarPerfil so vale como booleano e nao combina com forcarPerfil' {
            $sim = @{ ramGb = 4; nucleos = 2; gpuDedicada = $false; discoSistemaMediaType = 'HDD'; discoSistemaBusType = 'SATA' }
            Set-Perfil @{ classe = 'gamer'; disco = 'ssd'; manual = $true } $true
            (Invoke-Coleta 'coletar' @{ simular = $sim; resetarPerfil = 'true' }).dados.perfil.classe | Should -Be 'gamer'
            $r = Invoke-Coleta 'coletar' @{ resetarPerfil = $true; forcarPerfil = @{ classe = 'medio'; disco = 'ssd' } }
            $r.ok | Should -BeFalse
            (Get-Perfil $true).classe | Should -Be 'gamer'
        }
        It 'forcarPerfil invalido nao grava valores fora do conjunto' {
            $r = Invoke-Coleta 'coletar' @{ forcarPerfil = @{ classe = 'xyz'; disco = 'ssd' } }
            $r.ok | Should -BeFalse
            Get-Perfil $true | Should -BeNullOrEmpty
        }
        It 'coleta real devolve estrutura esperada' {
            $r = Invoke-Coleta 'coletar' @{}
            $r.ok | Should -BeTrue
            $d = $r.dados
            $d.cpu.nucleos | Should -BeGreaterThan 0
            $d.ram.totalBytes | Should -BeGreaterThan 0
            @($d.discos).Count | Should -BeGreaterOrEqual 1
            @($d.discos | Where-Object { $_.sistema -eq $true }).Count | Should -Be 1
            $Script:UltimaSaida | Should -Match '"discos":\[\{'
            $Script:UltimaSaida | Should -Match '"unidades":\[\{'
            $d.perfil.classe | Should -BeIn @('basico', 'medio', 'gamer')
            $d.perfil.disco | Should -BeIn @('hdd', 'ssd')
            $d.sistema.inicioRapido | Should -BeOfType [bool]
            @($d.unidades).Count | Should -BeGreaterOrEqual 1
            $d.servicos.PSObject.Properties.Name | Should -Contain 'sysmain'
            $d.servicos.PSObject.Properties.Name | Should -Contain 'wsearch'
            (Get-Perfil $true).classe | Should -Be $d.perfil.classe
        }
        It 'serializa arrays mesmo com um unico elemento' {
            $sim = @{ ramGb = 8; nucleos = 4; gpuDedicada = $false; discoSistemaMediaType = 'SSD'; discoSistemaBusType = 'SATA' }
            $sw = New-Object System.IO.StringWriter
            Set-Saida $sw
            try { Invoke-Acao 'a1' 'coletar' @{ simular = $sim } $true } finally { Set-Saida $null }
            $sw.ToString() | Should -Match '"discos":\['
            $sw.ToString() | Should -Match '"gpus":\['
            $sw.ToString() | Should -Match '"unidades":\['
        }
        It 'forcarPerfil normaliza maiusculas antes de gravar' {
            $r = Invoke-Coleta 'coletar' @{ forcarPerfil = @{ classe = 'GAMER'; disco = 'SSD' } }
            $r.ok | Should -BeTrue
            $p = Get-Perfil $true
            $p.classe | Should -BeExactly 'gamer'
            $p.disco | Should -BeExactly 'ssd'
            $p.manual | Should -BeTrue
            $r.dados.perfil.classe | Should -BeExactly 'gamer'
        }
        It 'forcarPerfil com disco nvme ou objeto vazio e rejeitado sem gravar' {
            (Invoke-Coleta 'coletar' @{ forcarPerfil = @{ classe = 'gamer'; disco = 'nvme' } }).ok | Should -BeFalse
            (Invoke-Coleta 'coletar' @{ forcarPerfil = @{} }).ok | Should -BeFalse
            Get-Perfil $true | Should -BeNullOrEmpty
        }
        It 'perfil existente com caixa inesperada nao e tratado como manual' {
            Set-Perfil @{ classe = 'GAMER'; disco = 'SSD'; manual = $true } $true
            $sim = @{ ramGb = 4; nucleos = 2; gpuDedicada = $false; discoSistemaMediaType = 'HDD'; discoSistemaBusType = 'SATA' }
            (Invoke-Coleta 'coletar' @{ simular = $sim }).ok | Should -BeTrue
            $p = Get-Perfil $true
            $p.classe | Should -BeExactly 'basico'
            $p.manual | Should -BeFalse
        }
        It 'falha inesperada ainda devolve exatamente um resultado ok:false' {
            $vazio = New-PastaTeste 'semperfis'
            $sim = @{ ramGb = 4; nucleos = 2; gpuDedicada = $false; discoSistemaMediaType = 'HDD' }
            $r = Invoke-Coleta 'coletar' @{ simular = $sim; dataDir = $vazio }
            $r | Should -Not -BeNullOrEmpty
            $r.ok | Should -BeFalse
            $r.erro | Should -Match 'falhou'
        }
        It 'acao desconhecida devolve erro' {
            $r = Invoke-Coleta 'xyz' @{}
            $r.ok | Should -BeFalse
            $r.erro | Should -Be 'ação desconhecida'
        }
    }

    Context 'reinicios (classificacao pura)' {
        BeforeAll {
            function Get-EvFalso {
                param([int]$Id, [string]$Data, [string]$Provedor = 'Microsoft-Windows-Kernel-Power', [string[]]$Props = @())
                return @{ Id = $Id; Data = [datetime]::Parse($Data, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind); Provedor = $Provedor; Props = $Props }
            }
            $Script:Wer = 'Microsoft-Windows-WER-SystemErrorReporting'
        }
        It 'tabela de telas azuis tem os 14 codigos, todos com texto' {
            $Script:TelasAzuis.Count | Should -Be 14
            foreach ($k in $Script:TelasAzuis.Keys) { $k | Should -Match '^0x[0-9a-f]{8}$'; $Script:TelasAzuis[$k] | Should -Not -BeNullOrEmpty }
        }
        It '41 sem codigo vira queda' {
            $r = @(Get-ClassificacaoReinicio @(Get-EvFalso 41 '2026-11-01T10:00:00Z' -Props @('0')))
            $r.Count | Should -Be 1
            $r[0].tipo | Should -Be 'queda'
            $r[0].motivo | Should -Match 'energia'
            $r[0].Contains('codigo') | Should -BeFalse
        }
        It '41 com codigo e sem 1001 vira tela azul' {
            $r = @(Get-ClassificacaoReinicio @(Get-EvFalso 41 '2026-11-01T10:00:00Z' -Props @('278')))
            $r[0].tipo | Should -Be 'telaAzul'
            $r[0].codigo | Should -Be '0x00000116'
        }
        It '41 + 1001 de bugcheck juntos viram uma tela azul so, com o codigo do 1001' {
            $r = @(Get-ClassificacaoReinicio @(
                    (Get-EvFalso 41 '2026-11-01T10:05:00Z' -Props @('0')),
                    (Get-EvFalso 1001 '2026-11-01T10:06:00Z' $Script:Wer @('0x00000116 (0x1, 0x2, 0x3, 0x4)'))))
            $r.Count | Should -Be 1
            $r[0].tipo | Should -Be 'telaAzul'
            $r[0].codigo | Should -Be '0x00000116'
            $r[0].motivo | Should -Match 'placa de vídeo'
        }
        It '1001 sozinho com codigo vira tela azul' {
            $r = @(Get-ClassificacaoReinicio @(Get-EvFalso 1001 '2026-11-01T10:06:00Z' $Script:Wer @('0x0000001A (0x1)')))
            $r[0].tipo | Should -Be 'telaAzul'
            $r[0].codigo | Should -Be '0x0000001a'
            $r[0].motivo | Should -Match 'memória RAM'
        }
        It '1001 de outro provedor (relatorio de erro comum) e ignorado' {
            @(Get-ClassificacaoReinicio @(Get-EvFalso 1001 '2026-11-01T10:06:00Z' 'Windows Error Reporting' @('x'))).Count | Should -Be 0
        }
        It 'codigo desconhecido vira Tela azul (codigo X)' {
            $r = @(Get-ClassificacaoReinicio @(Get-EvFalso 1001 '2026-11-01T10:06:00Z' $Script:Wer @('0x00000ABC (0x1)')))
            $r[0].motivo | Should -Match '^Tela azul \(código 0x00000abc\)'
        }
        It '1074 de usuario: reinicio ou desligamento conforme o tipo' {
            $props = @('C:\Windows\Explorer.EXE (PC)', 'PC', 'Outro (planejado)', '0x80020002', 'reiniciar', '', 'PC\ana')
            $r = @(Get-ClassificacaoReinicio @(Get-EvFalso 1074 '2026-11-01T10:00:00Z' -Props $props))
            $r[0].tipo | Should -Be 'reinicio'
            $r[0].quem | Should -Be 'Você'
            $props[4] = 'power off'
            $r = @(Get-ClassificacaoReinicio @(Get-EvFalso 1074 '2026-11-01T10:00:00Z' -Props $props))
            $r[0].tipo | Should -Be 'desligamento'
            $props[4] = 'desligar'
            @(Get-ClassificacaoReinicio @(Get-EvFalso 1074 '2026-11-01T10:00:00Z' -Props $props))[0].tipo | Should -Be 'desligamento'
        }
        It '1074 do Windows Update: reinicio normal' {
            $props = @('C:\Windows\servicing\TrustedInstaller.exe (PC)', 'PC', 'Instalação', '0x80020010', 'restart', '', 'NT AUTHORITY\SYSTEM')
            $r = @(Get-ClassificacaoReinicio @(Get-EvFalso 1074 '2026-11-01T10:00:00Z' -Props $props))
            $r[0].tipo | Should -Be 'reinicio'
            $r[0].quem | Should -Be 'Windows Update'
            $r[0].motivo | Should -Match 'atualizações'
        }
        It '1074 de programa (conta do sistema): reinicio por programa' {
            $props = @('C:\Program Files\Setup\instalador.exe (PC)', 'PC', 'Instalação', '0x80020010', 'restart', '', 'NT AUTHORITY\SISTEMA')
            $r = @(Get-ClassificacaoReinicio @(Get-EvFalso 1074 '2026-11-01T10:00:00Z' -Props $props))
            $r[0].tipo | Should -Be 'reinicio'
            $r[0].quem | Should -Be 'Programa instalador'
        }
        It '6008 sozinho vira queda; junto de um 41 nao duplica' {
            $r = @(Get-ClassificacaoReinicio @(Get-EvFalso 6008 '2026-11-01T10:00:00Z' 'EventLog' @('x')))
            $r[0].tipo | Should -Be 'queda'
            $r = @(Get-ClassificacaoReinicio @((Get-EvFalso 41 '2026-11-01T10:00:00Z' -Props @('0')), (Get-EvFalso 6008 '2026-11-01T10:03:00Z' 'EventLog' @('x'))))
            $r.Count | Should -Be 1
        }
        It 'ordena do mais recente e limita a 50' {
            $evs = @(1..60 | ForEach-Object { Get-EvFalso 41 ([datetime]'2026-10-01T00:00:00Z').AddHours($_ * 2).ToString('o') -Props @('0') })
            $r = @(Get-ClassificacaoReinicio $evs)
            $r.Count | Should -Be 50
            [datetime]$r[0].data | Should -BeGreaterThan ([datetime]$r[49].data)
        }
    }

    Context 'Invoke-Acao reinicios' {
        It 'le simular.eventos e devolve o formato combinado; nunca le o log real em teste' {
            Mock Get-WinEvent { throw 'nao deveria ler o log real' }
            $sim = @{ eventos = @(
                    @{ id = 41; data = '2026-11-01T10:00:00Z'; provedor = 'Microsoft-Windows-Kernel-Power'; props = @('0') },
                    @{ id = 1001; data = '2026-11-02T10:00:00Z'; provedor = 'Microsoft-Windows-WER-SystemErrorReporting'; props = @('0x00000116 (0x1)') }) }
            $r = Invoke-Coleta 'reinicios' @{ simular = $sim }
            $r.ok | Should -BeTrue
            @($r.dados.eventos).Count | Should -Be 2
            $r.dados.eventos[0].tipo | Should -Be 'telaAzul'
            $r.dados.eventos[0].codigo | Should -Be '0x00000116'
            $r.dados.eventos[1].tipo | Should -Be 'queda'
            Should -Invoke Get-WinEvent -Times 0 -Exactly
        }
        It 'sem simular em teste: lista vazia, sem ler o log' {
            Mock Get-WinEvent { throw 'nao deveria ler o log real' }
            $r = Invoke-Coleta 'reinicios' @{}
            $r.ok | Should -BeTrue
            @($r.dados.eventos).Count | Should -Be 0
            Should -Invoke Get-WinEvent -Times 0 -Exactly
        }
    }
}
