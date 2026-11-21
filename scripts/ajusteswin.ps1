# ajusteswin.ps1 - Ajustes do Windows (anuncios, privacidade, Copilot/Widgets, Explorador, desempenho).
# Acoes: listar {avancado?}, aplicar {ids, confirmado, avancado?}, restaurar {ids, confirmado}.
# Catalogo em data\ajustes.json: cada ajuste tem id, grupo, chaves [{chave, nome, tipo, aplicar}], politica,
# avancado, recomendadoPara (todos|fraco|nenhum), soWin11, reiniciarExplorer. Textos ficam na interface.
# Regra de ouro (spec 8.5): so chaves que a tela de Configuracoes grava; chave de Politica so com
# politica:true + avancado:true. Antes de escrever, o valor original de cada chave\nome vai para
# Backups\ajustes-registro.json (nunca sobrescrito enquanto existir); restaurar devolve exatamente o
# valor e o tipo anteriores, ou remove o nome (e a chave, se nem ela existia e ficou vazia).
# Em modo teste: HKCU\X e HKLM\X viram HKCU\Software\NexTuneTeste\Ajustes\{HKCU|HKLM}\X; backups em
# %TEMP%\NexTuneTeste\Backups; simular {build?} substitui o build do Windows.
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

function Test-ChaveDoAjuste {
    # Puro: chave\nome pertence ao ajuste do catalogo? (sem diferenciar caixa)
    param($Ajuste, [string]$Chave, [string]$Nome)
    foreach ($c in @($Ajuste.chaves)) {
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
    param($Ajuste, [bool]$Teste)
    foreach ($c in @($Ajuste.chaves)) {
        if (-not (Test-ValorAplicado (Get-ValorAtual ([string]$c.chave) ([string]$c.nome) $Teste) $c)) { return $false }
    }
    return $true
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
    param($Ajuste, [bool]$Teste)
    $id = [string]$Ajuste.id
    $backups = Read-Backups $Teste
    if (-not $backups.ContainsKey($id)) {
        $valores = New-Object System.Collections.Generic.List[object]
        foreach ($c in @($Ajuste.chaves)) { $valores.Add((Get-ValorAtual ([string]$c.chave) ([string]$c.nome) $Teste)) }
        $backups[$id] = [ordered]@{ data = (Get-Date).ToString('o'); valores = $valores.ToArray() }
        Write-Backups $backups $Teste
    }
    foreach ($c in @($Ajuste.chaves)) {
        $tipo = [string]$c.tipo
        $valor = if ($tipo -eq 'String') { [string]$c.aplicar } else { [int32]$c.aplicar }
        Set-ValorRegistro ([string]$c.chave) ([string]$c.nome) $valor $tipo $Teste
    }
}

function Invoke-RestaurarAjuste {
    param($Ajuste, [bool]$Teste)
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
        $lista.Add([ordered]@{
            id                 = [string]$a.id
            grupo              = [string]$a.grupo
            politica           = ($a.politica -eq $true)
            avancado           = ($a.avancado -eq $true)
            recomendado        = [bool](Test-RecomendadoAjuste $a $perfil)
            disponivel         = [bool]$disp.disponivel
            motivoIndisponivel = [string]$disp.motivo
            aplicado           = $(if ($disp.disponivel) { [bool](Test-Aplicado $a $Teste) } else { $false })
            temBackup          = $backups.ContainsKey([string]$a.id)
            reiniciarExplorer  = ($a.reiniciarExplorer -eq $true)
        })
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
                Invoke-AplicarAjuste $a $Teste
            } else {
                Invoke-RestaurarAjuste $a $Teste
            }
            $feitos.Add($idAj)
            if ($a.reiniciarExplorer -eq $true) { $reiniciar = $true }
            Write-AppLog ("ajusteswin: {0} id={1} chaves={2}" -f $Acao, $idAj, @($a.chaves).Count) $Teste
        } catch {
            $falhas.Add([ordered]@{ id = $idAj; erro = $_.Exception.Message })
            Send-Log $Id 'aviso' ("Falha em ${idAj}: " + $_.Exception.Message)
        }
    }
    Send-Progress $Id 100 'Concluído'
    $chave = if ($Acao -eq 'aplicar') { 'aplicados' } else { 'restaurados' }
    Send-Result $Id ([ordered]@{ $chave = $feitos.ToArray(); falhas = $falhas.ToArray(); precisaReiniciar = $reiniciar })
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
