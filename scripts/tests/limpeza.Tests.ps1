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
    function New-ArquivoIdade {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param([string]$Caminho, [int]$Bytes, [DateTime]$Data)
        [IO.File]::WriteAllBytes($Caminho, (New-Object byte[] $Bytes))
        (Get-Item -LiteralPath $Caminho).LastWriteTime = $Data
    }
    # Junction criada/removida pelo cmd: Remove-Item -Recurse do PS 5.1 entraria no alvo.
    function New-Juncao {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param([string]$Link, [string]$Alvo)
        cmd /c mklink /J "$Link" "$Alvo" | Out-Null
    }
    function Remove-Juncao {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param([string]$Link)
        if (Test-Path -LiteralPath $Link) { cmd /c rmdir "$Link" | Out-Null }
    }
}

AfterAll {
    $t = Join-Path $env:TEMP 'OtimizadorTeste'
    if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'limpeza.ps1' {
    BeforeEach {
        if (Test-Path -LiteralPath $Script:Raiz) { Remove-Item -LiteralPath $Script:Raiz -Recurse -Force -ErrorAction SilentlyContinue }
        foreach ($id in $Script:Ids) { New-Item -ItemType Directory -Path (Join-Path $Script:Raiz $id) -Force | Out-Null }
        # Temporarios so saem depois de uma idade minima (24 h / 7 dias): as sementes nascem "velhas".
        1..3 | ForEach-Object { New-ArquivoIdade (Join-Path $Script:Raiz "temp_usuario\f$_.tmp") 100 (Get-Date).AddDays(-2) }
        1..2 | ForEach-Object { New-ArquivoIdade (Join-Path $Script:Raiz "temp_windows\g$_.tmp") 50 (Get-Date).AddDays(-10) }
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
            try {
                $r = Invoke-Limp 'limpar' @{ categorias = @('temp_usuario') }
                $r.ok | Should -BeTrue
                Test-Path -LiteralPath (Join-Path $alvo 'preciso.txt') | Should -BeTrue
            } finally { Remove-Juncao $j }
        }
        It 'raiz da categoria que e junction: alvo intacto e categoria em falhas' {
            $alvo = Join-Path $env:TEMP 'OtimizadorTeste\foraRaiz'
            New-Item -ItemType Directory -Path $alvo -Force | Out-Null
            New-ArquivoIdade (Join-Path $alvo 'preciso.txt') 18 (Get-Date).AddDays(-30)
            $j = Join-Path $Script:Raiz 'informes'
            Remove-Item -LiteralPath $j -Force
            New-Juncao $j $alvo
            try {
                (Get-Cat (Invoke-Limp 'analisar') 'informes').tamanhoBytes | Should -Be 0
                $r = Invoke-Limp 'limpar' @{ categorias = @('informes') }
                $r.ok | Should -BeTrue
                Test-Path -LiteralPath (Join-Path $alvo 'preciso.txt') | Should -BeTrue
                $r.dados.liberadoBytes | Should -Be 0
                $r.dados.pulados | Should -Be 0
                @($r.dados.falhas).Count | Should -Be 1
                $r.dados.falhas[0].id | Should -Be 'informes'
                $r.dados.falhas[0].erro | Should -Match 'segurança'
                $r.dados.detalhes[0].erro | Should -Not -BeNullOrEmpty
            } finally { Remove-Juncao $j }
        }
        It 'pasta acima da raiz que e junction: alvo intacto e categoria em falhas' {
            $alvo = Join-Path $env:TEMP 'OtimizadorTeste\foraPai'
            New-Item -ItemType Directory -Path (Join-Path $alvo 'temp_usuario') -Force | Out-Null
            New-ArquivoIdade (Join-Path $alvo 'temp_usuario\preciso.tmp') 10 (Get-Date).AddDays(-30)
            Remove-Item -LiteralPath $Script:Raiz -Recurse -Force
            New-Juncao $Script:Raiz $alvo
            try {
                $r = Invoke-Limp 'limpar' @{ categorias = @('temp_usuario') }
                $r.ok | Should -BeTrue
                Test-Path -LiteralPath (Join-Path $alvo 'temp_usuario\preciso.tmp') | Should -BeTrue
                @($r.dados.falhas | ForEach-Object { $_.id }) | Should -Be @('temp_usuario')
            } finally { Remove-Juncao $Script:Raiz }
        }
        It 'temp_usuario so apaga itens com mais de 24 h (e analisar mede igual)' {
            $novo = Join-Path $Script:Raiz 'temp_usuario\novo.tmp'
            New-ArquivoIdade $novo 1000 (Get-Date).AddHours(-1)
            (Get-Cat (Invoke-Limp 'analisar') 'temp_usuario').tamanhoBytes | Should -Be 300
            $r = Invoke-Limp 'limpar' @{ categorias = @('temp_usuario') }
            $r.dados.liberadoBytes | Should -Be 300
            Test-Path -LiteralPath $novo | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $Script:Raiz 'temp_usuario\f1.tmp') | Should -BeFalse
        }
        It 'temp_windows so apaga itens com mais de 7 dias' {
            $recente = Join-Path $Script:Raiz 'temp_windows\recente.tmp'
            New-ArquivoIdade $recente 70 (Get-Date).AddDays(-2)
            (Get-Cat (Invoke-Limp 'analisar') 'temp_windows').tamanhoBytes | Should -Be 100
            $r = Invoke-Limp 'limpar' @{ categorias = @('temp_windows') }
            $r.dados.liberadoBytes | Should -Be 100
            Test-Path -LiteralPath $recente | Should -BeTrue
            @(Get-ChildItem -LiteralPath (Join-Path $Script:Raiz 'temp_windows') -Force).Count | Should -Be 1
        }
        It 'pasta velha esvaziada sai; pasta nova vazia fica' {
            $velha = Join-Path $Script:Raiz 'temp_usuario\velha'
            $nova = Join-Path $Script:Raiz 'temp_usuario\nova'
            New-Item -ItemType Directory -Path $velha, $nova -Force | Out-Null
            New-ArquivoIdade (Join-Path $velha 'x.tmp') 5 (Get-Date).AddDays(-3)
            (Get-Item -LiteralPath $velha).LastWriteTime = (Get-Date).AddDays(-3)
            Invoke-Limp 'limpar' @{ categorias = @('temp_usuario') } | Out-Null
            Test-Path -LiteralPath $velha | Should -BeFalse
            Test-Path -LiteralPath $nova | Should -BeTrue
        }
        It 'falha de ferramenta externa vai para falhas, nao para pulados' {
            Mock Invoke-LimparDism { throw 'DISM terminou com código 5' }
            $r = Invoke-Limp 'limpar' @{ categorias = @('dism_componentes', 'temp_usuario') }
            $r.ok | Should -BeTrue
            $r.dados.pulados | Should -Be 0
            @($r.dados.falhas).Count | Should -Be 1
            $r.dados.falhas[0].id | Should -Be 'dism_componentes'
            $r.dados.falhas[0].erro | Should -Match 'DISM'
            $r.dados.detalhes[1].erro | Should -BeNullOrEmpty
        }
        It 'sem falhas devolve falhas vazia' {
            $r = Invoke-Limp 'limpar' @{ categorias = @('temp_usuario') }
            @($r.dados.falhas).Count | Should -Be 0
            $Script:UltimaSaida | Should -Match '"falhas":\[\]'
        }
        It 'dono nao confiavel sob a base protegida e recusado' {
            $base = Join-Path $env:TEMP 'OtimizadorTeste\pd'
            $fab = Join-Path $base 'Fabricante'
            $pasta = Join-Path $fab 'Cache'
            New-Item -ItemType Directory -Path $pasta -Force | Out-Null
            $admins = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'
            $acl = Get-Acl -LiteralPath $fab
            $acl.SetOwner($admins)
            Set-Acl -LiteralPath $fab -AclObject $acl
            $acl = Get-Acl -LiteralPath $pasta
            $acl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
            Set-Acl -LiteralPath $pasta -AclObject $acl
            Test-DonoRaiz $pasta $base | Should -BeFalse
            $acl.SetOwner($admins)
            Set-Acl -LiteralPath $pasta -AclObject $acl
            Test-DonoRaiz $pasta $base | Should -BeTrue
            Test-DonoRaiz (Join-Path $Script:Raiz 'temp_usuario') $base | Should -BeTrue
        }
        It 'recusa raiz perigosa' {
            Test-RaizSegura "$env:SystemDrive\" | Should -BeFalse
            Test-RaizSegura $env:windir | Should -BeFalse
            Test-RaizSegura "$env:windir\" | Should -BeFalse
            Test-RaizSegura $env:USERPROFILE | Should -BeFalse
            Test-RaizSegura $env:ProgramFiles | Should -BeFalse
            Test-RaizSegura $env:LOCALAPPDATA | Should -BeFalse
            Test-RaizSegura $env:ProgramData | Should -BeFalse
            Test-RaizSegura '' | Should -BeFalse
            Test-RaizSegura 'C:\.' | Should -BeFalse
            Test-RaizSegura 'C:\x\..' | Should -BeFalse
            Test-RaizSegura '\Temp' | Should -BeFalse
            Test-RaizSegura 'Temp' | Should -BeFalse
            Test-RaizSegura "$env:LOCALAPPDATA\D3DSCache" | Should -BeTrue
            Test-RaizSegura (Join-Path $Script:Raiz 'temp_usuario') | Should -BeTrue
        }
    }

    Context 'pontos_antigos (selecao pura)' {
        BeforeAll {
            function Get-SombraFalsa { param($Id, $Vol, $Data, $Acessivel = $true) return [pscustomobject]@{ ID = $Id; VolumeName = $Vol; InstallDate = $Data; ClientAccessible = $Acessivel } }
        }
        It 'dois volumes: so as mais antigas do volume do sistema' {
            $s = @(
                (Get-SombraFalsa '{A}' 'C' ([datetime]'2026-01-01')), (Get-SombraFalsa '{B}' 'C' ([datetime]'2026-02-01')),
                (Get-SombraFalsa '{C}' 'C' ([datetime]'2026-03-01')), (Get-SombraFalsa '{D}' 'D' ([datetime]'2026-04-01')),
                (Get-SombraFalsa '{E}' 'D' ([datetime]'2025-01-01')))
            @(Get-SombraParaApagar $s 'C') | Should -Be @('{B}', '{A}')
        }
        It 'uma unica sombra no sistema: nada' {
            @(Get-SombraParaApagar @((Get-SombraFalsa '{A}' 'C' (Get-Date)), (Get-SombraFalsa '{D}' 'D' (Get-Date))) 'C').Count | Should -Be 0
        }
        It 'sombras so de outro volume: nada' {
            @(Get-SombraParaApagar @((Get-SombraFalsa '{A}' 'D' (Get-Date)), (Get-SombraFalsa '{B}' 'D' (Get-Date).AddDays(-5))) 'C').Count | Should -Be 0
        }
        It 'ignora sombras nao acessiveis ao cliente' {
            @(Get-SombraParaApagar @((Get-SombraFalsa '{A}' 'C' (Get-Date)), (Get-SombraFalsa '{B}' 'C' (Get-Date).AddDays(-1) $false)) 'C').Count | Should -Be 0
        }
    }

    Context 'cleanmgr somente um handler' {
        It 'define a flag so no handler pedido e restaura as dos outros' {
            $base = 'HKCU:\Software\OtimizadorTeste\VolumeCaches'
            try {
                New-Item -Path "$base\Previous Installations" -Force | Out-Null
                New-Item -Path "$base\DownloadsFolder" -Force | Out-Null
                New-Item -Path "$base\Outro" -Force | Out-Null
                Set-ItemProperty -LiteralPath "$base\DownloadsFolder" -Name 'StateFlags0099' -Value 2 -Type DWord
                Set-ItemProperty -LiteralPath "$base\Outro" -Name 'StateFlags0042' -Value 2 -Type DWord
                Invoke-CleanmgrSomente 'Previous Installations' 99 $base $true
                (Get-ItemProperty -LiteralPath "$base\DownloadsFolder").StateFlags0099 | Should -Be 2
                (Get-ItemProperty -LiteralPath "$base\Outro").StateFlags0042 | Should -Be 2
                (Get-ItemProperty -LiteralPath "$base\Previous Installations").StateFlags0099 | Should -BeNullOrEmpty
            } finally { Remove-Item -LiteralPath 'HKCU:\Software\OtimizadorTeste' -Recurse -Force -ErrorAction SilentlyContinue }
        }
        It 'remove a flag dos outros antes da execucao (observado no ponto do cleanmgr)' {
            $base = 'HKCU:\Software\OtimizadorTeste\VolumeCaches'
            try {
                New-Item -Path "$base\Previous Installations" -Force | Out-Null
                New-Item -Path "$base\DownloadsFolder" -Force | Out-Null
                Set-ItemProperty -LiteralPath "$base\DownloadsFolder" -Name 'StateFlags0099' -Value 2 -Type DWord
                $Script:Obs = $null
                $Script:Chamou = $false
                Mock Start-Process { $Script:Obs = (Get-ItemProperty -LiteralPath 'HKCU:\Software\OtimizadorTeste\VolumeCaches\DownloadsFolder').StateFlags0099; $Script:Chamou = $true }
                Invoke-CleanmgrSomente 'Previous Installations' 99 $base $false
                $Script:Chamou | Should -BeTrue
                $Script:Obs | Should -BeNullOrEmpty
                (Get-ItemProperty -LiteralPath "$base\DownloadsFolder").StateFlags0099 | Should -Be 2
            } finally { Remove-Item -LiteralPath 'HKCU:\Software\OtimizadorTeste' -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}