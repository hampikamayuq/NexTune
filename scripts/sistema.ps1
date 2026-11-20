# sistema.ps1 - ponto de restauracao, Protecao do Sistema e verificacao de sessao.
# Acoes: protecaoEstado {}, criarPonto {descricao?}, ligarProtecao {}, sessao {}.
# Em modo de teste: registro em HKCU:\Software\NexTuneTeste\SystemRestore, marcadores em
# %TEMP%\NexTuneTeste\sistema\ e nenhum Checkpoint-Computer/Enable-ComputerRestore/vssadmin real.
# simular {falharCriar?, usuarioConsole?, usuarioProcesso?} so vale em modo de teste.
. "$PSScriptRoot\common.ps1"

$Script:ChaveRestauracaoReal = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
$Script:ChaveRestauracaoTeste = 'HKCU:\Software\NexTuneTeste\SystemRestore'
$Script:NomeFrequencia = 'SystemRestorePointCreationFrequency'
$Script:NomeIntervalo = 'RPSessionInterval'
$Script:MaxDescricao = 80

function Get-Simulacao {
    # 'simular' so vale em modo de teste; fora dele e ignorado.
    param($Params, [bool]$Teste)
    if (-not $Teste -or $null -eq $Params) { return $null }
    return $Params.simular
}

function Get-ChaveRestauracao {
    param([bool]$Teste)
    if ($Teste) { return $Script:ChaveRestauracaoTeste }
    return $Script:ChaveRestauracaoReal
}

function Get-PastaSistemaTeste {
    # Pasta dos marcadores do modo de teste (%TEMP%\NexTuneTeste\sistema), criada se preciso.
    $p = Join-Path (Get-AppPastas $true).Base 'sistema'
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    return $p
}

function Get-ValorRegistro {
    # Valor de um nome numa chave, ou $null se a chave ou o nome nao existirem.
    param([string]$Chave, [string]$Nome)
    try { return (Get-ItemProperty -LiteralPath $Chave -Name $Nome -ErrorAction Stop).$Nome }
    catch { return $null }
}

function Get-UltimoPontoIso {
    # Data (ISO 8601) do ponto de restauracao mais recente, ou $null se nao houver.
    param([bool]$Teste)
    if ($Teste) {
        $pasta = Get-PastaSistemaTeste
        $m = Get-ChildItem -LiteralPath $pasta -Filter 'ponto-*.txt' -File -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($null -eq $m) { return $null }
        try {
            $d = [DateTime]::ParseExact($m.BaseName.Substring(6), 'yyyyMMddHHmmssfff', [Globalization.CultureInfo]::InvariantCulture)
        } catch { $d = $m.LastWriteTime }
        return $d.ToString('o')
    }
    $pontos = @()
    try { $pontos = @(Get-ComputerRestorePoint -ErrorAction Stop) } catch { return $null }
    $ultimo = $null
    foreach ($p in $pontos) {
        # CreationTime vem como data WMI (yyyyMMddHHmmss.ffffff+zzz).
        try { $d = [Management.ManagementDateTimeConverter]::ToDateTime([string]$p.CreationTime) } catch { continue }
        if ($null -eq $ultimo -or $d -gt $ultimo) { $ultimo = $d }
    }
    if ($null -eq $ultimo) { return $null }
    return $ultimo.ToString('o')
}

function Get-DescricaoPonto {
    # Puro: "NexTune dd/MM HH:mm" mais a descricao do usuario (sem caracteres de controle,
    # ate $Script:MaxDescricao caracteres), se houver.
    param($Params, [DateTime]$Agora = (Get-Date))
    $d = 'NexTune ' + $Agora.ToString('dd/MM HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    if ($null -ne $Params -and $null -ne $Params.descricao) {
        $extra = (([string]$Params.descricao) -replace '[\p{Cc}]', '').Trim()
        if ($extra.Length -gt $Script:MaxDescricao) { $extra = $extra.Substring(0, $Script:MaxDescricao) }
        if ($extra.Length -gt 0) { $d += ' - ' + $extra }
    }
    return $d
}

function Set-FrequenciaPonto {
    # Define SystemRestorePointCreationFrequency (minutos; 0 = sem limite). Lanca se nao conseguir.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Chave, [int]$Minutos)
    if (-not (Test-Path -LiteralPath $Chave)) { New-Item -Path $Chave -Force -ErrorAction Stop | Out-Null }
    Set-ItemProperty -LiteralPath $Chave -Name $Script:NomeFrequencia -Value $Minutos -Type DWord -ErrorAction Stop
}

function Restore-FrequenciaPonto {
    # Devolve a frequencia ao estado anterior: valor original, nome removido (se nao existia) ou
    # chave removida (se nem a chave existia). Nunca lanca; devolve $true se conseguiu.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Chave, $Original, [bool]$ChaveExistia)
    try {
        if (-not $ChaveExistia) {
            if (Test-Path -LiteralPath $Chave) { Remove-Item -LiteralPath $Chave -Recurse -Force -ErrorAction Stop }
            return $true
        }
        if ($null -eq $Original) {
            # Remocao incondicional: um erro de leitura (ou o runspace sendo parado) nao pode
            # deixar a frequencia em 0 para sempre. O sucesso vem dos nomes de valor da chave.
            Remove-ItemProperty -LiteralPath $Chave -Name $Script:NomeFrequencia -ErrorAction SilentlyContinue
            return ((Get-Item -LiteralPath $Chave -ErrorAction Stop).GetValueNames() -notcontains $Script:NomeFrequencia)
        }
        Set-ItemProperty -LiteralPath $Chave -Name $Script:NomeFrequencia -Value ([int]$Original) -Type DWord -ErrorAction Stop
        return $true
    } catch { return $false }
}

function New-PontoRestauracao {
    # Cria o ponto de fato (real) ou grava o marcador ponto-<yyyyMMddHHmmssfff>.txt (teste).
    # Lanca em caso de falha; em teste, simular.falharCriar=$true forca a falha.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Descricao, [bool]$Teste, $Sim)
    if ($Teste) {
        if (Test-ParamVerdadeiro $Sim 'falharCriar') { throw 'falha simulada ao criar o ponto' }
        $arq = Join-Path (Get-PastaSistemaTeste) ('ponto-' + (Get-Date).ToString('yyyyMMddHHmmssfff') + '.txt')
        [IO.File]::WriteAllText($arq, $Descricao, (New-Object System.Text.UTF8Encoding $false))
        return
    }
    Checkpoint-Computer -Description $Descricao -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
}

function Get-Sessao {
    # Puro: compara o usuario do processo (elevado) com o do console sem diferenciar caixa.
    # Console sem usuario (RDP, servico, teste) -> desconhecido:true e mesmo:true (nao bloqueia).
    param([string]$UsuarioProcesso, $UsuarioConsole)
    $console = $null
    if ($null -ne $UsuarioConsole) { $console = [string]$UsuarioConsole }
    if ([string]::IsNullOrWhiteSpace($console)) {
        return [ordered]@{ usuarioProcesso = $UsuarioProcesso; usuarioConsole = $null; mesmo = $true; desconhecido = $true }
    }
    $mesmo = [string]::Equals($UsuarioProcesso, $console, [StringComparison]::OrdinalIgnoreCase)
    return [ordered]@{ usuarioProcesso = $UsuarioProcesso; usuarioConsole = $console; mesmo = $mesmo; desconhecido = $false }
}

function Test-MesmoSid {
    # $true se o nome do console resolve para o SID do processo; $null se nao der para resolver.
    # Cobre contas Microsoft: o console informa "MicrosoftAccount\email" e o processo "PC\nome".
    param([string]$UsuarioConsole, $Identidade)
    try {
        $sid = (New-Object Security.Principal.NTAccount($UsuarioConsole)).Translate([Security.Principal.SecurityIdentifier])
        return ($sid.Value -eq $Identidade.User.Value)
    } catch { return $null }
}

function Invoke-ProtecaoEstado {
    param([string]$Id, [bool]$Teste)
    $chave = Get-ChaveRestauracao $Teste
    $intervalo = Get-ValorRegistro $chave $Script:NomeIntervalo
    $freq = Get-ValorRegistro $chave $Script:NomeFrequencia
    $freqMin = $null
    if ($null -ne $freq) { try { $freqMin = [int]$freq } catch { $freqMin = $null } }
    Send-Result $Id ([ordered]@{
        ativa         = ($null -ne $intervalo -and ([string]$intervalo) -eq '1')
        ultimoPonto   = Get-UltimoPontoIso $Teste
        frequenciaMin = $freqMin
        unidade       = $env:SystemDrive
    })
}

function Invoke-CriarPonto {
    # Nunca lanca: qualquer falha vira criado:false com mensagem. A frequencia de criacao e zerada
    # so durante a criacao e volta ao original (ou e removida) no finally, mesmo com cancelamento.
    param([string]$Id, $Params, [bool]$Teste)
    $sim = Get-Simulacao $Params $Teste
    $chave = Get-ChaveRestauracao $Teste
    $descricao = Get-DescricaoPonto $Params
    $criado = $false
    $mensagem = ''
    $restaurou = $true
    try {
        Send-Progress $Id 10 'Preparando o ponto de restauração'
        $chaveExistia = Test-Path -LiteralPath $chave
        $original = Get-ValorRegistro $chave $Script:NomeFrequencia
        try {
            Set-FrequenciaPonto $chave 0
            Send-Progress $Id 30 'Criando o ponto de restauração'
            New-PontoRestauracao $descricao $Teste $sim
            $criado = $true
            $mensagem = "Ponto de restauração criado: $descricao"
        } finally {
            $restaurou = Restore-FrequenciaPonto $chave $original $chaveExistia
        }
    } catch {
        $criado = $false
        $mensagem = 'Não foi possível criar o ponto de restauração: ' + $_.Exception.Message
    }
    if (-not $restaurou) {
        $mensagem += " Atenção: não foi possível devolver $Script:NomeFrequencia ao valor original."
    }
    Write-AppLog ("sistema: criarPonto criado={0} frequenciaRestaurada={1} - {2}" -f $criado, $restaurou, $mensagem) $Teste
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ criado = $criado; mensagem = $mensagem })
}

function Invoke-LigarProtecao {
    # Liga a Protecao do Sistema na unidade do Windows e reserva ate 3 % do disco para pontos.
    # Falha do vssadmin so entra na mensagem: a protecao ja ficou ligada.
    param([string]$Id, [bool]$Teste)
    $ligada = $false
    $mensagem = ''
    $unidade = $env:SystemDrive
    try {
        Send-Progress $Id 20 'Ligando a Proteção do Sistema'
        if ($Teste) {
            $chave = Get-ChaveRestauracao $true
            if (-not (Test-Path -LiteralPath $chave)) { New-Item -Path $chave -Force -ErrorAction Stop | Out-Null }
            Set-ItemProperty -LiteralPath $chave -Name $Script:NomeIntervalo -Value 1 -Type DWord -ErrorAction Stop
            $arq = Join-Path (Get-PastaSistemaTeste) 'protecao-ligada.txt'
            [IO.File]::WriteAllText($arq, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding $false))
            $ligada = $true
            $mensagem = "Proteção do Sistema ligada em $unidade (teste)."
        } else {
            Enable-ComputerRestore -Drive "$unidade\" -ErrorAction Stop
            $ligada = $true
            $mensagem = "Proteção do Sistema ligada em $unidade."
            Send-Progress $Id 60 'Reservando 3 % do disco para pontos de restauração'
            try {
                & "$env:windir\System32\vssadmin.exe" resize shadowstorage "/for=$unidade" "/on=$unidade" '/maxsize=3%' | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "vssadmin terminou com código $LASTEXITCODE" }
            } catch {
                $mensagem += ' Não foi possível reservar 3 % do disco (' + $_.Exception.Message + '); o Windows usará o espaço padrão.'
            }
        }
    } catch {
        $ligada = $false
        $mensagem = 'Não foi possível ligar a Proteção do Sistema: ' + $_.Exception.Message
    }
    Write-AppLog ("sistema: ligarProtecao ligada={0} unidade={1} - {2}" -f $ligada, $unidade, $mensagem) $Teste
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ ligada = $ligada; mensagem = $mensagem })
}

function Invoke-Sessao {
    param([string]$Id, $Params, [bool]$Teste)
    $sim = Get-Simulacao $Params $Teste
    $identidade = [Security.Principal.WindowsIdentity]::GetCurrent()
    $processo = [string]$identidade.Name
    $console = $null
    if ($null -ne $sim) {
        # Em teste o console vem inteiro da simulacao (chave ausente ou $null = desconhecido).
        $console = $sim.usuarioConsole
        if (-not [string]::IsNullOrEmpty([string]$sim.usuarioProcesso)) { $processo = [string]$sim.usuarioProcesso }
    } else {
        try { $console = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop | Select-Object -First 1).UserName }
        catch { $console = $null }
    }
    $r = Get-Sessao $processo $console
    if ($null -eq $sim -and -not $r.desconhecido -and -not $r.mesmo) {
        # Nomes diferentes podem ser a mesma conta (conta Microsoft): confere pelo SID antes de bloquear.
        if ((Test-MesmoSid ([string]$r.usuarioConsole) $identidade) -eq $true) { $r.mesmo = $true }
    }
    Send-Result $Id $r
}

function Invoke-Acao {
    param([string]$Id, [string]$Acao, $Params, [bool]$Teste)
    if (@('protecaoEstado', 'criarPonto', 'ligarProtecao', 'sessao') -notcontains $Acao) {
        Send-Result $Id $null $false 'ação desconhecida'
        return
    }
    try {
        switch ($Acao) {
            'protecaoEstado' { Invoke-ProtecaoEstado $Id $Teste }
            'criarPonto' { Invoke-CriarPonto $Id $Params $Teste }
            'ligarProtecao' { Invoke-LigarProtecao $Id $Teste }
            'sessao' { Invoke-Sessao $Id $Params $Teste }
        }
    } catch {
        $msg = 'sistema falhou: ' + $_.Exception.Message
        Write-AppLog $msg $Teste
        Send-Result $Id $null $false $msg
    }
}
