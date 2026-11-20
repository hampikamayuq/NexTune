BeforeAll {
    . "$PSScriptRoot\..\common.ps1"
    . "$PSScriptRoot\..\diagnostico.ps1"
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
    $t = Join-Path $env:TEMP 'OtimizadorTeste'
    if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'diagnostico.ps1' {
    BeforeEach {
        $t = Join-Path $env:TEMP 'OtimizadorTeste'
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
        It 'acao desconhecida devolve erro' {
            $r = Invoke-Coleta 'xyz' @{}
            $r.ok | Should -BeFalse
            $r.erro | Should -Be 'ação desconhecida'
        }
    }
}
