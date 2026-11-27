BeforeAll {
    . "$PSScriptRoot\..\common.ps1"
    . "$PSScriptRoot\..\espaco.ps1"
    . "$PSScriptRoot\_helpers.ps1"

    function Invoke-Espaco {
        param([string]$Acao, $Params = @{})
        $sw = New-Object System.IO.StringWriter
        Set-Saida $sw
        try { Invoke-Acao 'e1' $Acao $Params $true } finally { Set-Saida $null }
        $linhas = @($sw.ToString() -split "`r?`n" | Where-Object { $_.StartsWith('@@RESULT ') })
        if ($linhas.Count -ne 1) { return $null }
        return $linhas[0].Substring(9) | ConvertFrom-Json
    }
    function New-Arquivo {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param([string]$Caminho, [int64]$Bytes)
        $pai = Split-Path -Parent $Caminho
        if (-not (Test-Path -LiteralPath $pai)) { New-Item -ItemType Directory -Path $pai -Force | Out-Null }
        $fs = [IO.File]::Create($Caminho)
        try { $fs.SetLength($Bytes) } finally { $fs.Dispose() }
    }
    # Nega "listar pasta" ao usuario atual (so nas pastas de teste) e desfaz depois.
    $Script:Sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    function Set-Negado {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param([string]$Pasta)
        & "$env:windir\System32\icacls.exe" $Pasta /deny "*$($Script:Sid):(RD)" | Out-Null
    }
    function Clear-Negado {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param([string]$Pasta)
        if (Test-Path -LiteralPath $Pasta) { & "$env:windir\System32\icacls.exe" $Pasta /remove:d "*$($Script:Sid)" | Out-Null }
    }
    function Clear-Fixture {
        Remove-Juncao (Join-Path $Script:Raiz 'link')
        Remove-Juncao (Join-Path $Script:Raiz 'grande\link2')
        Remove-Juncao $Script:RaizLink
        Clear-Negado (Join-Path $Script:Raiz 'semacesso')
        Clear-Negado (Join-Path $Script:Raiz 'grande\trancada')
    }

    $base = Join-Path $env:TEMP 'NexTuneTeste'
    $Script:Raiz = Join-Path $base 'espaco'
    $Script:Fora = Join-Path $base 'espaco-fora'
    $Script:RaizLink = Join-Path $base 'espaco-link'
    Clear-Fixture
    $Script:Raiz = New-PastaTeste 'espaco'
    $Script:Fora = New-PastaTeste 'espaco-fora'

    New-Arquivo (Join-Path $Script:Raiz 'grande\sub\a.bin') 3MB
    New-Arquivo (Join-Path $Script:Raiz 'grande\b.bin') 1MB
    New-Arquivo (Join-Path $Script:Raiz 'media\c.bin') 2MB
    New-Arquivo (Join-Path $Script:Raiz 'pequena\d.bin') 10KB
    New-Item -ItemType Directory -Path (Join-Path $Script:Raiz 'vazia') | Out-Null
    New-Arquivo (Join-Path $Script:Raiz 'solto.bin') 512KB
    New-Arquivo (Join-Path $Script:Fora 'enorme.bin') 8MB
    New-Arquivo (Join-Path $Script:Raiz 'semacesso\x.bin') 5MB
    New-Arquivo (Join-Path $Script:Raiz 'grande\trancada\y.bin') 6MB
    New-Juncao (Join-Path $Script:Raiz 'link') $Script:Fora
    New-Juncao (Join-Path $Script:Raiz 'grande\link2') $Script:Fora
    New-Juncao $Script:RaizLink $Script:Raiz
    Set-Negado (Join-Path $Script:Raiz 'semacesso')
    Set-Negado (Join-Path $Script:Raiz 'grande\trancada')
}

AfterAll {
    Clear-Fixture
    Remove-Item -LiteralPath (Join-Path $env:TEMP 'NexTuneTeste') -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'espaco.ps1: Test-RaizValida' {
    It 'aceita caminhos absolutos de unidade' {
        Test-RaizValida 'C:\' | Should -BeTrue
        Test-RaizValida 'C:\Users\Fulano\Downloads' | Should -BeTrue
        Test-RaizValida 'd:\Jogos\' | Should -BeTrue
    }
    It 'recusa relativo, rede, curinga, aspas e . ou ..' {
        foreach ($ruim in @('', ' ', 'C:', 'C:pasta', 'pasta\x', '\\servidor\c$', '\\?\C:\x', 'C:\a\..\Windows', 'C:\a\.\b', 'C:\*', 'C:\a?b', 'C:\a"b', 'C:\a|b', 'C:\a:b', 'C:/x')) {
            Test-RaizValida $ruim | Should -BeFalse -Because $ruim
        }
        Test-RaizValida ('C:\' + ('a' * 1100)) | Should -BeFalse
    }
}

Describe 'espaco.ps1: analisar' {
    BeforeAll { $Script:R = Invoke-Espaco 'analisar' @{ raiz = $Script:Raiz } }

    It 'termina com sucesso' {
        $Script:R.ok | Should -BeTrue
        (Get-CaminhoLongo $Script:R.dados.raiz) | Should -Be (Get-CaminhoLongo $Script:Raiz)
    }
    It 'pastas na ordem do tamanho, sem acesso no fim' {
        $nomes = @($Script:R.dados.pastas | ForEach-Object { Split-Path -Leaf $_.caminho })
        $nomes | Should -Be @('grande', 'media', 'pequena', 'vazia', 'semacesso')
    }
    It 'junction nao aparece e nao e somada, nem no primeiro nivel nem dentro de outra pasta' {
        @($Script:R.dados.pastas | Where-Object { $_.caminho -like '*\link' }).Count | Should -Be 0
        ($Script:R.dados.pastas | Where-Object { $_.caminho -like '*\grande' }).bytes | Should -Be (4MB)
        @($Script:R.dados.arquivos | Where-Object { $_.caminho -like '*enorme.bin' }).Count | Should -Be 0
    }
    It 'pasta sem permissao: semAcesso e bytes nulo, nunca zero' {
        $p = $Script:R.dados.pastas | Where-Object { $_.caminho -like '*\semacesso' }
        $p.semAcesso | Should -BeTrue
        $p.bytes | Should -BeNullOrEmpty
        @($Script:R.dados.arquivos | Where-Object { $_.caminho -like '*x.bin' }).Count | Should -Be 0
    }
    It 'subpasta sem permissao marca a pasta de cima como parcial' {
        $g = $Script:R.dados.pastas | Where-Object { $_.caminho -like '*\grande' }
        $g.parcial | Should -BeTrue
        $g.semAcesso | Should -BeFalse
        ($Script:R.dados.pastas | Where-Object { $_.caminho -like '*\media' }).parcial | Should -BeFalse
        $Script:R.dados.parcial | Should -BeTrue
    }
    It 'pasta vazia mede 0 e nao e "sem acesso"' {
        $v = $Script:R.dados.pastas | Where-Object { $_.caminho -like '*\vazia' }
        $v.bytes | Should -Be 0
        $v.semAcesso | Should -BeFalse
    }
    It 'total e arquivos soltos' {
        $Script:R.dados.soltosBytes | Should -Be (512KB)
        $Script:R.dados.totalBytes | Should -Be (4MB + 2MB + 10KB + 512KB)
    }
    It 'maiores arquivos de toda a arvore, em ordem' {
        $nomes = @($Script:R.dados.arquivos | ForEach-Object { Split-Path -Leaf $_.caminho })
        $nomes | Should -Be @('a.bin', 'c.bin', 'b.bin', 'solto.bin', 'd.bin')
        $Script:R.dados.arquivos[0].bytes | Should -Be (3MB)
    }
    It 'um nivel abaixo (clicar numa pasta) analisa so ela' {
        $r = Invoke-Espaco 'analisar' @{ raiz = (Join-Path $Script:Raiz 'grande') }
        $r.ok | Should -BeTrue
        @($r.dados.pastas | ForEach-Object { Split-Path -Leaf $_.caminho }) | Should -Be @('sub', 'trancada')
        $r.dados.soltosBytes | Should -Be (1MB)
    }
}

Describe 'espaco.ps1: limites e recusas' {
    It 'no maximo 20 pastas e 20 arquivos' {
        $muitas = New-PastaTeste 'espaco-muitas'
        1..25 | ForEach-Object { New-Arquivo (Join-Path $muitas ("p{0:D2}\f.bin" -f $_)) ([int64]$_ * 1KB) }
        $r = Invoke-Espaco 'analisar' @{ raiz = $muitas }
        @($r.dados.pastas).Count | Should -Be 20
        @($r.dados.arquivos).Count | Should -Be 20
        (Split-Path -Leaf $r.dados.pastas[0].caminho) | Should -Be 'p25'
        $r.dados.totalBytes | Should -Be ((1..25 | Measure-Object -Sum).Sum * 1KB)
    }
    It 'estourou o teto total: devolve parcial em vez de travar' {
        $r = Invoke-Espaco 'analisar' @{ raiz = $Script:Raiz; simular = @{ tetoTotalMs = 0 } }
        $r.ok | Should -BeTrue
        $r.dados.parcial | Should -BeTrue
        @($r.dados.pastas | Where-Object { -not $_.parcial }).Count | Should -Be 0
    }
    It 'raiz que e junction e recusada' {
        $r = Invoke-Espaco 'analisar' @{ raiz = $Script:RaizLink }
        $r.ok | Should -BeFalse
        $r.erro | Should -Match 'link'
    }
    It 'raiz dentro de uma junction tambem e recusada' {
        $r = Invoke-Espaco 'analisar' @{ raiz = (Join-Path $Script:RaizLink 'media') }
        $r.ok | Should -BeFalse
    }
    It 'raiz sem permissao, inexistente, invalida ou ausente falha com mensagem' {
        (Invoke-Espaco 'analisar' @{ raiz = (Join-Path $Script:Raiz 'semacesso') }).erro | Should -Match 'permissão'
        (Invoke-Espaco 'analisar' @{ raiz = (Join-Path $Script:Raiz 'nao-existe') }).erro | Should -Match 'não existe'
        (Invoke-Espaco 'analisar' @{ raiz = 'C:\a\..\Windows' }).erro | Should -Match 'inválida'
        (Invoke-Espaco 'analisar' @{}).ok | Should -BeFalse
    }
    It 'acao desconhecida falha' {
        (Invoke-Espaco 'apagar' @{ raiz = $Script:Raiz }).ok | Should -BeFalse
    }
}
