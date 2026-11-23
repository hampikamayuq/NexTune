# rede.ps1 - ferramentas de rede: estado do DNS, limpar o cache, redefinir Winsock/TCP-IP e DNS seguro (DoH).
# Servidores e DoH baseados em DNSoverHTTPS do Sophia Script for Windows (MIT, farag2)
# Acoes: estado {} -> {adaptadores: [{indice, nome, descricao, dns, automatico}], provedor, dohDisponivel, temBackup};
#        limparDns {} -> {ok};
#        redefinir {confirmado} -> {precisaReiniciar: true, detalhe};
#        dnsSeguro {provedor: cloudflare|google|quad9|automatico, confirmado} -> {adaptadores: [{indice, nome, ok, erro}], provedor}.
# Adaptadores: fisicos e ativos (Get-NetAdapter -Physical, Status Up). Servidores "automaticos" (DHCP) = valor NameServer
# vazio em Tcpip\Parameters\Interfaces\<guid> (IPv4) e Tcpip6\Parameters\Interfaces\<guid> (IPv6), como o Windows grava.
# Backup: antes da primeira troca, Backups\dns.json guarda por adaptador {indice, guid, nome, ipv4, ipv6, ipv4Automatico,
# ipv6Automatico}; entrada existente nunca e sobrescrita (adaptador novo entra como entrada nova). O mesmo arquivo lista
# em dohAdicionados as chaves DoH que o NexTune criou. automatico restaura cada adaptador exatamente (DHCP com
# -ResetServerAddresses, servidores fixos com a lista), remove so essas chaves (as que ja existiam ficam intocadas) e
# apaga o arquivo quando tudo voltou; o que nao voltou fica no backup. Sem backup, automatico volta todos ao DHCP.
# DoH (so Windows 11, build >= 22000), como no Sophia: chave Dnscache\InterfaceSpecificParameters\<guid>\
# DohInterfaceSettings\Doh\<ip> (Doh6 para IPv6) com DohFlags (QWord 2) e DohTemplate.
# Em modo teste nada real roda: simular {adaptadores?: [{indice, guid, nome, descricao, ipv4, ipv6, ipv4Automatico,
# ipv6Automatico, ipv4Dhcp?, ipv6Dhcp?}], build?, falharIndice?, codigo? (ipconfig), netsh?: {winsock?, ip?}}. O estado
# dos adaptadores vive em %TEMP%\NexTuneTeste\rede\adaptadores.json (semeado por simular.adaptadores quando ainda nao
# existe); ipv4Dhcp/ipv6Dhcp sao os servidores que o "DHCP" entrega ao voltar ao automatico. O backup vai para
# %TEMP%\NexTuneTeste\Backups, as chaves DoH para HKCU\Software\NexTuneTeste\Dnscache\... e ipconfig/netsh viram
# marcadores em %TEMP%\NexTuneTeste\rede\<acao>.txt.
. "$PSScriptRoot\common.ps1"

# Dados do DNSoverHTTPS do Sophia (Sophia_Script_for_Windows_11\Module\Sophia.psm1): primario e secundario IPv4 e um
# modelo DoH por provedor, usado para os dois servidores. O Sophia nao configura IPv6: ipv6 fica vazio (nada inventado).
$Script:Provedores = [ordered]@{
    cloudflare = @{ ipv4 = @('1.1.1.1', '1.0.0.1'); ipv6 = @(); modelo = 'https://cloudflare-dns.com/dns-query' }
    google     = @{ ipv4 = @('8.8.8.8', '8.8.4.4'); ipv6 = @(); modelo = 'https://dns.google/dns-query' }
    quad9      = @{ ipv4 = @('9.9.9.9', '149.112.112.112'); ipv6 = @(); modelo = 'https://dns.quad9.net/dns-query' }
}
$Script:FlagsDoh = 2
$Script:BuildWin11 = 22000
$Script:ArquivoBackupDns = 'dns.json'

# ---------- funcoes puras ----------

function Test-GuidInterface {
    # Puro: GUID de interface na forma {xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}?
    param([string]$Guid)
    return ($Guid -match '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$')
}

function Get-FamiliaIp {
    # Puro: 'IPv4' | 'IPv6' | $null (texto que nao e endereco IP).
    param([string]$Ip)
    if ([string]::IsNullOrWhiteSpace($Ip)) { return $null }
    $x = $null
    if ($Ip -match '^\d{1,3}(\.\d{1,3}){3}$') {
        if ([Net.IPAddress]::TryParse($Ip, [ref]$x)) { return 'IPv4' }
        return $null
    }
    if ($Ip.Contains(':') -and $Ip -match '^[0-9A-Fa-f:.]+$') {
        if ([Net.IPAddress]::TryParse($Ip, [ref]$x) -and $x.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) { return 'IPv6' }
    }
    return $null
}

function Get-ListaIp {
    # Puro: lista de textos nao vazios (aceita $null, texto unico ou lista).
    param($Valor)
    return @(@($Valor) | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim() })
}

function Test-MesmoConjunto {
    # Puro: os mesmos enderecos, sem importar ordem, repeticao ou caixa.
    param($A, $B)
    $na = @(Get-ListaIp $A | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    $nb = @(Get-ListaIp $B | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    return (($na -join ',') -eq ($nb -join ','))
}

function Get-DnsExibido {
    # Puro: IPv4 e IPv6 do adaptador para a tela, sem os fec0:0:0:ffff::1..3 que o Windows mostra quando nao ha DNS IPv6.
    param($Adaptador)
    $v6 = @(Get-ListaIp $Adaptador.ipv6 | Where-Object { $_ -notmatch '^fec0:0:0:ffff::[1-3]$' })
    return @(@(Get-ListaIp $Adaptador.ipv4) + $v6)
}

function Get-ProvedorDetectado {
    # Puro: provedor cujo conjunto IPv4 e o de todos os adaptadores (servidores fixos); automatico quando todos vem do
    # DHCP (nas duas familias); senao outro. Sem adaptadores: automatico.
    param($Adaptadores)
    $lista = @($Adaptadores | Where-Object { $null -ne $_ })
    if ($lista.Count -eq 0) { return 'automatico' }
    foreach ($nome in @($Script:Provedores.Keys)) {
        $ipv4 = $Script:Provedores[$nome].ipv4
        $iguais = @($lista | Where-Object { -not $_.ipv4Automatico -and (Test-MesmoConjunto $_.ipv4 $ipv4) })
        if ($iguais.Count -eq $lista.Count) { return $nome }
    }
    if (@($lista | Where-Object { $_.ipv4Automatico -and $_.ipv6Automatico }).Count -eq $lista.Count) { return 'automatico' }
    return 'outro'
}

function Find-AdaptadorPorGuid {
    param($Lista, [string]$Guid)
    foreach ($a in @($Lista)) { if ([string]$a.guid -eq $Guid) { return $a } }
    return $null
}

function ConvertTo-AdaptadorRede {
    # Normaliza um adaptador (simulado, lido do arquivo falso ou do sistema). Em teste guarda tambem o que o "DHCP"
    # entrega (ipv4Dhcp/ipv6Dhcp), para que voltar ao automatico seja fiel.
    param($Fonte, [bool]$Teste)
    $v4 = @(Get-ListaIp $Fonte.ipv4)
    $v6 = @(Get-ListaIp $Fonte.ipv6)
    $a4 = ($Fonte.ipv4Automatico -eq $true)
    $a6 = ($Fonte.ipv6Automatico -eq $true)
    $o = [ordered]@{
        indice         = [int]$Fonte.indice
        guid           = [string]$Fonte.guid
        nome           = [string]$Fonte.nome
        descricao      = [string]$Fonte.descricao
        ipv4           = $v4
        ipv6           = $v6
        ipv4Automatico = $a4
        ipv6Automatico = $a6
    }
    if ($Teste) {
        $d4 = @()
        if ($null -ne $Fonte.ipv4Dhcp) { $d4 = @(Get-ListaIp $Fonte.ipv4Dhcp) } elseif ($a4) { $d4 = $v4 }
        $d6 = @()
        if ($null -ne $Fonte.ipv6Dhcp) { $d6 = @(Get-ListaIp $Fonte.ipv6Dhcp) } elseif ($a6) { $d6 = $v6 }
        $o['ipv4Dhcp'] = $d4
        $o['ipv6Dhcp'] = $d6
    }
    return [pscustomobject]$o
}

function ConvertTo-EntradaBackup {
    # Puro: o que o backup guarda de um adaptador, nesta ordem.
    param($Adaptador)
    return [ordered]@{
        indice         = [int]$Adaptador.indice
        guid           = [string]$Adaptador.guid
        nome           = [string]$Adaptador.nome
        ipv4           = @(Get-ListaIp $Adaptador.ipv4)
        ipv6           = @(Get-ListaIp $Adaptador.ipv6)
        ipv4Automatico = ($Adaptador.ipv4Automatico -eq $true)
        ipv6Automatico = ($Adaptador.ipv6Automatico -eq $true)
    }
}

# ---------- modo teste ----------

function Get-PastaRedeTeste {
    $p = Join-Path (Get-AppPastas $true).Base 'rede'
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    return $p
}

function Write-MarcadorRede {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Acao, [string[]]$Linhas)
    [IO.File]::WriteAllText((Join-Path (Get-PastaRedeTeste) ($Acao + '.txt')), ($Linhas -join "`r`n"), (New-Object System.Text.UTF8Encoding $false))
}

function Get-ArquivoEstadoFalso {
    return (Join-Path (Get-PastaRedeTeste) 'adaptadores.json')
}

function Read-EstadoFalso {
    # Adaptadores do teste: o arquivo falso ou, se ainda nao existe, simular.adaptadores.
    param($Sim)
    $arq = Get-ArquivoEstadoFalso
    $fontes = @()
    if (Test-Path -LiteralPath $arq -PathType Leaf) { $fontes = @((Read-ArquivoJson $arq).adaptadores) }
    elseif ($null -ne $Sim -and $null -ne $Sim.adaptadores) { $fontes = @($Sim.adaptadores) }
    return @($fontes | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-AdaptadorRede $_ $true })
}

function Write-EstadoFalso {
    param($Adaptadores)
    Write-JsonAtomico (Get-ArquivoEstadoFalso) ([ordered]@{ adaptadores = @($Adaptadores) })
}

# ---------- leitura do sistema ----------

function Get-BuildRede {
    param([bool]$Teste, $Sim)
    if ($Teste -and $null -ne $Sim -and $null -ne $Sim.build) { return [int]$Sim.build }
    return [int][Environment]::OSVersion.Version.Build
}

function Test-DhcpRegistro {
    # NameServer vazio (ou ausente) em <Servico>\Parameters\Interfaces\<guid> = servidores vindos do DHCP.
    param([string]$Servico, [string]$Guid)
    $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$Servico\Parameters\Interfaces\$Guid"
    try { $v = (Get-ItemProperty -LiteralPath $k -Name NameServer -ErrorAction Stop).NameServer }
    catch { return $true }
    return [string]::IsNullOrWhiteSpace([string]$v)
}

function Get-AdaptadorReal {
    # Adaptadores fisicos (so os ativos com $SoAtivos) com os servidores das duas familias.
    param([bool]$SoAtivos)
    $saida = New-Object System.Collections.Generic.List[object]
    foreach ($n in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)) {
        if ($SoAtivos -and [string]$n.Status -ne 'Up') { continue }
        $guid = [string]$n.InterfaceGuid
        if (-not (Test-GuidInterface $guid)) { continue }
        $i = [int]$n.ifIndex
        $v4 = @(Get-DnsClientServerAddress -InterfaceIndex $i -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.ServerAddresses })
        $v6 = @(Get-DnsClientServerAddress -InterfaceIndex $i -AddressFamily IPv6 -ErrorAction SilentlyContinue | ForEach-Object { $_.ServerAddresses })
        $fonte = [ordered]@{
            indice         = $i
            guid           = $guid
            nome           = [string]$n.Name
            descricao      = [string]$n.InterfaceDescription
            ipv4           = $v4
            ipv6           = $v6
            ipv4Automatico = (Test-DhcpRegistro 'Tcpip' $guid)
            ipv6Automatico = (Test-DhcpRegistro 'Tcpip6' $guid)
        }
        $saida.Add((ConvertTo-AdaptadorRede $fonte $false))
    }
    return $saida.ToArray()
}

function Get-AdaptadorRede {
    param([bool]$Teste, $Sim, [bool]$SoAtivos = $true)
    if ($Teste) { return @(Read-EstadoFalso $Sim) }
    return @(Get-AdaptadorReal $SoAtivos)
}

# ---------- escrita: servidores ----------

function Set-ServidorAdaptador {
    # $Reset volta as duas familias ao DHCP; depois $Fixos (se houver) vira a lista fixa das familias presentes nela.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param($Adaptador, [bool]$Reset, [string[]]$Fixos, [bool]$Teste, $Sim)
    $lista = @(Get-ListaIp $Fixos)
    foreach ($ip in $lista) { if ($null -eq (Get-FamiliaIp $ip)) { throw "endereço de DNS inválido: $ip" } }
    if ($Teste) {
        if ($null -ne $Sim -and $null -ne $Sim.falharIndice -and [int]$Sim.falharIndice -eq [int]$Adaptador.indice) {
            throw "falha simulada no adaptador $($Adaptador.indice)"
        }
        $todos = @(Read-EstadoFalso $Sim)
        $a = Find-AdaptadorPorGuid $todos ([string]$Adaptador.guid)
        if ($null -eq $a) { throw 'o adaptador não foi encontrado' }
        if ($Reset) {
            $a.ipv4 = @($a.ipv4Dhcp)
            $a.ipv6 = @($a.ipv6Dhcp)
            $a.ipv4Automatico = $true
            $a.ipv6Automatico = $true
        }
        $v4 = @($lista | Where-Object { (Get-FamiliaIp $_) -eq 'IPv4' })
        $v6 = @($lista | Where-Object { (Get-FamiliaIp $_) -eq 'IPv6' })
        if ($v4.Count -gt 0) { $a.ipv4 = $v4; $a.ipv4Automatico = $false }
        if ($v6.Count -gt 0) { $a.ipv6 = $v6; $a.ipv6Automatico = $false }
        Write-EstadoFalso $todos
        return
    }
    $indice = [int]$Adaptador.indice
    if ($Reset) { Set-DnsClientServerAddress -InterfaceIndex $indice -ResetServerAddresses -ErrorAction Stop }
    if ($lista.Count -gt 0) { Set-DnsClientServerAddress -InterfaceIndex $indice -ServerAddresses $lista -ErrorAction Stop }
}

function Restore-AdaptadorDoBackup {
    # Familia que vinha do DHCP (ou sem servidor guardado) volta com -ResetServerAddresses; as fixas voltam com a lista.
    param($Entrada, $Adaptador, [bool]$Teste, $Sim)
    $v4 = @(Get-ListaIp $Entrada.ipv4)
    $v6 = @(Get-ListaIp $Entrada.ipv6)
    foreach ($ip in $v4) { if ((Get-FamiliaIp $ip) -ne 'IPv4') { throw "endereço inválido no backup: $ip" } }
    foreach ($ip in $v6) { if ((Get-FamiliaIp $ip) -ne 'IPv6') { throw "endereço inválido no backup: $ip" } }
    $auto4 = ($Entrada.ipv4Automatico -eq $true) -or $v4.Count -eq 0
    $auto6 = ($Entrada.ipv6Automatico -eq $true) -or $v6.Count -eq 0
    $fixos = @()
    if (-not $auto4) { $fixos += $v4 }
    if (-not $auto6) { $fixos += $v6 }
    Set-ServidorAdaptador $Adaptador ($auto4 -or $auto6) $fixos $Teste $Sim
}

# ---------- escrita: chaves DoH ----------

function Get-RegistroDoh {
    # Hive e subchave base das configuracoes DoH por interface (em teste, uma copia sob HKCU).
    param([bool]$Teste)
    if ($Teste) { return @{ hive = [Microsoft.Win32.Registry]::CurrentUser; base = 'Software\NexTuneTeste\Dnscache\InterfaceSpecificParameters' } }
    return @{ hive = [Microsoft.Win32.Registry]::LocalMachine; base = 'SYSTEM\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters' }
}

function Get-FamiliaDoh {
    param([string]$Ip)
    if ((Get-FamiliaIp $Ip) -eq 'IPv6') { return 'Doh6' }
    return 'Doh'
}

function Get-SubchaveDoh {
    # <base>\<guid>\DohInterfaceSettings\Doh|Doh6\<ip>; $null se guid, familia ou ip nao forem validos (o backup e um
    # arquivo e nunca decide sozinho que chave apagar).
    param([string]$Guid, [string]$Familia, [string]$Ip, [bool]$Teste)
    if (-not (Test-GuidInterface $Guid)) { return $null }
    $fam = Get-FamiliaIp $Ip
    if (-not (($Familia -ceq 'Doh' -and $fam -eq 'IPv4') -or ($Familia -ceq 'Doh6' -and $fam -eq 'IPv6'))) { return $null }
    return ((Get-RegistroDoh $Teste).base + '\' + $Guid + '\DohInterfaceSettings\' + $Familia + '\' + $Ip)
}

function Test-ChaveDoh {
    param([string]$Subchave, [bool]$Teste)
    $k = (Get-RegistroDoh $Teste).hive.OpenSubKey($Subchave)
    if ($null -eq $k) { return $false }
    $k.Dispose()
    return $true
}

function Add-ChaveDoh {
    # Cria a chave DoH com DohFlags (QWord 2) e DohTemplate, como o Sophia. Chave que ja existia nao e tocada: $false.
    param([string]$Subchave, [string]$Modelo, [bool]$Teste)
    if (Test-ChaveDoh $Subchave $Teste) { return $false }
    $hive = (Get-RegistroDoh $Teste).hive
    $k = $hive.CreateSubKey($Subchave)
    if ($null -eq $k) { throw "não foi possível criar a chave DoH $Subchave" }
    try {
        $k.SetValue('DohFlags', [int64]$Script:FlagsDoh, [Microsoft.Win32.RegistryValueKind]::QWord)
        $k.SetValue('DohTemplate', $Modelo, [Microsoft.Win32.RegistryValueKind]::String)
    } catch {
        $k.Dispose()
        $hive.DeleteSubKeyTree($Subchave, $false)
        throw
    }
    $k.Dispose()
    return $true
}

function Remove-ChaveDoh {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Subchave, [bool]$Teste)
    (Get-RegistroDoh $Teste).hive.DeleteSubKeyTree($Subchave, $false)
}

function Test-DohDoNexTune {
    param($Backup, [string]$Guid, [string]$Familia, [string]$Ip)
    foreach ($d in $Backup.dohAdicionados) {
        if ([string]$d.guid -eq $Guid -and [string]$d.familia -ceq $Familia -and [string]$d.ip -eq $Ip) { return $true }
    }
    return $false
}

function Remove-DohAdaptador {
    # Remove as chaves DoH que o NexTune criou para o adaptador (todas, ou so as de IPs fora de $Manter).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param($Backup, [string]$Guid, [bool]$Teste, [string[]]$Manter = @())
    foreach ($d in @($Backup.dohAdicionados)) {
        if ([string]$d.guid -ne $Guid -or @($Manter) -contains [string]$d.ip) { continue }
        $sub = Get-SubchaveDoh ([string]$d.guid) ([string]$d.familia) ([string]$d.ip) $Teste
        if ($null -ne $sub) {
            Remove-ChaveDoh $sub $Teste
            Write-AppLog ('rede: chave DoH removida: ' + $sub) $Teste
        }
        $null = $Backup.dohAdicionados.Remove($d)
    }
}

function Update-DohAdaptador {
    # Chaves DoH do provedor no adaptador; as que o NexTune criou para outro provedor saem. Cada chave criada entra em
    # dohAdicionados; chave que ja existia antes do NexTune fica como estava e nao entra na lista.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param($Backup, $Adaptador, $Provedor, [bool]$Teste)
    $guid = [string]$Adaptador.guid
    $ips = @(@($Provedor.ipv4) + @($Provedor.ipv6))
    Remove-DohAdaptador $Backup $guid $Teste $ips
    foreach ($ip in $ips) {
        $fam = Get-FamiliaDoh $ip
        if (Test-DohDoNexTune $Backup $guid $fam $ip) { continue }
        $sub = Get-SubchaveDoh $guid $fam $ip $Teste
        if ($null -eq $sub) { throw "não foi possível montar a chave DoH de $ip" }
        if (Add-ChaveDoh $sub ([string]$Provedor.modelo) $Teste) {
            $Backup.dohAdicionados.Add([ordered]@{ guid = $guid; familia = $fam; ip = $ip })
            Write-AppLog ('rede: chave DoH criada: ' + $sub + ' -> ' + $Provedor.modelo) $Teste
        } else {
            Write-AppLog ('rede: chave DoH já existia e não foi alterada: ' + $sub) $Teste
        }
    }
}

# ---------- backup ----------

function Get-ArquivoBackupRede {
    param([bool]$Teste)
    return (Join-Path (Get-AppPastas $Teste).Backups $Script:ArquivoBackupDns)
}

function New-BackupRede {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param()
    $adaptadores = New-Object System.Collections.Generic.List[object]
    $doh = New-Object System.Collections.Generic.List[object]
    return @{ data = (Get-Date).ToString('o'); adaptadores = $adaptadores; dohAdicionados = $doh }
}

function Read-BackupRede {
    # $null se nao ha backup. Ilegivel lanca: nunca e sobrescrito as cegas.
    param([bool]$Teste)
    $arq = Get-ArquivoBackupRede $Teste
    if (-not (Test-Path -LiteralPath $arq -PathType Leaf)) { return $null }
    try { $o = Read-ArquivoJson $arq } catch { throw "backup do DNS ilegível ($arq): $($_.Exception.Message)" }
    if ($o -isnot [pscustomobject]) { throw "backup do DNS ilegível ($arq)" }
    $b = New-BackupRede
    $b.data = [string]$o.data
    foreach ($e in @($o.adaptadores | Where-Object { $null -ne $_ })) { $b.adaptadores.Add((ConvertTo-EntradaBackup $e)) }
    foreach ($d in @($o.dohAdicionados | Where-Object { $null -ne $_ })) {
        $b.dohAdicionados.Add([ordered]@{ guid = [string]$d.guid; familia = [string]$d.familia; ip = [string]$d.ip })
    }
    return $b
}

function Write-BackupRede {
    param($Backup, [bool]$Teste)
    $o = [ordered]@{
        versao         = 1
        data           = [string]$Backup.data
        adaptadores    = @($Backup.adaptadores)
        dohAdicionados = @($Backup.dohAdicionados)
    }
    Write-JsonAtomico (Get-ArquivoBackupRede $Teste) $o
}

# ---------- dnsSeguro ----------

function Invoke-AplicarProvedor {
    # Backup antes da primeira troca (entradas existentes nunca mudam); depois servidores e DoH, adaptador por adaptador.
    param([string]$Id, [string]$Nome, $Adaptadores, [bool]$Teste, $Sim)
    $prov = $Script:Provedores[$Nome]
    $lista = @($Adaptadores)
    $backup = Read-BackupRede $Teste
    if ($null -eq $backup) { $backup = New-BackupRede }
    $novos = 0
    foreach ($a in $lista) {
        if ($null -ne (Find-AdaptadorPorGuid $backup.adaptadores ([string]$a.guid))) { continue }
        $backup.adaptadores.Add((ConvertTo-EntradaBackup $a))
        $novos++
    }
    if ($novos -gt 0) {
        Write-BackupRede $backup $Teste
        Write-AppLog ('rede: backup do DNS gravado em {0} ({1} adaptador(es) novo(s))' -f (Get-ArquivoBackupRede $Teste), $novos) $Teste
    }
    $servidores = @(@($prov.ipv4) + @($prov.ipv6))
    $saida = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($a in $lista) {
        Send-Progress $Id (10 + [int](80 * $i / $lista.Count)) ('Configurando o DNS de ' + $a.nome)
        $i++
        $item = [ordered]@{ indice = [int]$a.indice; nome = [string]$a.nome; ok = $false; erro = '' }
        try {
            Set-ServidorAdaptador $a $false $servidores $Teste $Sim
            Write-AppLog ('rede: DNS de {0} ({1}) -> {2} ({3})' -f $a.nome, $a.indice, ($servidores -join ', '), $Nome) $Teste
            Update-DohAdaptador $backup $a $prov $Teste
            $item.ok = $true
        } catch {
            $item.erro = $_.Exception.Message
            Write-AppLog ('rede: falha ao configurar o DNS de {0} ({1}): {2}' -f $a.nome, $a.indice, $_.Exception.Message) $Teste
        } finally {
            # A lista de chaves DoH criadas vai para o disco a cada adaptador, deu certo ou nao.
            Write-BackupRede $backup $Teste
        }
        $saida.Add($item)
    }
    return $saida.ToArray()
}

function Invoke-VoltarAutomatico {
    # Com backup: restaura cada adaptador guardado e remove as chaves DoH do NexTune; o que voltou sai do backup e o
    # arquivo some quando nada sobra. Sem backup: todos os adaptadores ativos voltam ao DHCP.
    param([string]$Id, [bool]$Teste, $Sim)
    $saida = New-Object System.Collections.Generic.List[object]
    $backup = Read-BackupRede $Teste
    if ($null -eq $backup) {
        foreach ($a in @(Get-AdaptadorRede $Teste $Sim $true)) {
            Send-Progress $Id 50 ('Voltando o DNS de ' + $a.nome + ' ao automático')
            $item = [ordered]@{ indice = [int]$a.indice; nome = [string]$a.nome; ok = $false; erro = '' }
            try {
                Set-ServidorAdaptador $a $true @() $Teste $Sim
                Write-AppLog ('rede: DNS de {0} ({1}) -> automático (sem backup)' -f $a.nome, $a.indice) $Teste
                $item.ok = $true
            } catch {
                $item.erro = $_.Exception.Message
                Write-AppLog ('rede: falha ao voltar o DNS de {0} ({1}) ao automático: {2}' -f $a.nome, $a.indice, $_.Exception.Message) $Teste
            }
            $saida.Add($item)
        }
        return $saida.ToArray()
    }
    $atuais = @(Get-AdaptadorRede $Teste $Sim $false)
    foreach ($e in @($backup.adaptadores)) {
        Send-Progress $Id 50 ('Restaurando o DNS de ' + $e.nome)
        $item = [ordered]@{ indice = [int]$e.indice; nome = [string]$e.nome; ok = $false; erro = '' }
        $a = Find-AdaptadorPorGuid $atuais ([string]$e.guid)
        if ($null -eq $a) {
            $item.erro = 'O adaptador não foi encontrado (desconectado ou removido); o backup dele foi mantido.'
            Write-AppLog ('rede: adaptador {0} ({1}) do backup não encontrado' -f $e.nome, $e.guid) $Teste
            $saida.Add($item)
            continue
        }
        $item.indice = [int]$a.indice
        $item.nome = [string]$a.nome
        try {
            Restore-AdaptadorDoBackup $e $a $Teste $Sim
            Write-AppLog ('rede: DNS de {0} ({1}) restaurado do backup (IPv4 {2}, IPv6 {3})' -f $a.nome, $a.indice,
                $(if ($e.ipv4Automatico) { 'automático' } else { @($e.ipv4) -join ', ' }),
                $(if ($e.ipv6Automatico) { 'automático' } else { @($e.ipv6) -join ', ' })) $Teste
            Remove-DohAdaptador $backup ([string]$e.guid) $Teste
            $null = $backup.adaptadores.Remove($e)
            $item.ok = $true
        } catch {
            $item.erro = $_.Exception.Message
            Write-AppLog ('rede: falha ao restaurar o DNS de {0} ({1}): {2}' -f $a.nome, $a.indice, $_.Exception.Message) $Teste
        }
        $saida.Add($item)
    }
    # Chaves DoH de adaptadores que nao estao mais no backup tambem saem.
    foreach ($g in @($backup.dohAdicionados | ForEach-Object { [string]$_.guid } | Sort-Object -Unique)) {
        if ($null -ne (Find-AdaptadorPorGuid $backup.adaptadores $g)) { continue }
        try { Remove-DohAdaptador $backup $g $Teste }
        catch { Write-AppLog ('rede: falha ao remover chave DoH de {0}: {1}' -f $g, $_.Exception.Message) $Teste }
    }
    $arq = Get-ArquivoBackupRede $Teste
    if ($backup.adaptadores.Count -eq 0 -and $backup.dohAdicionados.Count -eq 0) {
        Remove-Item -LiteralPath $arq -Force -ErrorAction Stop
        Write-AppLog ('rede: DNS restaurado do backup; backup apagado: ' + $arq) $Teste
    } else {
        Write-BackupRede $backup $Teste
        Write-AppLog ('rede: restauração parcial do DNS; backup mantido com {0} adaptador(es) e {1} chave(s) DoH' -f $backup.adaptadores.Count, $backup.dohAdicionados.Count) $Teste
    }
    return $saida.ToArray()
}

# ---------- acoes ----------

function Invoke-EstadoRede {
    param([string]$Id, $Params, [bool]$Teste)
    $sim = Get-Simulacao $Params $Teste
    Send-Progress $Id 10 'Lendo os adaptadores de rede'
    $adaptadores = @(Get-AdaptadorRede $Teste $sim $true)
    $lista = @($adaptadores | ForEach-Object {
            [ordered]@{
                indice     = [int]$_.indice
                nome       = [string]$_.nome
                descricao  = [string]$_.descricao
                dns        = @(Get-DnsExibido $_)
                automatico = ($_.ipv4Automatico -and $_.ipv6Automatico)
            }
        })
    $dados = [ordered]@{
        adaptadores   = $lista
        provedor      = (Get-ProvedorDetectado $adaptadores)
        dohDisponivel = ((Get-BuildRede $Teste $sim) -ge $Script:BuildWin11)
        temBackup     = (Test-Path -LiteralPath (Get-ArquivoBackupRede $Teste) -PathType Leaf)
    }
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id $dados
}

function Invoke-LimparCache {
    param([string]$Id, $Params, [bool]$Teste)
    $sim = Get-Simulacao $Params $Teste
    $exe = Join-Path $env:windir 'System32\ipconfig.exe'
    Send-Progress $Id 10 'Limpando o cache de DNS'
    if ($Teste) {
        Write-MarcadorRede 'limparDns' @($exe + ' /flushdns')
        $codigo = 0
        if ($null -ne $sim -and $null -ne $sim.codigo) { $codigo = [int]$sim.codigo }
    } else {
        $null = & $exe '/flushdns' 2>&1
        $codigo = $LASTEXITCODE
    }
    Write-AppLog ('rede: ipconfig /flushdns terminou com ' + $codigo) $Teste
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ ok = ($codigo -eq 0) })
}

function Invoke-Redefinir {
    param([string]$Id, $Params, [bool]$Teste)
    if (-not (Test-ParamVerdadeiro $Params 'confirmado')) { Send-Result $Id $null $false 'ação exige confirmação'; return }
    $sim = Get-Simulacao $Params $Teste
    $netsh = Join-Path $env:windir 'System32\netsh.exe'
    $passos = @(
        @{ chave = 'winsock'; argumentos = @('winsock', 'reset'); pct = 10; msg = 'Redefinindo o Winsock' },
        @{ chave = 'ip'; argumentos = @('int', 'ip', 'reset'); pct = 50; msg = 'Redefinindo o TCP/IP' }
    )
    $marcador = New-Object System.Collections.Generic.List[string]
    $falhas = New-Object System.Collections.Generic.List[string]
    foreach ($passo in $passos) {
        Send-Progress $Id $passo.pct $passo.msg
        $comando = 'netsh ' + ($passo.argumentos -join ' ')
        if ($Teste) {
            $marcador.Add($netsh + ' ' + ($passo.argumentos -join ' '))
            $codigo = 0
            if ($null -ne $sim -and $null -ne $sim.netsh -and $null -ne $sim.netsh.($passo.chave)) { $codigo = [int]$sim.netsh.($passo.chave) }
        } else {
            $null = & $netsh $passo.argumentos 2>&1
            $codigo = $LASTEXITCODE
        }
        Write-AppLog ('rede: ' + $comando + ' terminou com ' + $codigo) $Teste
        if ($codigo -ne 0) { $falhas.Add('O comando "' + $comando + '" terminou com o código ' + $codigo + '.') }
    }
    if ($Teste) { Write-MarcadorRede 'redefinir' $marcador.ToArray() }
    if ($falhas.Count -eq 0) {
        $detalhe = 'O Winsock e o TCP/IP voltaram ao padrão do Windows. Reinicie o PC para concluir.'
    } else {
        $detalhe = ($falhas.ToArray() -join ' ') + ' Reinicie o PC para concluir o que foi redefinido.'
    }
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ precisaReiniciar = $true; detalhe = $detalhe })
}

function Invoke-DnsSeguro {
    param([string]$Id, $Params, [bool]$Teste)
    if (-not (Test-ParamVerdadeiro $Params 'confirmado')) { Send-Result $Id $null $false 'ação exige confirmação'; return }
    $provedor = $null
    if ($null -ne $Params) { $provedor = $Params.provedor }
    $validos = @(@($Script:Provedores.Keys) + 'automatico')
    if ($provedor -isnot [string] -or $validos -cnotcontains $provedor) { Send-Result $Id $null $false 'provedor de DNS inválido'; return }
    $sim = Get-Simulacao $Params $Teste
    if ($provedor -cne 'automatico' -and (Get-BuildRede $Teste $sim) -lt $Script:BuildWin11) {
        Send-Result $Id $null $false 'DNS seguro precisa do Windows 11'
        return
    }
    Send-Progress $Id 5 'Lendo os adaptadores de rede'
    if ($provedor -ceq 'automatico') {
        $resultado = @(Invoke-VoltarAutomatico $Id $Teste $sim)
    } else {
        $adaptadores = @(Get-AdaptadorRede $Teste $sim $true)
        if ($adaptadores.Count -eq 0) { Send-Result $Id $null $false 'nenhum adaptador de rede físico ativo foi encontrado'; return }
        $resultado = @(Invoke-AplicarProvedor $Id $provedor $adaptadores $Teste $sim)
    }
    if (-not $Teste) { Clear-DnsClientCache -ErrorAction SilentlyContinue }
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ adaptadores = $resultado; provedor = $provedor })
}

function Invoke-Acao {
    param([string]$Id, [string]$Acao, $Params, [bool]$Teste)
    if (@('estado', 'limparDns', 'redefinir', 'dnsSeguro') -notcontains $Acao) {
        Send-Result $Id $null $false 'ação desconhecida'
        return
    }
    try {
        switch ($Acao) {
            'estado' { Invoke-EstadoRede $Id $Params $Teste }
            'limparDns' { Invoke-LimparCache $Id $Params $Teste }
            'redefinir' { Invoke-Redefinir $Id $Params $Teste }
            'dnsSeguro' { Invoke-DnsSeguro $Id $Params $Teste }
        }
    } catch {
        $msg = 'ferramentas de rede falharam: ' + $_.Exception.Message
        Write-AppLog $msg $Teste
        Send-Result $Id $null $false $msg
    }
}
