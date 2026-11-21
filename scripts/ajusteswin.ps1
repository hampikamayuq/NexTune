# ajusteswin.ps1 - Ajustes do Windows (anuncios, privacidade, Copilot/Widgets, Explorador, desempenho).
# Acoes: listar {avancado?}, aplicar {ids, confirmado, avancado?}, restaurar {ids, confirmado}.
# Catalogo em data\ajustes.json: cada ajuste tem id, grupo, chaves [{chave, nome, tipo, aplicar}], politica,
# avancado, recomendadoPara (todos|fraco|nenhum), soWin11, reiniciarExplorer. Textos ficam na interface.
# Regra de ouro (spec 8.5): so chaves que a tela de Configuracoes grava; chave de Politica so com
# politica:true + avancado:true. Antes de escrever, o valor original de cada chave\nome vai para
# Backups\ajustes-registro.json (nunca sobrescrito enquanto existir); restaurar devolve exatamente o
# valor e o tipo anteriores, ou remove o nome (e a chave, se nem ela existia e ficou vazia).
# Alem de chaves, o ajuste pode ter servicos [{nome, inicio}] (tipo de inicio alvo, ex.: Disabled) e
# tarefas [{caminho, nome}] (desativadas; resolvidas por nome sob o caminho, recursivamente). O backup guarda o
# tipo de inicio e se o servico rodava, e se a tarefa estava ativa; restaurar devolve exatamente isso. Servico ou
# tarefa que nao existe nesta edicao do Windows e "naoAplica" e nao falha o ajuste.
# Baseado em Sophia Script for Windows (MIT, farag2): servicos DiagTrack e WerSvc e lista de tarefas de telemetria.
# Em modo teste: HKCU\X e HKLM\X viram HKCU\Software\NexTuneTeste\Ajustes\{HKCU|HKLM}\X; backups em
# %TEMP%\NexTuneTeste\Backups; simular {build?, servicos?: {Nome: {inicio, rodando, atrasado?}}, tarefas?: [{caminho,
# nome, ativa}]} substitui o build e o estado do sistema; escritas em servicos/tarefas viram marcadores em
# %TEMP%\NexTuneTeste\ajustes.
. "$PSScriptRoot\common.ps1"

$Script:Catalogo = $null
$Script:PrefixoTeste = 'HKCU\Software\NexTuneTeste\Ajustes'
$Script:ArquivoBackup = 'ajustes-registro.json'
$Script:BuildWin11 = 22000
$Script:MotivoWin11 = 'Só existe no Windows 11.'

# ---------- catalogo ----------

function Get-Catalogo {
    if ($null -eq $Script:Catalogo) {
        $Script:Catalogo = @((Read-ArquivoJson (Join-Path (Get-PastaDeDados) 'ajustes.json')).ajustes)
    }
    return $Script:Catalogo
}

$Script:TiposRegistro = @('DWord', 'String', 'QWord', 'Binary', 'MultiString', 'ExpandString')

function Get-ItemCatalogo {
    # Puro: itens nao nulos da lista 'chaves', 'servicos' ou 'tarefas' do ajuste (vazia se ausente). Use @(...).
    param($Ajuste, [string]$Lista)
    return @($Ajuste.$Lista | Where-Object { $null -ne $_ })
}

function Test-ChaveDoAjuste {
    # Puro: chave\nome pertence ao ajuste do catalogo? (sem diferenciar caixa)
    param($Ajuste, [string]$Chave, [string]$Nome)
    foreach ($c in @(Get-ItemCatalogo $Ajuste 'chaves')) {
        if ([string]::Equals([string]$c.chave, $Chave, [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals([string]$c.nome, $Nome, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-AjustePorId {
    param([string]$IdAjuste)
    foreach ($a in (Get-Catalogo)) { if ([string]::Equals([string]$a.id, $IdAjuste, [StringComparison]::Ordinal)) { return $a } }
    return $null
}

# ---------- funcoes puras ----------

function Get-ChaveEfetiva {
    # Puro: em teste, 'HKLM\X' -> 'HKCU\Software\NexTuneTeste\Ajustes\HKLM\X'; fora dele, a chave intacta.
    param([string]$Chave, [bool]$Teste)
    if (-not $Teste) { return $Chave }
    return ($Script:PrefixoTeste + '\' + $Chave)
}

function Test-AjusteDisponivel {
    # Puro: @{ disponivel; motivo }. soWin11 exige build >= 22000.
    param($Ajuste, [int]$Build)
    if ($Ajuste.soWin11 -eq $true -and $Build -lt $Script:BuildWin11) { return @{ disponivel = $false; motivo = $Script:MotivoWin11 } }
    return @{ disponivel = $true; motivo = '' }
}

function Test-RecomendadoAjuste {
    # Puro: 'todos' sempre; 'fraco' com classe basico ou disco hdd (perfil ausente conta como fraco).
    param($Ajuste, $Perfil)
    switch ([string]$Ajuste.recomendadoPara) {
        'todos' { return $true }
        'fraco' { return ($null -eq $Perfil -or [string]$Perfil.classe -eq 'basico' -or [string]$Perfil.disco -eq 'hdd') }
        default { return $false }
    }
}

function Get-BuildWindows {
    param([bool]$Teste, $Sim)
    if ($Teste -and $null -ne $Sim -and $null -ne $Sim.build) { return [int]$Sim.build }
    try { return [int](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuildNumber -ErrorAction Stop).CurrentBuildNumber }
    catch { return [int][Environment]::OSVersion.Version.Build }
}

# ---------- registro ----------

function Get-ValorAtual {
    # Estado atual de chave\nome: @{ chave; nome; chaveExistia; existia; tipo; valor } (Binary vira lista de inteiros).
    param([string]$Chave, [string]$Nome, [bool]$Teste)
    $r = [ordered]@{ chave = $Chave; nome = $Nome; chaveExistia = $false; existia = $false; tipo = $null; valor = $null }
    $prov = ConvertTo-CaminhoRegistro (Get-ChaveEfetiva $Chave $Teste)
    if (-not (Test-Path -LiteralPath $prov)) { return $r }
    $r.chaveExistia = $true
    $k = Get-Item -LiteralPath $prov -ErrorAction Stop
    $nomeReal = @($k.GetValueNames() | Where-Object { [string]::Equals($_, $Nome, [StringComparison]::OrdinalIgnoreCase) })
    if ($nomeReal.Count -eq 0) { return $r }
    $r.existia = $true
    $r.tipo = [string]$k.GetValueKind($nomeReal[0])
    $v = $k.GetValue($nomeReal[0], $null, 'DoNotExpandEnvironmentNames')
    if ($r.tipo -eq 'Binary') { $v = @($v | ForEach-Object { [int]$_ }) }
    elseif ($r.tipo -eq 'MultiString') { $v = @($v | ForEach-Object { [string]$_ }) }
    $r.valor = $v
    return $r
}

function Test-ValorAplicado {
    # Puro: o valor atual ja e o valor 'aplicar' da chave do catalogo?
    param($Atual, $ChaveCatalogo)
    if (-not $Atual.existia) { return $false }
    if ([string]$ChaveCatalogo.tipo -eq 'String') { return ([string]$Atual.valor -eq [string]$ChaveCatalogo.aplicar) }
    try { return ([int64]$Atual.valor -eq [int64]$ChaveCatalogo.aplicar) } catch { return $false }
}

function Test-Aplicado {
    # Chaves no valor alvo, servicos existentes no inicio alvo e tarefas existentes desativadas. Sem nada
    # aplicavel (nenhuma chave, servico ou tarefa existe aqui) nao conta como aplicado.
    param($Ajuste, [bool]$Teste, $Extra = $null)
    $chaves = @(Get-ItemCatalogo $Ajuste 'chaves')
    foreach ($c in $chaves) {
        if (-not (Test-ValorAplicado (Get-ValorAtual ([string]$c.chave) ([string]$c.nome) $Teste) $c)) { return $false }
    }
    $existentes = 0
    if ($null -ne $Extra) {
        foreach ($s in @($Extra.servicos | Where-Object { $_.existe })) {
            $existentes++
            if ([string]$s.inicio -ne [string]$s.alvo) { return $false }
        }
        foreach ($k in @($Extra.tarefas | Where-Object { $_.existe })) {
            $existentes++
            if ($k.ativa) { return $false }
        }
    }
    return ($chaves.Count -gt 0 -or $existentes -gt 0)
}

function ConvertFrom-ValorBackup {
    # Valor do backup (JSON) de volta ao tipo do registro.
    param($Entrada)
    switch ([string]$Entrada.tipo) {
        'DWord' { return [int32]$Entrada.valor }
        'QWord' { return [int64]$Entrada.valor }
        'Binary' { return [byte[]]@(@($Entrada.valor) | ForEach-Object { [byte]$_ }) }
        'MultiString' { return [string[]]@(@($Entrada.valor) | ForEach-Object { [string]$_ }) }
        default { return [string]$Entrada.valor }
    }
}

function Set-ValorRegistro {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Chave, [string]$Nome, $Valor, [string]$Tipo, [bool]$Teste)
    $prov = ConvertTo-CaminhoRegistro (Get-ChaveEfetiva $Chave $Teste)
    if (-not (Test-Path -LiteralPath $prov)) { New-Item -Path $prov -Force -ErrorAction Stop | Out-Null }
    Set-ItemProperty -LiteralPath $prov -Name $Nome -Value $Valor -Type $Tipo -ErrorAction Stop
}

function Remove-ValorRegistro {
    # Remove o nome; se a chave nao existia antes e ficou vazia, remove a chave tambem.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Chave, [string]$Nome, [bool]$ChaveExistia, [bool]$Teste)
    $prov = ConvertTo-CaminhoRegistro (Get-ChaveEfetiva $Chave $Teste)
    if (-not (Test-Path -LiteralPath $prov)) { return }
    Remove-ItemProperty -LiteralPath $prov -Name $Nome -ErrorAction SilentlyContinue
    if ($ChaveExistia) { return }
    $k = Get-Item -LiteralPath $prov -ErrorAction Stop
    if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -LiteralPath $prov -Force -ErrorAction Stop }
}

# ---------- servicos e tarefas ----------

$Script:InicioValido = @('Automatic', 'Manual', 'Disabled')

function Get-PastaMarcadorAjuste {
    $p = Join-Path (Get-AppPastas $true).Base 'ajustes'
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    return $p
}

function Write-MarcadorAjuste {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Nome, [string]$Texto = '')
    [IO.File]::WriteAllText((Join-Path (Get-PastaMarcadorAjuste) $Nome), $Texto, (New-Object System.Text.UTF8Encoding $false))
}

function Get-EstadoServico {
    # $null se o servico nao existe aqui; senao @{ nome; inicio; rodando; atrasado }.
    param([string]$Nome, [bool]$Teste, $Sim)
    if ($Teste) {
        if ($null -eq $Sim -or $null -eq $Sim.servicos) { return $null }
        $v = $Sim.servicos.$Nome
        if ($null -eq $v) { return $null }
        return [pscustomobject]@{ nome = $Nome; inicio = [string]$v.inicio; rodando = ($v.rodando -eq $true); atrasado = ($v.atrasado -eq $true) }
    }
    $s = Get-Service -Name $Nome -ErrorAction SilentlyContinue
    if ($null -eq $s) { return $null }
    $atrasado = $false
    try {
        $reg = Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $Nome) -Name DelayedAutostart -ErrorAction Stop
        $atrasado = ($reg.DelayedAutostart -eq 1)
    } catch { $null = $_ }
    return [pscustomobject]@{ nome = $Nome; inicio = [string]$s.StartType; rodando = ($s.Status -eq 'Running'); atrasado = $atrasado }
}

function Set-InicioServico {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Nome, [string]$Inicio, [bool]$Atrasado, [bool]$Teste)
    $atrasa = ($Inicio -eq 'Automatic' -and $Atrasado)
    if ($Teste) { Write-MarcadorAjuste ('servico-' + $Nome + '-inicio.txt') $(if ($atrasa) { 'AutomaticDelayed' } else { $Inicio }); return }
    if ($atrasa) {
        & "$env:windir\System32\sc.exe" config $Nome start= delayed-auto | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "não foi possível restaurar o início do serviço $Nome" }
        return
    }
    Set-Service -Name $Nome -StartupType $Inicio -ErrorAction Stop
}

function Set-ExecucaoServico {
    # Para ou inicia o servico (nunca encerra processo).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Nome, [bool]$Rodar, [bool]$Teste)
    $verbo = if ($Rodar) { 'start' } else { 'stop' }
    if ($Teste) { Write-MarcadorAjuste ('servico-' + $Nome + '-' + $verbo + '.txt') $verbo; return }
    if ($Rodar) { Start-Service -Name $Nome -ErrorAction Stop -WarningAction SilentlyContinue }
    else { Stop-Service -Name $Nome -ErrorAction Stop -WarningAction SilentlyContinue }
}

function Test-CaminhoTarefa {
    # Puro: o caminho da tarefa esta no caminho do catalogo (ou abaixo dele)?
    param([string]$Caminho, [string]$Base)
    return $Caminho.StartsWith($Base, [StringComparison]::OrdinalIgnoreCase)
}

function Get-TarefaEncontrada {
    # Tarefas com o nome dado sob o caminho (recursivo): @{ caminho; nome; ativa }. Nenhuma = nao existe aqui.
    param([string]$Caminho, [string]$Nome, [bool]$Teste, $Sim)
    if ($Teste) {
        if ($null -eq $Sim -or $null -eq $Sim.tarefas) { return }
        foreach ($k in @($Sim.tarefas)) {
            if ([string]::Equals([string]$k.nome, $Nome, [StringComparison]::OrdinalIgnoreCase) -and (Test-CaminhoTarefa ([string]$k.caminho) $Caminho)) {
                [pscustomobject]@{ caminho = [string]$k.caminho; nome = [string]$k.nome; ativa = ($k.ativa -ne $false) }
            }
        }
        return
    }
    foreach ($k in @(Get-ScheduledTask -TaskName $Nome -ErrorAction SilentlyContinue)) {
        if (Test-CaminhoTarefa ([string]$k.TaskPath) $Caminho) {
            [pscustomobject]@{ caminho = [string]$k.TaskPath; nome = [string]$k.TaskName; ativa = ([string]$k.State -ne 'Disabled') }
        }
    }
}

function Set-EstadoTarefa {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Caminho, [string]$Nome, [bool]$Ativa, [bool]$Teste)
    if ($Teste) { Write-MarcadorAjuste ('tarefa-' + $Nome + '-' + $(if ($Ativa) { 'enable' } else { 'disable' }) + '.txt') $Caminho; return }
    if ($Ativa) { Enable-ScheduledTask -TaskPath $Caminho -TaskName $Nome -ErrorAction Stop | Out-Null }
    else { Disable-ScheduledTask -TaskPath $Caminho -TaskName $Nome -ErrorAction Stop | Out-Null }
}

function Get-EstadoExtra {
    # Estado atual dos servicos e tarefas do catalogo (existentes ou nao), para listar, aplicar e backup.
    param($Ajuste, [bool]$Teste, $Sim)
    $servicos = New-Object System.Collections.Generic.List[object]
    $tarefas = New-Object System.Collections.Generic.List[object]
    foreach ($s in @(Get-ItemCatalogo $Ajuste 'servicos')) {
        $e = Get-EstadoServico ([string]$s.nome) $Teste $Sim
        if ($null -eq $e) {
            $servicos.Add([ordered]@{ nome = [string]$s.nome; existe = $false; inicio = $null; rodando = $false; atrasado = $false; alvo = [string]$s.inicio })
        } else {
            $servicos.Add([ordered]@{ nome = [string]$s.nome; existe = $true; inicio = $e.inicio; rodando = $e.rodando; atrasado = $e.atrasado; alvo = [string]$s.inicio })
        }
    }
    foreach ($k in @(Get-ItemCatalogo $Ajuste 'tarefas')) {
        $achadas = @(Get-TarefaEncontrada ([string]$k.caminho) ([string]$k.nome) $Teste $Sim)
        if ($achadas.Count -eq 0) { $tarefas.Add([ordered]@{ nome = [string]$k.nome; caminho = [string]$k.caminho; existe = $false; ativa = $false }) }
        foreach ($a in $achadas) { $tarefas.Add([ordered]@{ nome = $a.nome; caminho = $a.caminho; existe = $true; ativa = [bool]$a.ativa }) }
    }
    return [pscustomobject]@{ servicos = $servicos.ToArray(); tarefas = $tarefas.ToArray() }
}

function Invoke-AplicarExtra {
    # Desliga servicos (inicio alvo; para se rodava) e desativa tarefas ativas; so o que existe aqui.
    param($Extra, [bool]$Teste)
    foreach ($s in @($Extra.servicos | Where-Object { $_.existe })) {
        if ($Script:InicioValido -notcontains [string]$s.alvo) { throw "início inválido no catálogo para o serviço $($s.nome)" }
        Set-InicioServico ([string]$s.nome) ([string]$s.alvo) $false $Teste
        if ($s.rodando -and [string]$s.alvo -eq 'Disabled') {
            # Ja desligado para o proximo boot; se nao parar agora, vale ao reiniciar (nao e erro).
            try { Set-ExecucaoServico ([string]$s.nome) $false $Teste } catch { $null = $_ }
        }
    }
    foreach ($k in @($Extra.tarefas | Where-Object { $_.existe -and $_.ativa })) {
        Set-EstadoTarefa ([string]$k.caminho) ([string]$k.nome) $false $Teste
    }
}

function Get-NaoAplica {
    # Itens do catalogo que nao existem nesta edicao do Windows: @{ id; tipo; nome }.
    param([string]$IdAjuste, $Extra)
    $r = New-Object System.Collections.Generic.List[object]
    foreach ($s in @($Extra.servicos | Where-Object { -not $_.existe })) { $r.Add([ordered]@{ id = $IdAjuste; tipo = 'servico'; nome = [string]$s.nome }) }
    foreach ($k in @($Extra.tarefas | Where-Object { -not $_.existe })) { $r.Add([ordered]@{ id = $IdAjuste; tipo = 'tarefa'; nome = [string]$k.nome }) }
    return $r.ToArray()
}

function Restore-ServicoDoBackup {
    # So servicos que o catalogo lista (o backup e um arquivo e nao manda no sistema).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param($Ajuste, $Entrada, [bool]$Teste, $Sim)
    $nome = [string]$Entrada.nome
    $noCatalogo = @(Get-ItemCatalogo $Ajuste 'servicos' | Where-Object { [string]::Equals([string]$_.nome, $nome, [StringComparison]::OrdinalIgnoreCase) })
    if ($noCatalogo.Count -eq 0 -or $Script:InicioValido -notcontains [string]$Entrada.inicio) { return }
    if ($null -eq (Get-EstadoServico $nome $Teste $Sim) -and -not $Teste) { return }
    Set-InicioServico $nome ([string]$Entrada.inicio) ($Entrada.atrasado -eq $true) $Teste
    if ($Entrada.rodando -eq $true -and [string]$Entrada.inicio -ne 'Disabled') { Set-ExecucaoServico $nome $true $Teste }
}

function Restore-TarefaDoBackup {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param($Ajuste, $Entrada, [bool]$Teste)
    $caminho = [string]$Entrada.caminho
    $nome = [string]$Entrada.nome
    $noCatalogo = @(Get-ItemCatalogo $Ajuste 'tarefas' | Where-Object {
            [string]::Equals([string]$_.nome, $nome, [StringComparison]::OrdinalIgnoreCase) -and (Test-CaminhoTarefa $caminho ([string]$_.caminho)) })
    if ($noCatalogo.Count -eq 0) { return }
    if (-not $Teste -and $null -eq (Get-ScheduledTask -TaskPath $caminho -TaskName $nome -ErrorAction SilentlyContinue)) { return }
    Set-EstadoTarefa $caminho $nome ($Entrada.ativa -eq $true) $Teste
}

# ---------- backups ----------

function Get-ArquivoBackup {
    param([bool]$Teste)
    return (Join-Path (Get-AppPastas $Teste).Backups $Script:ArquivoBackup)
}

function Read-Backups {
    # Hashtable id -> @{ data; valores }. Ausente = vazio. Ilegivel lanca (quem chama decide).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    param([bool]$Teste)
    $arq = Get-ArquivoBackup $Teste
    $saida = @{}
    if (-not (Test-Path -LiteralPath $arq -PathType Leaf)) { return $saida }
    $texto = [IO.File]::ReadAllText($arq, [Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
    if ([string]::IsNullOrWhiteSpace($texto)) { return $saida }
    try { $o = $texto | ConvertFrom-Json -ErrorAction Stop } catch { throw "backup de ajustes ilegível ($arq): $($_.Exception.Message)" }
    if ($o -isnot [pscustomobject]) { throw "backup de ajustes ilegível ($arq)" }
    foreach ($p in $o.PSObject.Properties) { $saida[$p.Name] = $p.Value }
    return $saida
}

function Test-TemBackup {
    param([string]$IdAjuste, [bool]$Teste)
    try { return (Read-Backups $Teste).ContainsKey($IdAjuste) } catch { return $false }
}

function Write-Backups {
    # Escrita atomica: .tmp + Move-Item -Force.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    param($Dados, [bool]$Teste)
    $o = [ordered]@{}
    foreach ($k in @($Dados.Keys | Sort-Object)) { $o[$k] = $Dados[$k] }
    Write-JsonAtomico (Get-ArquivoBackup $Teste) $o
}

# ---------- aplicar / restaurar (um ajuste) ----------

function Invoke-AplicarAjuste {
    # Backup antes da primeira escrita (nunca sobrescrito); depois grava cada chave\nome com o tipo do catalogo.
    # Devolve os itens "naoAplica" (servico/tarefa que nao existe aqui).
    param($Ajuste, [bool]$Teste, $Sim = $null)
    $id = [string]$Ajuste.id
    $backups = Read-Backups $Teste
    $extra = Get-EstadoExtra $Ajuste $Teste $Sim
    if (-not $backups.ContainsKey($id)) {
        $valores = New-Object System.Collections.Generic.List[object]
        foreach ($c in @(Get-ItemCatalogo $Ajuste 'chaves')) { $valores.Add((Get-ValorAtual ([string]$c.chave) ([string]$c.nome) $Teste)) }
        $entrada = [ordered]@{ data = (Get-Date).ToString('o'); valores = $valores.ToArray() }
        $svc = @($extra.servicos | Where-Object { $_.existe } | ForEach-Object { [ordered]@{ nome = $_.nome; inicio = $_.inicio; rodando = $_.rodando; atrasado = $_.atrasado } })
        $tar = @($extra.tarefas | Where-Object { $_.existe } | ForEach-Object { [ordered]@{ caminho = $_.caminho; nome = $_.nome; ativa = $_.ativa } })
        if ($svc.Count -gt 0) { $entrada['servicos'] = $svc }
        if ($tar.Count -gt 0) { $entrada['tarefas'] = $tar }
        $backups[$id] = $entrada
        Write-Backups $backups $Teste
    }
    foreach ($c in @(Get-ItemCatalogo $Ajuste 'chaves')) {
        $tipo = [string]$c.tipo
        $valor = if ($tipo -eq 'String') { [string]$c.aplicar } else { [int32]$c.aplicar }
        Set-ValorRegistro ([string]$c.chave) ([string]$c.nome) $valor $tipo $Teste
    }
    Invoke-AplicarExtra $extra $Teste
    return @(Get-NaoAplica $id $extra)
}

function Invoke-RestaurarAjuste {
    param($Ajuste, [bool]$Teste, $Sim = $null)
    $id = [string]$Ajuste.id
    $backups = Read-Backups $Teste
    if (-not $backups.ContainsKey($id)) { throw 'sem backup para este ajuste (ele não foi aplicado por este programa)' }
    foreach ($v in @($backups[$id].valores)) {
        # So as chaves que o catalogo lista para este ajuste: o backup e um arquivo e nao manda no registro.
        if (-not (Test-ChaveDoAjuste $Ajuste ([string]$v.chave) ([string]$v.nome))) { continue }
        if ($v.existia -eq $true -and $Script:TiposRegistro -notcontains [string]$v.tipo) { continue }
        if ($v.existia -eq $true) { Set-ValorRegistro ([string]$v.chave) ([string]$v.nome) (ConvertFrom-ValorBackup $v) ([string]$v.tipo) $Teste }
        else { Remove-ValorRegistro ([string]$v.chave) ([string]$v.nome) ([bool]$v.chaveExistia) $Teste }
    }
    foreach ($sv in @($backups[$id].servicos | Where-Object { $null -ne $_ })) { Restore-ServicoDoBackup $Ajuste $sv $Teste $Sim }
    foreach ($tk in @($backups[$id].tarefas | Where-Object { $null -ne $_ })) { Restore-TarefaDoBackup $Ajuste $tk $Teste }
    $backups.Remove($id)
    Write-Backups $backups $Teste
}

# ---------- acoes ----------

function Invoke-ListarAjuste {
    param([string]$Id, $Params, [bool]$Teste)
    $sim = Get-Simulacao $Params $Teste
    $avancado = Test-ParamVerdadeiro $Params 'avancado'
    $build = Get-BuildWindows $Teste $sim
    $perfil = Get-Perfil $Teste
    $backups = @{}
    try { $backups = Read-Backups $Teste } catch { Send-Log $Id 'aviso' $_.Exception.Message }
    $lista = New-Object System.Collections.Generic.List[object]
    $cat = @(Get-Catalogo)
    $i = 0
    foreach ($a in $cat) {
        if (($i % 5) -eq 0) { Send-Progress $Id ([int](100 * $i / [math]::Max(1, $cat.Count))) 'Lendo os ajustes atuais' }
        $i++
        if ($a.avancado -eq $true -and -not $avancado) { continue }
        $disp = Test-AjusteDisponivel $a $build
        $extra = if ($disp.disponivel) { Get-EstadoExtra $a $Teste $sim } else { $null }
        $item = [ordered]@{
            id                 = [string]$a.id
            grupo              = [string]$a.grupo
            politica           = ($a.politica -eq $true)
            avancado           = ($a.avancado -eq $true)
            recomendado        = [bool](Test-RecomendadoAjuste $a $perfil)
            disponivel         = [bool]$disp.disponivel
            motivoIndisponivel = [string]$disp.motivo
            aplicado           = $(if ($disp.disponivel) { [bool](Test-Aplicado $a $Teste $extra) } else { $false })
            temBackup          = $backups.ContainsKey([string]$a.id)
            reiniciarExplorer  = ($a.reiniciarExplorer -eq $true)
        }
        if ($null -ne $extra -and @($extra.servicos).Count -gt 0) { $item['servicos'] = @($extra.servicos | ForEach-Object { [ordered]@{ nome = $_.nome; existe = $_.existe; inicio = $_.inicio; rodando = $_.rodando } }) }
        if ($null -ne $extra -and @($extra.tarefas).Count -gt 0) { $item['tarefas'] = @($extra.tarefas | ForEach-Object { [ordered]@{ nome = $_.nome; existe = $_.existe; ativa = $_.ativa } }) }
        $lista.Add($item)
    }
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ ajustes = $lista.ToArray() })
}

function Invoke-EmLote {
    # Roda $Acao (aplicar|restaurar) por id, acumulando sucessos e falhas; nunca interrompe os demais.
    param([string]$Id, $Params, [bool]$Teste, [string]$Acao)
    if (-not (Test-ParamVerdadeiro $Params 'confirmado')) { Send-Result $Id $null $false 'ação exige confirmação'; return }
    $ids = Get-IdsParam $Params
    if ($ids.Count -eq 0) { Send-Result $Id $null $false 'nenhum ajuste informado'; return }
    $sim = Get-Simulacao $Params $Teste
    $avancado = Test-ParamVerdadeiro $Params 'avancado'
    $build = Get-BuildWindows $Teste $sim
    $feitos = New-Object System.Collections.Generic.List[string]
    $falhas = New-Object System.Collections.Generic.List[object]
    $naoAplica = New-Object System.Collections.Generic.List[object]
    $reiniciar = $false
    $i = 0
    foreach ($idAj in $ids) {
        Send-Progress $Id ([int](100 * $i / $ids.Count)) $(if ($Acao -eq 'aplicar') { "Aplicando $idAj" } else { "Restaurando $idAj" })
        $i++
        $a = Get-AjustePorId $idAj
        if ($null -eq $a) { $falhas.Add([ordered]@{ id = $idAj; erro = 'ajuste desconhecido' }); continue }
        try {
            if ($Acao -eq 'aplicar') {
                if ($a.avancado -eq $true -and -not $avancado) { throw 'este ajuste só está disponível no modo avançado' }
                $disp = Test-AjusteDisponivel $a $build
                if (-not $disp.disponivel) { throw [string]$disp.motivo }
                foreach ($n in @(Invoke-AplicarAjuste $a $Teste $sim)) { $naoAplica.Add($n) }
            } else {
                Invoke-RestaurarAjuste $a $Teste $sim
            }
            $feitos.Add($idAj)
            if ($a.reiniciarExplorer -eq $true) { $reiniciar = $true }
            Write-AppLog ("ajusteswin: {0} id={1} chaves={2}" -f $Acao, $idAj, @(Get-ItemCatalogo $a 'chaves').Count) $Teste
        } catch {
            $falhas.Add([ordered]@{ id = $idAj; erro = $_.Exception.Message })
            Send-Log $Id 'aviso' ("Falha em ${idAj}: " + $_.Exception.Message)
        }
    }
    Send-Progress $Id 100 'Concluído'
    $chave = if ($Acao -eq 'aplicar') { 'aplicados' } else { 'restaurados' }
    Send-Result $Id ([ordered]@{ $chave = $feitos.ToArray(); falhas = $falhas.ToArray(); naoAplica = $naoAplica.ToArray(); precisaReiniciar = $reiniciar })
}

function Invoke-Acao {
    param([string]$Id, [string]$Acao, $Params, [bool]$Teste)
    if (@('listar', 'aplicar', 'restaurar') -notcontains $Acao) {
        Send-Result $Id $null $false 'ação desconhecida'
        return
    }
    try {
        switch ($Acao) {
            'listar' { Invoke-ListarAjuste $Id $Params $Teste }
            'aplicar' { Invoke-EmLote $Id $Params $Teste 'aplicar' }
            'restaurar' { Invoke-EmLote $Id $Params $Teste 'restaurar' }
        }
    } catch {
        $msg = 'ajustes do Windows falharam: ' + $_.Exception.Message
        Write-AppLog $msg $Teste
        Send-Result $Id $null $false $msg
    }
}
