BeforeAll {
    . "$PSScriptRoot\..\common.ps1"
    . "$PSScriptRoot\..\espaco.ps1"
    . "$PSScriptRoot\_helpers.ps1"
    $Script:BaseEspaco = Join-Path (Join-Path $env:TEMP 'NexTuneTeste') 'espaco'

    function Invoke-Espaco {
        param([string]$Acao, $Params = @{}, [bool]$Teste = $true)
        $sw = New-Object System.IO.StringWriter
        Set-Saida $sw
        try { Invoke-Acao 'e1' $Acao $Params $Teste } finally { Set-Saida $null }
        $Script:UltimaSaida = $sw.ToString()
        $linhas = @($sw.ToString() -split "`r?`n" | Where-Object { $_.StartsWith('@@RESULT ') })
        if ($linhas.Count -ne 1) { return $null }
        return $linhas[0].Substring(9) | ConvertFrom-Json
    }
    function Get-Porcentagem {
        return @($Script:UltimaSaida -split "`r?`n" | Where-Object { $_.StartsWith('@@PROGRESS ') } | ForEach-Object { ($_.Substring(11) | ConvertFrom-Json).pct })
    }
    function New-Arquivo {
        # Arquivo com tamanho exato (SetLength: rapido, sem escrever os bytes).
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param([string]$Caminho, [int64]$Bytes)
        $pai = Split-Path -Parent $Caminho
        if (-not (Test-Path -LiteralPath $pai)) { New-Item -ItemType Directory -Path $pai -Force | Out-Null }
        $fs = [IO.File]::Create($Caminho)
        try { $fs.SetLength($Bytes) } finally { $fs.Dispose() }
    }
    function Remove-JuncaoEspaco {
        # Junctions saem antes de qualquer Remove-Item -Recurse (o do PS 5.1 entraria no alvo).
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param()
        foreach ($l in @('arvore\Link', 'arvore\Media\LinkDentro')) { Remove-Juncao (Join-Path $Script:BaseEspaco $l) }
    }

    # Arvore com tamanhos conhecidos:
    #   arvore\solto.bin 500 (solto na raiz)
    #   arvore\Grande\a.bin 3000, arvore\Grande\sub\b.bin 4000            -> 7000
    #   arvore\Media\c.bin 2000 + Media\LinkDentro (junction para fora)   -> 2000
    #   arvore\Pequena\d.bin 100, arvore\Pequena\sub\sub2\e.bin 50        -> 150
    #   arvore\Vazia                                                        -> 0
    #   arvore\Link (junction no primeiro nivel para fora)                 -> 0, fora da soma
    #   fora\enorme.bin 1000000 e fora\dentro\ (nunca podem aparecer)
    Remove-JuncaoEspaco
    $null = New-PastaTeste 'espaco'
    $Script:Raiz = Join-Path $Script:BaseEspaco 'arvore'
    $Script:Fora = Join-Path $Script:BaseEspaco 'fora'
    New-Arquivo (Join-Path $Script:Raiz 'solto.bin') 500
    New-Arquivo (Join-Path $Script:Raiz 'Grande\a.bin') 3000
    New-Arquivo (Join-Path $Script:Raiz 'Grande\sub\b.bin') 4000
    New-Arquivo (Join-Path $Script:Raiz 'Media\c.bin') 2000
    New-Arquivo (Join-Path $Script:Raiz 'Pequena\d.bin') 100
    New-Arquivo (Join-Path $Script:Raiz 'Pequena\sub\sub2\e.bin') 50
    New-Item -ItemType Directory -Path (Join-Path $Script:Raiz 'Vazia') -Force | Out-Null
    New-Arquivo (Join-Path $Script:Fora 'enorme.bin') 1000000
    New-Item -ItemType Directory -Path (Join-Path $Script:Fora 'dentro') -Force | Out-Null
    New-Juncao (Join-Path $Script:Raiz 'Link') $Script:Fora
    New-Juncao (Join-Path $Script:Raiz 'Media\LinkDentro') $Script:Fora

    # 25 pastas com um arquivo cada (p01\f01.bin = 100 bytes ... p25\f25.bin = 2500 bytes).
    $Script:Raiz25 = Join-Path $Script:BaseEspaco 'vinteecinco'
    for ($i = 1; $i -le 25; $i++) {
        $nn = '{0:D2}' -f $i
        New-Arquivo (Join-Path $Script:Raiz25 ('p' + $nn + '\f' + $nn + '.bin')) ($i * 100)
    }
}

AfterAll {
    # Os alvos das junctions ficam dentro de espaco\fora: mesmo se uma sobrar, nada fora do %TEMP% de teste e tocado.
    foreach ($l in @('arvore\Link', 'arvore\Media\LinkDentro')) {
        $j = Join-Path (Join-Path (Join-Path $env:TEMP 'NexTuneTeste') 'espaco') $l
        if (Test-Path -LiteralPath $j) { cmd /c rmdir "$j" | Out-Null }
    }
    Remove-Item -LiteralPath (Join-Path $env:TEMP 'NexTuneTeste') -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'espaco.ps1: funcoes puras' {
    Context 'Get-TetoParam' {
        It 'ausente vale 60; 5 e 300 sao aceitos' {
            (Get-TetoParam @{}).segundos | Should -Be 60
            (Get-TetoParam $null).segundos | Should -Be 60
            (Get-TetoParam @{ tetoSegundos = 5 }).segundos | Should -Be 5
            (Get-TetoParam @{ tetoSegundos = 300 }).segundos | Should -Be 300
            (Get-TetoParam @{ tetoSegundos = 5 }).erro | Should -BeNullOrEmpty
        }
        It 'fora de 5..300, fracionario, texto ou booleano e recusado' {
            (Get-TetoParam @{ tetoSegundos = 4 }).erro | Should -Match 'intervalo'
            (Get-TetoParam @{ tetoSegundos = 301 }).erro | Should -Match 'intervalo'
            (Get-TetoParam @{ tetoSegundos = 5.5 }).erro | Should -Not -BeNullOrEmpty
            (Get-TetoParam @{ tetoSegundos = '60' }).erro | Should -Not -BeNullOrEmpty
            (Get-TetoParam @{ tetoSegundos = $true }).erro | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Add-ItemLimitado' {
        It 'guarda so os N maiores, em ordem crescente, sem ordenar tudo' {
            $l = New-Object System.Collections.Generic.List[object]
            foreach ($b in @(7, 3, 99, 15, 1, 42, 8, 64, 2, 30)) { Add-ItemLimitado $l ([pscustomobject]@{ bytes = [int64]$b }) 4 }
            $l.Count | Should -Be 4
            @($l | ForEach-Object { $_.bytes }) | Should -Be @(30, 42, 64, 99)
        }
        It 'empate com o menor, com a lista cheia, fica de fora' {
            $l = New-Object System.Collections.Generic.List[object]
            foreach ($b in @(10, 20)) { Add-ItemLimitado $l ([pscustomobject]@{ bytes = [int64]$b; n = 'a' }) 2 }
            Add-ItemLimitado $l ([pscustomobject]@{ bytes = [int64]10; n = 'b' }) 2
            @($l | ForEach-Object { $_.n }) | Should -Be @('a', 'a')
        }
    }

    Context 'Get-RaizAnalise' {
        It 'aceita a raiz da unidade' {
            $r = Get-RaizAnalise ($env:SystemDrive + '\')
            $r.erro | Should -BeNullOrEmpty
            $r.caminho | Should -Be ($env:SystemDrive + '\')
        }
        It 'tira a barra do fim' {
            $r = Get-RaizAnalise ($Script:Raiz + '\')
            $r.erro | Should -BeNullOrEmpty
            $r.caminho | Should -Not -Match '\\$'
        }
    }
}

Describe 'espaco.ps1: analisar' {
    It 'arvore com tamanhos conhecidos: total exato e pastas e arquivos do maior para o menor' {
        $r = Invoke-Espaco 'analisar' @{ raiz = $Script:Raiz }
        $r.ok | Should -BeTrue
        $r.dados.incompleto | Should -BeFalse
        $r.dados.totalBytes | Should -Be 9650
        (Get-CaminhoLongo $r.dados.raiz) | Should -Be (Get-CaminhoLongo $Script:Raiz)
        @($r.dados.pastas | ForEach-Object { $_.nome }) | Should -Be @('Grande', 'Media', 'Pequena', 'Link', 'Vazia')
        @($r.dados.pastas | ForEach-Object { $_.bytes }) | Should -Be @(7000, 2000, 150, 0, 0)
        @($r.dados.pastas | Where-Object { $_.semAcesso -or $_.parcial }).Count | Should -Be 0
        $grande = @($r.dados.pastas)[0]
        (Get-CaminhoLongo $grande.caminho) | Should -Be (Get-CaminhoLongo (Join-Path $Script:Raiz 'Grande'))
        @($r.dados.arquivos | ForEach-Object { $_.nome }) | Should -Be @('b.bin', 'a.bin', 'c.bin', 'solto.bin', 'd.bin', 'e.bin')
        @($r.dados.arquivos | ForEach-Object { $_.bytes }) | Should -Be @(4000, 3000, 2000, 500, 100, 50)
        (Get-CaminhoLongo @($r.dados.arquivos)[0].caminho) | Should -Be (Get-CaminhoLongo (Join-Path $Script:Raiz 'Grande\sub\b.bin'))
    }
    It 'junction para fora nao e seguida nem somada, em nenhum nivel (Review Focus 5)' {
        $r = Invoke-Espaco 'analisar' @{ raiz = $Script:Raiz }
        $link = @($r.dados.pastas | Where-Object { $_.nome -eq 'Link' })
        $link.Count | Should -Be 1
        $link[0].bytes | Should -Be 0
        @($r.dados.pastas | Where-Object { $_.nome -eq 'Media' })[0].bytes | Should -Be 2000
        @($r.dados.arquivos | Where-Object { $_.nome -eq 'enorme.bin' }).Count | Should -Be 0
        $r.dados.totalBytes | Should -BeLessThan 1000000
    }
    It 'pasta sem permissao: semAcesso e bytes -1, nunca 0, e vai para o fim da lista (Review Focus 5)' {
        $r = Invoke-Espaco 'analisar' @{ raiz = $Script:Raiz; simular = @{ negarAcesso = @((Join-Path $Script:Raiz 'Media')) } }
        $r.ok | Should -BeTrue
        $media = @($r.dados.pastas | Where-Object { $_.nome -eq 'Media' })[0]
        $media.bytes | Should -Be -1
        $media.semAcesso | Should -BeTrue
        $media.parcial | Should -BeFalse
        @($r.dados.pastas)[-1].nome | Should -Be 'Media'
        $r.dados.totalBytes | Should -Be 7650
        $r.dados.incompleto | Should -BeFalse
        @($r.dados.arquivos | Where-Object { $_.nome -eq 'c.bin' }).Count | Should -Be 0
    }
    It 'pasta vazia nao e confundida com pasta sem acesso' {
        $r = Invoke-Espaco 'analisar' @{ raiz = $Script:Raiz }
        $vazia = @($r.dados.pastas | Where-Object { $_.nome -eq 'Vazia' })[0]
        $vazia.bytes | Should -Be 0
        $vazia.semAcesso | Should -BeFalse
    }
    It 'subpasta sem permissao marca parcial e soma o resto' {
        $r = Invoke-Espaco 'analisar' @{ raiz = $Script:Raiz; simular = @{ negarAcesso = @((Join-Path $Script:Raiz 'Grande\sub')) } }
        $grande = @($r.dados.pastas | Where-Object { $_.nome -eq 'Grande' })[0]
        $grande.bytes | Should -Be 3000
        $grande.parcial | Should -BeTrue
        $grande.semAcesso | Should -BeFalse
        $r.dados.totalBytes | Should -Be 5650
    }
    It 'negarAcesso so vale em modo teste' {
        $r = Invoke-Espaco 'analisar' @{ raiz = $Script:Raiz; simular = @{ negarAcesso = @((Join-Path $Script:Raiz 'Media')) } } $false
        $r.ok | Should -BeTrue
        @($r.dados.pastas | Where-Object { $_.nome -eq 'Media' })[0].bytes | Should -Be 2000
    }
    It 'raiz sem permissao falha' {
        $r = Invoke-Espaco 'analisar' @{ raiz = $Script:Raiz; simular = @{ negarAcesso = @($Script:Raiz) } }
        $r.ok | Should -BeFalse
        $r.erro | Should -Match 'sem acesso'
    }
    It 'teto de tempo: a primeira pasta para no meio, as outras vem com -1 e parcial, incompleto' {
        $r = Invoke-Espaco 'analisar' @{ raiz = $Script:Raiz; tetoSegundos = 5; simular = @{ tetoMs = 0 } }
        $r.ok | Should -BeTrue
        $r.dados.incompleto | Should -BeTrue
        $grande = @($r.dados.pastas | Where-Object { $_.nome -eq 'Grande' })[0]
        $grande.bytes | Should -Be 3000
        $grande.parcial | Should -BeTrue
        foreach ($nome in @('Media', 'Pequena', 'Vazia')) {
            $p = @($r.dados.pastas | Where-Object { $_.nome -eq $nome })[0]
            $p.bytes | Should -Be -1
            $p.parcial | Should -BeTrue
            $p.semAcesso | Should -BeFalse
        }
        @($r.dados.pastas | Where-Object { $_.nome -eq 'Link' })[0].bytes | Should -Be 0
        $r.dados.totalBytes | Should -Be 3500
        @($r.dados.arquivos | ForEach-Object { $_.nome }) | Should -Be @('a.bin', 'solto.bin')
    }
    It 'guarda so as 20 maiores pastas e os 20 maiores arquivos quando ha 25' {
        $r = Invoke-Espaco 'analisar' @{ raiz = $Script:Raiz25 }
        $r.ok | Should -BeTrue
        $r.dados.totalBytes | Should -Be 32500
        @($r.dados.pastas).Count | Should -Be 20
        @($r.dados.pastas)[0].nome | Should -Be 'p25'
        @($r.dados.pastas)[19].nome | Should -Be 'p06'
        @($r.dados.arquivos).Count | Should -Be 20
        @($r.dados.arquivos | ForEach-Object { $_.bytes }) | Should -Be @(25..6 | ForEach-Object { $_ * 100 })
    }
    It 'progresso por pasta do primeiro nivel, crescente, terminando em 100' {
        $null = Invoke-Espaco 'analisar' @{ raiz = $Script:Raiz25 }
        $pct = @(Get-Porcentagem)
        $pct.Count | Should -BeGreaterThan 25
        $pct[-1] | Should -Be 100
        for ($i = 1; $i -lt $pct.Count; $i++) { $pct[$i] | Should -BeGreaterOrEqual $pct[$i - 1] }
    }
}

Describe 'espaco.ps1: validacao' {
    It 'raiz relativa, UNC, ausente ou nao texto e recusada' {
        (Invoke-Espaco 'analisar' @{ raiz = 'pasta\relativa' }).ok | Should -BeFalse
        (Invoke-Espaco 'analisar' @{ raiz = '\\servidor\compartilhado' }).ok | Should -BeFalse
        (Invoke-Espaco 'analisar' @{ raiz = 'C:' }).ok | Should -BeFalse
        (Invoke-Espaco 'analisar' @{}).ok | Should -BeFalse
        (Invoke-Espaco 'analisar' @{ raiz = 5 }).ok | Should -BeFalse
    }
    It 'raiz que nao existe ou que e arquivo e recusada' {
        $r = Invoke-Espaco 'analisar' @{ raiz = (Join-Path $Script:Raiz 'naoExiste') }
        $r.ok | Should -BeFalse
        $r.erro | Should -Match 'não existe'
        $r = Invoke-Espaco 'analisar' @{ raiz = (Join-Path $Script:Raiz 'solto.bin') }
        $r.ok | Should -BeFalse
        $r.erro | Should -Match 'arquivo'
    }
    It 'raiz que e junction ou fica dentro de uma e recusada' {
        $r = Invoke-Espaco 'analisar' @{ raiz = (Join-Path $Script:Raiz 'Link') }
        $r.ok | Should -BeFalse
        $r.erro | Should -Match 'link'
        (Invoke-Espaco 'analisar' @{ raiz = (Join-Path $Script:Raiz 'Link\dentro') }).ok | Should -BeFalse
    }
    It 'raiz com mais de 260 caracteres ou caractere invalido e recusada' {
        (Invoke-Espaco 'analisar' @{ raiz = ('C:\' + ('a' * 300)) }).ok | Should -BeFalse
        (Invoke-Espaco 'analisar' @{ raiz = 'C:\pasta|x' }).ok | Should -BeFalse
    }
    It 'tetoSegundos 4 e 301 sao recusados; 5 e 300 sao aceitos' {
        $r = Invoke-Espaco 'analisar' @{ raiz = $Script:Raiz; tetoSegundos = 4 }
        $r.ok | Should -BeFalse
        $r.erro | Should -Match 'tetoSegundos'
        (Invoke-Espaco 'analisar' @{ raiz = $Script:Raiz; tetoSegundos = 301 }).ok | Should -BeFalse
        (Invoke-Espaco 'analisar' @{ raiz = $Script:Raiz; tetoSegundos = 5 }).ok | Should -BeTrue
        (Invoke-Espaco 'analisar' @{ raiz = $Script:Raiz; tetoSegundos = 300 }).ok | Should -BeTrue
    }
    It 'acao desconhecida falha' {
        $r = Invoke-Espaco 'apagar' @{ raiz = $Script:Raiz }
        $r.ok | Should -BeFalse
        $r.erro | Should -Be 'ação desconhecida'
    }
    It 'excecao no meio vira ok:false com a mensagem' {
        Mock Measure-PastaPrimeiroNivel { throw 'falha simulada' }
        $r = Invoke-Espaco 'analisar' @{ raiz = $Script:Raiz }
        $r.ok | Should -BeFalse
        $r.erro | Should -Match 'falha simulada'
    }
}
