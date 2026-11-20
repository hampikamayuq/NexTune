BeforeAll {
    . "$PSScriptRoot\..\common.ps1"
    . "$PSScriptRoot\..\quarentena.ps1"
    . "$PSScriptRoot\_helpers.ps1"
    $Script:Raiz = Join-Path $env:TEMP 'NexTuneTeste\quarentena'   # origem dos itens de teste
    $Script:Quar = (Get-AppPastas $true).Quarentena
    $Script:ChaveBase = 'HKCU:\Software\NexTuneTeste'

    function Invoke-Q {
        param([string]$Acao, $Params = @{})
        $sw = New-Object System.IO.StringWriter
        Set-Saida $sw
        try { Invoke-Acao 'q1' $Acao $Params $true } finally { Set-Saida $null }
        $Script:UltimaSaida = $sw.ToString()
        $linhas = @($sw.ToString() -split "`r?`n" | Where-Object { $_.StartsWith('@@RESULT ') })
        if ($linhas.Count -ne 1) { return $null }
        return $linhas[0].Substring(9) | ConvertFrom-Json
    }
    function New-ArquivoTeste {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param([string]$Caminho, [int]$Bytes = 10)
        $pai = Split-Path -Parent $Caminho
        if (-not (Test-Path -LiteralPath $pai)) { New-Item -ItemType Directory -Path $pai -Force | Out-Null }
        [IO.File]::WriteAllBytes($Caminho, (New-Object byte[] $Bytes))
    }
    function New-EntradaTeste {
        # Um arquivo (100 bytes) e uma pasta com um arquivo dentro (50 bytes), ja fechados numa entrada.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param([string]$Nome = 'e1')
        $arq = Join-Path $Script:Raiz "$Nome\arquivo.txt"
        $pasta = Join-Path $Script:Raiz "$Nome\pasta"
        New-ArquivoTeste $arq 100
        New-ArquivoTeste (Join-Path $pasta 'dentro.txt') 50
        $e = New-EntradaQuarentena -Modulo 'teste' -Descricao "entrada $Nome" -Teste $true
        Add-ItemQuarentena -Entrada $e -Caminho $arq | Out-Null
        Add-ItemQuarentena -Entrada $e -Caminho $pasta | Out-Null
        return (Complete-EntradaQuarentena -Entrada $e)
    }
    function Get-PastaDaEntrada { param([string]$Id) return (Join-Path $Script:Quar $Id) }
    function Get-ManifestoTeste {
        param([string]$Id)
        return (Get-Content -LiteralPath (Join-Path (Get-PastaDaEntrada $Id) 'manifesto.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    function Set-ManifestoTeste {
        # Reescreve o manifesto depois de $Alterar mexer nele (data normalizada em ISO 8601 UTC).
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param([string]$Id, [scriptblock]$Alterar)
        $m = Get-ManifestoTeste $Id
        & $Alterar $m
        $m.data = (ConvertTo-DataUtc $m.data).ToString('o')
        $json = $m | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText((Join-Path (Get-PastaDaEntrada $Id) 'manifesto.json'), $json, (New-Object System.Text.UTF8Encoding $false))
    }
    function Get-IntervaloDia {
        # Diferenca em dias entre dois valores vindos do JSON (string ISO ou [DateTime]), comparados em UTC.
        param($Inicio, $Fim)
        return (([DateTime]$Fim).ToUniversalTime() - ([DateTime]$Inicio).ToUniversalTime()).TotalDays
    }
}

AfterAll {
    $t = Join-Path $env:TEMP 'NexTuneTeste'
    if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath 'HKCU:\Software\NexTuneTeste' -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'quarentena.ps1' {
    BeforeEach {
        foreach ($p in @($Script:Quar, $Script:Raiz)) {
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
            New-Item -ItemType Directory -Path $p -Force | Out-Null
        }
        Remove-Item -LiteralPath $Script:ChaveBase -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'funcoes puras' {
        It 'Test-IdQuarentena aceita so o formato yyyyMMdd-HHmmss-xxxx' {
            Test-IdQuarentena '20261120-143022-0abf' | Should -BeTrue
            Test-IdQuarentena '20261120-143022-0ABF' | Should -BeFalse
            Test-IdQuarentena '20261120-143022-0abf\..' | Should -BeFalse
            Test-IdQuarentena '..' | Should -BeFalse
            Test-IdQuarentena $null | Should -BeFalse
            Test-IdQuarentena 7 | Should -BeFalse
        }
        It 'ConvertTo-CaminhoRegistro traduz a forma do reg.exe para a do provedor' {
            ConvertTo-CaminhoRegistro 'HKCU\Software\X' | Should -Be 'Registry::HKEY_CURRENT_USER\Software\X'
            ConvertTo-CaminhoRegistro 'HKLM\SOFTWARE\Y\' | Should -Be 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Y'
            ConvertTo-CaminhoRegistro 'HKEY_CURRENT_USER\Software\Z' | Should -Be 'Registry::HKEY_CURRENT_USER\Software\Z'
            Test-ChaveRegistro 'C:\Temp\x' | Should -BeFalse
            Test-ChaveRegistro 'HKCU' | Should -BeFalse
            Test-ChaveRegistro '' | Should -BeFalse
            { ConvertTo-CaminhoRegistro 'C:\Temp\x' } | Should -Throw
        }
        It 'Test-ChaveTeste aceita so chaves sob HKCU\Software\NexTuneTeste' {
            Test-ChaveTeste 'HKCU\Software\NexTuneTeste\Abc' | Should -BeTrue
            Test-ChaveTeste 'hkey_current_user\software\nextuneteste\Abc' | Should -BeTrue
            Test-ChaveTeste 'HKCU\Software\NexTuneTeste' | Should -BeFalse
            Test-ChaveTeste 'HKCU\Software\NexTuneTesteOutra\Abc' | Should -BeFalse
            Test-ChaveTeste 'HKLM\Software\NexTuneTeste\Abc' | Should -BeFalse
        }
        It 'ConvertTo-DataUtc aceita string ISO e DateTime' {
            $d = ConvertTo-DataUtc '2026-11-20T14:03:22.1234567Z'
            $d.Kind | Should -Be ([DateTimeKind]::Utc)
            $d.Hour | Should -Be 14
            (ConvertTo-DataUtc ([DateTime]'2026-11-20T14:03:22Z')).Hour | Should -Be 14
            ConvertTo-DataUtc 'ontem' | Should -BeNullOrEmpty
            ConvertTo-DataUtc $null | Should -BeNullOrEmpty
        }
    }

    Context 'mover para a quarentena' {
        It 'mover arquivo e pasta cria manifesto com 2 itens e a origem desaparece' {
            $e = New-EntradaTeste 'm1'
            $e | Should -Not -BeNullOrEmpty
            Test-IdQuarentena $e.id | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $Script:Raiz 'm1\arquivo.txt') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $Script:Raiz 'm1\pasta') | Should -BeFalse
            $pasta = Get-PastaDaEntrada $e.id
            Test-Path -LiteralPath (Join-Path $pasta 'manifesto.json') | Should -BeTrue
            (Get-Item -LiteralPath (Join-Path $pasta 'itens\1\arquivo.txt')).Length | Should -Be 100
            (Get-Item -LiteralPath (Join-Path $pasta 'itens\2\pasta\dentro.txt')).Length | Should -Be 50
            $m = Get-ManifestoTeste $e.id
            $m.id | Should -Be $e.id
            $m.modulo | Should -Be 'teste'
            $m.descricao | Should -Be 'entrada m1'
            @($m.itens).Count | Should -Be 2
            $m.itens[0].n | Should -Be 1
            $m.itens[0].tipo | Should -Be 'arquivo'
            $m.itens[0].nome | Should -Be 'arquivo.txt'
            $m.itens[0].origem | Should -Match 'm1\\arquivo\.txt$'
            $m.itens[1].n | Should -Be 2
            $m.itens[1].tipo | Should -Be 'pasta'
            $m.itens[1].nome | Should -Be 'pasta'
            # manifesto em UTF-8 sem BOM
            $b = [IO.File]::ReadAllBytes((Join-Path $pasta 'manifesto.json'))
            $b[0] | Should -Be ([byte][char]'{')
        }
        It 'ids nao se repetem e seguem o formato' {
            $a = New-EntradaTeste 'i1'
            $b = New-EntradaTeste 'i2'
            $a.id | Should -Not -Be $b.id
            $a.id | Should -Match '^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$'
            $b.id | Should -Match '^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$'
        }
        It 'Complete-EntradaQuarentena sem itens apaga a pasta e devolve $null' {
            $e = New-EntradaQuarentena -Modulo 'teste' -Descricao 'vazia' -Teste $true
            Test-Path -LiteralPath $e.pasta | Should -BeTrue
            $r = Complete-EntradaQuarentena -Entrada $e
            $r | Should -BeNullOrEmpty
            Test-Path -LiteralPath $e.pasta | Should -BeFalse
        }
        It 'New-EntradaQuarentena sem modulo lanca' {
            { New-EntradaQuarentena -Modulo '' -Descricao 'x' -Teste $true } | Should -Throw
        }
        It 'caminho protegido lanca e nada e movido' {
            $e = New-EntradaQuarentena -Modulo 'teste' -Descricao 'protegido' -Teste $true
            { Add-ItemQuarentena -Entrada $e -Caminho "$env:windir\System32\x" } | Should -Throw -ExpectedMessage '*protegido*'
            { Add-ItemQuarentena -Entrada $e -Caminho $env:windir } | Should -Throw -ExpectedMessage '*protegido*'
            $e.itens.Count | Should -Be 0
            @(Get-ChildItem -LiteralPath (Join-Path $e.pasta 'itens') -Force).Count | Should -Be 0
            Complete-EntradaQuarentena -Entrada $e | Should -BeNullOrEmpty
        }
        It 'junction como item e recusada e o alvo fica intacto' {
            $alvo = Join-Path $env:TEMP 'NexTuneTeste\foraJn'
            New-ArquivoTeste (Join-Path $alvo 'preciso.txt') 10
            $j = Join-Path $Script:Raiz 'jn'
            New-Juncao $j $alvo
            try {
                $e = New-EntradaQuarentena -Modulo 'teste' -Descricao 'junction' -Teste $true
                { Add-ItemQuarentena -Entrada $e -Caminho $j } | Should -Throw -ExpectedMessage '*junção*'
                $e.itens.Count | Should -Be 0
                Test-Path -LiteralPath $j | Should -BeTrue
                Test-Path -LiteralPath (Join-Path $alvo 'preciso.txt') | Should -BeTrue
                @(Get-ChildItem -LiteralPath (Join-Path $e.pasta 'itens') -Force).Count | Should -Be 0
            } finally { Remove-Juncao $j }
        }
        It 'caminho inexistente lanca' {
            $e = New-EntradaQuarentena -Modulo 'teste' -Descricao 'x' -Teste $true
            { Add-ItemQuarentena -Entrada $e -Caminho (Join-Path $Script:Raiz 'nao-existe.txt') } | Should -Throw
            $e.itens.Count | Should -Be 0
        }
    }

    Context 'listar' {
        It 'devolve a entrada com itens:2, tamanhoBytes > 0 e venceEm = data + 7 dias' {
            $e = New-EntradaTeste 'l1'
            $r = Invoke-Q 'listar'
            $r.ok | Should -BeTrue
            $r.dados.diasPadrao | Should -Be 7
            @($r.dados.entradas).Count | Should -Be 1
            $x = $r.dados.entradas[0]
            $x.id | Should -Be $e.id
            $x.modulo | Should -Be 'teste'
            $x.descricao | Should -Be 'entrada l1'
            $x.itens | Should -Be 2
            $x.tamanhoBytes | Should -BeGreaterThan 150   # 100 + 50 + manifesto
            Get-IntervaloDia $x.data $x.venceEm | Should -Be 7
        }
        It 'quarentena vazia devolve lista vazia' {
            $r = Invoke-Q 'listar'
            $r.ok | Should -BeTrue
            @($r.dados.entradas).Count | Should -Be 0
            $Script:UltimaSaida | Should -Match '"entradas":\[\]'
        }
        It 'ordena da mais nova para a mais antiga' {
            $a = New-EntradaTeste 'o1'
            $b = New-EntradaTeste 'o2'
            Set-ManifestoTeste $a.id { param($m) $m.data = (Get-Date).AddDays(-1).ToUniversalTime().ToString('o') }
            @((Invoke-Q 'listar').dados.entradas | ForEach-Object { $_.id }) | Should -Be @($b.id, $a.id)
            Set-ManifestoTeste $b.id { param($m) $m.data = (Get-Date).AddDays(-3).ToUniversalTime().ToString('o') }
            @((Invoke-Q 'listar').dados.entradas | ForEach-Object { $_.id }) | Should -Be @($a.id, $b.id)
        }
        It 'aceita dias de 1 a 90 e recusa fora disso' {
            New-EntradaTeste 'd1' | Out-Null
            $x = (Invoke-Q 'listar' @{ dias = 30 }).dados.entradas[0]
            Get-IntervaloDia $x.data $x.venceEm | Should -Be 30
            (Invoke-Q 'listar' @{ dias = 0 }).ok | Should -BeFalse
            (Invoke-Q 'listar' @{ dias = 91 }).ok | Should -BeFalse
            (Invoke-Q 'listar' @{ dias = '7' }).ok | Should -BeFalse
            (Invoke-Q 'listar' @{ dias = 7.5 }).ok | Should -BeFalse
        }
        It 'ignora pastas cujo nome nao e um id' {
            New-Item -ItemType Directory -Path (Join-Path $Script:Quar 'lixo') -Force | Out-Null
            New-EntradaTeste 'n1' | Out-Null
            @((Invoke-Q 'listar').dados.entradas).Count | Should -Be 1
        }
        It 'manifesto corrompido aparece como ilegivel, nao vence por data forjada e pode ser purgado' {
            $e = New-EntradaTeste 'c1'
            [IO.File]::WriteAllText((Join-Path (Get-PastaDaEntrada $e.id) 'manifesto.json'), '{ isto não é json', (New-Object System.Text.UTF8Encoding $false))
            $r = Invoke-Q 'listar'
            $r.ok | Should -BeTrue
            @($r.dados.entradas).Count | Should -Be 1
            $x = $r.dados.entradas[0]
            $x.id | Should -Be $e.id
            $x.descricao | Should -Be '(manifesto ilegível)'
            $x.itens | Should -Be 0
            $x.tamanhoBytes | Should -BeGreaterThan 0
            Get-IntervaloDia $x.data $x.venceEm | Should -Be 7
            # restaurar nao da: falha explicita, nada se move
            $r = Invoke-Q 'restaurar' @{ ids = @($e.id) }
            $r.ok | Should -BeTrue
            @($r.dados.falhas).Count | Should -Be 1
            Test-Path -LiteralPath (Join-Path (Get-PastaDaEntrada $e.id) 'itens\1\arquivo.txt') | Should -BeTrue
            # pasta criada hoje: nao vence
            @((Invoke-Q 'purgarVencidos' @{ dias = 7 }).dados.removidas).Count | Should -Be 0
            Test-Path -LiteralPath (Get-PastaDaEntrada $e.id) | Should -BeTrue
            # mas pode ser purgada
            $r = Invoke-Q 'purgar' @{ ids = @($e.id); confirmado = $true }
            $r.ok | Should -BeTrue
            @($r.dados.removidas) | Should -Be @($e.id)
            Test-Path -LiteralPath (Get-PastaDaEntrada $e.id) | Should -BeFalse
        }
    }

    Context 'restaurar' {
        It 'devolve tudo a origem e remove a entrada' {
            $e = New-EntradaTeste 'r1'
            $r = Invoke-Q 'restaurar' @{ ids = @($e.id) }
            $r.ok | Should -BeTrue
            @($r.dados.restauradas) | Should -Be @($e.id)
            @($r.dados.conflitos).Count | Should -Be 0
            @($r.dados.falhas).Count | Should -Be 0
            $Script:UltimaSaida | Should -Match '"conflitos":\[\]'
            $Script:UltimaSaida | Should -Match '"falhas":\[\]'
            (Get-Item -LiteralPath (Join-Path $Script:Raiz 'r1\arquivo.txt')).Length | Should -Be 100
            (Get-Item -LiteralPath (Join-Path $Script:Raiz 'r1\pasta\dentro.txt')).Length | Should -Be 50
            Test-Path -LiteralPath (Get-PastaDaEntrada $e.id) | Should -BeFalse
            @((Invoke-Q 'listar').dados.entradas).Count | Should -Be 0
        }
        It 'recria a pasta pai da origem quando ela sumiu' {
            $e = New-EntradaTeste 'r2'
            Remove-Item -LiteralPath (Join-Path $Script:Raiz 'r2') -Recurse -Force
            $r = Invoke-Q 'restaurar' @{ ids = @($e.id) }
            @($r.dados.restauradas) | Should -Be @($e.id)
            (Get-Item -LiteralPath (Join-Path $Script:Raiz 'r2\arquivo.txt')).Length | Should -Be 100
            Test-Path -LiteralPath (Join-Path $Script:Raiz 'r2\pasta\dentro.txt') | Should -BeTrue
        }
        It 'restaura varias entradas de uma vez e relata a inexistente em falhas' {
            $a = New-EntradaTeste 'r3'
            $b = New-EntradaTeste 'r4'
            $r = Invoke-Q 'restaurar' @{ ids = @($a.id, '20200101-000000-abcd', $b.id) }
            $r.ok | Should -BeTrue
            @($r.dados.restauradas) | Should -Be @($a.id, $b.id)
            @($r.dados.falhas).Count | Should -Be 1
            $r.dados.falhas[0].id | Should -Be '20200101-000000-abcd'
            $r.dados.falhas[0].erro | Should -Not -BeNullOrEmpty
        }
        It 'Review Focus 1: origem que voltou a existir vira conflito e a entrada inteira fica' {
            $e = New-EntradaTeste 'rf1'
            $origemArq = Join-Path $Script:Raiz 'rf1\arquivo.txt'
            $origemPasta = Join-Path $Script:Raiz 'rf1\pasta'
            New-ArquivoTeste $origemArq 7   # algo novo apareceu na origem do arquivo
            $r = Invoke-Q 'restaurar' @{ ids = @($e.id) }
            $r.ok | Should -BeTrue
            @($r.dados.restauradas).Count | Should -Be 0
            @($r.dados.falhas).Count | Should -Be 0
            @($r.dados.conflitos).Count | Should -Be 1
            $r.dados.conflitos[0].id | Should -Be $e.id
            $r.dados.conflitos[0].item | Should -Match 'rf1\\arquivo\.txt$'
            $r.dados.conflitos[0].motivo | Should -Not -BeNullOrEmpty
            # nao sobrescreveu o que esta na origem
            (Get-Item -LiteralPath $origemArq).Length | Should -Be 7
            # a pasta (sem conflito) TAMBEM nao voltou: atomicidade por entrada
            Test-Path -LiteralPath $origemPasta | Should -BeFalse
            $pasta = Get-PastaDaEntrada $e.id
            Test-Path -LiteralPath (Join-Path $pasta 'itens\1\arquivo.txt') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $pasta 'itens\2\pasta\dentro.txt') | Should -BeTrue
            @((Get-ManifestoTeste $e.id).itens).Count | Should -Be 2
            @((Invoke-Q 'listar').dados.entradas).Count | Should -Be 1
            # tirado o conflito, restaura normalmente
            Remove-Item -LiteralPath $origemArq -Force
            $r = Invoke-Q 'restaurar' @{ ids = @($e.id) }
            @($r.dados.restauradas) | Should -Be @($e.id)
            (Get-Item -LiteralPath $origemArq).Length | Should -Be 100
            Test-Path -LiteralPath (Join-Path $origemPasta 'dentro.txt') | Should -BeTrue
        }
        It 'origem em caminho protegido vira conflito' {
            $e = New-EntradaTeste 'rp1'
            Set-ManifestoTeste $e.id { param($m) $m.itens[0].origem = "$env:windir\System32\nextune-teste.txt" }
            $r = Invoke-Q 'restaurar' @{ ids = @($e.id) }
            $r.ok | Should -BeTrue
            @($r.dados.restauradas).Count | Should -Be 0
            @($r.dados.conflitos).Count | Should -Be 1
            $r.dados.conflitos[0].motivo | Should -Match 'protegid'
            Test-Path -LiteralPath "$env:windir\System32\nextune-teste.txt" | Should -BeFalse
            Test-Path -LiteralPath (Join-Path (Get-PastaDaEntrada $e.id) 'itens\2\pasta\dentro.txt') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $Script:Raiz 'rp1\pasta') | Should -BeFalse
        }
        It 'item ausente na quarentena vai para falhas sem mover os demais' {
            $e = New-EntradaTeste 'ra1'
            Remove-Item -LiteralPath (Join-Path (Get-PastaDaEntrada $e.id) 'itens\1\arquivo.txt') -Force
            $r = Invoke-Q 'restaurar' @{ ids = @($e.id) }
            $r.ok | Should -BeTrue
            @($r.dados.restauradas).Count | Should -Be 0
            @($r.dados.falhas).Count | Should -Be 1
            $r.dados.falhas[0].id | Should -Be $e.id
            Test-Path -LiteralPath (Join-Path $Script:Raiz 'ra1\pasta') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path (Get-PastaDaEntrada $e.id) 'itens\2\pasta\dentro.txt') | Should -BeTrue
        }
        It 'ids invalidos, repetidos ou ausentes sao recusados' {
            $e = New-EntradaTeste 'ri1'
            (Invoke-Q 'restaurar' @{}).ok | Should -BeFalse
            (Invoke-Q 'restaurar' @{ ids = @() }).ok | Should -BeFalse
            (Invoke-Q 'restaurar' @{ ids = $e.id }).ok | Should -BeFalse
            (Invoke-Q 'restaurar' @{ ids = @('..\..\x') }).ok | Should -BeFalse
            (Invoke-Q 'restaurar' @{ ids = @($e.id, $e.id) }).ok | Should -BeFalse
            (Invoke-Q 'restaurar' @{ ids = @(1) }).ok | Should -BeFalse
            Test-Path -LiteralPath (Get-PastaDaEntrada $e.id) | Should -BeTrue
        }
    }

    Context 'chaves de registro' {
        It 'Review Focus 2: chave com espaco, acento e parenteses exportada, removida e restaurada igual' {
            $chave = 'HKCU\Software\NexTuneTeste\Teste Ação (1)'
            $prov = 'HKCU:\Software\NexTuneTeste\Teste Ação (1)'
            New-Item -Path $prov -Force | Out-Null
            Set-ItemProperty -LiteralPath $prov -Name 'Nome Çã' -Value 'Valor Ção'
            Set-ItemProperty -LiteralPath $prov -Name 'Numero' -Value 42 -Type DWord
            New-Item -Path "$prov\Sub" -Force | Out-Null
            Set-ItemProperty -LiteralPath "$prov\Sub" -Name 'Interno' -Value 'ok'

            $e = New-EntradaQuarentena -Modulo 'teste' -Descricao 'chave' -Teste $true
            $it = Add-ItemQuarentena -Entrada $e -Caminho $chave
            $it.tipo | Should -Be 'chave'
            $it.nome | Should -Be 'chave.reg'
            Test-Path -LiteralPath $prov | Should -BeFalse
            $reg = Join-Path $e.pasta 'itens\1\chave.reg'
            Test-Path -LiteralPath $reg | Should -BeTrue
            # .reg e UTF-16 LE com BOM, como o reg.exe gera
            $b = [IO.File]::ReadAllBytes($reg)
            $b[0] | Should -Be 255
            $b[1] | Should -Be 254
            $e = Complete-EntradaQuarentena -Entrada $e
            $m = Get-ManifestoTeste $e.id
            $m.itens[0].tipo | Should -Be 'chave'
            $m.itens[0].origem | Should -Be $chave
            (Invoke-Q 'listar').dados.entradas[0].itens | Should -Be 1

            $r = Invoke-Q 'restaurar' @{ ids = @($e.id) }
            $r.ok | Should -BeTrue
            @($r.dados.restauradas) | Should -Be @($e.id)
            Test-Path -LiteralPath $prov | Should -BeTrue
            (Get-ItemProperty -LiteralPath $prov).'Nome Çã' | Should -Be 'Valor Ção'
            (Get-ItemProperty -LiteralPath $prov).Numero | Should -Be 42
            (Get-ItemProperty -LiteralPath "$prov\Sub").Interno | Should -Be 'ok'
            Test-Path -LiteralPath (Get-PastaDaEntrada $e.id) | Should -BeFalse
        }
        It 'chave que voltou a existir vira conflito e o .reg fica' {
            $chave = 'HKCU\Software\NexTuneTeste\Volta'
            $prov = 'HKCU:\Software\NexTuneTeste\Volta'
            New-Item -Path $prov -Force | Out-Null
            Set-ItemProperty -LiteralPath $prov -Name 'V' -Value 'antigo'
            $e = New-EntradaQuarentena -Modulo 'teste' -Descricao 'chave' -Teste $true
            Add-ItemQuarentena -Entrada $e -Caminho $chave | Out-Null
            $e = Complete-EntradaQuarentena -Entrada $e
            New-Item -Path $prov -Force | Out-Null
            Set-ItemProperty -LiteralPath $prov -Name 'V' -Value 'novo'
            $r = Invoke-Q 'restaurar' @{ ids = @($e.id) }
            @($r.dados.restauradas).Count | Should -Be 0
            @($r.dados.conflitos).Count | Should -Be 1
            $r.dados.conflitos[0].item | Should -Be $chave
            (Get-ItemProperty -LiteralPath $prov).V | Should -Be 'novo'
            Test-Path -LiteralPath (Join-Path (Get-PastaDaEntrada $e.id) 'itens\1\chave.reg') | Should -BeTrue
        }
        It 'em modo teste, chave fora de HKCU\Software\NexTuneTeste e recusada e nada muda' {
            $e = New-EntradaQuarentena -Modulo 'teste' -Descricao 'fora' -Teste $true
            { Add-ItemQuarentena -Entrada $e -Caminho 'HKCU\Software\Microsoft' } | Should -Throw -ExpectedMessage '*teste*'
            { Add-ItemQuarentena -Entrada $e -Caminho 'HKCU\Software\NexTuneTeste' } | Should -Throw
            Test-Path -LiteralPath 'HKCU:\Software\Microsoft' | Should -BeTrue
            $e.itens.Count | Should -Be 0
            $arq = Join-Path $Script:Raiz 'fora.reg'
            { Export-ChaveRegistro -Chave 'HKCU\Software\Microsoft' -Arquivo $arq -Teste $true } | Should -Throw
            Test-Path -LiteralPath $arq | Should -BeFalse
            { Restore-ChaveRegistro -Arquivo $arq -Chave 'HKCU\Software\Microsoft' -Teste $true } | Should -Throw
        }
        It 'chave inexistente lanca' {
            $e = New-EntradaQuarentena -Modulo 'teste' -Descricao 'x' -Teste $true
            { Add-ItemQuarentena -Entrada $e -Caminho 'HKCU\Software\NexTuneTeste\NaoExiste' } | Should -Throw
            $e.itens.Count | Should -Be 0
        }
    }

    Context 'purgar' {
        It 'sem confirmado recusa (inclusive a string "true")' {
            $e = New-EntradaTeste 'p1'
            $r = Invoke-Q 'purgar' @{ ids = @($e.id) }
            $r.ok | Should -BeFalse
            $r.erro | Should -Match 'confirma'
            (Invoke-Q 'purgar' @{ ids = @($e.id); confirmado = 'true' }).ok | Should -BeFalse
            (Invoke-Q 'purgar' @{ ids = @($e.id); confirmado = 1 }).ok | Should -BeFalse
            Test-Path -LiteralPath (Get-PastaDaEntrada $e.id) | Should -BeTrue
        }
        It 'com confirmado apaga' {
            $e = New-EntradaTeste 'p2'
            $outra = New-EntradaTeste 'p3'
            $r = Invoke-Q 'purgar' @{ ids = @($e.id); confirmado = $true }
            $r.ok | Should -BeTrue
            @($r.dados.removidas) | Should -Be @($e.id)
            @($r.dados.falhas).Count | Should -Be 0
            Test-Path -LiteralPath (Get-PastaDaEntrada $e.id) | Should -BeFalse
            Test-Path -LiteralPath (Get-PastaDaEntrada $outra.id) | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $Script:Raiz 'p2\arquivo.txt') | Should -BeFalse
        }
        It 'id inexistente vai para falhas' {
            $r = Invoke-Q 'purgar' @{ ids = @('20200101-000000-abcd'); confirmado = $true }
            $r.ok | Should -BeTrue
            @($r.dados.removidas).Count | Should -Be 0
            @($r.dados.falhas).Count | Should -Be 1
            $r.dados.falhas[0].id | Should -Be '20200101-000000-abcd'
        }
        It 'nao segue junction dentro da pasta em quarentena' {
            $alvo = Join-Path $env:TEMP 'NexTuneTeste\foraPurga'
            New-ArquivoTeste (Join-Path $alvo 'preciso.txt') 10
            $pasta = Join-Path $Script:Raiz 'comLink'
            New-ArquivoTeste (Join-Path $pasta 'normal.txt') 10
            $j = Join-Path $pasta 'jn'
            New-Juncao $j $alvo
            $e = $null
            try {
                $e = New-EntradaQuarentena -Modulo 'teste' -Descricao 'pasta com junction' -Teste $true
                Add-ItemQuarentena -Entrada $e -Caminho $pasta | Out-Null
                $e = Complete-EntradaQuarentena -Entrada $e
                $r = Invoke-Q 'purgar' @{ ids = @($e.id); confirmado = $true }
                $r.ok | Should -BeTrue
                @($r.dados.removidas) | Should -Be @($e.id)
                Test-Path -LiteralPath (Join-Path $alvo 'preciso.txt') | Should -BeTrue
                Test-Path -LiteralPath (Get-PastaDaEntrada $e.id) | Should -BeFalse
            } finally {
                Remove-Juncao $j
                if ($null -ne $e) { Remove-Juncao (Join-Path (Get-PastaDaEntrada $e.id) 'itens\1\comLink\jn') }
            }
        }
    }

    Context 'purgarVencidos' {
        It 'remove so a entrada com data forjada ha 8 dias e mantem a de hoje' {
            $velha = New-EntradaTeste 'v1'
            $nova = New-EntradaTeste 'v2'
            Set-ManifestoTeste $velha.id { param($m) $m.data = (Get-Date).AddDays(-8).ToUniversalTime().ToString('o') }
            $r = Invoke-Q 'purgarVencidos' @{ dias = 7 }
            $r.ok | Should -BeTrue
            @($r.dados.removidas) | Should -Be @($velha.id)
            Test-Path -LiteralPath (Get-PastaDaEntrada $velha.id) | Should -BeFalse
            Test-Path -LiteralPath (Get-PastaDaEntrada $nova.id) | Should -BeTrue
            # com prazo maior que a idade, nada vence
            Set-ManifestoTeste $nova.id { param($m) $m.data = (Get-Date).AddDays(-8).ToUniversalTime().ToString('o') }
            @((Invoke-Q 'purgarVencidos' @{ dias = 30 }).dados.removidas).Count | Should -Be 0
            Test-Path -LiteralPath (Get-PastaDaEntrada $nova.id) | Should -BeTrue
        }
        It 'dias e obrigatorio e fica em 1..90' {
            New-EntradaTeste 'v3' | Out-Null
            (Invoke-Q 'purgarVencidos' @{}).ok | Should -BeFalse
            (Invoke-Q 'purgarVencidos' @{ dias = 0 }).ok | Should -BeFalse
            (Invoke-Q 'purgarVencidos' @{ dias = 91 }).ok | Should -BeFalse
            (Invoke-Q 'purgarVencidos' @{ dias = '7' }).ok | Should -BeFalse
            @((Invoke-Q 'listar').dados.entradas).Count | Should -Be 1
        }
        It 'quarentena vazia devolve removidas vazia' {
            $r = Invoke-Q 'purgarVencidos' @{ dias = 7 }
            $r.ok | Should -BeTrue
            @($r.dados.removidas).Count | Should -Be 0
            $Script:UltimaSaida | Should -Match '"removidas":\[\]'
        }
    }

    Context 'Invoke-Acao' {
        It 'acao desconhecida devolve ok:false' {
            $r = Invoke-Q 'apagarTudo'
            $r.ok | Should -BeFalse
            $r.erro | Should -Be 'ação desconhecida'
            (Invoke-Q 'Listar').ok | Should -BeFalse
        }
        It 'excecao interna vira ok:false com mensagem' {
            Mock Get-ListaQuarentena { throw 'disco sumiu' }
            $r = Invoke-Q 'listar'
            $r.ok | Should -BeFalse
            $r.erro | Should -Match 'disco sumiu'
        }
    }
}
