# inicializacao.ps1 - o que abre com o Windows: chaves Run (HKCU, HKLM, HKLM 32 bits), pastas de
# inicializacao (usuario e todos) e, no modo avancado, tarefas agendadas de fabricante.
# Acoes: listar {avancado?}, alternar {id, ativar, confirmado, avancado?}.
# Liga/desliga pelo mesmo mecanismo do Gerenciador de Tarefas (StartupApproved): byte 0 em 02/06 =
# ativo, 03/07 = desligado (bytes 4..11 = FILETIME de quando desligou); entrada ausente = ativo.
# Ids: run:<hkcu|hklm|hklm32>:<nome do valor>, pasta:<usuario|todos>:<arquivo.lnk>, tarefa:<TaskPath><TaskName>.
# Classificacao: protegidos.json (processos pelo nome do exe; programas por nome/editor/comando) ->
# vermelho + protegido; depois inicio.json (itens para run/pasta, tarefas para tarefas). Vermelho de
# qualquer lista e protegido: nenhuma acao de escrita o aceita.
# Em modo teste: Run em HKCU\Software\NexTuneTeste\Inicio\Run\<hive>, StartupApproved em
# HKCU\Software\NexTuneTeste\Inicio\StartupApproved\<hkcu|hklm>\<Run|Run32|StartupFolder>, pastas em
# %TEMP%\NexTuneTeste\inicio\<usuario|todos>, tarefas so de simular.tarefas e alternar de tarefa grava
# %TEMP%\NexTuneTeste\inicio\tarefa-<nome>.txt.
. "$PSScriptRoot\common.ps1"

$Script:TabelasInicio = $null
$Script:Hives = @('hkcu', 'hklm', 'hklm32')
$Script:Escopos = @('usuario', 'todos')
$Script:RaizTeste = 'HKCU:\Software\NexTuneTeste\Inicio'
$Script:SufixoAprovado = 'Explorer\StartupApproved'
# hive do Run -> (hive do StartupApproved, subchave)
$Script:AprovadoDoRun = @{ hkcu = @('hkcu', 'Run'); hklm = @('hklm', 'Run'); hklm32 = @('hklm', 'Run32') }
$Script:AprovadoDaPasta = @{ usuario = @('hkcu', 'StartupFolder'); todos = @('hklm', 'StartupFolder') }
$Script:GatilhosInicio = @('MSFT_TaskLogonTrigger', 'MSFT_TaskBootTrigger')

# ---------- caminhos ----------

function Get-ChaveRun {
    param([string]$Hive, [bool]$Teste)
    if ($Teste) { return (Join-Path (Join-Path $Script:RaizTeste 'Run') $Hive) }
    switch ($Hive) {
        'hkcu' { return 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' }
        'hklm' { return 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' }
        'hklm32' { return 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run' }
    }
    throw "hive desconhecida: $Hive"
}

function Get-ChaveAprovado {
    # Chave StartupApproved\<Sub> da hive pedida (hkcu ou hklm).
    param([string]$HiveAprov, [string]$Sub, [bool]$Teste)
    if ($Teste) { return (Join-Path (Join-Path (Join-Path $Script:RaizTeste 'StartupApproved') $HiveAprov) $Sub) }
    $raiz = if ($HiveAprov -eq 'hklm') { 'HKLM:\SOFTWARE' } else { 'HKCU:\Software' }
    return (Join-Path (Join-Path $raiz "Microsoft\Windows\CurrentVersion") (Join-Path $Script:SufixoAprovado $Sub))
}

function Get-PastaInicio {
    param([string]$Escopo, [bool]$Teste)
    if ($Teste) { return (Join-Path (Join-Path (Get-AppPastas $true).Base 'inicio') $Escopo) }
    if ($Escopo -eq 'todos') { return [Environment]::GetFolderPath('CommonStartup') }
    return [Environment]::GetFolderPath('Startup')
}

# ---------- funcoes puras ----------

function Get-EstadoAprovado {
    # Puro: valor binario do StartupApproved -> ativo? Ausente/vazio = ativo; 03/07 = desligado.
    param($Bytes)
    if ($null -eq $Bytes) { return $true }
    $b = @($Bytes)
    if ($b.Count -lt 1) { return $true }
    return -not (([int]$b[0]) -in @(3, 7))
}

function New-ValorAprovado {
    # Puro: 12 bytes do StartupApproved. Ligar = 02 + zeros; desligar = 03 + FILETIME UTC (little-endian).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([bool]$Ativar, [DateTime]$Agora = (Get-Date))
    $v = New-Object byte[] 12
    if ($Ativar) { $v[0] = 2; return $v }
    $v[0] = 3
    $ft = [BitConverter]::GetBytes($Agora.ToFileTimeUtc())
    [Array]::Copy($ft, 0, $v, 4, 8)
    return $v
}

function Split-ComandoInicio {
    # Puro: comando do Run -> @{ exe; args }, com %var% expandido. Com aspas: ate a proxima aspa.
    # shortcut: sem aspas e com espacos, o exe vai ate o primeiro ".exe"; sem ".exe", ate o primeiro espaco.
    param([string]$Comando)
    $c = [Environment]::ExpandEnvironmentVariables(([string]$Comando).Trim())
    if ([string]::IsNullOrEmpty($c)) { return @{ exe = ''; args = '' } }
    if ($c.StartsWith('"')) {
        $fim = $c.IndexOf('"', 1)
        if ($fim -lt 0) { return @{ exe = $c.Trim('"'); args = '' } }
        return @{ exe = $c.Substring(1, $fim - 1); args = $c.Substring($fim + 1).Trim() }
    }
    $pos = $c.IndexOf('.exe', [StringComparison]::OrdinalIgnoreCase)
    if ($pos -ge 0) { $corte = $pos + 4 }
    else {
        $corte = $c.IndexOf(' ')
        if ($corte -lt 0) { $corte = $c.Length }
    }
    return @{ exe = $c.Substring(0, $corte).Trim(); args = $c.Substring($corte).Trim() }
}

# ---------- classificacao ----------

function Get-TabelaInicio {
    # Carrega protegidos.json e inicio.json uma vez por runspace.
    if ($null -ne $Script:TabelasInicio) { return $Script:TabelasInicio }
    $pr = Read-ArquivoJson (Join-Path (Get-PastaDeDados) 'protegidos.json')
    $ini = Read-ArquivoJson (Join-Path (Get-PastaDeDados) 'inicio.json')
    $regras = {
        param($Lista)
        $saida = New-Object System.Collections.Generic.List[object]
        foreach ($e in @($Lista)) {
            $rx = New-RegexLista $e.padrao
            if ($null -eq $rx) { continue }
            $saida.Add(@{ regex = $rx; cor = [string]$e.cor; motivo = [string]$e.motivo })
        }
        return $saida.ToArray()
    }
    $processos = @(@($pr.processos) | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $Script:TabelasInicio = @{
        protegidos = (& $regras $pr.programas)
        processos  = $processos
        itens      = (& $regras $ini.itens)
        tarefas    = (& $regras $ini.tarefas)
    }
    return $Script:TabelasInicio
}

function Get-ClassificacaoInicio {
    # @{ cor; motivoCor; protegido; motivoProtegido }. protegidos.json primeiro; depois a lista do tipo.
    param([string]$Nome, [string]$Exe, [string]$Comando, [string]$Editor, [string]$Origem)
    $t = Get-TabelaInicio
    $textos = @($Nome, $Editor, $Comando)
    if (-not [string]::IsNullOrEmpty($Exe)) {
        $base = [IO.Path]::GetFileName($Exe).ToLowerInvariant()
        # powershell/explorer/conhost so abrem outra coisa (script, URL): protege-los travaria justo o que se quer desligar.
        if ($t.processos -contains $base -and @('powershell.exe', 'explorer.exe', 'conhost.exe') -notcontains $base) {
            $m = 'Processo essencial do Windows ou deste programa.'
            return @{ cor = 'vermelho'; motivoCor = $m; protegido = $true; motivoProtegido = $m }
        }
    }
    foreach ($e in $t.protegidos) {
        foreach ($x in $textos) {
            if (-not [string]::IsNullOrEmpty($x) -and $e.regex.IsMatch($x)) {
                return @{ cor = 'vermelho'; motivoCor = $e.motivo; protegido = $true; motivoProtegido = $e.motivo }
            }
        }
    }
    $lista = if ($Origem -eq 'tarefa') { $t.tarefas } else { $t.itens }
    foreach ($e in $lista) {
        foreach ($x in $textos) {
            if (-not [string]::IsNullOrEmpty($x) -and $e.regex.IsMatch($x)) {
                $prot = ($e.cor -eq 'vermelho')
                return @{ cor = $e.cor; motivoCor = $e.motivo; protegido = $prot; motivoProtegido = $(if ($prot) { $e.motivo } else { $null }) }
            }
        }
    }
    return @{ cor = $null; motivoCor = $null; protegido = $false; motivoProtegido = $null }
}

# ---------- itens ----------

function New-ItemInicio {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Id, [string]$Nome, [string]$Comando, [string]$Origem, [string]$Escopo, [bool]$Ativo,
        [string]$Exe = '', [bool]$Avancado = $false, $Aprovado = $null)
    $editor = $null
    $tam = [int64]-1
    if (-not [string]::IsNullOrEmpty($Exe) -and (Test-Path -LiteralPath $Exe -PathType Leaf)) {
        try {
            $f = Get-Item -LiteralPath $Exe -Force -ErrorAction Stop
            $tam = [int64]$f.Length
            $ed = [string]$f.VersionInfo.CompanyName
            if (-not [string]::IsNullOrWhiteSpace($ed)) { $editor = $ed.Trim() }
        } catch { $null = $_ }
    }
    $c = Get-ClassificacaoInicio $Nome $Exe $Comando $editor $Origem
    return [ordered]@{
        id              = $Id
        nome            = $Nome
        comando         = $Comando
        exe             = $(if ([string]::IsNullOrEmpty($Exe)) { $null } else { $Exe })
        editor          = $editor
        origem          = $Origem
        escopo          = $Escopo
        ativo           = $Ativo
        cor             = $c.cor
        motivoCor       = $c.motivoCor
        protegido       = [bool]$c.protegido
        motivoProtegido = $c.motivoProtegido
        tamanhoBytes    = $tam
        ramBytes        = [int64]0
        rodando         = $false
        avancado        = $Avancado
        aprovado        = $Aprovado   # interno: @{ hive; sub; nome } (run/pasta) ou @{ caminho; nome } (tarefa)
    }
}

function Get-ValorAprovado {
    param([string]$HiveAprov, [string]$Sub, [string]$Nome, [bool]$Teste)
    $k = Get-ChaveAprovado $HiveAprov $Sub $Teste
    if (-not (Test-Path -LiteralPath $k)) { return $null }
    try { return (Get-Item -LiteralPath $k -ErrorAction Stop).GetValue($Nome) } catch { return $null }
}

function Get-ItemRun {
    param([string]$Hive, [bool]$Teste)
    $lista = New-Object System.Collections.Generic.List[object]
    $chave = Get-ChaveRun $Hive $Teste
    if (-not (Test-Path -LiteralPath $chave)) { return @() }
    $k = Get-Item -LiteralPath $chave -ErrorAction SilentlyContinue
    if ($null -eq $k) { return @() }
    $aprov = $Script:AprovadoDoRun[$Hive]
    $escopo = if ($Hive -eq 'hkcu') { 'usuario' } else { 'todos' }
    foreach ($nome in @($k.GetValueNames())) {
        if ([string]::IsNullOrEmpty($nome)) { continue }
        $cmd = [string]$k.GetValue($nome, '', 'DoNotExpandEnvironmentNames')
        $partes = Split-ComandoInicio $cmd
        $ativo = Get-EstadoAprovado (Get-ValorAprovado $aprov[0] $aprov[1] $nome $Teste)
        $lista.Add((New-ItemInicio -Id "run:${Hive}:$nome" -Nome $nome -Comando $cmd -Origem 'run' -Escopo $escopo -Ativo $ativo `
                    -Exe $partes.exe -Aprovado @{ hive = $aprov[0]; sub = $aprov[1]; nome = $nome }))
    }
    return $lista.ToArray()
}

function Get-ItemPasta {
    param([string]$Escopo, [bool]$Teste)
    $lista = New-Object System.Collections.Generic.List[object]
    $pasta = Get-PastaInicio $Escopo $Teste
    if ([string]::IsNullOrEmpty($pasta) -or -not (Test-Path -LiteralPath $pasta)) { return @() }
    $aprov = $Script:AprovadoDaPasta[$Escopo]
    foreach ($f in @(Get-ChildItem -LiteralPath $pasta -File -Force -ErrorAction SilentlyContinue)) {
        if ($f.Name -eq 'desktop.ini') { continue }
        $exe = ''
        if ($f.Extension -eq '.lnk') { $exe = [string](Get-AlvoAtalho $f.FullName) }
        elseif ($f.Extension -in @('.exe', '.bat', '.cmd')) { $exe = $f.FullName }
        $ativo = Get-EstadoAprovado (Get-ValorAprovado $aprov[0] $aprov[1] $f.Name $Teste)
        $lista.Add((New-ItemInicio -Id "pasta:${Escopo}:$($f.Name)" -Nome $f.BaseName -Comando $exe -Origem 'pasta' -Escopo $Escopo -Ativo $ativo `
                    -Exe $exe -Aprovado @{ hive = $aprov[0]; sub = $aprov[1]; nome = $f.Name }))
    }
    return $lista.ToArray()
}

function Get-TarefaBruta {
    # Tarefas com gatilho de logon/boot fora de \Microsoft\: @{ caminho; nome; exe; ativo }.
    # Em teste vem so de simular.tarefas (nunca Get-ScheduledTask).
    param([bool]$Teste, $Sim)
    $saida = New-Object System.Collections.Generic.List[object]
    if ($Teste) {
        if ($null -ne $Sim -and $null -ne $Sim.tarefas) {
            foreach ($t in @($Sim.tarefas)) {
                $saida.Add(@{ caminho = [string]$t.caminho; nome = [string]$t.nome; exe = [string]$t.exe; ativo = [bool]$t.ativo })
            }
        }
    } else {
        $tarefas = @()
        try { $tarefas = @(Get-ScheduledTask -ErrorAction Stop) } catch { $tarefas = @() }
        foreach ($t in $tarefas) {
            $gatilhos = @($t.Triggers | ForEach-Object { [string]$_.CimClass.CimClassName })
            if (-not ($gatilhos | Where-Object { $Script:GatilhosInicio -contains $_ })) { continue }
            $exe = ''
            $acao = @($t.Actions)[0]
            if ($null -ne $acao -and $null -ne $acao.Execute) { $exe = (Split-ComandoInicio ([string]$acao.Execute)).exe }
            $saida.Add(@{ caminho = [string]$t.TaskPath; nome = [string]$t.TaskName; exe = $exe; ativo = ([string]$t.State -ne 'Disabled') })
        }
    }
    return @($saida.ToArray() | Where-Object { -not ([string]$_.caminho).StartsWith('\Microsoft\', [StringComparison]::OrdinalIgnoreCase) })
}

function Get-ItemTarefa {
    param([bool]$Teste, $Sim)
    $lista = New-Object System.Collections.Generic.List[object]
    foreach ($t in @(Get-TarefaBruta $Teste $Sim)) {
        $caminho = [string]$t.caminho
        if (-not $caminho.EndsWith('\')) { $caminho += '\' }
        $lista.Add((New-ItemInicio -Id "tarefa:$caminho$($t.nome)" -Nome $t.nome -Comando $t.exe -Origem 'tarefa' -Escopo 'todos' -Ativo $t.ativo `
                    -Exe $t.exe -Avancado $true -Aprovado @{ caminho = $caminho; nome = $t.nome }))
    }
    return $lista.ToArray()
}

function Add-EnriquecimentoInicio {
    # Processo em execucao (Get-Process uma vez): rodando e RAM somada por caminho do exe.
    param($Lista)
    $processos = @()
    try { $processos = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrEmpty($_.Path) }) } catch { $processos = @() }
    foreach ($i in $Lista) {
        if ([string]::IsNullOrEmpty($i.exe)) { continue }
        $ram = [int64]0
        $rodando = $false
        foreach ($p in $processos) {
            if ([string]::Equals([string]$p.Path, [string]$i.exe, [StringComparison]::OrdinalIgnoreCase)) { $rodando = $true; $ram += [int64]$p.WorkingSet64 }
        }
        $i.rodando = $rodando
        $i.ramBytes = $ram
    }
}

function Get-ListaInicio {
    # Lista interna completa (com tarefas sempre, para resolver ids); 'avancado' filtra na saida.
    param([string]$Id, [bool]$Teste, $Sim)
    $lista = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($h in $Script:Hives) {
        if ($Id) { Send-Progress $Id ([int](40 * $i / $Script:Hives.Count)) "Lendo programas que abrem com o Windows ($h)" }
        $i++
        foreach ($x in @(Get-ItemRun $h $Teste)) { $lista.Add($x) }
    }
    if ($Id) { Send-Progress $Id 40 'Lendo as pastas de inicialização' }
    foreach ($e in $Script:Escopos) { foreach ($x in @(Get-ItemPasta $e $Teste)) { $lista.Add($x) } }
    if ($Id) { Send-Progress $Id 60 'Lendo tarefas agendadas' }
    foreach ($x in @(Get-ItemTarefa $Teste $Sim)) { $lista.Add($x) }
    if ($Id) { Send-Progress $Id 80 'Medindo memória em uso' }
    Add-EnriquecimentoInicio $lista
    return $lista.ToArray()
}

function Get-ItemInicioPorId {
    param([string]$IdItem, $Lista)
    foreach ($i in $Lista) { if ([string]::Equals($i.id, $IdItem, [StringComparison]::Ordinal)) { return $i } }
    return $null
}

function ConvertTo-ItemSaida {
    param($I)
    $o = [ordered]@{}
    foreach ($k in $I.Keys) { if ($k -ne 'aprovado') { $o[$k] = $I[$k] } }
    return $o
}

# ---------- acoes ----------

function Invoke-ListarInicio {
    param([string]$Id, $Params, [bool]$Teste)
    $sim = Get-Simulacao $Params $Teste
    $avancado = Test-ParamVerdadeiro $Params 'avancado'
    $lista = @(Get-ListaInicio $Id $Teste $sim | Where-Object { $avancado -or -not $_.avancado })
    $ordenada = @($lista | Sort-Object -Property @{ Expression = { -not $_.ativo } }, @{ Expression = { [string]$_.nome } })
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ itens = @($ordenada | ForEach-Object { ConvertTo-ItemSaida $_ }) })
}

function Set-TarefaAtiva {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Caminho, [string]$Nome, [bool]$Ativar, [bool]$Teste)
    if ($Teste) {
        $pasta = Join-Path (Get-AppPastas $true).Base 'inicio'
        if (-not (Test-Path -LiteralPath $pasta)) { New-Item -ItemType Directory -Path $pasta -Force | Out-Null }
        [IO.File]::WriteAllText((Join-Path $pasta "tarefa-$Nome.txt"), [string]$Ativar, (New-Object System.Text.UTF8Encoding $false))
        return
    }
    if ($Ativar) { Enable-ScheduledTask -TaskPath $Caminho -TaskName $Nome -ErrorAction Stop | Out-Null }
    else { Disable-ScheduledTask -TaskPath $Caminho -TaskName $Nome -ErrorAction Stop | Out-Null }
}

function Invoke-AlternarInicio {
    param([string]$Id, $Params, [bool]$Teste)
    if (-not (Test-ParamVerdadeiro $Params 'confirmado')) { Send-Result $Id $null $false 'ação exige confirmação'; return }
    if ($null -eq $Params -or $Params.ativar -isnot [bool]) { Send-Result $Id $null $false 'ativar deve ser verdadeiro ou falso'; return }
    $idItem = [string]$Params.id
    if ([string]::IsNullOrWhiteSpace($idItem)) { Send-Result $Id $null $false 'id não informado'; return }
    $ativar = [bool]$Params.ativar
    $sim = Get-Simulacao $Params $Teste
    Send-Progress $Id 10 'Localizando o item'
    $item = Get-ItemInicioPorId $idItem (Get-ListaInicio '' $Teste $sim)
    if ($null -eq $item) { Send-Result $Id $null $false "item não encontrado na lista: $idItem"; return }
    if ($item.protegido) { Send-Result $Id $null $false "item protegido, não pode ser desligado: $($item.nome). $($item.motivoProtegido)"; return }
    if ($item.origem -eq 'tarefa' -and -not (Test-ParamVerdadeiro $Params 'avancado')) {
        Send-Result $Id $null $false 'tarefas agendadas só podem ser alteradas no modo avançado'; return
    }
    Send-Progress $Id 50 $(if ($ativar) { "Ligando $($item.nome)" } else { "Desligando $($item.nome)" })
    $a = $item.aprovado
    if ($item.origem -eq 'tarefa') {
        Set-TarefaAtiva $a.caminho $a.nome $ativar $Teste
    } else {
        $chave = Get-ChaveAprovado $a.hive $a.sub $Teste
        if (-not (Test-Path -LiteralPath $chave)) { New-Item -Path $chave -Force -ErrorAction Stop | Out-Null }
        Set-ItemProperty -LiteralPath $chave -Name $a.nome -Value (New-ValorAprovado $ativar) -Type Binary -ErrorAction Stop
    }
    Write-AppLog ("inicializacao: alternar id={0} ativo={1}" -f $idItem, $ativar) $Teste
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ id = $idItem; ativo = $ativar })
}

function Invoke-Acao {
    param([string]$Id, [string]$Acao, $Params, [bool]$Teste)
    if (@('listar', 'alternar') -notcontains $Acao) {
        Send-Result $Id $null $false 'ação desconhecida'
        return
    }
    try {
        switch ($Acao) {
            'listar' { Invoke-ListarInicio $Id $Params $Teste }
            'alternar' { Invoke-AlternarInicio $Id $Params $Teste }
        }
    } catch {
        $msg = 'inicialização falhou: ' + $_.Exception.Message
        Write-AppLog $msg $Teste
        Send-Result $Id $null $false $msg
    }
}
