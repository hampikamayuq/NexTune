BeforeAll {
    . "$PSScriptRoot\..\common.ps1"
    . "$PSScriptRoot\..\reparo.ps1"
    . "$PSScriptRoot\_helpers.ps1"
}

Describe 'reparo.ps1: funcoes puras' {
    Context 'Get-MensagemWinget' {
        It 'traduz os codigos conhecidos e inclui o codigo em hexadecimal' {
            $m = Get-MensagemWinget 0x8A150110L
            $m | Should -Match 'dependência'
            $m | Should -Match '0x8A150110'
            (Get-MensagemWinget 0x8A15010CL) | Should -Match 'fech'
            (Get-MensagemWinget 0x8A150107L) | Should -Match 'internet'
        }
        It 'aceita o codigo como inteiro de 32 bits negativo' {
            (Get-MensagemWinget ([int]-1978334964)) | Should -Match '0x8A15010C'
        }
        It 'codigo desconhecido vira mensagem generica com o codigo, nunca vazia' {
            (Get-MensagemWinget 0x12345678L) | Should -Be 'winget terminou com código 0x12345678'
        }
    }

    Context 'ConvertTo-GuidCompactado' {
        It 'converte para a forma do Windows Installer' {
            ConvertTo-GuidCompactado '{E5281CF4-57AC-41C9-8034-00F8428B8951}' | Should -Be '4FC1825ECA759C140843008F24B89815'
        }
        It 'guid invalido e recusado' {
            { ConvertTo-GuidCompactado 'nao-guid' } | Should -Throw
            { ConvertTo-GuidCompactado '{E5281CF4-57AC-41C9-8034-00F8428B895}' } | Should -Throw
            { ConvertTo-GuidCompactado '' } | Should -Throw
        }
    }

    Context 'Test-ProdutoOrfao' {
        BeforeAll {
            $Script:Pasta = New-PastaTeste 'reparo-orfao'
            $Script:Msi = Join-Path $Script:Pasta 'x.msi'
            Set-Content -LiteralPath $Script:Msi -Value 'msi'
            $Script:Origem = New-PastaTeste 'reparo-origem'
            Set-Content -LiteralPath (Join-Path $Script:Origem 'vc.msi') -Value 'msi'
        }
        It 'cache local existe: nao e orfao' {
            Test-ProdutoOrfao @{ localPackage = $Script:Msi; packageName = 'vc.msi'; origens = @() } | Should -BeFalse
        }
        It 'origem acessivel salva o produto' {
            Test-ProdutoOrfao @{ localPackage = 'C:\nao\existe.msi'; packageName = 'vc.msi'; origens = @($Script:Origem) } | Should -BeFalse
        }
        It 'sem cache e sem origem utilizavel: orfao' {
            Test-ProdutoOrfao @{ localPackage = 'C:\nao\existe.msi'; packageName = 'vc.msi'; origens = @('W:\Data\x64\', ($Script:Origem + 'x')) } | Should -BeTrue
        }
        It 'localPackage vazio e sem origens: orfao, sem excecao' {
            Test-ProdutoOrfao @{ localPackage = ''; packageName = ''; origens = @() } | Should -BeTrue
            Test-ProdutoOrfao @{ localPackage = $null; packageName = $null; origens = $null } | Should -BeTrue
        }
    }
}

Describe 'reparo.ps1: diagnosticar' {
    BeforeAll {
        function Invoke-Reparo {
            param([string]$Acao, $Params = @{})
            $sw = New-Object System.IO.StringWriter
            Set-Saida $sw
            try { Invoke-Acao 'r1' $Acao $Params $true } finally { Set-Saida $null }
            $linhas = @($sw.ToString() -split "`r?`n" | Where-Object { $_.StartsWith('@@RESULT ') })
            if ($linhas.Count -ne 1) { return $null }
            return $linhas[0].Substring(9) | ConvertFrom-Json
        }
        $Script:Pasta2 = New-PastaTeste 'reparo-diag'
        $Script:MsiOk = Join-Path $Script:Pasta2 'ok.msi'
        Set-Content -LiteralPath $Script:MsiOk -Value 'msi'
        $Script:Sim = @{ produtos = @(
                @{ codigo = '{37B34C3A-D825-40AF-BB33-A4DA7A6E4782}'; nome = 'Microsoft Visual C++ 2019 X64 Minimum Runtime - 14.28.29213'; versao = '14.28.29213'; editor = 'Microsoft Corporation'; localPackage = 'C:\Windows\Installer\nao-existe.msi'; packageName = 'vc_runtimeMinimum_x64.msi'; origens = @('W:\Data\VCpp\') },
                @{ codigo = '{11111111-2222-3333-4444-555555555555}'; nome = 'Microsoft Edge WebView2 Runtime'; versao = '1'; editor = 'Microsoft'; localPackage = ''; packageName = ''; origens = @() },
                @{ codigo = '{AAAAAAAA-2222-3333-4444-555555555555}'; nome = 'Programa Saudavel'; versao = '1'; editor = 'X'; localPackage = $Script:MsiOk; packageName = 'ok.msi'; origens = @() }
            )
        }
    }
    AfterAll { Remove-Item -LiteralPath (Join-Path $env:TEMP 'NexTuneTeste') -Recurse -Force -ErrorAction SilentlyContinue }

    It 'devolve so os orfaos, com reparavel certo' {
        $r = Invoke-Reparo 'diagnosticar' @{ simular = $Script:Sim }
        $r.ok | Should -BeTrue
        @($r.dados.produtos).Count | Should -Be 2
        $vc = @($r.dados.produtos | Where-Object { $_.nome -like '*Visual C++*' })[0]
        $vc.reparavel | Should -BeTrue
        $vc.codigo | Should -Be '{37B34C3A-D825-40AF-BB33-A4DA7A6E4782}'
        $wv = @($r.dados.produtos | Where-Object { $_.nome -like '*WebView2*' })[0]
        $wv.reparavel | Should -BeFalse
        $wv.motivo | Should -Not -BeNullOrEmpty
    }
    It 'sem simulacao em teste devolve lista vazia e nao toca no registro real' {
        $r = Invoke-Reparo 'diagnosticar'
        @($r.dados.produtos).Count | Should -Be 0
    }
    It 'acao desconhecida falha' {
        (Invoke-Reparo 'apagar').ok | Should -BeFalse
    }
    It 'ida e volta do GUID compactado' {
        ConvertFrom-GuidCompactado (ConvertTo-GuidCompactado '{E5281CF4-57AC-41C9-8034-00F8428B8951}') | Should -Be '{E5281CF4-57AC-41C9-8034-00F8428B8951}'
    }
}

Describe 'reparo.ps1: reparar' {
    BeforeAll {
        function Invoke-Reparo {
            param([string]$Acao, $Params = @{})
            $sw = New-Object System.IO.StringWriter
            Set-Saida $sw
            try { Invoke-Acao 'r2' $Acao $Params $true } finally { Set-Saida $null }
            $linhas = @($sw.ToString() -split "`r?`n" | Where-Object { $_.StartsWith('@@RESULT ') })
            if ($linhas.Count -ne 1) { return $null }
            return $linhas[0].Substring(9) | ConvertFrom-Json
        }
        function New-RegistroProduto {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
            [CmdletBinding()]
            param([string]$Guid)
            foreach ($k in (Get-ChaveProduto $Guid $true)) {
                $p = ConvertTo-CaminhoRegistro $k
                New-Item -Path $p -Force | Out-Null
                Set-ItemProperty -LiteralPath $p -Name 'Marca' -Value $Guid
            }
        }
        function Get-ProdutoSim {
            param([string]$Guid, [string]$Nome = 'Visual C++ de teste')
            return @{ codigo = $Guid; nome = $Nome; versao = '1'; editor = 'X'; localPackage = 'C:\nao\existe.msi'; packageName = 'x.msi'; origens = @('W:\Data\') }
        }
        $Script:G1 = '{37B34C3A-D825-40AF-BB33-A4DA7A6E4782}'
        $Script:G2 = '{E5281CF4-57AC-41C9-8034-00F8428B8951}'
        $Script:Gweb = '{11111111-2222-3333-4444-555555555555}'
        $Script:Raiz = 'HKCU:\Software\NexTuneTeste\Reparo'
        $Script:BaseQ = (Get-AppPastas $true).Quarentena
    }
    BeforeEach {
        foreach ($p in @($Script:Raiz, (Join-Path (Get-AppPastas $true).Base 'Quarentena'))) {
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
        }
        $null = Get-AppPastas $true
        New-RegistroProduto $Script:G1
        New-RegistroProduto $Script:Gweb
    }
    AfterAll {
        Remove-Item -LiteralPath 'HKCU:\Software\NexTuneTeste' -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $env:TEMP 'NexTuneTeste') -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'remove as chaves do produto, deixa backup .reg na quarentena e o backup restaura' {
        $sim = @{ produtos = @((Get-ProdutoSim $Script:G1)) }
        $r = Invoke-Reparo 'reparar' @{ ids = @($Script:G1); confirmado = $true; simular = $sim }
        $r.ok | Should -BeTrue
        @($r.dados.reparados) | Should -Be @($Script:G1)
        @($r.dados.falhas).Count | Should -Be 0
        foreach ($k in (Get-ChaveProduto $Script:G1 $true)) { (ConvertTo-CaminhoRegistro $k) | Should -Not -Exist }
        $pastaEntrada = Join-Path $Script:BaseQ $r.dados.entrada
        $regs = @(Get-ChildItem -LiteralPath $pastaEntrada -Recurse -Filter 'chave.reg')
        $regs.Count | Should -Be 5
        # restaurar um dos backups devolve a chave com o valor original
        $m = Get-Manifesto $pastaEntrada
        $item = @($m.itens)[0]
        Restore-ChaveRegistro (Join-Path (Join-Path (Join-Path $pastaEntrada 'itens') ([string]$item.n)) 'chave.reg') $item.origem $true
        (Get-ItemProperty -LiteralPath (ConvertTo-CaminhoRegistro $item.origem)).Marca | Should -Be $Script:G1
    }
    It 'guid invalido e recusado sem tocar em nada' {
        $r = Invoke-Reparo 'reparar' @{ ids = @('HKLM\SOFTWARE'); confirmado = $true; simular = @{ produtos = @() } }
        @($r.dados.reparados).Count | Should -Be 0
        @($r.dados.falhas)[0].erro | Should -Match 'GUID inválido'
        (ConvertTo-CaminhoRegistro (Get-ChaveProduto $Script:G1 $true)[0]) | Should -Exist
    }
    It 'falha no backup nao remove nada daquele produto' {
        $sim = @{ produtos = @((Get-ProdutoSim $Script:G1)); falharBackup = $true }
        $r = Invoke-Reparo 'reparar' @{ ids = @($Script:G1); confirmado = $true; simular = $sim }
        @($r.dados.reparados).Count | Should -Be 0
        @($r.dados.falhas).Count | Should -Be 1
        foreach ($k in (Get-ChaveProduto $Script:G1 $true)) { (ConvertTo-CaminhoRegistro $k) | Should -Exist }
    }
    It 'produto saudavel (ja nao esta quebrado) e recusado' {
        $msi = Join-Path (New-PastaTeste 'reparo-sa') 'x.msi'
        Set-Content -LiteralPath $msi -Value 'msi'
        $p = Get-ProdutoSim $Script:G1; $p.localPackage = $msi
        $r = Invoke-Reparo 'reparar' @{ ids = @($Script:G1); confirmado = $true; simular = @{ produtos = @($p) } }
        @($r.dados.reparados).Count | Should -Be 0
        @($r.dados.falhas)[0].erro | Should -Match 'já não está quebrado'
        (ConvertTo-CaminhoRegistro (Get-ChaveProduto $Script:G1 $true)[0]) | Should -Exist
    }
    It 'produto protegido (WebView2) e recusado com o motivo' {
        $sim = @{ produtos = @((Get-ProdutoSim $Script:Gweb 'Microsoft Edge WebView2 Runtime')) }
        $r = Invoke-Reparo 'reparar' @{ ids = @($Script:Gweb); confirmado = $true; simular = $sim }
        @($r.dados.reparados).Count | Should -Be 0
        @($r.dados.falhas)[0].erro | Should -Match 'dependem dele'
        (ConvertTo-CaminhoRegistro (Get-ChaveProduto $Script:Gweb $true)[0]) | Should -Exist
    }
    It 'sem confirmacao recusa tudo' {
        $r = Invoke-Reparo 'reparar' @{ ids = @($Script:G1); simular = @{ produtos = @((Get-ProdutoSim $Script:G1)) } }
        $r.ok | Should -BeFalse
        (ConvertTo-CaminhoRegistro (Get-ChaveProduto $Script:G1 $true)[0]) | Should -Exist
    }
}
