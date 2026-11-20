BeforeAll {
    . "$PSScriptRoot\..\common.ps1"
    . "$PSScriptRoot\..\limpeza.ps1"
    . "$PSScriptRoot\_helpers.ps1"
    $Script:Ids = @('temp_usuario', 'temp_windows', 'wu_cache', 'entrega', 'informes', 'miniaturas', 'launchers', 'navegadores', 'minidumps', 'lixeira', 'shaders', 'dism_componentes', 'windows_old', 'pontos_antigos')
    $Script:Raiz = Join-Path $env:TEMP 'OtimizadorTeste\limpeza'

    function Invoke-Limp {
        param([string]$Acao, $Params = @{})
        $sw = New-Object System.IO.StringWriter
        Set-Saida $sw
        try { Invoke-Acao 'a1' $Acao $Params $true } finally { Set-Saida $null }
        $Script:UltimaSaida = $sw.ToString()
        $linhas = @($sw.ToString() -split "`r?`n" | Where-Object { $_.StartsWith('@@RESULT ') })
        if ($linhas.Count -ne 1) { return $null }
        return $linhas[0].Substring(9) | ConvertFrom-Json
    }
    function Use-PerfilTeste {
        param([string]$Classe)
        Set-Perfil ([pscustomobject]@{ classe = $Classe; disco = 'hdd'; manual = $true }) $true
    }
    function Get-Cat { param($R, [string]$Id) return @($R.dados.categorias | Where-Object { $_.id -eq $Id })[0] }
}

AfterAll {
    $t = Join-Path $env:TEMP 'OtimizadorTeste'
    if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'limpeza.ps1' {
    BeforeEach {
        if (Test-Path -LiteralPath $Script:Raiz) { Remove-Item -LiteralPath $Script:Raiz -Recurse -Force -ErrorAction SilentlyContinue }
        foreach ($id in $Script:Ids) { New-Item -ItemType Directory -Path (Join-Path $Script:Raiz $id) -Force | Out-Null }
        1..3 | ForEach-Object { [IO.File]::WriteAllBytes((Join-Path $Script:Raiz "temp_usuario\f$_.tmp"), (New-Object byte[] 100)) }
        1..2 | ForEach-Object { [IO.File]::WriteAllBytes((Join-Path $Script:Raiz "temp_windows\g$_.tmp"), (New-Object byte[] 50)) }
        Use-PerfilTeste 'medio'
    }

    Context 'analisar' {
        It 'devolve 14 categorias na ordem e com as cores certas' {
            $r = Invoke-Limp 'analisar'
            $r.ok | Should -BeTrue
            @($r.dados.categorias | ForEach-Object { $_.id }) | Should -Be $Script:Ids
            $verdes = @('temp_usuario', 'temp_windows', 'wu_cache', 'entrega', 'informes', 'miniaturas', 'launchers')
            foreach ($c in $r.dados.categorias) {
                if ($verdes -contains $c.id) { $c.cor | Should -Be 'verde' } else { $c.cor | Should -Be 'amarelo' }
            }
        }
        It 'mede o tamanho das pastas de teste' {
            $r = Invoke-Limp 'analisar'
            (Get-Cat $r 'temp_usuario').tamanhoBytes | Should -Be 300
            (Get-Cat $r 'temp_windows').tamanhoBytes | Should -Be 100
            (Get-Cat $r 'dism_componentes').tamanhoBytes | Should -Be -1
            (Get-Cat $r 'dism_componentes').disponivel | Should -BeTrue
        }
        It 'shaders indisponivel em medio, com motivo' {
            $c = Get-Cat (Invoke-Limp 'analisar') 'shaders'
            $c.disponivel | Should -BeFalse
            $c.motivoIndisponivel | Should -Not -BeNullOrEmpty
        }
        It 'shaders disponivel em gamer' {
            Use-PerfilTeste 'gamer'
            (Get-Cat (Invoke-Limp 'analisar') 'shaders').disponivel | Should -BeTrue
        }
        It 'shaders disponivel em medio com avancado' {
            (Get-Cat (Invoke-Limp 'analisar' @{ avancado = $true }) 'shaders').disponivel | Should -BeTrue
        }
        It 'sem perfil trata como basico (shaders indisponivel)' {
            Remove-Item -LiteralPath (Join-Path (Get-AppPastas $true).Estado 'perfil.json') -Force
            (Get-Cat (Invoke-Limp 'analisar') 'shaders').disponivel | Should -BeFalse
        }
        It 'pontos_antigos so com avancado' {
            $c = Get-Cat (Invoke-Limp 'analisar') 'pontos_antigos'
            $c.disponivel | Should -BeFalse
            $c.avancado | Should -BeTrue
            (Get-Cat (Invoke-Limp 'analisar' @{ avancado = $true }) 'pontos_antigos').disponivel | Should -BeTrue
        }
        It 'confirmacaoDupla apenas em windows_old e pontos_antigos' {
            $r = Invoke-Limp 'analisar'
            (Get-Cat $r 'windows_old').confirmacaoDupla | Should -BeTrue
            (Get-Cat $r 'pontos_antigos').confirmacaoDupla | Should -BeTrue
            (Get-Cat $r 'temp_usuario').confirmacaoDupla | Should -BeFalse
            (Get-Cat $r 'temp_usuario').avancado | Should -BeFalse
        }
        It 'windows_old segue simularWindowsOld em teste' {
            $c = Get-Cat (Invoke-Limp 'analisar') 'windows_old'
            $c.disponivel | Should -BeFalse
            $c.motivoIndisponivel | Should -Not -BeNullOrEmpty
            (Get-Cat (Invoke-Limp 'analisar' @{ simularWindowsOld = $true }) 'windows_old').disponivel | Should -BeTrue
        }
    }

    Context 'limpar' {
        It 'apaga o conteudo de temp_usuario e preserva temp_windows e a raiz' {
            $r = Invoke-Limp 'limpar' @{ categorias = @('temp_usuario') }
            $r.ok | Should -BeTrue
            $r.dados.liberadoBytes | Should -Be 300
            $r.dados.pulados | Should -Be 0
            Test-Path -LiteralPath (Join-Path $Script:Raiz 'temp_usuario') | Should -BeTrue
            @(Get-ChildItem -LiteralPath (Join-Path $Script:Raiz 'temp_usuario') -Force).Count | Should -Be 0
            @(Get-ChildItem -LiteralPath (Join-Path $Script:Raiz 'temp_windows') -Force).Count | Should -Be 2
        }
        It 'pula arquivo em uso, conta e continua ok' {
            $f = Join-Path $Script:Raiz 'temp_usuario\f1.tmp'
            $h = [IO.File]::Open($f, 'Open', 'ReadWrite', 'None')
            try { $r = Invoke-Limp 'limpar' @{ categorias = @('temp_usuario') } } finally { $h.Dispose() }
            $r.ok | Should -BeTrue
            $r.dados.pulados | Should -Be 1
            Test-Path -LiteralPath $f | Should -BeTrue
            @(Get-ChildItem -LiteralPath (Join-Path $Script:Raiz 'temp_usuario') -Force).Count | Should -Be 1
            $r.dados.liberadoBytes | Should -Be 200
        }
        It 'categoria desconhecida falha' {
            $r = Invoke-Limp 'limpar' @{ categorias = @('inexistente') }
            $r.ok | Should -BeFalse
            $r.erro | Should -Match 'categoria'
        }
        It 'windows_old e pontos_antigos exigem confirmado' {
            foreach ($id in 'windows_old', 'pontos_antigos') {
                $r = Invoke-Limp 'limpar' @{ categorias = @($id) }
                $r.ok | Should -BeFalse
                $r = Invoke-Limp 'limpar' @{ categorias = @($id); confirmado = 'true' }
                $r.ok | Should -BeFalse
            }
        }
        It 'simula categorias externas com confirmado (antes=depois=0)' {
            $r = Invoke-Limp 'limpar' @{ categorias = @('windows_old', 'lixeira', 'dism_componentes'); confirmado = $true; simularWindowsOld = $true }
            $r.ok | Should -BeTrue
            $r.dados.liberadoBytes | Should -Be 0
            @($r.dados.detalhes).Count | Should -Be 3
        }
        It 'detalhes seguem a ordem de categorias' {
            $r = Invoke-Limp 'limpar' @{ categorias = @('temp_windows', 'temp_usuario') }
            @($r.dados.detalhes | ForEach-Object { $_.id }) | Should -Be @('temp_windows', 'temp_usuario')
            $r.dados.detalhes[0].antes | Should -Be 100
            $r.dados.detalhes[0].depois | Should -Be 0
            $r.dados.liberadoBytes | Should -Be 400
        }
        It 'nao segue junction para fora da raiz' {
            $alvo = Join-Path $env:TEMP 'OtimizadorTeste\fora'
            New-Item -ItemType Directory -Path $alvo -Force | Out-Null
            [IO.File]::WriteAllBytes((Join-Path $alvo 'preciso.txt'), (New-Object byte[] 10))
            $j = Join-Path $Script:Raiz 'temp_usuario\jn'
            cmd /c mklink /J "$j" "$alvo" | Out-Null
            $r = Invoke-Limp 'limpar' @{ categorias = @('temp_usuario') }
            $r.ok | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $alvo 'preciso.txt') | Should -BeTrue
        }
        It 'recusa raiz perigosa' {
            Test-RaizSegura "$env:SystemDrive\" | Should -BeFalse
            Test-RaizSegura $env:windir | Should -BeFalse
            Test-RaizSegura $env:USERPROFILE | Should -BeFalse
            Test-RaizSegura '' | Should -BeFalse
            Test-RaizSegura (Join-Path $Script:Raiz 'temp_usuario') | Should -BeTrue
        }
    }
}
