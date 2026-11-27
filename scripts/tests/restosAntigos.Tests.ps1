BeforeAll {
    . "$PSScriptRoot\..\common.ps1"
    . "$PSScriptRoot\..\programas.ps1"
    . "$PSScriptRoot\_helpers.ps1"
    $Script:Base = Join-Path $env:TEMP 'NexTuneTeste'
    $Script:RA = Join-Path $Script:Base 'restosAntigos'       # raizes do modo teste (Get-RaizRestoAntigo)
    $Script:Fora = Join-Path $Script:Base 'restosAntigosFora' # fora das raizes (alvo de juncao, locais de programas)
    $Script:UninstallT = 'HKCU:\Software\NexTuneTeste\Uninstall'

    # Executa uma acao do modulo capturando o protocolo; devolve o @@RESULT (objeto) ou $null se nao houver exatamente um.
    function Invoke-P {
        param([string]$Acao, $Params = @{}, [bool]$Teste = $true)
        $sw = New-Object System.IO.StringWriter
        Set-Saida $sw
        try { Invoke-Acao 'ra1' $Acao $Params $Teste } finally { Set-Saida $null }
        $Script:UltimaSaida = $sw.ToString()
        $linhas = @($sw.ToString() -split "`r?`n" | Where-Object { $_.StartsWith('@@RESULT ') })
        if ($linhas.Count -ne 1) { return $null }
        return $linhas[0].Substring(9) | ConvertFrom-Json
    }
    function New-ProgramaFalso {
        # Chave do Uninstall falso (hive hkcu do modo teste).
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param([string]$Chave, [hashtable]$Valores)
        $k = Join-Path (Join-Path $Script:UninstallT 'hkcu') $Chave
        New-Item -Path $k -Force | Out-Null
        foreach ($n in $Valores.Keys) { Set-ItemProperty -LiteralPath $k -Name $n -Value ([string]$Valores[$n]) -Type String }
    }
    function Set-Idade {
        # Envelhece a pasta e tudo dentro dela (filhos antes do pai, porque criar um filho muda a data do pai).
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param([string]$Pasta, [int]$Dias = 60)
        $data = (Get-Date).AddDays(-$Dias)
        $itens = @(Get-ChildItem -LiteralPath $Pasta -Recurse -Force | Sort-Object -Property @{ Expression = { $_.FullName.Length }; Descending = $true })
        foreach ($i in $itens) { $i.LastWriteTime = $data }
        (Get-Item -LiteralPath $Pasta -Force).LastWriteTime = $data
    }
    function New-PastaResto {
        # Pasta sob uma raiz de teste com um arquivo de $Bytes bytes; envelhecida $Dias dias (0 = recente).
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param([string]$Raiz, [string]$Nome, [int]$Bytes = 100, [int]$Dias = 60, [string]$Arquivo = 'dados.txt')
        $p = Join-Path (Join-Path $Script:RA $Raiz) $Nome
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $p $Arquivo), (New-Object byte[] $Bytes))
        if ($Dias -gt 0) { Set-Idade $p $Dias }
        return $p
    }
    function New-AtalhoTeste {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param([string]$Caminho, [string]$Alvo)
        $pai = Split-Path -Parent $Caminho
        if (-not (Test-Path -LiteralPath $pai)) { New-Item -ItemType Directory -Path $pai -Force | Out-Null }
        $ws = New-Object -ComObject WScript.Shell
        $s = $ws.CreateShortcut($Caminho)
        $s.TargetPath = $Alvo
        $s.Save()
    }
    function Get-Item1 {
        # Item do resultado pelo caminho (comparando a forma longa); $null se nao estiver.
        param($R, [string]$Caminho)
        $alvo = Get-CaminhoLongo $Caminho
        foreach ($i in @($R.dados.itens)) { if ((Get-CaminhoLongo $i.caminho) -eq $alvo) { return $i } }
        return $null
    }
    function Get-NomeItem { param($R) return @(@($R.dados.itens) | ForEach-Object { $_.nome }) }
    function Get-LetraLivre {
        $usadas = @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpperInvariant() })
        foreach ($l in @('Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'P', 'O', 'N', 'M')) { if ($usadas -notcontains $l) { return $l } }
        return $null
    }
}

AfterAll {
    foreach ($j in @(Get-ChildItem -LiteralPath $Script:RA -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { Test-Reparse $_ })) { Remove-Juncao $j.FullName }
    foreach ($p in @($Script:RA, $Script:Fora)) {
        if (Test-Path -LiteralPath $p) { Remove-PastaSegura $p }
    }
    Remove-Item -LiteralPath $Script:UninstallT -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'programas.ps1 restosAntigos' {
    BeforeEach {
        if (Test-Path -LiteralPath $Script:UninstallT) { Remove-Item -LiteralPath $Script:UninstallT -Recurse -Force -ErrorAction SilentlyContinue }
        foreach ($p in @($Script:RA, $Script:Fora)) {
            if (Test-Path -LiteralPath $p) { Remove-PastaSegura $p }
            New-Item -ItemType Directory -Path $p -Force | Out-Null
        }
        foreach ($r in @('ProgramFiles', 'ProgramFilesX86', 'ProgramData', 'AppData', 'LocalAppData', 'LocalAppDataPrograms', 'Menu', 'MenuTodos')) {
            New-Item -ItemType Directory -Path (Join-Path $Script:RA $r) -Force | Out-Null
        }
        New-Item -ItemType Directory -Path (Join-Path $Script:Fora 'Qualquer') -Force | Out-Null
        New-ProgramaFalso 'Qualquer' @{ DisplayName = 'Programa Qualquer'; Publisher = 'Editor Teste'; InstallLocation = (Join-Path $Script:Fora 'Qualquer') }
        New-ProgramaFalso 'Acrobat' @{ DisplayName = 'Adobe Acrobat (64-bit)'; DisplayVersion = '24.1' }
        New-ProgramaFalso 'Steam' @{ DisplayName = 'Steam'; Publisher = 'Valve Corporation' }
    }

    Context 'nome limpo (regra do RetroLimpia)' {
        It 'tira parenteses, versao, arquitetura e " - sufixo"' {
            Get-NomeLimpo 'Programa Qualquer (x64) 2.1.3 - Edição Especial' | Should -Be 'Programa Qualquer'
            Get-NomeLimpo '7-Zip 23.01 (x64)' | Should -Be '7-Zip'
            Get-NomeLimpo 'Ferramenta x86 v1.2' | Should -Be 'Ferramenta'
            Get-ChaveNome 'Programa-Qualquer.Novo' | Should -Be 'programaqualquernovo'
            Get-EditorLimpo 'Valve Corporation' | Should -Be 'Valve'
            Get-EditorLimpo 'Fabricante Co., Ltd.' | Should -Be 'Fabricante'
        }
    }

    Context 'pastas' {
        It 'pasta de programa removido e achada e marcada como segura' {
            $p = New-PastaResto 'ProgramFiles' 'Programa Removido' 100
            $r = Invoke-P 'restosAntigos'
            $r.ok | Should -BeTrue
            $i = Get-Item1 $r $p
            $i | Should -Not -BeNullOrEmpty
            $i.tipo | Should -Be 'pasta'
            $i.nome | Should -Be 'Programa Removido'
            $i.bytes | Should -Be 100
            $i.seguro | Should -BeTrue
            $i.parecido | Should -BeNullOrEmpty
            $i.motivo | Should -Match 'não está mais instalado'
            $Script:UltimaSaida | Should -Match '"parecido":null'
        }
        It 'acha em todas as raizes (ProgramFiles, x86, ProgramData, AppData, LocalAppData e Programs)' {
            $ps = foreach ($raiz in @('ProgramFiles', 'ProgramFilesX86', 'ProgramData', 'AppData', 'LocalAppData', 'LocalAppDataPrograms')) { New-PastaResto $raiz "Orfao $raiz" }
            $r = Invoke-P 'restosAntigos'
            foreach ($p in $ps) { (Get-Item1 $r $p).seguro | Should -BeTrue }
        }
        It 'pasta com nome parecido de programa ainda instalado aparece sem ser segura (Adobe x Adobe Acrobat)' {
            $p = New-PastaResto 'AppData' 'Adobe' 100
            $r = Invoke-P 'restosAntigos'
            $i = Get-Item1 $r $p
            $i | Should -Not -BeNullOrEmpty
            $i.seguro | Should -BeFalse
            $i.parecido | Should -Be 'Adobe Acrobat (64-bit)'
            $i.motivo | Should -Match 'parece com o de um programa instalado'
            # com o editor 'Adobe Inc.' a pasta e a do editor de um programa instalado: nem aparece
            New-ProgramaFalso 'Acrobat' @{ DisplayName = 'Adobe Acrobat (64-bit)'; Publisher = 'Adobe Inc.' }
            Get-Item1 (Invoke-P 'restosAntigos') $p | Should -BeNullOrEmpty
        }
        It 'palavra de 4+ letras em comum com um programa instalado tambem e parecido (nuvem-cli-cache x Ferramenta Nuvem)' {
            New-ProgramaFalso 'Nuvem' @{ DisplayName = 'Ferramenta Nuvem'; Publisher = 'Empresa Exemplo' }
            $p = New-PastaResto 'LocalAppData' 'nuvem-cli-cache'
            $g = New-PastaResto 'LocalAppData' 'Programa Removido Cache'   # 'programa' e 'cache' sao genericas
            $r = Invoke-P 'restosAntigos'
            (Get-Item1 $r $p).seguro | Should -BeFalse
            (Get-Item1 $r $p).parecido | Should -Be 'Ferramenta Nuvem'
            (Get-Item1 $r $g).seguro | Should -BeTrue
        }
        It 'app da Store vinda de simular: editor igual esconde, parte do nome parecida marca como nao segura' {
            $p = New-PastaResto 'LocalAppData' 'Spotify' 100
            $loja = @(@{ PackageFullName = 'SpotifyAB.SpotifyMusic_1.0.0.0_x64__zpdnekdrzrea0'; PackageFamilyName = 'SpotifyAB.SpotifyMusic_zpdnekdrzrea0'; Name = 'SpotifyAB.SpotifyMusic'; Publisher = 'CN=Empresa Musical Ltda'; Version = '1.0.0.0'; InstallLocation = ''; SignatureKind = 'Store'; IsFramework = $false; NonRemovable = $false })
            (Get-Item1 (Invoke-P 'restosAntigos') $p).seguro | Should -BeTrue
            $i = Get-Item1 (Invoke-P 'restosAntigos' @{ simular = @{ store = $loja } }) $p
            $i.seguro | Should -BeFalse
            $i.parecido | Should -Be 'SpotifyAB.SpotifyMusic'
            $loja[0].Publisher = 'CN=Spotify AB'
            Get-Item1 (Invoke-P 'restosAntigos' @{ simular = @{ store = $loja } }) $p | Should -BeNullOrEmpty
        }
        It 'nome curto (menos de 4 letras) nunca e seguro; parecido se for palavra do nome de um programa' {
            New-ProgramaFalso 'HPSmart' @{ DisplayName = 'HP Smart'; Publisher = 'Fabricante Grande' }
            New-ProgramaFalso 'LGTool' @{ DisplayName = 'Painel'; Publisher = 'LG Inc.' }
            $hp = New-PastaResto 'ProgramData' 'HP'
            $xy = New-PastaResto 'ProgramData' 'XYZ'
            $lg = New-PastaResto 'ProgramData' 'LG'
            $r = Invoke-P 'restosAntigos'
            Get-Item1 $r $lg | Should -BeNullOrEmpty   # igual ao editor (sem 'Inc.'): e do programa instalado
            (Get-Item1 $r $hp).seguro | Should -BeFalse
            (Get-Item1 $r $hp).parecido | Should -Be 'HP Smart'
            (Get-Item1 $r $xy).seguro | Should -BeFalse
            (Get-Item1 $r $xy).parecido | Should -BeNullOrEmpty
        }
        It 'pasta de programa instalado nao aparece: nome, editor, nome com versao e InstallLocation' {
            New-Item -ItemType Directory -Path (Join-Path $Script:RA 'ProgramFilesX86\Pacote Grande\App') -Force | Out-Null
            New-ProgramaFalso 'Ferramenta' @{ DisplayName = 'Ferramenta Diferente'; Publisher = 'Outra Empresa'; InstallLocation = (Join-Path $Script:RA 'ProgramFilesX86\Pacote Grande\App') }
            New-ProgramaFalso 'Unins' @{ DisplayName = 'Utilitario Sem Local'; UninstallString = ('"' + (Join-Path $Script:RA 'ProgramFiles\Pasta do Desinstalador\uninst.exe') + '" /x') }
            $pacote = Join-Path $Script:RA 'ProgramFilesX86\Pacote Grande'
            [IO.File]::WriteAllBytes((Join-Path $pacote 'leia.txt'), (New-Object byte[] 10))
            Set-Idade $pacote
            $ps = @(
                (New-PastaResto 'LocalAppData' 'Programa Qualquer'),
                (New-PastaResto 'ProgramData' 'Editor Teste'),
                (New-PastaResto 'AppData' 'Programa-Qualquer 2.0 (x64)'),
                (New-PastaResto 'ProgramData' 'Valve'),
                (New-PastaResto 'ProgramFiles' 'Steam'),
                (New-PastaResto 'ProgramFiles' 'Pasta do Desinstalador'),
                $pacote
            )
            $r = Invoke-P 'restosAntigos'
            $r.ok | Should -BeTrue
            foreach ($p in $ps) { Get-Item1 $r $p | Should -BeNullOrEmpty -Because $p }
        }
        It 'pasta protegida, de protegidos.json, de segmento proibido ou da lista ignorar nunca aparece' {
            $ps = @(
                (New-PastaResto 'LocalAppData' 'Temp'),
                (New-PastaResto 'LocalAppData' 'Packages'),
                (New-PastaResto 'LocalAppData' 'CrashDumps'),
                (New-PastaResto 'ProgramData' 'regid.1991-06.com.microsoft'),
                (New-PastaResto 'ProgramData' 'Package Cache'),
                (New-PastaResto 'ProgramData' '{11111111-2222-3333-4444-555555555555}'),
                (New-PastaResto 'ProgramFiles' 'NVIDIA Corporation'),
                (New-PastaResto 'ProgramFiles' 'Intel'),
                (New-PastaResto 'ProgramFiles' 'Microsoft Office Antigo'),
                (New-PastaResto 'ProgramFiles' 'Windows Kits'),
                (New-PastaResto 'ProgramFiles' 'DirectX Antigo'),
                (New-PastaResto 'ProgramFiles' 'GameInput'),
                (New-PastaResto 'ProgramFiles' 'NexTune'),
                (New-PastaResto 'AppData' 'Classes'),
                (New-PastaResto 'AppData' 'Google'),
                (New-PastaResto 'LocalAppData' 'Programs')
            )
            $controle = New-PastaResto 'ProgramFiles' 'Programa Removido'
            $r = Invoke-P 'restosAntigos'
            (Get-Item1 $r $controle).seguro | Should -BeTrue
            foreach ($p in $ps) { Get-Item1 $r $p | Should -BeNullOrEmpty -Because $p }
        }
        It 'caminho protegido do Windows nunca aparece (raiz real sob %windir%)' {
            Mock Get-RaizRestoAntigo { return @{ pastas = @($env:windir, (Join-Path $Script:RA 'ProgramFiles')); atalhos = @() } }
            $controle = New-PastaResto 'ProgramFiles' 'Programa Removido'
            $r = Invoke-P 'restosAntigos'
            $r.ok | Should -BeTrue
            (Get-Item1 $r $controle).seguro | Should -BeTrue
            $win = $env:windir.TrimEnd('\') + '\'
            @(@($r.dados.itens) | Where-Object { $_.caminho.StartsWith($win, [StringComparison]::OrdinalIgnoreCase) }).Count | Should -Be 0
            foreach ($i in @($r.dados.itens)) { Test-ProtectedPath $i.caminho | Should -BeFalse }
        }
        It 'pasta alterada ha menos de 30 dias e pasta com .exe/.dll nao aparecem' {
            $recente = New-PastaResto 'ProgramFiles' 'Recente Orfao' 100 0
            $quase = New-PastaResto 'ProgramFiles' 'Quase Velho' 100 20
            $exe = New-PastaResto 'ProgramFiles' 'Portatil Orfao' 100 60 'app.exe'
            $dll = New-PastaResto 'AppData' 'Biblioteca Orfa' 100 60 'lib.dll'
            # arquivo recente la no fundo tambem conta
            $fundo = New-PastaResto 'ProgramData' 'Fundo Orfao'
            New-Item -ItemType Directory -Path (Join-Path $fundo 'sub') -Force | Out-Null
            [IO.File]::WriteAllBytes((Join-Path $fundo 'sub\novo.txt'), (New-Object byte[] 5))
            (Get-Item -LiteralPath $fundo).LastWriteTime = (Get-Date).AddDays(-60)
            $r = Invoke-P 'restosAntigos'
            foreach ($p in @($recente, $quase, $exe, $dll, $fundo)) { Get-Item1 $r $p | Should -BeNullOrEmpty -Because $p }
        }
        It 'juncao nao aparece e nao e seguida' {
            $alvo = Join-Path $Script:Fora 'Alvo Orfao'
            New-Item -ItemType Directory -Path $alvo -Force | Out-Null
            [IO.File]::WriteAllBytes((Join-Path $alvo 'dados.txt'), (New-Object byte[] 50))
            Set-Idade $alvo
            $jn = Join-Path $Script:RA 'ProgramData\Juncao Orfa'
            $comJuncao = New-PastaResto 'AppData' 'Com Juncao Dentro'
            $jn2 = Join-Path $comJuncao 'link'
            try {
                New-Juncao $jn $alvo
                New-Juncao $jn2 $alvo
                Set-Idade $comJuncao
                (Get-Item -LiteralPath $jn -Force).Attributes -band [IO.FileAttributes]::ReparsePoint | Should -Not -Be 0
                $r = Invoke-P 'restosAntigos'
                $r.ok | Should -BeTrue
                Get-Item1 $r $jn | Should -BeNullOrEmpty
                Get-Item1 $r $comJuncao | Should -BeNullOrEmpty
                @(Get-NomeItem $r) -contains 'Alvo Orfao' | Should -BeFalse
                @(@($r.dados.itens) | Where-Object { $_.caminho -like '*Alvo Orfao*' }).Count | Should -Be 0
            } finally {
                Remove-Juncao $jn
                Remove-Juncao $jn2
            }
            Test-Path -LiteralPath (Join-Path $alvo 'dados.txt') | Should -BeTrue
        }
        It 'raiz que e juncao nao e percorrida' {
            $alvo = Join-Path $Script:Fora 'RaizFalsa'
            New-Item -ItemType Directory -Path (Join-Path $alvo 'Orfao Na Juncao') -Force | Out-Null
            [IO.File]::WriteAllBytes((Join-Path $alvo 'Orfao Na Juncao\a.txt'), (New-Object byte[] 5))
            Set-Idade $alvo
            $raiz = Join-Path $Script:RA 'LocalAppDataPrograms'
            Remove-Item -LiteralPath $raiz -Recurse -Force
            try {
                New-Juncao $raiz $alvo
                $r = Invoke-P 'restosAntigos'
                $r.ok | Should -BeTrue
                @(Get-NomeItem $r) -contains 'Orfao Na Juncao' | Should -BeFalse
            } finally { Remove-Juncao $raiz }
        }
    }

    Context 'atalhos' {
        It 'atalho quebrado aparece e e seguro; atalho valido, de rede ou de unidade ausente nao aparece' {
            $quebrado = Join-Path $Script:RA 'Menu\Jogo Velho\Jogo Velho.lnk'
            $todos = Join-Path $Script:RA 'MenuTodos\Agenda Antiga.lnk'
            $valido = Join-Path $Script:RA 'Menu\Bloco.lnk'
            $rede = Join-Path $Script:RA 'Menu\Rede.lnk'
            New-AtalhoTeste $quebrado 'C:\nao-existe-nextune\jogo\jogo.exe'
            New-AtalhoTeste $todos 'C:\nao-existe-nextune\agenda\agenda.exe'
            New-AtalhoTeste $valido (Join-Path $env:windir 'System32\notepad.exe')
            New-AtalhoTeste $rede '\\servidor-inexistente-nextune\share\app.exe'
            $letra = Get-LetraLivre
            $ausente = Join-Path $Script:RA 'Menu\Pendrive.lnk'
            if ($null -ne $letra) { New-AtalhoTeste $ausente ($letra + ':\Programas\app.exe') }
            $r = Invoke-P 'restosAntigos'
            $r.ok | Should -BeTrue
            $i = Get-Item1 $r $quebrado
            $i.tipo | Should -Be 'atalho'
            $i.nome | Should -Be 'Jogo Velho'
            $i.seguro | Should -BeTrue
            $i.parecido | Should -BeNullOrEmpty
            $i.motivo | Should -Match 'destino não existe mais'
            $i.bytes | Should -BeGreaterThan 0
            (Get-Item1 $r $todos).seguro | Should -BeTrue
            Get-Item1 $r $valido | Should -BeNullOrEmpty
            Get-Item1 $r $rede | Should -BeNullOrEmpty
            if ($null -ne $letra) { Get-Item1 $r $ausente | Should -BeNullOrEmpty }
        }
        It 'atalho quebrado com nome de programa instalado ou destino na pasta dele nao e seguro' {
            $pq = Join-Path $Script:RA 'Menu\Programa Qualquer.lnk'
            $ad = Join-Path $Script:RA 'Menu\Adobe.lnk'
            $local = Join-Path $Script:RA 'Menu\Outro Nome.lnk'
            $pasta = Join-Path $Script:RA 'Menu\Pasta Existe.lnk'
            New-AtalhoTeste $pq 'C:\nao-existe-nextune\pq\pq.exe'
            New-AtalhoTeste $ad 'C:\nao-existe-nextune\adobe\a.exe'
            New-AtalhoTeste $local (Join-Path $Script:Fora 'Qualquer\versao-antiga.exe')
            New-AtalhoTeste $pasta (Join-Path $Script:Fora 'sumiu.exe')
            $r = Invoke-P 'restosAntigos'
            (Get-Item1 $r $pq).seguro | Should -BeFalse
            (Get-Item1 $r $pq).parecido | Should -Be 'Programa Qualquer'
            (Get-Item1 $r $ad).seguro | Should -BeFalse
            (Get-Item1 $r $ad).parecido | Should -Be 'Adobe Acrobat (64-bit)'
            (Get-Item1 $r $local).seguro | Should -BeFalse
            (Get-Item1 $r $local).parecido | Should -Be 'Programa Qualquer'
            (Get-Item1 $r $pasta).seguro | Should -BeFalse
            (Get-Item1 $r $pasta).motivo | Should -Match 'pasta do destino ainda existe'
        }
    }

    Context 'resultado' {
        It 'seguros primeiro, depois por bytes decrescente' {
            New-PastaResto 'ProgramFiles' 'Pequeno Orfao' 10 | Out-Null
            New-PastaResto 'ProgramFiles' 'Grande Orfao' 5000 | Out-Null
            New-PastaResto 'AppData' 'Medio Orfao' 300 | Out-Null
            New-PastaResto 'AppData' 'Adobe' 90000 | Out-Null
            $r = Invoke-P 'restosAntigos'
            @(Get-NomeItem $r) | Should -Be @('Grande Orfao', 'Medio Orfao', 'Pequeno Orfao', 'Adobe')
            @(@($r.dados.itens) | ForEach-Object { $_.seguro }) | Should -Be @($true, $true, $true, $false)
        }
        It 'no maximo 500 itens, mantendo os seguros e maiores' {
            $raiz = Join-Path $Script:RA 'ProgramData'
            $data = (Get-Date).AddDays(-60)
            for ($n = 0; $n -lt 501; $n++) {
                $p = Join-Path $raiz ('Orfao Numero {0:D3}' -f $n)
                [void][IO.Directory]::CreateDirectory($p)
                $f = Join-Path $p 'd.txt'
                [IO.File]::WriteAllBytes($f, (New-Object byte[] (1 + $n)))
                [IO.File]::SetLastWriteTime($f, $data)
                [IO.Directory]::SetLastWriteTime($p, $data)
            }
            New-PastaResto 'AppData' 'Adobe' 90000 | Out-Null
            $r = Invoke-P 'restosAntigos'
            $r.ok | Should -BeTrue
            $itens = @($r.dados.itens)
            $itens.Count | Should -Be 500
            $Script:MaxItensRestos | Should -Be 500
            @($itens | Where-Object { -not $_.seguro }).Count | Should -Be 0
            $itens[0].nome | Should -Be 'Orfao Numero 500'
            $itens[499].nome | Should -Be 'Orfao Numero 001'
            $Script:UltimaSaida | Should -Match '@@LOG .*mostrando os primeiros 500'
        }
        It 'todo item devolvido seria aceito por limparRestos (e vai para a quarentena)' {
            New-PastaResto 'ProgramFiles' 'Programa Removido' | Out-Null
            New-PastaResto 'AppData' 'Adobe' | Out-Null
            New-AtalhoTeste (Join-Path $Script:RA 'Menu\Jogo Velho.lnk') 'C:\nao-existe-nextune\jogo\jogo.exe'
            $r = Invoke-P 'restosAntigos'
            $itens = @($r.dados.itens)
            $itens.Count | Should -Be 3
            foreach ($i in $itens) {
                $i.caminho | Should -Match '^[A-Za-z]:\\.'
                Test-ProtectedPath $i.caminho | Should -BeFalse
                @('pasta', 'atalho') -ccontains $i.tipo | Should -BeTrue
                if ($i.tipo -eq 'atalho') { [IO.Path]::GetExtension($i.caminho) | Should -Be '.lnk' }
                ($i.bytes -is [int] -or $i.bytes -is [long]) | Should -BeTrue
                $i.seguro | Should -BeOfType [bool]
                $i.motivo | Should -Not -BeNullOrEmpty
            }
            $l = Invoke-P 'limparRestos' @{ itens = @($itens | ForEach-Object { @{ tipo = $_.tipo; caminho = $_.caminho } }); confirmado = $true; nome = 'restos antigos' }
            $l.ok | Should -BeTrue
            $l.dados.movidos | Should -Be 3
            @($l.dados.falhas).Count | Should -Be 0
        }
        It 'progresso em pt-BR e exatamente um @@RESULT' {
            $r = Invoke-P 'restosAntigos'
            $r.ok | Should -BeTrue
            @($r.dados.itens).Count | Should -Be 0
            $Script:UltimaSaida | Should -Match '"itens":\[\]'
            $Script:UltimaSaida | Should -Match 'Lendo programas instalados'
            $Script:UltimaSaida | Should -Match 'Procurando pastas sem programa'
            $Script:UltimaSaida | Should -Match 'Procurando atalhos quebrados'
        }
        It 'erro inesperado devolve exatamente um @@RESULT ok:false' {
            Mock Get-RaizRestoAntigo { throw 'falha simulada' }
            $r = Invoke-P 'restosAntigos'
            $r | Should -Not -BeNullOrEmpty
            $r.ok | Should -BeFalse
            $r.erro | Should -Match 'falha simulada'
        }
        It 'acao desconhecida continua falhando' {
            $r = Invoke-P 'restosantigos'
            $r.ok | Should -BeFalse
            $r.erro | Should -Be 'ação desconhecida'
        }
    }

    Context 'fora do modo teste' {
        It 'simular e ignorado: a Store vem do sistema, nao da lista simulada' {
            Mock Get-RaizRestoAntigo { return @{ pastas = @((Join-Path $Script:RA 'AppData')); atalhos = @() } }
            Mock Get-ProgramaClassico { return @(New-Programa -Id 'cl:hkcu:Outro' -Tipo 'classico' -Nome 'Outro Programa' -Editor 'Outra Empresa') }
            Mock Get-PacoteStore { return @() }
            $p = New-PastaResto 'AppData' 'Spotify'
            $loja = @(@{ PackageFullName = 'SpotifyAB.SpotifyMusic_1.0.0.0_x64__zpdnekdrzrea0'; PackageFamilyName = 'SpotifyAB.SpotifyMusic_zpdnekdrzrea0'; Name = 'SpotifyAB.SpotifyMusic'; Publisher = 'CN=Spotify AB'; Version = '1.0.0.0'; InstallLocation = ''; SignatureKind = 'Store'; IsFramework = $false; NonRemovable = $false })
            $r = Invoke-P 'restosAntigos' @{ simular = @{ store = $loja } } $false
            $r.ok | Should -BeTrue
            (Get-Item1 $r $p).seguro | Should -BeTrue
            Should -Invoke Get-PacoteStore -Times 1 -Exactly -ParameterFilter { -not $Teste -and $null -eq $Simulacao }
        }
        It 'sem nenhum programa classico lido, recusa em vez de marcar tudo como resto' {
            Mock Get-RaizRestoAntigo { return @{ pastas = @((Join-Path $Script:RA 'AppData')); atalhos = @() } }
            Mock Get-ProgramaClassico { return @() }
            Mock Get-PacoteStore { return @() }
            Mock Write-AppLog { }
            New-PastaResto 'AppData' 'Programa Removido' | Out-Null
            $r = Invoke-P 'restosAntigos' @{} $false
            $r.ok | Should -BeFalse
            $r.erro | Should -Match 'programas instalados'
        }
    }
}
