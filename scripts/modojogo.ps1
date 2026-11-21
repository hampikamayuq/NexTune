# modojogo.ps1 - Modo Jogo: pede para fechar programas, troca o plano de energia, silencia notificacoes
# e pausa servicos (so os que estavam rodando), guardando antes de cada mudanca o que precisa voltar.
# Acoes: estado {}, processos {}, ativar {preset, fechar, jogo?, automatico?, confirmado, avancado?},
# desativar {confirmado}. Presets: suave (so fecha e troca o plano), equilibrado (+ notificacoes e
# servicos de segundo plano), a_fundo (+ WSearch/SysMain e prioridade alta no jogo; PC fraco so no avancado).
# Regras: nunca Stop-Process/kill (so CloseMainWindow e espera de 10 s); nunca Set-Service -StartupType;
# o estado fica em Estado\modojogo.json, regravado a cada passo (atomico), e desativar so religa o que
# esta la; programas protegidos (protegidos.json + modojogo.json) nunca sao fechados.
# Em modo teste: simular {processos [{exe, nome, caminho, ramBytes, janela, naoFecha?}], planoAtivo,
# servicos {nome: 'Running'|'Stopped'}, windowsInstalando?, perfil?} substitui toda leitura real;
# marcadores em %TEMP%\NexTuneTeste\modojogo\; notificacoes em HKCU\Software\NexTuneTeste\ModoJogo.
. "$PSScriptRoot\common.ps1"

$Script:ArquivoEstado = 'modojogo.json'
$Script:Presets = @('suave', 'equilibrado', 'a_fundo')
$Script:ServicosDeInstalacao = @('wuauserv', 'BITS', 'DoSvc')
$Script:ChaveNotificacoes = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'
$Script:ChaveNotificacoesTeste = 'HKCU\Software\NexTuneTeste\ModoJogo\Notifications\Settings'
$Script:ValorNotificacoes = 'NOC_GLOBAL_SETTING_TOASTS_ENABLED'
$Script:EsperaFecharMs = 10000
$Script:MotivoSistema = 'Faz parte do Windows: fechar pode travar o PC.'

# ---------- funcoes puras ----------

function Test-PerfilFraco {
    # Puro: sem perfil conhecido, classe basica ou disco hdd contam como PC fraco.
    param($Perfil)
    if ($null -eq $Perfil) { return $true }
    return ([string]$Perfil.classe -eq 'basico' -or [string]$Perfil.disco -eq 'hdd')
}

function Test-PresetPermitido {
    # Puro: o preset existe e, no a fundo, o PC nao e fraco (ou o modo avancado esta ligado).
    param([string]$Preset, $Perfil, [bool]$Avancado)
    if ($Script:Presets -notcontains $Preset) { return $false }
    if ($Preset -eq 'a_fundo' -and (Test-PerfilFraco $Perfil) -and -not $Avancado) { return $false }
    return $true
}

function Get-GuidPlano {
    # Puro: o GUID do plano na saida (localizada) do powercfg, ou $null.
    param([string]$SaidaPowercfg)
    if ($SaidaPowercfg -match '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}') { return $Matches[0] }
    return $null
}

function Get-ProcessoProtegido {
    # Puro: motivo de proteger o exe (nome exato do protegidos.json ou regex do modojogo.json) ou $null.
    param([string]$Exe, $Tabelas)
    foreach ($nome in @($Tabelas.processos)) {
        if ([string]::Equals([string]$nome, $Exe, [StringComparison]::OrdinalIgnoreCase)) { return $Script:MotivoSistema }
    }
    foreach ($e in @($Tabelas.protegidos)) {
        $re = New-RegexLista $e.padrao
        if ($null -ne $re -and $re.IsMatch($Exe)) { return [string]$e.motivo }
    }
    return $null
}

function Get-ServicosDoPreset {
    # Puro: servicos que o preset pausa (suave nenhum; a fundo = equilibrado + a fundo).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    param([string]$Preset, $Dados)
    switch ($Preset) {
        'equilibrado' { return @($Dados.servicos.equilibrado) }
        'a_fundo' { return @(@($Dados.servicos.equilibrado) + @($Dados.servicos.a_fundo)) }
        default { return @() }
    }
}

function Test-NomeExe {
    # Puro: nome simples de executavel (sem pasta), usado para o 'jogo'. Mesma regra do re_exe do Rust e do RE_EXE da UI.
    param([string]$Nome)
    return ($Nome -match '^[^\\/:*?"<>|\x00-\x1f]{1,120}\.exe$')
}

# ---------- dados e estado ----------

function Get-TabelasProtegidos {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    param()
    $pasta = Get-PastaDeDados
    $pr = Read-ArquivoJson (Join-Path $pasta 'protegidos.json')
    $mj = Read-ArquivoJson (Join-Path $pasta 'modojogo.json')
    return [pscustomobject]@{ processos = @($pr.processos); protegidos = @($mj.protegidos) }
}

function Get-ArquivoEstado {
    param([bool]$Teste)
    return (Join-Path (Get-AppPastas $Teste).Estado $Script:ArquivoEstado)
}

function Read-EstadoJogo {
    # @{ existe; ilegivel; estado }. Ilegivel = nao e JSON, nao e objeto ou nao tem a forma de um estado ativo.
    param([bool]$Teste)
    $arq = Get-ArquivoEstado $Teste
    if (-not (Test-Path -LiteralPath $arq -PathType Leaf)) { return @{ existe = $false; ilegivel = $false; estado = $null } }
    try {
        $texto = [IO.File]::ReadAllText($arq, [Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
        $o = $texto | ConvertFrom-Json -ErrorAction Stop
        if ($o -isnot [pscustomobject] -or $o.ativo -ne $true -or [string]::IsNullOrEmpty([string]$o.preset)) {
            return @{ existe = $true; ilegivel = $true; estado = $null }
        }
        return @{ existe = $true; ilegivel = $false; estado = $o }
    } catch { return @{ existe = $true; ilegivel = $true; estado = $null } }
}

function Write-EstadoJogo {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param($Estado, [bool]$Teste)
    Write-JsonAtomico (Get-ArquivoEstado $Teste) $Estado
}

function Get-PastaJogoTeste {
    $p = Join-Path (Get-AppPastas $true).Base 'modojogo'
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    return $p
}

function Write-MarcadorJogo {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Nome, [string]$Texto = '')
    [IO.File]::WriteAllText((Join-Path (Get-PastaJogoTeste) $Nome), $Texto, (New-Object System.Text.UTF8Encoding $false))
}

# ---------- processos ----------

function Get-ProcessosReais {
    # Um item por exe entre os processos com janela; a RAM soma todos os processos do mesmo nome.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    param()
    $todos = @(Get-Process -ErrorAction SilentlyContinue)
    $ram = @{}
    foreach ($p in $todos) { $ram[$p.ProcessName.ToLowerInvariant()] = [int64]$ram[$p.ProcessName.ToLowerInvariant()] + [int64]$p.WorkingSet64 }
    $lista = New-Object System.Collections.Generic.List[object]
    $grupos = @($todos | Where-Object { $_.MainWindowHandle -ne 0 } | Group-Object { $_.ProcessName.ToLowerInvariant() })
    foreach ($g in $grupos) {
        $p0 = $g.Group[0]
        $exe = $p0.ProcessName + '.exe'
        $titulo = [string](@($g.Group | Where-Object { -not [string]::IsNullOrEmpty($_.MainWindowTitle) } | Select-Object -First 1)[0]).MainWindowTitle
        $caminho = $null
        try { if (-not [string]::IsNullOrEmpty([string]$p0.Path)) { $caminho = [string]$p0.Path } } catch { $null = $_ }
        $lista.Add([pscustomobject]@{
            exe      = $exe
            nome     = $(if ([string]::IsNullOrEmpty($titulo)) { $exe } else { $titulo })
            caminho  = $caminho
            ramBytes = [int64]$ram[$g.Name]
        })
    }
    return $lista.ToArray()
}

function Get-ProcessosSimulados {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    param($Sim)
    $lista = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Sim -or $null -eq $Sim.processos) { return @() }
    foreach ($p in @($Sim.processos)) {
        if ($p.janela -ne $true) { continue }
        $caminho = $null
        if (-not [string]::IsNullOrEmpty([string]$p.caminho)) { $caminho = [string]$p.caminho }
        $lista.Add([pscustomobject]@{ exe = [string]$p.exe; nome = [string]$p.nome; caminho = $caminho; ramBytes = [int64]$p.ramBytes })
    }
    return $lista.ToArray()
}

function Get-ProcessosJanela {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    param([bool]$Teste, $Sim)
    if ($Teste) { return @(Get-ProcessosSimulados $Sim) }
    return @(Get-ProcessosReais)
}

function Get-ProcessoSimulado {
    # O item de simular.processos com esse exe (qualquer janela) ou $null.
    param($Sim, [string]$Exe)
    if ($null -eq $Sim -or $null -eq $Sim.processos) { return $null }
    foreach ($p in @($Sim.processos)) { if ([string]$p.exe -eq $Exe) { return $p } }
    return $null
}

function Request-FecharJanela {
    # Pede para fechar (CloseMainWindow) e espera ate 10 s. $true = fechou. Nunca mata o processo.
    param([string]$Exe, [bool]$Teste, $Sim)
    if ($Teste) {
        Write-MarcadorJogo ('fechar-' + $Exe + '.txt') 'CloseMainWindow'
        $sp = Get-ProcessoSimulado $Sim $Exe
        return -not ($null -ne $sp -and $sp.naoFecha -eq $true)
    }
    $nome = [IO.Path]::GetFileNameWithoutExtension($Exe)
    $procs = @(Get-Process -Name $nome -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })
    foreach ($p in $procs) { try { $null = $p.CloseMainWindow() } catch { $null = $_ } }
    $limite = [DateTime]::UtcNow.AddMilliseconds($Script:EsperaFecharMs)
    foreach ($p in $procs) {
        $resto = [int][math]::Max(0, ($limite - [DateTime]::UtcNow).TotalMilliseconds)
        try { if (-not $p.WaitForExit($resto)) { return $false } } catch { $null = $_ }
    }
    return $true
}

function Get-PidsJogo {
    # PIDs do jogo neste momento (so eles recebem prioridade alta; vazio = nao esta rodando).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    param([string]$Exe, [bool]$Teste, $Sim)
    if ($Teste) {
        if ($null -eq $Sim -or $null -eq $Sim.processos) { return @() }
        return @(@($Sim.processos) | Where-Object { [string]$_.exe -eq $Exe -and $null -ne $_.pid } | ForEach-Object { [int]$_.pid })
    }
    return @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Exe)) -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.Id })
}

function Get-PrioridadeAtual {
    # Classe de prioridade atual do primeiro PID ($null sem PIDs ou se o processo sumiu).
    param($Pids, [bool]$Teste)
    if (@($Pids).Count -eq 0) { return $null }
    if ($Teste) { return 'Normal' }
    $p = Get-Process -Id ([int]@($Pids)[0]) -ErrorAction SilentlyContinue
    if ($null -eq $p) { return $null }
    return [string]$p.PriorityClass
}

function Set-PrioridadeJogo {
    # So nos PIDs guardados; confere o nome (PID reaproveitado) e ignora processo que ja morreu.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Exe, $Pids, [string]$Classe, [bool]$Teste)
    if ($Teste) { Write-MarcadorJogo ('prioridade-' + $Exe + '-' + $Classe + '.txt') $Classe; return }
    $nome = [IO.Path]::GetFileNameWithoutExtension($Exe)
    foreach ($id in @($Pids)) {
        $p = Get-Process -Id ([int]$id) -ErrorAction SilentlyContinue
        if ($null -ne $p -and $p.ProcessName -eq $nome) { $p.PriorityClass = $Classe }
    }
}

# ---------- servicos, plano de energia e notificacoes ----------

function Get-StatusServico {
    param([string]$Nome, [bool]$Teste, $Sim)
    if ($Teste) {
        if ($null -eq $Sim -or $null -eq $Sim.servicos) { return $null }
        $v = $Sim.servicos.$Nome
        if ($null -eq $v) { return $null }
        return [string]$v
    }
    $s = Get-Service -Name $Nome -ErrorAction SilentlyContinue
    if ($null -eq $s) { return $null }
    return [string]$s.Status
}

function Stop-ServicoJogo {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Nome, [bool]$Teste)
    if ($Teste) { Write-MarcadorJogo ('servico-' + $Nome + '-stop.txt') 'Stop-Service'; return }
    Stop-Service -Name $Nome -ErrorAction Stop -WarningAction SilentlyContinue
}

function Start-ServicoJogo {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Nome, [bool]$Teste)
    if ($Teste) { Write-MarcadorJogo ('servico-' + $Nome + '-start.txt') 'Start-Service'; return }
    Start-Service -Name $Nome -ErrorAction Stop -WarningAction SilentlyContinue
}

function Test-WindowsInstalando {
    param([bool]$Teste, $Sim)
    if ($Teste) { return ($null -ne $Sim -and $Sim.windowsInstalando -eq $true) }
    return (@(Get-Process -Name 'TiWorker', 'TrustedInstaller' -ErrorAction SilentlyContinue).Count -gt 0)
}

function Get-PlanoAtivo {
    param([bool]$Teste, $Sim)
    if ($Teste) { if ($null -ne $Sim -and $Sim.planoAtivo) { return [string]$Sim.planoAtivo } else { return $null } }
    return (Get-GuidPlano ((& "$env:windir\System32\powercfg.exe" /getactivescheme) | Out-String))
}

function Set-PlanoEnergia {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Guid, [bool]$Teste, $Sim = $null)
    if ($Teste -and $null -ne $Sim -and $Sim.falharPlano -eq $true) { throw 'powercfg simulado falhou' }
    # O GUID vem do estado em disco: so a forma exata chega ao powercfg (o PS 5.1 nao escapa aspas em argumentos).
    if ($Guid -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { throw "GUID de plano inválido: $Guid" }
    if ($Teste) { Write-MarcadorJogo ('powercfg-' + $Guid + '.txt') 'powercfg /setactive'; return }
    & "$env:windir\System32\powercfg.exe" /setactive $Guid | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "powercfg terminou com código $LASTEXITCODE" }
}

function Get-ChaveNotificacao {
    param([bool]$Teste)
    return (ConvertTo-CaminhoRegistro $(if ($Teste) { $Script:ChaveNotificacoesTeste } else { $Script:ChaveNotificacoes }))
}

function Get-NotificacoesAtual {
    # Valor atual de NOC_GLOBAL_SETTING_TOASTS_ENABLED ou $null se ausente.
    param([bool]$Teste)
    $c = Get-ChaveNotificacao $Teste
    if (-not (Test-Path -LiteralPath $c)) { return $null }
    $v = (Get-Item -LiteralPath $c -ErrorAction Stop).GetValue($Script:ValorNotificacoes, $null)
    if ($null -eq $v) { return $null }
    return [int]$v
}

function Set-NotificacoesValor {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([int]$Valor, [bool]$Teste)
    $c = Get-ChaveNotificacao $Teste
    if (-not (Test-Path -LiteralPath $c)) { New-Item -Path $c -Force -ErrorAction Stop | Out-Null }
    Set-ItemProperty -LiteralPath $c -Name $Script:ValorNotificacoes -Value $Valor -Type DWord -ErrorAction Stop
}

function Restore-Notificacao {
    # Anterior $null = o valor nao existia: remove. Senao regrava o que havia.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param($Anterior, [bool]$Teste)
    if ($null -ne $Anterior) { Set-NotificacoesValor ([int]$Anterior) $Teste; return }
    if ($null -eq (Get-NotificacoesAtual $Teste)) { return }
    Remove-ItemProperty -LiteralPath (Get-ChaveNotificacao $Teste) -Name $Script:ValorNotificacoes -ErrorAction Stop
}

# ---------- ativar ----------

function Resolve-PedidoFechar {
    # Separa o pedido em programas a fechar (com caminho) e naoFechados (protegido ou nao esta aberto).
    # Protegido vale mesmo se nao estiver aberto: o motivo e mais util que "nao esta aberto".
    param($Pedidos, $Processos, $Tabelas, $Jogo = $null)
    $fechar = @()
    $nao = @()
    $vistos = @{}
    foreach ($pedido in @($Pedidos)) {
        $exe = [string]$pedido
        if ([string]::IsNullOrWhiteSpace($exe) -or $vistos.ContainsKey($exe.ToLowerInvariant())) { continue }
        $vistos[$exe.ToLowerInvariant()] = $true
        if ($null -ne $Jogo -and [string]::Equals($exe, [string]$Jogo, [StringComparison]::OrdinalIgnoreCase)) {
            $nao += [pscustomobject]@{ exe = $exe; motivo = 'é o jogo' }
            continue
        }
        $motivo = Get-ProcessoProtegido $exe $Tabelas
        if (-not [string]::IsNullOrEmpty($motivo)) { $nao += [pscustomobject]@{ exe = $exe; motivo = $motivo }; continue }
        $p = @($Processos | Where-Object { [string]::Equals($_.exe, $exe, [StringComparison]::OrdinalIgnoreCase) })
        if ($p.Count -eq 0) { $nao += [pscustomobject]@{ exe = $exe; motivo = 'não está aberto' }; continue }
        $fechar += [pscustomobject]@{ exe = $p[0].exe; caminho = $p[0].caminho }
    }
    return @{ fechar = @($fechar); naoFechados = @($nao) }
}

function Close-ProgramaPedido {
    # Pede para fechar cada programa planejado; os que nao fecharam saem de 'fechados' e vao para 'naoFechados'.
    param($Estado, [string]$Id, [bool]$Teste, $Sim)
    $total = @($Estado.fechados).Count
    $i = 0
    foreach ($f in @($Estado.fechados)) {
        $i++
        Send-Progress $Id (20 + [int](40 * $i / [math]::Max(1, $total))) ('Fechando ' + $f.exe)
        if (Request-FecharJanela ([string]$f.exe) $Teste $Sim) {
            Write-AppLog ('modojogo: fechou ' + $f.exe) $Teste
            continue
        }
        $Estado.fechados = @($Estado.fechados | Where-Object { $_.exe -ne $f.exe })
        $Estado.naoFechados = @($Estado.naoFechados) + [pscustomobject]@{ exe = $f.exe; motivo = 'não fechou a tempo (há algo para salvar?)' }
        Write-AppLog ('modojogo: ' + $f.exe + ' não fechou a tempo') $Teste
        Write-EstadoJogo $Estado $Teste
    }
}

function Add-Aviso {
    # Falha de um passo que nao impede a ativacao: log + registro + entrada em 'avisos' (devolve a nova lista).
    param($Avisos, [string]$Id, [string]$Item, [string]$Erro, [bool]$Teste)
    Send-Log $Id 'aviso' ($Item + ': ' + $Erro)
    Write-AppLog ('modojogo: aviso em ' + $Item + ': ' + $Erro) $Teste
    return @(@($Avisos) + [pscustomobject]@{ item = $Item; erro = $Erro })
}

function Suspend-ServicosPreset {
    # Para so os servicos que estavam rodando; cada um e anotado no estado ANTES de parar. Devolve os avisos.
    param($Estado, $Servicos, [string]$Id, [bool]$Teste)
    $avisos = @()
    foreach ($s in @($Servicos)) {
        $antes = @($Estado.servicos | Where-Object { $_.nome -eq $s })
        if ($antes.Count -eq 0 -or $antes[0].status -ne 'Running') { continue }
        if ($Estado.windowsInstalando -and $Script:ServicosDeInstalacao -contains $s) { continue }
        $Estado.servicosPausados = @($Estado.servicosPausados) + $s
        Write-EstadoJogo $Estado $Teste
        try {
            Stop-ServicoJogo $s $Teste
            Write-AppLog ('modojogo: pausou o serviço ' + $s) $Teste
        } catch {
            $Estado.servicosPausados = @($Estado.servicosPausados | Where-Object { $_ -ne $s })
            Write-EstadoJogo $Estado $Teste
            $avisos = Add-Aviso $avisos $Id ('serviço ' + $s) $_.Exception.Message $Teste
        }
    }
    return @($avisos)
}

function New-EstadoJogo {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Preset, [bool]$Automatico, $Jogo, $Plano, $Fechar, $Naofechados, $Servicos, $Pids, [bool]$Teste, $Sim)
    $antes = @()
    foreach ($s in @($Servicos)) {
        $st = Get-StatusServico $s $Teste $Sim
        $antes += [pscustomobject]@{ nome = $s; status = $(if ($null -eq $st) { 'Ausente' } else { $st }) }
    }
    return [ordered]@{
        ativo               = $true
        preset              = $Preset
        desde               = (Get-Date).ToString('o')
        automatico          = $Automatico
        jogo                = $Jogo
        fechados            = @($Fechar)
        naoFechados         = @($Naofechados)
        servicos            = $antes
        servicosPausados    = @()
        planoAnterior       = $Plano
        notificacoesAnterior = (Get-NotificacoesAtual $Teste)
        windowsInstalando   = (Test-WindowsInstalando $Teste $Sim)
        planoAplicado       = $false
        notificacoesAplicadas = $false
        jogoPids            = @($Pids)
        prioridadeAnterior  = $(if ($Preset -eq 'a_fundo') { Get-PrioridadeAtual $Pids $Teste } else { $null })
    }
}

function Invoke-Ativar {
    param([string]$Id, $Params, [bool]$Teste)
    if (-not (Test-ParamVerdadeiro $Params 'confirmado')) { Send-Result $Id $null $false 'ação exige confirmação'; return }
    $sim = Get-Simulacao $Params $Teste
    $preset = [string]$Params.preset
    if ($Script:Presets -notcontains $preset) { Send-Result $Id $null $false 'preset inválido'; return }
    $jogo = $null
    if (-not [string]::IsNullOrEmpty([string]$Params.jogo)) {
        if (-not (Test-NomeExe ([string]$Params.jogo))) { Send-Result $Id $null $false 'jogo inválido'; return }
        $jogo = [string]$Params.jogo
    }
    $atual = Read-EstadoJogo $Teste
    if ($atual.ilegivel) { Send-Result $Id $null $false 'estado do Modo Jogo ilegível'; return }
    if ($atual.existe) { Send-Result $Id $null $false 'Modo Jogo já ativo'; return }
    $perfil = if ($null -ne $sim -and $null -ne $sim.perfil) { $sim.perfil } else { Get-Perfil $Teste }
    if (-not (Test-PresetPermitido $preset $perfil (Test-ParamVerdadeiro $Params 'avancado'))) {
        Send-Result $Id $null $false 'preset a fundo só no modo avançado neste PC'
        return
    }

    Send-Progress $Id 10 'Lendo o que está aberto'
    $pedido = Resolve-PedidoFechar $Params.fechar (Get-ProcessosJanela $Teste $sim) (Get-TabelasProtegidos) $jogo
    $dados = Read-ArquivoJson (Join-Path (Get-PastaDeDados) 'modojogo.json')
    $servicos = @(Get-ServicosDoPreset $preset $dados)
    $pids = @(); if ($null -ne $jogo) { $pids = @(Get-PidsJogo $jogo $Teste $sim) }
    $estado = New-EstadoJogo $preset (Test-ParamVerdadeiro $Params 'automatico') $jogo (Get-PlanoAtivo $Teste $sim) $pedido.fechar $pedido.naoFechados $servicos $pids $Teste $sim
    Write-EstadoJogo $estado $Teste
    Write-AppLog ('modojogo: ativando preset ' + $preset) $Teste

    Close-ProgramaPedido $estado $Id $Teste $sim
    $avisos = @(Invoke-PassosAtivacao $estado $dados $servicos $Id $Teste $sim)
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{
        ativo             = $true
        preset            = $preset
        fechados          = @($estado.fechados)
        naoFechados       = @($estado.naoFechados)
        servicosPausados  = @($estado.servicosPausados)
        windowsInstalando = $estado.windowsInstalando
        avisos            = $avisos
    })
}

function Invoke-PassosAtivacao {
    # Plano, notificacoes, servicos e prioridade: cada passo e marcado no estado ANTES de agir e desmarcado se
    # falhar; a falha vira aviso e a ativacao segue. Devolve a lista de avisos.
    param($Estado, $Dados, $Servicos, [string]$Id, [bool]$Teste, $Sim)
    $avisos = @()
    Send-Progress $Id 65 'Trocando o plano de energia'
    if ([string]::IsNullOrEmpty([string]$Estado.planoAnterior)) {
        $avisos = Add-Aviso $avisos $Id 'plano de energia' 'não foi possível ler o plano de energia atual; plano mantido' $Teste
    } else {
        $Estado.planoAplicado = $true
        Write-EstadoJogo $Estado $Teste
        try {
            Set-PlanoEnergia ([string]$Dados.planoDesempenho) $Teste $Sim
            Write-AppLog ('modojogo: plano de desempenho ' + $Dados.planoDesempenho) $Teste
        } catch {
            $Estado.planoAplicado = $false
            Write-EstadoJogo $Estado $Teste
            $avisos = Add-Aviso $avisos $Id 'plano de energia' $_.Exception.Message $Teste
        }
    }
    if ([string]$Estado.preset -ne 'suave') {
        Send-Progress $Id 75 'Silenciando notificações e pausando serviços'
        $Estado.notificacoesAplicadas = $true
        Write-EstadoJogo $Estado $Teste
        try { Set-NotificacoesValor 0 $Teste; Write-AppLog 'modojogo: notificações silenciadas' $Teste }
        catch {
            $Estado.notificacoesAplicadas = $false
            Write-EstadoJogo $Estado $Teste
            $avisos = Add-Aviso $avisos $Id 'notificações' $_.Exception.Message $Teste
        }
        $avisos = @($avisos) + @(Suspend-ServicosPreset $Estado $Servicos $Id $Teste)
    }
    if ([string]$Estado.preset -eq 'a_fundo' -and $null -ne $Estado.prioridadeAnterior) {
        try { Set-PrioridadeJogo ([string]$Estado.jogo) $Estado.jogoPids 'High' $Teste; Write-AppLog ('modojogo: prioridade alta em ' + $Estado.jogo) $Teste }
        catch { $avisos = Add-Aviso $avisos $Id ('prioridade de ' + $Estado.jogo) $_.Exception.Message $Teste }
    }
    return @($avisos)
}

# ---------- desativar ----------

function Add-Falha {
    # Acrescenta {item, erro} a lista de falhas (devolve a nova lista).
    param($Falhas, [string]$Item, [string]$Erro)
    return @(@($Falhas) + [pscustomobject]@{ item = $Item; erro = $Erro })
}

function Restore-ServicoPausado {
    param($Estado, [bool]$Teste)
    $religados = @()
    $falhas = @()
    foreach ($s in @($Estado.servicosPausados)) {
        try {
            Start-ServicoJogo ([string]$s) $Teste
            $religados += [string]$s
            Write-AppLog ('modojogo: religou o serviço ' + $s) $Teste
        } catch { $falhas = Add-Falha $falhas ([string]$s) $_.Exception.Message }
    }
    return @{ religados = @($religados); falhas = @($falhas) }
}

function Restore-ProgramaFechado {
    param($Estado, [bool]$Teste)
    $reabertos = @()
    $falhas = @()
    foreach ($f in @($Estado.fechados)) {
        $exe = [string]$f.exe
        try {
            if ([string]::IsNullOrEmpty([string]$f.caminho)) { throw 'sem caminho para reabrir' }
            $cam = [string]$f.caminho
            if ($cam -notmatch '\.exe$' -or (-not $Teste -and -not (Test-Path -LiteralPath $cam -PathType Leaf))) { throw 'caminho inválido para reabrir' }
            if ($Teste) { Write-MarcadorJogo ('reabrir-' + $exe + '.txt') $cam }
            # Via explorer.exe: o alvo abre com o token do usuario (integridade media), nao elevado como este host.
            else { Start-Process -FilePath "$env:windir\explorer.exe" -ArgumentList @('"' + $cam + '"') -ErrorAction Stop }
            $reabertos += $exe
            Write-AppLog ('modojogo: reabriu ' + $exe) $Teste
        } catch { $falhas = Add-Falha $falhas $exe $_.Exception.Message }
    }
    return @{ reabertos = @($reabertos); falhas = @($falhas) }
}

function Restore-EstadoAnterior {
    # Desfaz na ordem inversa; cada passo que falha vai para 'falhas' e os demais continuam.
    param($Estado, [bool]$Teste)
    $falhas = @()
    if (-not [string]::IsNullOrEmpty([string]$Estado.jogo) -and -not [string]::IsNullOrEmpty([string]$Estado.prioridadeAnterior) -and @($Estado.jogoPids).Count -gt 0) {
        try { Set-PrioridadeJogo ([string]$Estado.jogo) $Estado.jogoPids ([string]$Estado.prioridadeAnterior) $Teste }
        catch { $falhas = Add-Falha $falhas ([string]$Estado.jogo) $_.Exception.Message }
    }
    $sv = Restore-ServicoPausado $Estado $Teste
    $falhas = @($falhas) + @($sv.falhas)
    if ($Estado.notificacoesAplicadas -eq $true) {
        try { Restore-Notificacao $Estado.notificacoesAnterior $Teste; Write-AppLog 'modojogo: notificações restauradas' $Teste }
        catch { $falhas = Add-Falha $falhas 'notificações' $_.Exception.Message }
    }
    if ($Estado.planoAplicado -eq $true -and -not [string]::IsNullOrEmpty([string]$Estado.planoAnterior)) {
        try { Set-PlanoEnergia ([string]$Estado.planoAnterior) $Teste; Write-AppLog ('modojogo: plano ' + $Estado.planoAnterior + ' de volta') $Teste }
        catch { $falhas = Add-Falha $falhas 'plano de energia' $_.Exception.Message }
    }
    $pr = Restore-ProgramaFechado $Estado $Teste
    return @{ religados = $sv.religados; reabertos = $pr.reabertos; falhas = (@($falhas) + @($pr.falhas)) }
}

function Invoke-Desativar {
    param([string]$Id, $Params, [bool]$Teste)
    if (-not (Test-ParamVerdadeiro $Params 'confirmado')) { Send-Result $Id $null $false 'ação exige confirmação'; return }
    $lido = Read-EstadoJogo $Teste
    if ($lido.ilegivel) { Send-Result $Id $null $false 'estado do Modo Jogo ilegível'; return }
    if (-not $lido.existe) {
        Send-Result $Id ([ordered]@{ ativo = $false; reabertos = @(); religados = @(); falhas = @() })
        return
    }
    Send-Progress $Id 10 'Voltando tudo como estava'
    $r = Restore-EstadoAnterior $lido.estado $Teste
    Remove-Item -LiteralPath (Get-ArquivoEstado $Teste) -Force -ErrorAction SilentlyContinue
    Write-AppLog ('modojogo: desativado (falhas: ' + @($r.falhas).Count + ')') $Teste
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ ativo = $false; reabertos = @($r.reabertos); religados = @($r.religados); falhas = @($r.falhas) })
}

# ---------- estado e processos ----------

function Invoke-Estado {
    param([string]$Id, [bool]$Teste)
    $lido = Read-EstadoJogo $Teste
    if ($lido.ilegivel) { Send-Result $Id $null $false 'estado do Modo Jogo ilegível'; return }
    if (-not $lido.existe) { Send-Result $Id ([ordered]@{ ativo = $false }); return }
    $e = $lido.estado
    Send-Result $Id ([ordered]@{
        ativo               = $true
        preset              = [string]$e.preset
        desde               = [string]$e.desde
        automatico          = ($e.automatico -eq $true)
        jogo                = $e.jogo
        fechados            = @($e.fechados)
        naoFechados         = @($e.naoFechados)
        servicosPausados    = @($e.servicosPausados)
        planoAnterior       = $e.planoAnterior
        notificacoesAnterior = $e.notificacoesAnterior
        windowsInstalando   = ($e.windowsInstalando -eq $true)
    })
}

function Invoke-ProcessoJanela {
    param([string]$Id, $Params, [bool]$Teste)
    $sim = Get-Simulacao $Params $Teste
    $tabelas = Get-TabelasProtegidos
    $itens = @()
    foreach ($p in @(Get-ProcessosJanela $Teste $sim | Sort-Object -Property ramBytes -Descending)) {
        $motivo = Get-ProcessoProtegido ([string]$p.exe) $tabelas
        $itens += [ordered]@{
            exe             = $p.exe
            nome            = $p.nome
            caminho         = $p.caminho
            ramBytes        = $p.ramBytes
            protegido       = (-not [string]::IsNullOrEmpty($motivo))
            motivoProtegido = $motivo
        }
    }
    Send-Result $Id ([ordered]@{ processos = @($itens) })
}

function Invoke-Acao {
    param([string]$Id, [string]$Acao, $Params, [bool]$Teste)
    if (@('estado', 'processos', 'ativar', 'desativar') -notcontains $Acao) {
        Send-Result $Id $null $false 'ação desconhecida'
        return
    }
    try {
        switch ($Acao) {
            'estado' { Invoke-Estado $Id $Teste }
            'processos' { Invoke-ProcessoJanela $Id $Params $Teste }
            'ativar' { Invoke-Ativar $Id $Params $Teste }
            'desativar' { Invoke-Desativar $Id $Params $Teste }
        }
    } catch {
        $msg = 'modo jogo falhou: ' + $_.Exception.Message
        Write-AppLog $msg $Teste
        Send-Result $Id $null $false $msg
    }
}
