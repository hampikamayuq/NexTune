BeforeAll {
    . "$PSScriptRoot\..\common.ps1"
    . "$PSScriptRoot\..\modojogo.ps1"
    . "$PSScriptRoot\_helpers.ps1"
    $Script:PastaT = Join-Path (Join-Path $env:TEMP 'NexTuneTeste') 'modojogo'
    $Script:Arquivo = Join-Path (Get-AppPastas $true).Estado 'modojogo.json'
    $Script:RaizReg = 'HKCU:\Software\NexTuneTeste\ModoJogo'
    $Script:ChaveNoc = 'HKCU:\Software\NexTuneTeste\ModoJogo\Notifications\Settings'
    $Script:GuidEquilibrado = '381b4222-f694-41f0-9685-ff5bb260df2e'
    $Script:GuidDesempenho = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'

    function Invoke-Jogo {
        param([string]$Acao, $Params = @{}, [bool]$Teste = $true)
        $sw = New-Object System.IO.StringWriter
        Set-Saida $sw
        try { Invoke-Acao 'j1' $Acao $Params $Teste } finally { Set-Saida $null }
        $Script:UltimaSaida = $sw.ToString()
        $linhas = @($sw.ToString() -split "`r?`n" | Where-Object { $_.StartsWith('@@RESULT ') })
        if ($linhas.Count -ne 1) { return $null }
        return $linhas[0].Substring(9) | ConvertFrom-Json
    }
    function Get-SimPadrao {
        return @{
            processos    = @(
                @{ exe = 'chrome.exe'; nome = 'Google Chrome'; caminho = 'C:\Program Files\Google\Chrome\Application\chrome.exe'; ramBytes = 540MB; janela = $true },
                @{ exe = 'Spotify.exe'; nome = 'Spotify'; caminho = 'C:\Users\x\AppData\Roaming\Spotify\Spotify.exe'; ramBytes = 300MB; janela = $true },
                @{ exe = 'Discord.exe'; nome = 'Discord'; caminho = 'C:\Users\x\AppData\Local\Discord\Discord.exe'; ramBytes = 200MB; janela = $true },
                @{ exe = 'obs64.exe'; nome = 'OBS Studio'; caminho = 'C:\Program Files\obs-studio\bin\64bit\obs64.exe'; ramBytes = 400MB; janela = $true },
                @{ exe = 'soffice.exe'; nome = 'Documento sem título'; caminho = 'C:\Program Files\LibreOffice\program\soffice.exe'; ramBytes = 150MB; janela = $true; naoFecha = $true },
                @{ exe = 'svchost.exe'; nome = 'svchost.exe'; caminho = 'C:\Windows\System32\svchost.exe'; ramBytes = 50MB; janela = $false },
                @{ exe = 'jogo.exe'; nome = 'Meu Jogo'; caminho = 'D:\Jogos\jogo.exe'; ramBytes = 800MB; janela = $true; pid = 4242 }
            )
            planoAtivo   = $Script:GuidEquilibrado
            servicos     = @{ wuauserv = 'Running'; BITS = 'Running'; DoSvc = 'Stopped'; WSearch = 'Running'; SysMain = 'Running' }
        }
    }
    function Use-PerfilTeste {
        param([string]$Classe = 'medio', [string]$Disco = 'ssd')
        Set-Perfil ([pscustomobject]@{ classe = $Classe; disco = $Disco; manual = $false }) $true
    }
    function Test-Marcador { param([string]$Nome) return (Test-Path -LiteralPath (Join-Path $Script:PastaT $Nome)) }
    function Get-Marcador {
        if (-not (Test-Path -LiteralPath $Script:PastaT)) { return @() }
        return @(Get-ChildItem -LiteralPath $Script:PastaT -File | ForEach-Object { $_.Name })
    }
    function Get-EstadoGravado { return (Get-Content -LiteralPath $Script:Arquivo -Raw -Encoding UTF8 | ConvertFrom-Json) }
    function Get-ValorNoc {
        $p = Get-ItemProperty -LiteralPath $Script:ChaveNoc -Name 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' -ErrorAction SilentlyContinue
        if ($null -eq $p) { return $null }
        return $p.NOC_GLOBAL_SETTING_TOASTS_ENABLED
    }
}

AfterAll {
    $t = Join-Path $env:TEMP 'NexTuneTeste'
    if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath 'HKCU:\Software\NexTuneTeste') { Remove-Item -LiteralPath 'HKCU:\Software\NexTuneTeste\ModoJogo' -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'modojogo.ps1' {
    BeforeEach {
        if (Test-Path -LiteralPath $Script:PastaT) { Remove-Item -LiteralPath $Script:PastaT -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $Script:Arquivo) { Remove-Item -LiteralPath $Script:Arquivo -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $Script:RaizReg) { Remove-Item -LiteralPath $Script:RaizReg -Recurse -Force -ErrorAction SilentlyContinue }
        Use-PerfilTeste
        $Script:Sim = Get-SimPadrao
        $Script:Tab = Get-TabelasProtegidos
    }

    Context 'funcoes puras' {
        It 'Get-GuidPlano extrai o GUID da saida localizada do powercfg e devolve null sem GUID' {
            Get-GuidPlano 'GUID do Esquema de Energia: 381b4222-f694-41f0-9685-ff5bb260df2e  (Equilibrado)' | Should -Be $Script:GuidEquilibrado
            Get-GuidPlano 'Power Scheme GUID: 8C5E7FDA-E8BF-4A96-9A85-A6E23A8C635C  (High performance)' | Should -Be '8C5E7FDA-E8BF-4A96-9A85-A6E23A8C635C'
            Get-GuidPlano 'nenhum esquema aqui' | Should -BeNullOrEmpty
            Get-GuidPlano '' | Should -BeNullOrEmpty
        }
        It 'Test-PerfilFraco: sem perfil, basico ou hdd contam como fracos' {
            Test-PerfilFraco $null | Should -BeTrue
            Test-PerfilFraco ([pscustomobject]@{ classe = 'basico'; disco = 'ssd' }) | Should -BeTrue
            Test-PerfilFraco ([pscustomobject]@{ classe = 'medio'; disco = 'hdd' }) | Should -BeTrue
            Test-PerfilFraco ([pscustomobject]@{ classe = 'medio'; disco = 'ssd' }) | Should -BeFalse
        }
        It 'Test-PresetPermitido: a fundo so em PC fraco com modo avancado; suave e equilibrado sempre' {
            $fraco = [pscustomobject]@{ classe = 'basico'; disco = 'hdd' }
            $forte = [pscustomobject]@{ classe = 'alto'; disco = 'ssd' }
            Test-PresetPermitido 'a_fundo' $fraco $false | Should -BeFalse
            Test-PresetPermitido 'a_fundo' $fraco $true | Should -BeTrue
            Test-PresetPermitido 'a_fundo' $null $false | Should -BeFalse
            Test-PresetPermitido 'a_fundo' $forte $false | Should -BeTrue
            Test-PresetPermitido 'suave' $fraco $false | Should -BeTrue
            Test-PresetPermitido 'equilibrado' $null $false | Should -BeTrue
            Test-PresetPermitido 'inexistente' $forte $true | Should -BeFalse
        }
        It 'Get-ProcessoProtegido acha por regex (sem diferenciar caixa) e por nome exato do protegidos.json' {
            Get-ProcessoProtegido 'OBS64.EXE' $Script:Tab | Should -Not -BeNullOrEmpty
            Get-ProcessoProtegido 'discordcanary.exe' $Script:Tab | Should -Not -BeNullOrEmpty
            Get-ProcessoProtegido 'explorer.exe' $Script:Tab | Should -Not -BeNullOrEmpty
            Get-ProcessoProtegido 'chrome.exe' $Script:Tab | Should -BeNullOrEmpty
            Get-ProcessoProtegido 'Discord.exe.bak' $Script:Tab | Should -BeNullOrEmpty
        }
        It 'Get-ServicosDoPreset: suave nenhum, equilibrado a sua lista, a fundo as duas' {
            $dados = Read-ArquivoJson (Join-Path (Get-PastaDeDados) 'modojogo.json')
            @(Get-ServicosDoPreset 'suave' $dados).Count | Should -Be 0
            @(Get-ServicosDoPreset 'equilibrado' $dados) | Should -Be @('wuauserv', 'BITS', 'DoSvc')
            @(Get-ServicosDoPreset 'a_fundo' $dados) | Should -Be @('wuauserv', 'BITS', 'DoSvc', 'WSearch', 'SysMain')
        }
    }

    Context 'estado e processos' {
        It 'estado sem arquivo devolve ativo:false' {
            $r = Invoke-Jogo 'estado'
            $r.ok | Should -BeTrue
            $r.dados.ativo | Should -BeFalse
        }
        It 'estado com arquivo ilegivel falha' {
            [IO.File]::WriteAllText($Script:Arquivo, '{ nao e json', (New-Object System.Text.UTF8Encoding $false))
            $r = Invoke-Jogo 'estado'
            $r.ok | Should -BeFalse
            $r.erro | Should -Match 'ilegível'
        }
        It 'processos lista so os com janela, protegidos marcados, ordenados por RAM' {
            $r = Invoke-Jogo 'processos' @{ simular = $Script:Sim }
            $r.ok | Should -BeTrue
            $lista = @($r.dados.processos)
            $lista.Count | Should -Be 6
            @($lista | ForEach-Object { $_.exe }) | Should -Not -Contain 'svchost.exe'
            @($lista | ForEach-Object { $_.exe }) | Should -Be @('jogo.exe', 'chrome.exe', 'obs64.exe', 'Spotify.exe', 'Discord.exe', 'soffice.exe')
            ($lista | Where-Object { $_.exe -eq 'Discord.exe' }).protegido | Should -BeTrue
            ($lista | Where-Object { $_.exe -eq 'Discord.exe' }).motivoProtegido | Should -Not -BeNullOrEmpty
            ($lista | Where-Object { $_.exe -eq 'obs64.exe' }).protegido | Should -BeTrue
            ($lista | Where-Object { $_.exe -eq 'chrome.exe' }).protegido | Should -BeFalse
            ($lista | Where-Object { $_.exe -eq 'chrome.exe' }).nome | Should -Be 'Google Chrome'
        }
    }

    Context 'ativar' {
        It 'RF1: suave fecha o pedido, troca o plano, grava o estado antes e nao mexe em servicos; segundo ativar recusa' {
            $r = Invoke-Jogo 'ativar' @{ preset = 'suave'; fechar = @('chrome.exe'); confirmado = $true; simular = $Script:Sim }
            $r.ok | Should -BeTrue
            $r.dados.ativo | Should -BeTrue
            @($r.dados.fechados).Count | Should -Be 1
            $r.dados.fechados[0].exe | Should -Be 'chrome.exe'
            $r.dados.fechados[0].caminho | Should -Be 'C:\Program Files\Google\Chrome\Application\chrome.exe'
            Test-Marcador 'fechar-chrome.exe.txt' | Should -BeTrue
            Test-Marcador "powercfg-$Script:GuidDesempenho.txt" | Should -BeTrue
            @(Get-Marcador | Where-Object { $_ -like 'servico-*' }).Count | Should -Be 0
            $e = Get-EstadoGravado
            $e.planoAnterior | Should -Be $Script:GuidEquilibrado
            $e.preset | Should -Be 'suave'
            $e.ativo | Should -BeTrue
            $antes = Get-Marcador
            $r2 = Invoke-Jogo 'ativar' @{ preset = 'suave'; fechar = @('Spotify.exe'); confirmado = $true; simular = $Script:Sim }
            $r2.ok | Should -BeFalse
            $r2.erro | Should -Match 'já ativo'
            @(Get-Marcador).Count | Should -Be @($antes).Count
            (Invoke-Jogo 'estado').dados.ativo | Should -BeTrue
        }
        It 'RF2: protegidos e desconhecidos vao para naoFechados com motivo; so o chrome e fechado' {
            $r = Invoke-Jogo 'ativar' @{ preset = 'suave'; fechar = @('Discord.exe', 'obs64.exe', 'chrome.exe', 'explorer.exe', 'naoexiste.exe'); confirmado = $true; simular = $Script:Sim }
            $r.ok | Should -BeTrue
            @($r.dados.fechados | ForEach-Object { $_.exe }) | Should -Be @('chrome.exe')
            $nf = @($r.dados.naoFechados)
            $nf.Count | Should -Be 4
            @($nf | ForEach-Object { $_.exe }) | Should -Be @('Discord.exe', 'obs64.exe', 'explorer.exe', 'naoexiste.exe')
            foreach ($x in $nf) { $x.motivo | Should -Not -BeNullOrEmpty }
            ($nf | Where-Object { $_.exe -eq 'naoexiste.exe' }).motivo | Should -Match 'não está aberto'
            Test-Marcador 'fechar-Discord.exe.txt' | Should -BeFalse
            Test-Marcador 'fechar-obs64.exe.txt' | Should -BeFalse
        }
        It 'RF5: janela que nao fecha vai para naoFechados, sai do estado e nao e reaberta no desativar' {
            $r = Invoke-Jogo 'ativar' @{ preset = 'suave'; fechar = @('soffice.exe'); confirmado = $true; simular = $Script:Sim }
            $r.ok | Should -BeTrue
            @($r.dados.fechados).Count | Should -Be 0
            $r.dados.naoFechados[0].exe | Should -Be 'soffice.exe'
            $r.dados.naoFechados[0].motivo | Should -Match 'não fechou a tempo'
            Test-Marcador 'fechar-soffice.exe.txt' | Should -BeTrue
            @((Get-EstadoGravado).fechados).Count | Should -Be 0
            (Invoke-Jogo 'desativar' @{ confirmado = $true }).ok | Should -BeTrue
            Test-Marcador 'reabrir-soffice.exe.txt' | Should -BeFalse
        }
        It 'RF3: Windows instalando poupa wuauserv/BITS mas mantem notificacoes e plano' {
            $sim = Get-SimPadrao
            $sim.windowsInstalando = $true
            $r = Invoke-Jogo 'ativar' @{ preset = 'equilibrado'; fechar = @(); confirmado = $true; simular = $sim }
            $r.ok | Should -BeTrue
            $r.dados.windowsInstalando | Should -BeTrue
            Test-Marcador 'servico-wuauserv-stop.txt' | Should -BeFalse
            Test-Marcador 'servico-BITS-stop.txt' | Should -BeFalse
            @($r.dados.servicosPausados).Count | Should -Be 0
            Get-ValorNoc | Should -Be 0
            Test-Marcador "powercfg-$Script:GuidDesempenho.txt" | Should -BeTrue
        }
        It 'RF3: sem instalacao pausa so os servicos que estavam rodando' {
            $r = Invoke-Jogo 'ativar' @{ preset = 'equilibrado'; fechar = @(); confirmado = $true; simular = $Script:Sim }
            $r.ok | Should -BeTrue
            $r.dados.windowsInstalando | Should -BeFalse
            Test-Marcador 'servico-wuauserv-stop.txt' | Should -BeTrue
            Test-Marcador 'servico-BITS-stop.txt' | Should -BeTrue
            Test-Marcador 'servico-DoSvc-stop.txt' | Should -BeFalse
            @($r.dados.servicosPausados) | Should -Be @('wuauserv', 'BITS')
            Test-Marcador 'servico-WSearch-stop.txt' | Should -BeFalse
            Get-ValorNoc | Should -Be 0
            @((Get-EstadoGravado).servicosPausados) | Should -Be @('wuauserv', 'BITS')
        }
        It 'RF4: a fundo em PC fraco sem modo avancado e recusado sem tocar em nada' {
            Use-PerfilTeste 'basico' 'hdd'
            $r = Invoke-Jogo 'ativar' @{ preset = 'a_fundo'; fechar = @('chrome.exe'); confirmado = $true; simular = $Script:Sim }
            $r.ok | Should -BeFalse
            $r.erro | Should -Match 'avançado'
            Test-Path -LiteralPath $Script:Arquivo | Should -BeFalse
            @(Get-Marcador).Count | Should -Be 0
        }
        It 'RF4: a fundo com avancado pausa tambem WSearch/SysMain, sobe a prioridade do jogo e o desativar desfaz tudo' {
            Use-PerfilTeste 'basico' 'hdd'
            $r = Invoke-Jogo 'ativar' @{ preset = 'a_fundo'; fechar = @('chrome.exe'); jogo = 'jogo.exe'; avancado = $true; confirmado = $true; simular = $Script:Sim }
            $r.ok | Should -BeTrue
            Test-Marcador 'servico-WSearch-stop.txt' | Should -BeTrue
            Test-Marcador 'servico-SysMain-stop.txt' | Should -BeTrue
            Test-Marcador 'prioridade-jogo.exe-High.txt' | Should -BeTrue
            @($r.dados.servicosPausados) | Should -Be @('wuauserv', 'BITS', 'WSearch', 'SysMain')
            $e = Get-EstadoGravado
            $e.jogo | Should -Be 'jogo.exe'
            $e.prioridadeAnterior | Should -Be 'Normal'
            @($e.jogoPids) | Should -Be @(4242)
            Get-ValorNoc | Should -Be 0

            $d = Invoke-Jogo 'desativar' @{ confirmado = $true }
            $d.ok | Should -BeTrue
            $d.dados.ativo | Should -BeFalse
            @($d.dados.religados) | Should -Be @('wuauserv', 'BITS', 'WSearch', 'SysMain')
            @($d.dados.reabertos) | Should -Be @('chrome.exe')
            @($d.dados.falhas).Count | Should -Be 0
            Test-Marcador 'servico-DoSvc-start.txt' | Should -BeFalse
            Test-Marcador 'servico-WSearch-start.txt' | Should -BeTrue
            Test-Marcador 'prioridade-jogo.exe-Normal.txt' | Should -BeTrue
            Test-Marcador "powercfg-$Script:GuidEquilibrado.txt" | Should -BeTrue
            Test-Marcador 'reabrir-chrome.exe.txt' | Should -BeTrue
            Get-ValorNoc | Should -BeNullOrEmpty
            Test-Path -LiteralPath $Script:Arquivo | Should -BeFalse
            (Invoke-Jogo 'estado').dados.ativo | Should -BeFalse
        }
        It 'falha do plano vira aviso: a ativacao segue, notificacoes e servicos sao aplicados e o desativar nao mexe no plano' {
            $sim = Get-SimPadrao
            $sim.falharPlano = $true
            $r = Invoke-Jogo 'ativar' @{ preset = 'equilibrado'; fechar = @('chrome.exe'); confirmado = $true; simular = $sim }
            $r.ok | Should -BeTrue
            @($r.dados.avisos | ForEach-Object { $_.item }) | Should -Contain 'plano de energia'
            Test-Marcador "powercfg-$Script:GuidDesempenho.txt" | Should -BeFalse
            Test-Marcador 'servico-wuauserv-stop.txt' | Should -BeTrue
            Get-ValorNoc | Should -Be 0
            $e = Get-EstadoGravado
            $e.ativo | Should -BeTrue
            $e.planoAplicado | Should -BeFalse
            (Invoke-Jogo 'desativar' @{ confirmado = $true }).ok | Should -BeTrue
            Test-Marcador "powercfg-$Script:GuidEquilibrado.txt" | Should -BeFalse
            Test-Marcador 'servico-wuauserv-start.txt' | Should -BeTrue
        }
        It 'plano atual ilegivel: nao troca o plano, avisa e o desativar nao mexe nele' {
            $sim = Get-SimPadrao
            $sim.planoAtivo = ''
            $r = Invoke-Jogo 'ativar' @{ preset = 'equilibrado'; fechar = @(); confirmado = $true; simular = $sim }
            $r.ok | Should -BeTrue
            @($r.dados.avisos | ForEach-Object { $_.item }) | Should -Contain 'plano de energia'
            @(Get-Marcador | Where-Object { $_ -like 'powercfg-*' }).Count | Should -Be 0
            (Invoke-Jogo 'desativar' @{ confirmado = $true }).ok | Should -BeTrue
            @(Get-Marcador | Where-Object { $_ -like 'powercfg-*' }).Count | Should -Be 0
        }
        It 'o jogo nunca e fechado, mesmo se estiver em fechar' {
            $r = Invoke-Jogo 'ativar' @{ preset = 'suave'; fechar = @('JOGO.exe'); jogo = 'jogo.exe'; confirmado = $true; simular = $Script:Sim }
            $r.ok | Should -BeTrue
            @($r.dados.fechados).Count | Should -Be 0
            $r.dados.naoFechados[0].motivo | Should -Be 'é o jogo'
            Test-Marcador 'fechar-jogo.exe.txt' | Should -BeFalse
        }
        It 'restaura o valor anterior das notificacoes quando ele existia' {
            New-Item -Path $Script:ChaveNoc -Force | Out-Null
            Set-ItemProperty -LiteralPath $Script:ChaveNoc -Name 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' -Value 1 -Type DWord
            (Invoke-Jogo 'ativar' @{ preset = 'equilibrado'; fechar = @(); confirmado = $true; simular = $Script:Sim }).ok | Should -BeTrue
            Get-ValorNoc | Should -Be 0
            (Get-EstadoGravado).notificacoesAnterior | Should -Be 1
            (Invoke-Jogo 'desativar' @{ confirmado = $true }).ok | Should -BeTrue
            Get-ValorNoc | Should -Be 1
        }
        It 'sem confirmado, preset invalido ou jogo invalido: recusa sem tocar em nada' {
            (Invoke-Jogo 'ativar' @{ preset = 'suave'; fechar = @(); simular = $Script:Sim }).ok | Should -BeFalse
            (Invoke-Jogo 'ativar' @{ preset = 'turbo'; fechar = @(); confirmado = $true; simular = $Script:Sim }).ok | Should -BeFalse
            (Invoke-Jogo 'ativar' @{ preset = 'suave'; fechar = @(); jogo = '..\x.exe'; confirmado = $true; simular = $Script:Sim }).ok | Should -BeFalse
            Test-Path -LiteralPath $Script:Arquivo | Should -BeFalse
            @(Get-Marcador).Count | Should -Be 0
        }
    }

    Context 'desativar' {
        It 'sem estado e idempotente: ok com listas vazias' {
            $r = Invoke-Jogo 'desativar' @{ confirmado = $true }
            $r.ok | Should -BeTrue
            $r.dados.ativo | Should -BeFalse
            @($r.dados.reabertos).Count | Should -Be 0
            @($r.dados.religados).Count | Should -Be 0
            @($r.dados.falhas).Count | Should -Be 0
        }
        It 'estado ilegivel falha sem tocar em nada' {
            [IO.File]::WriteAllText($Script:Arquivo, '{ nao e json', (New-Object System.Text.UTF8Encoding $false))
            $r = Invoke-Jogo 'desativar' @{ confirmado = $true }
            $r.ok | Should -BeFalse
            $r.erro | Should -Match 'ilegível'
            @(Get-Marcador).Count | Should -Be 0
            Test-Path -LiteralPath $Script:Arquivo | Should -BeTrue
        }
        It 'programa sem caminho entra em falhas, o resto e restaurado e o estado e apagado' {
            $sim = Get-SimPadrao
            $sim.processos[1].caminho = $null
            (Invoke-Jogo 'ativar' @{ preset = 'suave'; fechar = @('Spotify.exe', 'chrome.exe'); confirmado = $true; simular = $sim }).ok | Should -BeTrue
            $d = Invoke-Jogo 'desativar' @{ confirmado = $true }
            $d.ok | Should -BeTrue
            @($d.dados.reabertos) | Should -Be @('chrome.exe')
            @($d.dados.falhas).Count | Should -Be 1
            $d.dados.falhas[0].item | Should -Be 'Spotify.exe'
            $d.dados.falhas[0].erro | Should -Match 'sem caminho'
            Test-Path -LiteralPath $Script:Arquivo | Should -BeFalse
            Test-Marcador "powercfg-$Script:GuidEquilibrado.txt" | Should -BeTrue
        }
        It 'caminho que nao e .exe nao e reaberto: vai para falhas' {
            $sim = Get-SimPadrao
            $sim.processos[1].caminho = 'C:\x\documento.txt'
            (Invoke-Jogo 'ativar' @{ preset = 'suave'; fechar = @('Spotify.exe'); confirmado = $true; simular = $sim }).ok | Should -BeTrue
            $d = Invoke-Jogo 'desativar' @{ confirmado = $true }
            @($d.dados.reabertos).Count | Should -Be 0
            $d.dados.falhas[0].erro | Should -Match 'caminho inválido'
            Test-Marcador 'reabrir-Spotify.exe.txt' | Should -BeFalse
        }
        It 'sem confirmado recusa' {
            (Invoke-Jogo 'ativar' @{ preset = 'suave'; fechar = @(); confirmado = $true; simular = $Script:Sim }).ok | Should -BeTrue
            (Invoke-Jogo 'desativar' @{}).ok | Should -BeFalse
            Test-Path -LiteralPath $Script:Arquivo | Should -BeTrue
        }
    }

    Context 'geral' {
        It 'acao desconhecida falha' {
            $r = Invoke-Jogo 'xyz'
            $r.ok | Should -BeFalse
            $r.erro | Should -Match 'desconhecida'
        }
    }
}
