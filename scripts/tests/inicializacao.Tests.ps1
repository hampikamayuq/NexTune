BeforeAll {
    . "$PSScriptRoot\..\common.ps1"
    . "$PSScriptRoot\..\inicializacao.ps1"
    . "$PSScriptRoot\_helpers.ps1"
    $Script:RaizT = 'HKCU:\Software\NexTuneTeste\Inicio'
    $Script:PastaT = Join-Path (Join-Path $env:TEMP 'NexTuneTeste') 'inicio'
    $Script:Notepad = "$env:windir\System32\notepad.exe"

    # Executa uma acao do modulo capturando o protocolo; devolve o @@RESULT (objeto) ou $null.
    function Invoke-Ini {
        param([string]$Acao, $Params = @{}, [bool]$Teste = $true)
        $sw = New-Object System.IO.StringWriter
        Set-Saida $sw
        try { Invoke-Acao 'i1' $Acao $Params $Teste } finally { Set-Saida $null }
        $Script:UltimaSaida = $sw.ToString()
        $linhas = @($sw.ToString() -split "`r?`n" | Where-Object { $_.StartsWith('@@RESULT ') })
        if ($linhas.Count -ne 1) { return $null }
        return $linhas[0].Substring(9) | ConvertFrom-Json
    }
    function New-RunTeste {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param([string]$Hive, [string]$Nome, [string]$Comando)
        $k = Join-Path (Join-Path $Script:RaizT 'Run') $Hive
        # New-Item -Force em chave existente apaga os valores: so cria se faltar.
        if (-not (Test-Path -LiteralPath $k)) { New-Item -Path $k -Force | Out-Null }
        Set-ItemProperty -LiteralPath $k -Name $Nome -Value $Comando -Type String
    }
    function Get-ChaveAprovadoTeste {
        param([string]$HiveAprov, [string]$Sub)
        return (Join-Path (Join-Path (Join-Path $Script:RaizT 'StartupApproved') $HiveAprov) $Sub)
    }
    function Set-AprovadoTeste {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param([string]$HiveAprov, [string]$Sub, [string]$Nome, [byte[]]$Bytes)
        $k = Get-ChaveAprovadoTeste $HiveAprov $Sub
        # New-Item -Force em chave existente apaga os valores: so cria se faltar.
        if (-not (Test-Path -LiteralPath $k)) { New-Item -Path $k -Force | Out-Null }
        Set-ItemProperty -LiteralPath $k -Name $Nome -Value $Bytes -Type Binary
    }
    function Get-AprovadoTeste {
        param([string]$HiveAprov, [string]$Sub, [string]$Nome)
        $k = Get-ChaveAprovadoTeste $HiveAprov $Sub
        if (-not (Test-Path -LiteralPath $k)) { return $null }
        return (Get-Item -LiteralPath $k).GetValue($Nome)
    }
    function New-AtalhoInicio {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param([string]$Escopo, [string]$Arquivo, [string]$Alvo)
        $pasta = Join-Path $Script:PastaT $Escopo
        if (-not (Test-Path -LiteralPath $pasta)) { New-Item -ItemType Directory -Path $pasta -Force | Out-Null }
        $sh = New-Object -ComObject WScript.Shell
        $s = $sh.CreateShortcut((Join-Path $pasta $Arquivo))
        $s.TargetPath = $Alvo
        $s.Save()
    }
    function Get-Item1 { param($R, [string]$Id) return @($R.dados.itens | Where-Object { $_.id -eq $Id })[0] }
}

AfterAll {
    Remove-Item -LiteralPath 'HKCU:\Software\NexTuneTeste\Inicio' -Recurse -Force -ErrorAction SilentlyContinue
    $t = Join-Path $env:TEMP 'NexTuneTeste'
    if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'inicializacao.ps1' {
    BeforeEach {
        Remove-Item -LiteralPath 'HKCU:\Software\NexTuneTeste\Inicio' -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $Script:PastaT) { Remove-Item -LiteralPath $Script:PastaT -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path (Join-Path $Script:PastaT 'usuario') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $Script:PastaT 'todos') -Force | Out-Null
        New-RunTeste 'hkcu' 'Spotify' '"C:\Users\x\AppData\Roaming\Spotify\Spotify.exe" --autostart'
        New-RunTeste 'hkcu' 'Meu App (x64) ção' 'C:\Apps\meu.exe /min'
        New-RunTeste 'hkcu' 'SecurityHealth' '%windir%\system32\SecurityHealthSystray.exe'
        New-RunTeste 'hklm' 'Positivo Updater' '"C:\Program Files\Positivo\Updater.exe"'
        New-RunTeste 'hklm32' 'Discord' 'C:\x\Update.exe --processStart Discord.exe'
        Set-AprovadoTeste 'hklm' 'Run32' 'Discord' ([byte[]](3, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8))
        New-AtalhoInicio 'usuario' 'Bloco.lnk' $Script:Notepad
    }

    Context 'funcoes puras' {
        It 'Get-EstadoAprovado: 02/06 ativo, 03/07 desligado, ausente ou curto = ativo' {
            Get-EstadoAprovado ([byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) | Should -BeTrue
            Get-EstadoAprovado ([byte[]](6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) | Should -BeTrue
            Get-EstadoAprovado ([byte[]](3, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8)) | Should -BeFalse
            Get-EstadoAprovado ([byte[]](7, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8)) | Should -BeFalse
            Get-EstadoAprovado $null | Should -BeTrue
            Get-EstadoAprovado ([byte[]](3)) | Should -BeFalse
            Get-EstadoAprovado ([byte[]]@()) | Should -BeTrue
        }
        It 'New-ValorAprovado: ligar = 02 + 11 zeros; desligar = 03 + FILETIME UTC little-endian' {
            $agora = Get-Date -Year 2026 -Month 11 -Day 20 -Hour 15 -Minute 30 -Second 0 -Millisecond 0
            $on = New-ValorAprovado $true $agora
            $on.Count | Should -Be 12
            ($on -join ',') | Should -Be '2,0,0,0,0,0,0,0,0,0,0,0'
            $off = New-ValorAprovado $false $agora
            $off.Count | Should -Be 12
            $off[0] | Should -Be 3
            ($off[1..3] -join ',') | Should -Be '0,0,0'
            ($off[4..11] -join ',') | Should -Be (([BitConverter]::GetBytes($agora.ToFileTimeUtc())) -join ',')
        }
        It 'Split-ComandoInicio separa exe e argumentos com aspas, sem aspas e com %windir%' {
            $a = Split-ComandoInicio '"C:\Program Files\X\a b.exe" /q --x'
            $a.exe | Should -Be 'C:\Program Files\X\a b.exe'
            $a.args | Should -Be '/q --x'
            $b = Split-ComandoInicio 'C:\x\Update.exe --processStart Discord.exe'
            $b.exe | Should -Be 'C:\x\Update.exe'
            $b.args | Should -Be '--processStart Discord.exe'
            $c = Split-ComandoInicio '%windir%\system32\SecurityHealthSystray.exe'
            $c.exe | Should -Be "$env:windir\system32\SecurityHealthSystray.exe"
            $c.args | Should -Be ''
            $d = Split-ComandoInicio 'C:\Program Files\Sem Aspas\tool.exe -k'
            $d.exe | Should -Be 'C:\Program Files\Sem Aspas\tool.exe'
            (Split-ComandoInicio '').exe | Should -BeNullOrEmpty
        }
    }

    Context 'listar' {
        It 'devolve os 6 itens com origem, escopo, ativo e ordenacao (ativos primeiro, depois nome)' {
            $r = Invoke-Ini 'listar'
            $r.ok | Should -BeTrue
            @($r.dados.itens).Count | Should -Be 6
            $ids = @($r.dados.itens | ForEach-Object { $_.id })
            $ids | Should -Contain 'run:hkcu:Spotify'
            $ids | Should -Contain 'run:hkcu:Meu App (x64) ção'
            $ids | Should -Contain 'run:hkcu:SecurityHealth'
            $ids | Should -Contain 'run:hklm:Positivo Updater'
            $ids | Should -Contain 'run:hklm32:Discord'
            $ids | Should -Contain 'pasta:usuario:Bloco.lnk'
            # Discord e o unico desligado: fica por ultimo
            $ids[-1] | Should -Be 'run:hklm32:Discord'
            (Get-Item1 $r 'run:hklm:Positivo Updater').escopo | Should -Be 'todos'
            (Get-Item1 $r 'run:hkcu:Spotify').escopo | Should -Be 'usuario'
            (Get-Item1 $r 'run:hkcu:Spotify').origem | Should -Be 'run'
            foreach ($i in $r.dados.itens) { $i.avancado | Should -BeFalse }
        }
        It 'Review Focus 1: sem entrada em StartupApproved o item e ativo; com 03 e desligado' {
            $r = Invoke-Ini 'listar'
            (Get-Item1 $r 'run:hkcu:Spotify').ativo | Should -BeTrue
            (Get-Item1 $r 'run:hklm32:Discord').ativo | Should -BeFalse
        }
        It 'classifica por inicio.json e protegidos.json' {
            $r = Invoke-Ini 'listar'
            $sp = Get-Item1 $r 'run:hkcu:Spotify'
            $sp.cor | Should -Be 'verde'
            $sp.motivoCor | Should -Not -BeNullOrEmpty
            $sp.protegido | Should -BeFalse
            (Get-Item1 $r 'run:hklm:Positivo Updater').cor | Should -Be 'verde'
            $sh = Get-Item1 $r 'run:hkcu:SecurityHealth'
            $sh.cor | Should -Be 'vermelho'
            $sh.protegido | Should -BeTrue
            $sh.motivoProtegido | Should -Not -BeNullOrEmpty
            $m = Get-Item1 $r 'run:hkcu:Meu App (x64) ção'
            $m.cor | Should -BeNullOrEmpty
            $m.protegido | Should -BeFalse
        }
        It 'powershell.exe/explorer.exe no Run nao viram processo essencial; ctfmon.exe continua protegido' {
            (Get-ClassificacaoInicio 'Updater' 'powershell.exe' 'powershell.exe -w hidden -File C:\x\a.ps1' '' 'run').protegido | Should -BeFalse
            (Get-ClassificacaoInicio 'Promo' 'explorer.exe' 'explorer.exe "http://exemplo.invalid"' '' 'run').protegido | Should -BeFalse
            (Get-ClassificacaoInicio 'ctf' 'ctfmon.exe' 'ctfmon.exe' '' 'run').protegido | Should -BeTrue
        }
        It 'Review Focus 7: nome com acento, espaco e parenteses chega inteiro' {
            $r = Invoke-Ini 'listar'
            $m = Get-Item1 $r 'run:hkcu:Meu App (x64) ção'
            $m | Should -Not -BeNullOrEmpty
            $m.nome | Should -BeExactly 'Meu App (x64) ção'
            $m.comando | Should -Be 'C:\Apps\meu.exe /min'
            $m.exe | Should -Be 'C:\Apps\meu.exe'
            $m.tamanhoBytes | Should -Be -1
            $m.editor | Should -BeNullOrEmpty
        }
        It 'atalho da pasta de inicializacao resolve o exe, o editor e o tamanho' {
            $r = Invoke-Ini 'listar'
            $b = Get-Item1 $r 'pasta:usuario:Bloco.lnk'
            $b.origem | Should -Be 'pasta'
            $b.escopo | Should -Be 'usuario'
            $b.nome | Should -Be 'Bloco'
            $b.exe.ToLowerInvariant() | Should -Be $Script:Notepad.ToLowerInvariant()
            $b.editor | Should -Not -BeNullOrEmpty
            $b.tamanhoBytes | Should -BeGreaterThan 0
            $b.ativo | Should -BeTrue
            $b.rodando | Should -BeOfType [bool]
            $b.ramBytes | Should -BeGreaterOrEqual 0
        }
        It 'tarefas agendadas so com avancado e nunca sob \Microsoft\' {
            $sim = @{ tarefas = @(
                    @{ caminho = '\Positivo\'; nome = 'PositivoUpdate'; exe = 'C:\P\u.exe'; ativo = $true },
                    @{ caminho = '\Microsoft\Windows\X\'; nome = 'Oculta'; exe = 'C:\W\x.exe'; ativo = $true }
                ) }
            $sem = Invoke-Ini 'listar' @{ simular = $sim }
            @($sem.dados.itens | Where-Object { $_.origem -eq 'tarefa' }).Count | Should -Be 0
            $com = Invoke-Ini 'listar' @{ avancado = $true; simular = $sim }
            $tarefas = @($com.dados.itens | Where-Object { $_.origem -eq 'tarefa' })
            $tarefas.Count | Should -Be 1
            $t = $tarefas[0]
            $t.id | Should -Be 'tarefa:\Positivo\PositivoUpdate'
            $t.nome | Should -Be 'PositivoUpdate'
            $t.cor | Should -Be 'verde'
            $t.avancado | Should -BeTrue
            $t.ativo | Should -BeTrue
            $t.escopo | Should -Be 'todos'
            $t.exe | Should -Be 'C:\P\u.exe'
        }
    }

    Context 'alternar' {
        It 'Review Focus 1: desligar cria a entrada com 03; religar grava 02 e a entrada continua' {
            $r = Invoke-Ini 'alternar' @{ id = 'run:hkcu:Spotify'; ativar = $false; confirmado = $true }
            $r.ok | Should -BeTrue
            $r.dados.id | Should -Be 'run:hkcu:Spotify'
            $r.dados.ativo | Should -BeFalse
            $v = Get-AprovadoTeste 'hkcu' 'Run' 'Spotify'
            $v | Should -Not -BeNullOrEmpty
            @($v).Count | Should -Be 12
            $v[0] | Should -Be 3
            (Get-Item1 (Invoke-Ini 'listar') 'run:hkcu:Spotify').ativo | Should -BeFalse

            $r2 = Invoke-Ini 'alternar' @{ id = 'run:hkcu:Spotify'; ativar = $true; confirmado = $true }
            $r2.dados.ativo | Should -BeTrue
            $v2 = Get-AprovadoTeste 'hkcu' 'Run' 'Spotify'
            $v2 | Should -Not -BeNullOrEmpty
            $v2[0] | Should -Be 2
            (Get-Item1 (Invoke-Ini 'listar') 'run:hkcu:Spotify').ativo | Should -BeTrue
        }
        It 'hive hklm32 grava em StartupApproved\Run32 da hklm; pasta do usuario em StartupFolder da hkcu' {
            (Invoke-Ini 'alternar' @{ id = 'run:hklm32:Discord'; ativar = $true; confirmado = $true }).dados.ativo | Should -BeTrue
            (Get-AprovadoTeste 'hklm' 'Run32' 'Discord')[0] | Should -Be 2
            (Invoke-Ini 'alternar' @{ id = 'pasta:usuario:Bloco.lnk'; ativar = $false; confirmado = $true }).dados.ativo | Should -BeFalse
            (Get-AprovadoTeste 'hkcu' 'StartupFolder' 'Bloco.lnk')[0] | Should -Be 3
            (Get-Item1 (Invoke-Ini 'listar') 'pasta:usuario:Bloco.lnk').ativo | Should -BeFalse
        }
        It 'Review Focus 7: nome com acento, espaco e parenteses vira entrada com o nome exato' {
            $r = Invoke-Ini 'alternar' @{ id = 'run:hkcu:Meu App (x64) ção'; ativar = $false; confirmado = $true }
            $r.ok | Should -BeTrue
            $k = Get-Item -LiteralPath (Get-ChaveAprovadoTeste 'hkcu' 'Run')
            @($k.GetValueNames()) | Should -Contain 'Meu App (x64) ção'
            (Get-AprovadoTeste 'hkcu' 'Run' 'Meu App (x64) ção')[0] | Should -Be 3
        }
        It 'Review Focus 2: protegido nunca e desligado, mesmo com confirmado e avancado' {
            $r = Invoke-Ini 'alternar' @{ id = 'run:hkcu:SecurityHealth'; ativar = $false; confirmado = $true; avancado = $true }
            $r.ok | Should -BeFalse
            $r.erro | Should -Match 'protegid'
            Get-AprovadoTeste 'hkcu' 'Run' 'SecurityHealth' | Should -BeNullOrEmpty
        }
        It 'recusa sem confirmado, ativar nao booleano e id desconhecido' {
            (Invoke-Ini 'alternar' @{ id = 'run:hkcu:Spotify'; ativar = $false }).ok | Should -BeFalse
            (Invoke-Ini 'alternar' @{ id = 'run:hkcu:Spotify'; ativar = $false; confirmado = 'true' }).ok | Should -BeFalse
            (Invoke-Ini 'alternar' @{ id = 'run:hkcu:Spotify'; ativar = 'false'; confirmado = $true }).ok | Should -BeFalse
            (Invoke-Ini 'alternar' @{ id = 'run:hkcu:Spotify'; confirmado = $true }).ok | Should -BeFalse
            $x = Invoke-Ini 'alternar' @{ id = 'run:hkcu:NaoExiste'; ativar = $false; confirmado = $true }
            $x.ok | Should -BeFalse
            $x.erro | Should -Match 'encontrado'
            Get-AprovadoTeste 'hkcu' 'Run' 'Spotify' | Should -BeNullOrEmpty
        }
        It 'Review Focus 2: tarefa agendada so com avancado; em teste grava marcador' {
            $sim = @{ tarefas = @(@{ caminho = '\Positivo\'; nome = 'PositivoUpdate'; exe = 'C:\P\u.exe'; ativo = $true }) }
            $sem = Invoke-Ini 'alternar' @{ id = 'tarefa:\Positivo\PositivoUpdate'; ativar = $false; confirmado = $true; simular = $sim }
            $sem.ok | Should -BeFalse
            $sem.erro | Should -Match 'avan'
            Test-Path -LiteralPath (Join-Path $Script:PastaT 'tarefa-PositivoUpdate.txt') | Should -BeFalse
            $com = Invoke-Ini 'alternar' @{ id = 'tarefa:\Positivo\PositivoUpdate'; ativar = $false; confirmado = $true; avancado = $true; simular = $sim }
            $com.ok | Should -BeTrue
            $com.dados.ativo | Should -BeFalse
            $marc = Join-Path $Script:PastaT 'tarefa-PositivoUpdate.txt'
            Test-Path -LiteralPath $marc | Should -BeTrue
            (Get-Content -LiteralPath $marc -Raw).Trim() | Should -Be 'False'
        }
    }

    Context 'Invoke-Acao' {
        It 'acao desconhecida devolve erro' {
            $r = Invoke-Ini 'xyz'
            $r.ok | Should -BeFalse
            $r.erro | Should -Be 'ação desconhecida'
        }
    }
}
