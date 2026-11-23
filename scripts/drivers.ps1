# drivers.ps1 - dispositivos com problema (os de ponto de exclamacao no Gerenciador de Dispositivos), backup dos
# drivers e reparo escalonado.
# Baseado em drivers.ps1 do RetroLimpia (MIT, Retropunk94)
# Acoes: listar {simular?} -> {dispositivos: [{id, nome, classe, codigo, explicacao, critico}]};
#        backup {confirmado, simular?} -> {pasta, quantidade, codigo};
#        reparar {id, confirmado, simular?} -> {resolvido, passos: [{passo, ok, codigoDepois}], precisaReiniciar}.
# listar so mostra dispositivos presentes (fantasmas de aparelhos desconectados ficam fora).
# reparar: o id so vale se estiver na lista atual de listar e tiver so ASCII visivel, sem aspas. Passos, do mais leve
# ao mais forte, parando no primeiro depois do qual o ConfigManagerErrorCode vira 0 (ou vira 14/21, que so um
# reinicio resolve; quem ja esta em 14/21 nem e tocado): reiniciar (Disable/Enable-PnpDevice com -InputObject do
# dispositivo achado pelo id exato, nunca -InstanceId, que aceita curingas; religar fica num finally), reinstalar
# (pnputil /remove-device + /scan-devices) e procurar (pnputil /scan-devices).
# Dispositivo critico so procura hardware: desligar um disco, controladora, video, firmware, TPM ou o hub da entrada
# pode travar o Windows, pedir a chave do BitLocker ou deixar o usuario sem teclado e mouse. Passo pulado nao aparece
# em passos (vai para o log). Nada da saida do pnputil e lido (localizada): so o codigo de saida. Nunca encerra
# processos.
# Em modo teste nada roda: simular {dispositivos: [{id, nome, descricao?, classe, codigo, presente?, resolveNo?}],
# adaptadoresAtivos?: [id], codigoPnputil?, falharDesligar?, falharReligar?, exportados?, pastasSemInf?, codigo?,
# quando?}; os passos de reparar gravam marcadores em %TEMP%\NexTuneTeste\drivers-passos\<passo>.txt (reiniciar
# grava tambem desligar.txt e religar.txt) e o backup cria pastas .inf falsas em
# %TEMP%\NexTuneTeste\Drivers\<AAAAMMDD-HHMMSS>.
. "$PSScriptRoot\common.ps1"

# Classes que so passam por "procurar hardware" (disco, controladoras, video, sistema, entrada, firmware, TPM,
# leitor eMMC de boot e bateria). Firmware: reinstalar uma capsula UEFI que falhou reagenda a atualizacao e pode
# pedir a chave do BitLocker. Net entra quando e o unico adaptador fisico ativo (Test-DispositivoCritico).
$Script:ClassesCriticas = @('DiskDrive', 'HDC', 'SCSIAdapter', 'Display', 'System', 'Processor', 'Computer', 'Volume',
    'VolumeSnapshot', 'Keyboard', 'Mouse', 'HIDClass', 'USB', 'Firmware', 'SecurityDevices', 'SDHost', 'Battery')
# Espera maxima, depois de reinstalar/procurar, pelo dispositivo voltar a aparecer (codigo -1 = ainda nao voltou).
$Script:EsperaVoltaSegundos = 20
# 3010 = ERROR_SUCCESS_REBOOT_REQUIRED; 14 = precisa reiniciar; 21 = o Windows esta removendo o dispositivo.
$Script:ReinicioPedido = 3010
$Script:CodigosReiniciar = @(14, 21)

# Textos curtos por ConfigManagerErrorCode (CM_PROB_*): o que houve e o que fazer.
$Script:Explicacoes = @{
    1  = 'O dispositivo não está configurado corretamente. Tente o reparo; se não resolver, instale o driver do site do fabricante.'
    3  = 'O driver pode estar corrompido ou o Windows está com pouca memória. Feche alguns programas e tente o reparo.'
    10 = 'O dispositivo não consegue iniciar. Tente o reparo; se continuar, instale o driver mais novo do site do fabricante.'
    12 = 'O dispositivo não achou recursos livres no PC. Desative outro dispositivo que você não usa ou atualize o BIOS/UEFI.'
    14 = 'O dispositivo só volta a funcionar depois de reiniciar o PC. Reinicie.'
    16 = 'O Windows não conseguiu identificar todos os recursos do dispositivo. Tente o reparo ou procure o fabricante.'
    18 = 'O driver deste dispositivo precisa ser reinstalado. Use o reparo.'
    19 = 'A configuração do dispositivo no registro está incompleta ou danificada. Use o reparo para reinstalar o driver.'
    21 = 'O Windows está removendo este dispositivo. Reinicie o PC.'
    24 = 'O dispositivo não está presente, não funciona direito ou está sem driver. Confira se está bem conectado e tente o reparo.'
    28 = 'O driver deste dispositivo não está instalado. Instale o driver do site do fabricante ou pelo Windows Update.'
    29 = 'O dispositivo está desativado no BIOS/UEFI do PC. Ative-o na configuração do BIOS/UEFI.'
    31 = 'O Windows não conseguiu carregar o driver. Tente o reparo; se continuar, reinstale o driver do fabricante.'
    32 = 'O serviço do driver está desativado. Tente o reparo; se continuar, reinstale o driver do fabricante.'
    33 = 'O Windows não conseguiu definir os recursos de que o dispositivo precisa. Atualize o BIOS/UEFI ou procure o fabricante.'
    34 = 'O Windows não consegue configurar este dispositivo sozinho. Veja o manual do dispositivo ou procure o fabricante.'
    35 = 'O BIOS/UEFI do PC não tem as informações deste dispositivo. Atualize o BIOS/UEFI pelo site do fabricante do PC.'
    37 = 'O driver do dispositivo falhou ao iniciar. Reinstale o driver do site do fabricante.'
    38 = 'Uma cópia anterior do driver ainda está na memória. Reinicie o PC.'
    39 = 'O driver pode estar corrompido ou faltando. Use o reparo ou reinstale o driver do fabricante.'
    40 = 'O registro do serviço do driver está faltando ou errado. Use o reparo para reinstalar o driver.'
    41 = 'O driver foi carregado, mas não achou o aparelho. Confira se ele está conectado; se já foi removido, pode ignorar.'
    42 = 'Há um dispositivo duplicado no sistema. Reinicie o PC.'
    43 = 'O Windows parou o dispositivo porque ele informou problemas. Tente o reparo; se continuar, troque de porta ou atualize o driver.'
    44 = 'Um programa ou serviço desligou este dispositivo. Reinicie o PC.'
    45 = 'O dispositivo não está conectado ao PC agora. Conecte-o de novo; se você já não o usa, pode ignorar.'
    46 = 'O Windows está desligando e não deixa usar o dispositivo agora. Reinicie o PC.'
    47 = 'O dispositivo foi preparado para remoção segura. Desconecte-o e conecte de novo.'
    48 = 'O Windows bloqueou este driver por problemas conhecidos. Procure um driver mais novo no site do fabricante.'
    49 = 'O registro do sistema está grande demais para novos dispositivos. Remova dispositivos que você já não usa e reinicie.'
    50 = 'O Windows não conseguiu aplicar todas as configurações do dispositivo. Tente o reparo ou atualize o driver.'
    51 = 'O dispositivo está esperando outro dispositivo iniciar. Resolva primeiro os outros dispositivos com problema.'
    52 = 'O Windows não conseguiu verificar a assinatura digital do driver. Instale o driver oficial do fabricante.'
    53 = 'O dispositivo está reservado para o depurador do Windows. Isso é normal em PCs de desenvolvimento.'
    54 = 'O dispositivo falhou e o Windows está tentando reiniciá-lo. Aguarde um pouco; se continuar, reinicie o PC.'
}

# ---------- funcoes puras ----------

function Get-ExplicacaoCodigo {
    # Puro: texto pt-BR do ConfigManagerErrorCode; codigo fora da tabela tem texto generico com o numero.
    param([int]$Codigo)
    if ($Script:Explicacoes.ContainsKey($Codigo)) { return $Script:Explicacoes[$Codigo] }
    return ('O Windows informou o código de erro {0} para este dispositivo. Tente o reparo; se não resolver, procure o driver no site do fabricante.' -f $Codigo)
}

function Test-CodigoComProblema {
    # Puro: 0 = funcionando, 22 = desativado pelo usuario; os dois ficam fora da lista.
    param([int]$Codigo)
    return ($Codigo -ne 0 -and $Codigo -ne 22)
}

function Test-MesmoId {
    # Puro: ids de dispositivo sao comparados sem diferenciar maiusculas, texto exato.
    param([string]$A, [string]$B)
    return [string]::Equals($A, $B, [StringComparison]::OrdinalIgnoreCase)
}

function Test-DispositivoCritico {
    # Puro: classe que nunca e reinstalada. Net so quando o dispositivo e o unico adaptador fisico ativo;
    # $IdsRedeAtiva $null = nao deu para ler os adaptadores, e na duvida Net conta como critico.
    param([string]$Classe, [string]$Id, $IdsRedeAtiva)
    if ($Script:ClassesCriticas -contains $Classe) { return $true }
    if ($Classe -ne 'Net') { return $false }
    if ($null -eq $IdsRedeAtiva) { return $true }
    $ativos = @($IdsRedeAtiva | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    return ($ativos.Count -eq 1 -and (Test-MesmoId ([string]$ativos[0]) $Id))
}

function Get-NomeDispositivo {
    # Puro: Name, senao Description, senao o proprio id.
    param([string]$Nome, [string]$Descricao, [string]$Id)
    if (-not [string]::IsNullOrWhiteSpace($Nome)) { return $Nome }
    if (-not [string]::IsNullOrWhiteSpace($Descricao)) { return $Descricao }
    return $Id
}

function ConvertTo-FiltroWql {
    # Puro: filtro WQL que casa exatamente um PNPDeviceID. Dentro de '...' o WQL usa \ como escape: primeiro a barra
    # e dobrada, depois o apostrofo vira \' (na ordem inversa a barra do \' seria dobrada e o apostrofo fecharia o texto).
    param([string]$Id)
    $literal = $Id.Replace('\', '\\').Replace("'", "\'")
    return ("PNPDeviceID = '" + $literal + "'")
}

function Test-IdSeguro {
    # Puro: id so com ASCII visivel (sem espaco nem controle) e sem aspas, antes de ir para a linha do pnputil.
    param([string]$Id)
    # -cmatch: sem diferenciar maiusculas o .NET aceitaria o sinal de Kelvin (U+212A) como 'k'.
    return ($Id -cmatch '^[\x21-\x7E]+$' -and $Id.IndexOf('"') -lt 0)
}

# ---------- leitura ----------

function Get-PastaDriversTeste {
    $p = Join-Path (Get-AppPastas $true).Base 'drivers-passos'
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    return $p
}

function Write-MarcadorDriver {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Passo, [string]$Texto)
    [IO.File]::WriteAllText((Join-Path (Get-PastaDriversTeste) ($Passo + '.txt')), $Texto, (New-Object System.Text.UTF8Encoding $false))
}

function Get-DispositivoBruto {
    # Dispositivos com problema como @{ id; nome; classe; codigo; resolveNo }. Em teste vem so de simular.dispositivos.
    param($Sim, [bool]$Teste)
    $saida = New-Object System.Collections.Generic.List[object]
    if ($Teste) {
        $fonte = @()
        if ($null -ne $Sim -and $null -ne $Sim.dispositivos) { $fonte = @($Sim.dispositivos) }
        foreach ($d in $fonte) {
            if ($null -eq $d -or $d.presente -eq $false) { continue }
            $id = [string]$d.id
            $saida.Add(@{
                    id        = $id
                    nome      = (Get-NomeDispositivo ([string]$d.nome) ([string]$d.descricao) $id)
                    classe    = [string]$d.classe
                    codigo    = $(if ($null -ne $d.codigo) { [int]$d.codigo } else { 0 })
                    resolveNo = [string]$d.resolveNo
                })
        }
    } else {
        # Present = TRUE: fantasmas (aparelhos que ja foram desconectados) nao sao "dispositivos com problema".
        $filtro = 'Present = TRUE AND ConfigManagerErrorCode <> 0 AND ConfigManagerErrorCode <> 22'
        foreach ($d in @(Get-CimInstance Win32_PnPEntity -Filter $filtro -ErrorAction Stop)) {
            if ($d.Present -eq $false) { continue }
            $id = [string]$d.PNPDeviceID
            $saida.Add(@{
                    id        = $id
                    nome      = (Get-NomeDispositivo ([string]$d.Name) ([string]$d.Description) $id)
                    classe    = [string]$d.PNPClass
                    codigo    = $(if ($null -ne $d.ConfigManagerErrorCode) { [int]$d.ConfigManagerErrorCode } else { 0 })
                    resolveNo = ''
                })
        }
    }
    return @($saida | Where-Object { -not [string]::IsNullOrWhiteSpace($_.id) -and (Test-CodigoComProblema $_.codigo) })
}

function Get-IdRedeAtiva {
    # PNPDeviceID dos adaptadores fisicos ativos, dentro de um objeto (uma lista vazia sairia da funcao como $null).
    # ids = $null quando nao deu para ler.
    param($Sim, [bool]$Teste)
    if ($Teste) {
        $ids = @()
        if ($null -ne $Sim -and $null -ne $Sim.adaptadoresAtivos) { $ids = @($Sim.adaptadoresAtivos | ForEach-Object { [string]$_ }) }
        return @{ ids = $ids }
    }
    try {
        $ids = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' } | ForEach-Object { [string]$_.PnPDeviceID })
        return @{ ids = $ids }
    } catch { return @{ ids = $null } }
}

function Get-ListaDispositivo {
    # Lista de listar: brutos + explicacao + critico. Devolve @{ itens; brutos } (brutos guardam resolveNo do teste).
    param($Sim, [bool]$Teste)
    $brutos = @(Get-DispositivoBruto $Sim $Teste)
    $rede = @{ ids = @() }
    if (@($brutos | Where-Object { $_.classe -eq 'Net' }).Count -gt 0) { $rede = Get-IdRedeAtiva $Sim $Teste }
    $itens = New-Object System.Collections.Generic.List[object]
    foreach ($b in $brutos) {
        $b.critico = (Test-DispositivoCritico $b.classe $b.id $rede.ids)
        $itens.Add([ordered]@{
                id         = $b.id
                nome       = $b.nome
                classe     = $b.classe
                codigo     = $b.codigo
                explicacao = (Get-ExplicacaoCodigo $b.codigo)
                critico    = $b.critico
            })
    }
    return @{ itens = @($itens | Sort-Object { $_.nome }, { $_.id }); brutos = $brutos }
}

function Get-CodigoAtual {
    # ConfigManagerErrorCode atual do dispositivo; -1 quando ele sumiu (ou nao deu para ler).
    param([string]$IdDisp, $Ctx)
    if ($Ctx.teste) { return [int]$Ctx.estado.codigo }
    try {
        $d = @(Get-CimInstance Win32_PnPEntity -Filter (ConvertTo-FiltroWql $IdDisp) -ErrorAction Stop) | Select-Object -First 1
        if ($null -eq $d -or $null -eq $d.ConfigManagerErrorCode) { return -1 }
        return [int]$d.ConfigManagerErrorCode
    } catch { return -1 }
}

# ---------- execucao ----------

function Invoke-PnpUtil {
    # pnputil por caminho absoluto, com lista de argumentos (sem cmd no meio). Devolve so o codigo de saida.
    param([string[]]$Argumentos)
    $exe = Join-Path $env:windir 'System32\pnputil.exe'
    $null = & $exe @Argumentos 2>&1
    return [int]$LASTEXITCODE
}

function Test-CodigoPnpUtilOk {
    param([int]$Codigo)
    return ($Codigo -eq 0 -or $Codigo -eq $Script:ReinicioPedido)
}

function Get-DispositivoExato {
    # A instancia CIM do dispositivo pelo id exato (WQL escapado, sem curingas), conferida de novo sem diferenciar
    # maiusculas. Qualquer coisa diferente de exatamente um resultado lanca.
    param([string]$IdDisp)
    $achados = @(Get-CimInstance Win32_PnPEntity -Filter (ConvertTo-FiltroWql $IdDisp) -ErrorAction Stop |
            Where-Object { Test-MesmoId ([string]$_.PNPDeviceID) $IdDisp })
    if ($achados.Count -ne 1) { throw ('o dispositivo não foi achado pelo id exato (' + $achados.Count + ' resultado(s))') }
    return $achados[0]
}

function Invoke-PassoReiniciar {
    # Desligar e ligar. Religar fica no finally: roda mesmo que o desligar lance (com ou sem efeito) ou que a acao seja
    # interrompida durante a espera, para nunca deixar o dispositivo desativado. Religar um dispositivo ligado nao faz
    # nada. Em teste: marcadores desligar.txt/religar.txt e falhas por simular.falharDesligar/falharReligar.
    param($Dispositivo, [string]$IdDisp, $Ctx)
    $r = @{ ok = $false; reiniciar = $false; erro = '' }
    try {
        if ($Ctx.teste) {
            Write-MarcadorDriver 'desligar' "Disable-PnpDevice -InputObject $IdDisp"
            if ($Ctx.falharDesligar) { throw 'Disable-PnpDevice simulado falhou' }
        } else {
            Disable-PnpDevice -InputObject $Dispositivo -Confirm:$false -ErrorAction Stop
            Start-Sleep -Seconds 2
        }
    } catch {
        $r.erro = $_.Exception.Message
    } finally {
        try {
            if ($Ctx.teste) {
                Write-MarcadorDriver 'religar' "Enable-PnpDevice -InputObject $IdDisp"
                if ($Ctx.falharReligar) { throw 'Enable-PnpDevice simulado falhou' }
            } else {
                Enable-PnpDevice -InputObject $Dispositivo -Confirm:$false -ErrorAction Stop
            }
            $r.ok = [string]::IsNullOrEmpty($r.erro)
        } catch {
            $r.ok = $false
            $r.erro += ' / ao religar: ' + $_.Exception.Message
        }
    }
    return $r
}

function Invoke-PassoReal {
    # Um passo do reparo de verdade. Devolve @{ ok; reiniciar; erro }.
    param([string]$Passo, [string]$IdDisp, $Ctx)
    if (-not (Test-IdSeguro $IdDisp)) { throw 'id de dispositivo com caracteres inválidos: recusado' }
    $r = @{ ok = $false; reiniciar = $false; erro = '' }
    switch ($Passo) {
        'reiniciar' {
            $r = Invoke-PassoReiniciar (Get-DispositivoExato $IdDisp) $IdDisp $Ctx
        }
        'reinstalar' {
            $c1 = Invoke-PnpUtil @('/remove-device', $IdDisp)
            Start-Sleep -Seconds 2
            $c2 = Invoke-PnpUtil @('/scan-devices')
            $r.ok = (Test-CodigoPnpUtilOk $c1) -and (Test-CodigoPnpUtilOk $c2)
            $r.reiniciar = ($c1 -eq $Script:ReinicioPedido -or $c2 -eq $Script:ReinicioPedido)
            if (-not $r.ok) { $r.erro = "pnputil terminou com os códigos $c1 e $c2" }
        }
        'procurar' {
            $c = Invoke-PnpUtil @('/scan-devices')
            $r.ok = (Test-CodigoPnpUtilOk $c)
            $r.reiniciar = ($c -eq $Script:ReinicioPedido)
            if (-not $r.ok) { $r.erro = "pnputil terminou com o código $c" }
        }
    }
    # O Windows leva alguns segundos para reavaliar o dispositivo depois de cada passo.
    Start-Sleep -Seconds 4
    return $r
}

function Invoke-PassoSimulado {
    # Modo teste: grava o marcador do passo e "conserta" o dispositivo so se resolveNo for este passo.
    param([string]$Passo, [string]$IdDisp, $Ctx)
    $exe = Join-Path $env:windir 'System32\pnputil.exe'
    $texto = switch ($Passo) {
        'reiniciar' { "Disable-PnpDevice/Enable-PnpDevice -InputObject $IdDisp" }
        'reinstalar' { "$exe /remove-device $IdDisp; $exe /scan-devices" }
        default { "$exe /scan-devices" }
    }
    Write-MarcadorDriver $Passo $texto
    $r = @{ ok = $true; reiniciar = $false; erro = '' }
    if ($Passo -eq 'reiniciar') {
        $r = Invoke-PassoReiniciar $null $IdDisp $Ctx
    } else {
        $c = [int]$Ctx.codigoPnputil
        $r.ok = (Test-CodigoPnpUtilOk $c)
        $r.reiniciar = ($c -eq $Script:ReinicioPedido)
        if (-not $r.ok) { $r.erro = "pnputil terminou com o código $c" }
    }
    if ($Ctx.estado.resolveNo -eq $Passo) { $Ctx.estado.codigo = 0 }
    return $r
}

# ---------- acoes ----------

function Invoke-Listar {
    param([string]$Id, $Params, [bool]$Teste)
    $sim = Get-Simulacao $Params $Teste
    Send-Progress $Id 10 'Procurando dispositivos com problema'
    $lista = Get-ListaDispositivo $sim $Teste
    Write-AppLog ('drivers: listar achou ' + @($lista.itens).Count + ' dispositivo(s) com problema') $Teste
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ dispositivos = @($lista.itens) })
}

function New-PastaBackupDriver {
    # Cria <Raiz>\AAAAMMDD-HHMMSS (ou -2, -3... se ja existir) e devolve o caminho. Recusa raiz com link na cadeia.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Raiz, [datetime]$Quando)
    if (-not (Test-Path -LiteralPath $Raiz)) { New-Item -ItemType Directory -Path $Raiz -Force -ErrorAction Stop | Out-Null }
    if (-not (Test-CadeiaSemLink $Raiz)) { throw "a pasta de backup $Raiz é um link ou junção: recusada" }
    $nome = $Quando.ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
    $pasta = Join-Path $Raiz $nome
    $n = 1
    while (Test-Path -LiteralPath $pasta) {
        $n++
        $pasta = Join-Path $Raiz ($nome + '-' + $n)
    }
    $null = New-Item -ItemType Directory -Path $pasta -ErrorAction Stop
    return $pasta
}

function Get-QuantidadeExportada {
    # Subpastas (primeiro nivel) com pelo menos um .inf: um pacote de driver exportado cada.
    param([string]$Pasta)
    $com = @(Get-ChildItem -LiteralPath $Pasta -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
            -not (Test-Reparse $_) -and @(Get-ChildItem -LiteralPath $_.FullName -Filter '*.inf' -File -Force -ErrorAction SilentlyContinue).Count -gt 0
        })
    return $com.Count
}

function Invoke-Backup {
    param([string]$Id, $Params, [bool]$Teste)
    if (-not (Test-ParamVerdadeiro $Params 'confirmado')) { Send-Result $Id $null $false 'ação exige confirmação'; return }
    $sim = Get-Simulacao $Params $Teste
    $quando = Get-Date
    if ($Teste -and $null -ne $sim -and $null -ne $sim.quando) { $quando = [datetime]$sim.quando }
    $raiz = Join-Path (Get-AppPastas $Teste).Base 'Drivers'
    $pasta = New-PastaBackupDriver $raiz $quando
    Send-Progress $Id 10 'Copiando os drivers instalados (pode levar alguns minutos)'
    if ($Teste) {
        $exportados = if ($null -ne $sim -and $null -ne $sim.exportados) { [int]$sim.exportados } else { 0 }
        $semInf = if ($null -ne $sim -and $null -ne $sim.pastasSemInf) { [int]$sim.pastasSemInf } else { 0 }
        $utf8 = New-Object System.Text.UTF8Encoding $false
        for ($i = 1; $i -le $exportados; $i++) {
            $p = Join-Path $pasta ("oem$i.inf_amd64_teste")
            $null = New-Item -ItemType Directory -Path $p -ErrorAction Stop
            [IO.File]::WriteAllText((Join-Path $p "oem$i.inf"), '[Version]', $utf8)
        }
        for ($i = 1; $i -le $semInf; $i++) {
            $p = Join-Path $pasta ("vazia$i")
            $null = New-Item -ItemType Directory -Path $p -ErrorAction Stop
            [IO.File]::WriteAllText((Join-Path $p 'leia.txt'), 'sem inf', $utf8)
        }
        $codigo = if ($null -ne $sim -and $null -ne $sim.codigo) { [int]$sim.codigo } else { 0 }
    } else {
        $codigo = Invoke-PnpUtil @('/export-driver', '*', $pasta)
    }
    $quantidade = Get-QuantidadeExportada $pasta
    Write-AppLog ('drivers: backup em ' + $pasta + ': ' + $quantidade + ' driver(s), pnputil terminou com ' + $codigo) $Teste
    if ($codigo -ne 0 -and $quantidade -eq 0) {
        # Pasta vazia nao e backup: sai do caminho (Delete nao recursivo, falha se houver qualquer coisa dentro).
        try { [IO.Directory]::Delete($pasta) } catch { $null = $_ }
        Send-Result $Id $null $false "o backup dos drivers falhou: o pnputil terminou com o código $codigo e não exportou nenhum driver"
        return
    }
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ pasta = $pasta; quantidade = $quantidade; codigo = $codigo })
}

function Invoke-Reparar {
    param([string]$Id, $Params, [bool]$Teste)
    if (-not (Test-ParamVerdadeiro $Params 'confirmado')) { Send-Result $Id $null $false 'ação exige confirmação'; return }
    $pedido = if ($null -ne $Params) { [string]$Params.id } else { '' }
    $sim = Get-Simulacao $Params $Teste
    # O id so vale se estiver na lista atual: nunca se age sobre um id que listar nao mostraria agora.
    $lista = Get-ListaDispositivo $sim $Teste
    $alvo = $null
    if (-not [string]::IsNullOrWhiteSpace($pedido)) {
        $alvo = @($lista.brutos | Where-Object { Test-MesmoId $_.id $pedido }) | Select-Object -First 1
    }
    if ($null -eq $alvo) { Send-Result $Id $null $false 'dispositivo não encontrado ou já sem problema'; return }
    $idDisp = $alvo.id
    # O id vai para a linha de comando do pnputil: so ASCII visivel, sem aspas.
    if (-not (Test-IdSeguro $idDisp)) {
        Write-AppLog ('drivers: reparar recusado, id com caracteres inválidos: ' + $idDisp) $Teste
        Send-Result $Id $null $false 'id de dispositivo com caracteres inválidos: recusado'
        return
    }
    $ctx = @{
        teste          = $Teste
        estado         = @{ codigo = $alvo.codigo; resolveNo = $alvo.resolveNo }
        codigoPnputil  = $(if ($Teste -and $null -ne $sim -and $null -ne $sim.codigoPnputil) { [int]$sim.codigoPnputil } else { 0 })
        falharDesligar = ($Teste -and $null -ne $sim -and $sim.falharDesligar -eq $true)
        falharReligar  = ($Teste -and $null -ne $sim -and $sim.falharReligar -eq $true)
    }
    Write-AppLog ("drivers: reparar {0} ({1}, classe {2}, código {3}, crítico {4})" -f $alvo.nome, $idDisp, $alvo.classe, $alvo.codigo, $alvo.critico) $Teste
    # 14/21 antes de qualquer passo: so um reinicio resolve, e o dispositivo nao e tocado.
    if ($Script:CodigosReiniciar -contains [int]$alvo.codigo) {
        Send-Log $Id 'info' ($alvo.nome + ' só volta a funcionar depois de reiniciar o PC; nada foi alterado.')
        Write-AppLog ('drivers: reparar ' + $idDisp + ' não tocou o dispositivo (código ' + $alvo.codigo + ', precisa reiniciar)') $Teste
        Send-Progress $Id 100 'Concluído'
        Send-Result $Id ([ordered]@{ resolvido = $false; passos = @(); precisaReiniciar = $true })
        return
    }

    $etapas = @(
        @{ passo = 'reiniciar'; pct = 10; msg = 'Desligando e ligando ' + $alvo.nome },
        @{ passo = 'reinstalar'; pct = 40; msg = 'Reinstalando o driver de ' + $alvo.nome },
        @{ passo = 'procurar'; pct = 70; msg = 'Procurando alterações de hardware' }
    )
    $passos = New-Object System.Collections.Generic.List[object]
    $reiniciar = $false
    $codigo = [int]$alvo.codigo
    foreach ($e in $etapas) {
        if ($alvo.critico -and $e.passo -ne 'procurar') {
            $acao = if ($e.passo -eq 'reiniciar') { 'não foi desligado e ligado' } else { 'não teve o driver reinstalado' }
            Send-Log $Id 'info' ($alvo.nome + ' ' + $acao + ': é um dispositivo essencial do PC.')
            Write-AppLog ('drivers: ' + $e.passo + ' pulado em ' + $idDisp + ' (dispositivo crítico)') $Teste
            continue
        }
        Send-Progress $Id $e.pct $e.msg
        try {
            $r = if ($Teste) { Invoke-PassoSimulado $e.passo $idDisp $ctx } else { Invoke-PassoReal $e.passo $idDisp $ctx }
        } catch {
            $r = @{ ok = $false; reiniciar = $false; erro = $_.Exception.Message }
        }
        $codigo = Get-CodigoAtual $idDisp $ctx
        if (-not $Teste -and $e.passo -ne 'reiniciar') {
            # Depois de remover/procurar o dispositivo pode levar alguns segundos para reaparecer (-1 ate la).
            $limite = [DateTime]::UtcNow.AddSeconds($Script:EsperaVoltaSegundos)
            while ($codigo -eq -1 -and [DateTime]::UtcNow -lt $limite) {
                Start-Sleep -Seconds 2
                $codigo = Get-CodigoAtual $idDisp $ctx
            }
        }
        if ($r.reiniciar -or $Script:CodigosReiniciar -contains $codigo) { $reiniciar = $true }
        $passos.Add([ordered]@{ passo = $e.passo; ok = [bool]$r.ok; codigoDepois = $codigo })
        $detalhe = if ([string]::IsNullOrEmpty($r.erro)) { '' } else { ' (' + $r.erro + ')' }
        Write-AppLog ("drivers: passo {0} em {1}: ok={2}, código depois {3}{4}" -f $e.passo, $idDisp, [bool]$r.ok, $codigo, $detalhe) $Teste
        if (-not $r.ok) { Send-Log $Id 'aviso' ('O passo "' + $e.passo + '" não terminou bem' + $detalhe) }
        # Para no primeiro passo que resolve; 14/21 so um reinicio resolve, seguir escalando nao ajuda.
        if ($codigo -eq 0 -or $Script:CodigosReiniciar -contains $codigo) { break }
    }
    $resolvido = ($codigo -eq 0)
    Write-AppLog ("drivers: reparar {0} terminou: resolvido={1}, precisaReiniciar={2}" -f $idDisp, $resolvido, $reiniciar) $Teste
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ resolvido = $resolvido; passos = $passos.ToArray(); precisaReiniciar = $reiniciar })
}

function Invoke-Acao {
    param([string]$Id, [string]$Acao, $Params, [bool]$Teste)
    if (@('listar', 'backup', 'reparar') -notcontains $Acao) {
        Send-Result $Id $null $false 'ação desconhecida'
        return
    }
    try {
        switch ($Acao) {
            'listar' { Invoke-Listar $Id $Params $Teste }
            'backup' { Invoke-Backup $Id $Params $Teste }
            'reparar' { Invoke-Reparar $Id $Params $Teste }
        }
    } catch {
        $msg = 'drivers falhou: ' + $_.Exception.Message
        Write-AppLog $msg $Teste
        Send-Result $Id $null $false $msg
    }
}
