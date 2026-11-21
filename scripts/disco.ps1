# disco.ps1 - estado das unidades fixas, verificacao online (so leitura), correcao agendada para o
# proximo reinicio, reiniciar agora e otimizar (desfragmentar em HDD, TRIM em SSD; nunca o inverso).
# Acoes: estado {}, verificar {letra}, corrigir {letra, confirmado}, reiniciar {confirmado},
# otimizar {letra, confirmado}. 'letra' sempre na forma 'C:' e resolvida contra a lista do proprio script.
# Regras (spec 7 e 8.6): tipo decidido pelo disco fisico da unidade (ilegivel = hdd); otimizar so com bit
# sujo desligado e uma verificacao registrada sem erros; corrigir nao mexe no volume agora: marca o bit
# sujo (fsutil dirty set), o autochk do proximo reinicio faz o equivalente a chkdsk /f.
# Ultima verificacao: registro proprio em Estado\disco.json, complementado pelos eventos Wininit 1001 e
# Chkdsk 26226/26212/26214 (so a data; 'semErros' so vem do registro proprio).
# Em modo teste: simular {unidades [{letra, rotulo, total, livre, tipoDisco, sistema, sujo, agendada}],
# inicioRapido?, resultado?} substitui toda leitura real; marcadores em %TEMP%\NexTuneTeste\disco\.
. "$PSScriptRoot\common.ps1"

$Script:ArquivoRegistro = 'disco.json'
$Script:ResultadosSemErro = @('NoErrorsFound', 'ErrorsFixed')
$Script:ChaveSessionManager = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'

# ---------- funcoes puras ----------

function Test-UnidadeAgendada {
    # Puro: algum item do BootExecute agenda autochk para a letra (autochk ... \??\C:)? Sem diferenciar caixa.
    param([string[]]$BootExecute, [string]$Letra)
    if ($null -eq $BootExecute) { return $false }
    $re = 'autochk.*\\\?\?\\' + [regex]::Escape($Letra)
    foreach ($e in $BootExecute) { if ([string]$e -match $re) { return $true } }
    return $false
}

function Get-OperacaoOtimizar {
    # Puro: ssd -> trim; qualquer outra coisa (hdd, desconhecido) -> desfragmentar. TRIM em HDD nunca.
    param([string]$TipoDisco)
    if ($TipoDisco -eq 'ssd') { return 'trim' }
    return 'desfragmentar'
}

function Test-PodeOtimizar {
    # Puro: @{ pode; motivo }. Exige bit sujo desligado e verificacao registrada sem erros.
    param($Unidade)
    if ($Unidade.sujo -eq $true) { return @{ pode = $false; motivo = 'o volume está marcado para verificação; reinicie o PC antes de otimizar' } }
    if ($Unidade.semErros -ne $true) { return @{ pode = $false; motivo = 'verifique a unidade antes de otimizar (a verificação precisa terminar sem erros)' } }
    return @{ pode = $true; motivo = '' }
}

function Get-DiasDesde {
    # Puro: dias inteiros (para baixo) entre uma data ISO e agora; $null para vazio ou ilegivel.
    param([string]$Iso, [DateTime]$Agora)
    if ([string]::IsNullOrWhiteSpace($Iso)) { return $null }
    try { $d = [DateTime]::Parse($Iso, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
    catch { return $null }
    $dias = [math]::Floor(($Agora - $d).TotalDays)
    if ($dias -lt 0) { return 0 }
    return [int]$dias
}

function Get-UnidadePorLetra {
    param([string]$Letra, $Unidades)
    foreach ($u in @($Unidades)) { if ([string]$u.letra -eq $Letra) { return $u } }
    return $null
}

# ---------- registro da ultima verificacao ----------

function Get-ArquivoRegistro {
    param([bool]$Teste)
    return (Join-Path (Get-AppPastas $Teste).Estado $Script:ArquivoRegistro)
}

function Read-RegistroVerificacao {
    # Hashtable letra -> @{ verificadoEm; semErros }. Ausente ou ilegivel = vazio (nunca verificado por aqui).
    param([bool]$Teste)
    $saida = @{}
    $arq = Get-ArquivoRegistro $Teste
    if (-not (Test-Path -LiteralPath $arq -PathType Leaf)) { return $saida }
    try {
        $texto = [IO.File]::ReadAllText($arq, [Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
        $o = $texto | ConvertFrom-Json -ErrorAction Stop
        if ($o -is [pscustomobject]) { foreach ($p in $o.PSObject.Properties) { $saida[$p.Name] = $p.Value } }
    } catch { $null = $_ }
    return $saida
}

function Write-RegistroVerificacao {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param($Dados, [bool]$Teste)
    $o = [ordered]@{}
    foreach ($k in @($Dados.Keys | Sort-Object)) { $o[$k] = $Dados[$k] }
    Write-JsonAtomico (Get-ArquivoRegistro $Teste) $o
}

# ---------- leitura das unidades ----------

function Get-PastaDiscoTeste {
    $p = Join-Path (Get-AppPastas $true).Base 'disco'
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    return $p
}

function Write-Marcador {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Nome, [string]$Texto)
    [IO.File]::WriteAllText((Join-Path (Get-PastaDiscoTeste) $Nome), $Texto, (New-Object System.Text.UTF8Encoding $false))
}

function Get-TipoDiscoUnidade {
    # 'hdd' | 'ssd' pelo disco fisico da letra; qualquer falha conta como hdd (conservador).
    param([string]$Letra)
    try {
        $pd = Get-Partition -DriveLetter $Letra[0] -ErrorAction Stop | Get-Disk -ErrorAction Stop | Get-PhysicalDisk -ErrorAction Stop | Select-Object -First 1
        if ($null -eq $pd) { return 'hdd' }
        if ((Get-TipoDisco ([string]$pd.MediaType) ([string]$pd.BusType)) -eq 'HDD') { return 'hdd' }
        return 'ssd'
    } catch { return 'hdd' }
}

function Get-UltimaVerificacaoEventos {
    # Hashtable letra -> [DateTime] da verificacao mais recente registrada pelo Windows.
    param([string]$LetraSistema)
    $r = @{}
    try {
        foreach ($e in @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Microsoft-Windows-Wininit'; Id = 1001 } -MaxEvents 20 -ErrorAction Stop)) {
            if (-not $r.ContainsKey($LetraSistema) -or $e.TimeCreated -gt $r[$LetraSistema]) { $r[$LetraSistema] = $e.TimeCreated }
        }
    } catch { $null = $_ }
    try {
        foreach ($e in @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Chkdsk'; Id = 26226, 26212, 26214 } -MaxEvents 20 -ErrorAction Stop)) {
            $letra = $LetraSistema
            if ([string]$e.Message -cmatch '\b([A-Z]):') { $letra = $Matches[1] + ':' }
            if (-not $r.ContainsKey($letra) -or $e.TimeCreated -gt $r[$letra]) { $r[$letra] = $e.TimeCreated }
        }
    } catch { $null = $_ }
    return $r
}

function Get-UnidadesReais {
    $lista = New-Object System.Collections.Generic.List[object]
    $volumes = @{}
    try {
        foreach ($v in @(Get-CimInstance Win32_Volume -Filter 'DriveType=3' -ErrorAction Stop)) {
            if (-not [string]::IsNullOrEmpty([string]$v.DriveLetter)) { $volumes[[string]$v.DriveLetter] = $v }
        }
    } catch { $null = $_ }
    $bootExecute = @()
    try { $bootExecute = @((Get-ItemProperty -LiteralPath $Script:ChaveSessionManager -Name BootExecute -ErrorAction Stop).BootExecute) } catch { $null = $_ }
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        try {
            if ($d.DriveType -ne 'Fixed' -or -not $d.IsReady) { continue }
            $letra = $d.Name.TrimEnd('\')
            $sujo = ($volumes.ContainsKey($letra) -and $volumes[$letra].DirtyBitSet -eq $true)
            $lista.Add([ordered]@{
                letra     = $letra
                rotulo    = [string]$d.VolumeLabel
                total     = [int64]$d.TotalSize
                livre     = [int64]$d.AvailableFreeSpace
                tipoDisco = Get-TipoDiscoUnidade $letra
                sistema   = ($letra -eq $env:SystemDrive)
                sujo      = $sujo
                agendada  = ($sujo -or (Test-UnidadeAgendada $bootExecute $letra))
            })
        } catch { $null = $_ }
    }
    return $lista.ToArray()
}

function Get-UnidadesSimuladas {
    param($Sim)
    $lista = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Sim -or $null -eq $Sim.unidades) { return @() }
    foreach ($u in @($Sim.unidades)) {
        $sujo = ($u.sujo -eq $true)
        $lista.Add([ordered]@{
            letra     = [string]$u.letra
            rotulo    = [string]$u.rotulo
            total     = [int64]$u.total
            livre     = [int64]$u.livre
            tipoDisco = [string]$u.tipoDisco
            sistema   = ($u.sistema -eq $true)
            sujo      = $sujo
            agendada  = ($sujo -or $u.agendada -eq $true)
        })
    }
    return $lista.ToArray()
}

function Get-Unidades {
    # Unidades fixas com a ultima verificacao (registro proprio + eventos, fora do teste) ja anexada.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    param([bool]$Teste, $Sim)
    $unidades = @($(if ($Teste) { Get-UnidadesSimuladas $Sim } else { Get-UnidadesReais }))
    $registro = Read-RegistroVerificacao $Teste
    $eventos = @{}
    if (-not $Teste) { $eventos = Get-UltimaVerificacaoEventos $env:SystemDrive }
    $agora = Get-Date
    foreach ($u in $unidades) {
        $ultima = $null
        $semErros = $null
        if ($registro.ContainsKey($u.letra)) {
            $ultima = [string]$registro[$u.letra].verificadoEm
            $semErros = ($registro[$u.letra].semErros -eq $true)
        }
        if ($eventos.ContainsKey($u.letra)) {
            $ev = [DateTime]$eventos[$u.letra]
            $dReg = $null
            if (-not [string]::IsNullOrEmpty($ultima)) { try { $dReg = [DateTime]::Parse($ultima, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) } catch { $dReg = $null } }
            if ($null -eq $dReg -or $ev -gt $dReg) { $ultima = $ev.ToString('o') }
        }
        $u.ultimaVerificacao = $ultima
        $u.semErros = $semErros
        $u.diasSemVerificar = Get-DiasDesde $ultima $agora
    }
    return $unidades
}

# ---------- acoes ----------

function Get-UnidadeDoParam {
    # Unidade da 'letra' dos params ou $null (quem chama devolve 'unidade não encontrada').
    param($Params, [bool]$Teste, $Sim)
    $letra = ''
    if ($null -ne $Params -and $null -ne $Params.letra) { $letra = [string]$Params.letra }
    return (Get-UnidadePorLetra $letra (Get-Unidades $Teste $Sim))
}

function Invoke-Estado {
    param([string]$Id, $Params, [bool]$Teste)
    $sim = Get-Simulacao $Params $Teste
    Send-Progress $Id 10 'Lendo as unidades'
    $unidades = @(Get-Unidades $Teste $sim)
    $inicioRapido = if ($Teste) { ($null -ne $sim -and $sim.inicioRapido -eq $true) } else { Get-InicioRapido }
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ unidades = $unidades; inicioRapido = [bool]$inicioRapido })
}

function Invoke-Verificar {
    param([string]$Id, $Params, [bool]$Teste)
    $sim = Get-Simulacao $Params $Teste
    $u = Get-UnidadeDoParam $Params $Teste $sim
    if ($null -eq $u) { Send-Result $Id $null $false ('unidade não encontrada: ' + [string]$Params.letra); return }
    $letra = [string]$u.letra
    Send-Progress $Id 10 "Verificando $letra (pode levar alguns minutos)"
    if ($Teste) {
        $resultado = 'NoErrorsFound'
        if ($null -ne $sim -and -not [string]::IsNullOrEmpty([string]$sim.resultado)) { $resultado = [string]$sim.resultado }
        Write-Marcador ('verificar-' + $letra[0] + '.txt') $resultado
    } else {
        $resultado = [string](Repair-Volume -DriveLetter $letra[0] -Scan -ErrorAction Stop)
    }
    $semErros = ($Script:ResultadosSemErro -contains $resultado)
    $agora = (Get-Date).ToString('o')
    $registro = Read-RegistroVerificacao $Teste
    $registro[$letra] = [ordered]@{ verificadoEm = $agora; semErros = $semErros }
    Write-RegistroVerificacao $registro $Teste
    Write-AppLog ("disco: verificar {0} resultado={1}" -f $letra, $resultado) $Teste
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ letra = $letra; resultado = $resultado; semErros = $semErros; verificadoEm = $agora })
}

function Invoke-Corrigir {
    param([string]$Id, $Params, [bool]$Teste)
    if (-not (Test-ParamVerdadeiro $Params 'confirmado')) { Send-Result $Id $null $false 'ação exige confirmação'; return }
    $sim = Get-Simulacao $Params $Teste
    $u = Get-UnidadeDoParam $Params $Teste $sim
    if ($null -eq $u) { Send-Result $Id $null $false ('unidade não encontrada: ' + [string]$Params.letra); return }
    $letra = [string]$u.letra
    Send-Progress $Id 30 "Agendando a verificação de $letra para o próximo reinício"
    if ($Teste) {
        Write-Marcador ('corrigir-' + $letra[0] + '.txt') 'dirty set'
        $inicioRapido = ($null -ne $sim -and $sim.inicioRapido -eq $true)
    } else {
        & "$env:windir\System32\fsutil.exe" dirty set $letra | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "fsutil terminou com código $LASTEXITCODE" }
        $inicioRapido = Get-InicioRapido
    }
    Write-AppLog ("disco: corrigir {0} agendado para o reinício (inicioRapido={1})" -f $letra, $inicioRapido) $Teste
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ letra = $letra; agendada = $true; inicioRapido = [bool]$inicioRapido })
}

function Invoke-Reiniciar {
    param([string]$Id, $Params, [bool]$Teste)
    if (-not (Test-ParamVerdadeiro $Params 'confirmado')) { Send-Result $Id $null $false 'ação exige confirmação'; return }
    if ($Teste) {
        Write-Marcador 'reiniciar.txt' (Get-Date).ToString('o')
    } else {
        & "$env:windir\System32\shutdown.exe" /r /t 10 /c 'NexTune: reiniciando para verificar o disco' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "shutdown terminou com código $LASTEXITCODE" }
    }
    Write-AppLog 'disco: reiniciar agendado (10 s)' $Teste
    Send-Result $Id ([ordered]@{ agendado = $true })
}

function Invoke-Otimizar {
    param([string]$Id, $Params, [bool]$Teste)
    if (-not (Test-ParamVerdadeiro $Params 'confirmado')) { Send-Result $Id $null $false 'ação exige confirmação'; return }
    $sim = Get-Simulacao $Params $Teste
    $u = Get-UnidadeDoParam $Params $Teste $sim
    if ($null -eq $u) { Send-Result $Id $null $false ('unidade não encontrada: ' + [string]$Params.letra); return }
    $pode = Test-PodeOtimizar $u
    if (-not $pode.pode) { Send-Result $Id $null $false ([string]$pode.motivo); return }
    $letra = [string]$u.letra
    $operacao = Get-OperacaoOtimizar ([string]$u.tipoDisco)
    Send-Progress $Id 10 $(if ($operacao -eq 'trim') { "Fazendo TRIM em $letra" } else { "Desfragmentando $letra (em HDD pode levar horas)" })
    if ($Teste) {
        Write-Marcador ('otimizar-' + $letra[0] + '.txt') $operacao
    } elseif ($operacao -eq 'trim') {
        Optimize-Volume -DriveLetter $letra[0] -ReTrim -ErrorAction Stop
    } else {
        Optimize-Volume -DriveLetter $letra[0] -Defrag -ErrorAction Stop
    }
    Write-AppLog ("disco: otimizar {0} operacao={1} tipo={2}" -f $letra, $operacao, $u.tipoDisco) $Teste
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ letra = $letra; operacao = $operacao })
}

function Invoke-Acao {
    param([string]$Id, [string]$Acao, $Params, [bool]$Teste)
    if (@('estado', 'verificar', 'corrigir', 'reiniciar', 'otimizar') -notcontains $Acao) {
        Send-Result $Id $null $false 'ação desconhecida'
        return
    }
    try {
        switch ($Acao) {
            'estado' { Invoke-Estado $Id $Params $Teste }
            'verificar' { Invoke-Verificar $Id $Params $Teste }
            'corrigir' { Invoke-Corrigir $Id $Params $Teste }
            'reiniciar' { Invoke-Reiniciar $Id $Params $Teste }
            'otimizar' { Invoke-Otimizar $Id $Params $Teste }
        }
    } catch {
        $msg = 'disco falhou: ' + $_.Exception.Message
        Write-AppLog $msg $Teste
        Send-Result $Id $null $false $msg
    }
}
