# rede.ps1 - ferramentas de rede: estado do DNS, limpar o cache, redefinir Winsock/TCP-IP e DNS seguro (DoH).
# Baseado em Sophia Script for Windows (MIT, farag2): DNSoverHTTPS (servidores IPv4, modelos DoH e chaves
# DohInterfaceSettings com DohFlags/DohTemplate). Servidores IPv6 da documentacao publica de cada provedor
# (Cloudflare 1.1.1.1, Google Public DNS, Quad9).
# Uso de rede: so uma consulta DNS a dns.msftncsi.com (a mesma que o Windows faz para saber se ha internet), antes e
# depois de aplicar um provedor, para conferir que os nomes ainda resolvem. Nada mais sai da maquina.
# Acoes: estado {} -> {adaptadores: [{indice, nome, descricao, dns, automatico}], provedor, dohDisponivel,
#          bloqueadoPorPolitica, temBackup};
#        limparDns {} -> {ok};
#        redefinir {confirmado} -> {precisaReiniciar: true, detalhe};
#        dnsSeguro {provedor: cloudflare|google|quad9|automatico, confirmado} ->
#          {adaptadores: [{indice, nome, ok, erro, mantido, revertido}], provedor, aviso?}. revertido = o adaptador voltou
#          ao backup (resolucao parou ou falha no DoH); mantido = automatico sem backup deixou o adaptador como estava.
# Adaptadores: fisicos e ativos (Get-NetAdapter -Physical, Status Up). Servidores "automaticos" (DHCP) = valor NameServer
# vazio em Tcpip\Parameters\Interfaces\<guid> (IPv4) e Tcpip6\Parameters\Interfaces\<guid> (IPv6), como o Windows grava.
# IPv4 e IPv6 sao fixados em chamadas separadas; adaptador sem interface IPv6 fica so com o IPv4, e falha no IPv6 nunca
# desfaz o IPv4. Voltar uma familia ao DHCP usa netsh interface ipv4|ipv6 set dnsservers ... source=dhcp.
# Backup: antes da primeira troca, Backups\dns.json guarda {versao: 1, data, adaptadores: [{indice, guid, nome, ipv4,
# ipv6, ipv4Automatico, ipv6Automatico}], dohAdicionados: [{guid, familia, ip}]}; entrada existente nunca e sobrescrita
# (adaptador novo entra como entrada nova). Cada chave DoH entra em dohAdicionados e o backup vai para o disco ANTES de
# a chave ser criada; chave que ja existia nao e tocada. automatico restaura cada adaptador exatamente, remove so as
# chaves do NexTune e apaga o arquivo quando tudo voltou. Sem backup, automatico volta ao DHCP so as familias cujos
# servidores fixos sao de um dos tres provedores (restos do Sophia/NexTune); os demais adaptadores ficam (mantido).
# Backup com formato inesperado faz a acao recusar sem tocar no arquivo.
# Depois de aplicar: se dns.msftncsi.com resolvia antes e nao resolve em duas tentativas, os adaptadores trocados voltam
# ao backup. Falha ao gravar o DoH tambem devolve o adaptador ao backup.
# DoH so no Windows 11 (build >= 22000) e sem a politica DoHPolicy = 1 (proibido); valores de politica nunca sao apagados.
# Em modo teste nada real roda: simular {adaptadores?: [{indice, guid, nome, descricao, ipv4, ipv6, ipv4Automatico,
# ipv6Automatico, temIpv6?, ipv4Dhcp?, ipv6Dhcp?}], build?, falharIndice?, falharIpv6Indice?, falharDohIndice?,
# resolve?: {antes?, depois? (valor ou lista por tentativa)}, rota?: {indice, nome}, codigo? (ipconfig),
# netsh?: {winsock?, ip?}}. O estado dos adaptadores vive em %TEMP%\NexTuneTeste\rede\adaptadores.json (semeado por
# simular.adaptadores quando ainda nao existe); ipv4Dhcp/ipv6Dhcp sao o que o "DHCP" entrega ao voltar ao automatico.
# O backup vai para %TEMP%\NexTuneTeste\Backups, as chaves DoH para HKCU\Software\NexTuneTeste\Dnscache\..., a politica
# e lida de HKCU\Software\NexTuneTeste\Policies\... e ipconfig/netsh viram marcadores %TEMP%\NexTuneTeste\rede\<acao>.txt.
. "$PSScriptRoot\common.ps1"

# IPv4 e modelos DoH: Sophia.psm1 (DNSoverHTTPS). IPv6: documentacao de cada provedor
# (developers.cloudflare.com/1.1.1.1, developers.google.com/speed/public-dns, quad9.net/service/service-addresses-and-features).
$Script:Provedores = [ordered]@{
    cloudflare = @{ ipv4 = @('1.1.1.1', '1.0.0.1'); ipv6 = @('2606:4700:4700::1111', '2606:4700:4700::1001'); modelo = 'https://cloudflare-dns.com/dns-query' }
    google     = @{ ipv4 = @('8.8.8.8', '8.8.4.4'); ipv6 = @('2001:4860:4860::8888', '2001:4860:4860::8844'); modelo = 'https://dns.google/dns-query' }
    quad9      = @{ ipv4 = @('9.9.9.9', '149.112.112.112'); ipv6 = @('2620:fe::fe', '2620:fe::9'); modelo = 'https://dns.quad9.net/dns-query' }
}
$Script:FlagsDoh = 2
$Script:BuildWin11 = 22000
$Script:ArquivoBackupDns = 'dns.json'
$Script:NomeTesteResolucao = 'dns.msftncsi.com'
$Script:MsgNaoRespondeu = 'O DNS seguro não respondeu nesta rede; voltamos ao anterior.'

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

function Test-ListaDeProvedor {
    # Puro: a lista de uma familia ('ipv4' | 'ipv6') e exatamente a de algum dos provedores?
    param($Lista, [string]$Familia)
    if (@(Get-ListaIp $Lista).Count -eq 0) { return $false }
    foreach ($nome in @($Script:Provedores.Keys)) {
        if (Test-MesmoConjunto $Lista $Script:Provedores[$nome].$Familia) { return $true }
    }
    return $false
}

function Get-DnsExibido {
    # Puro: IPv4 e IPv6 do adaptador para a tela, sem os fec0:0:0:ffff::1..3 que o Windows mostra quando nao ha DNS IPv6.
    param($Adaptador)
    $v6 = @(Get-ListaIp $Adaptador.ipv6 | Where-Object { $_ -notmatch '^fec0:0:0:ffff::[1-3]$' })
    return @(@(Get-ListaIp $Adaptador.ipv4) + $v6)
}

function Get-ProvedorDetectado {
    # Puro: provedor cujos servidores fixos estao em todos os adaptadores (IPv4 e, onde ha IPv6, tambem o IPv6);
    # automatico quando todos vem do DHCP nas duas familias; senao outro. Sem adaptadores: automatico.
    param($Adaptadores)
    $lista = @($Adaptadores | Where-Object { $null -ne $_ })
    if ($lista.Count -eq 0) { return 'automatico' }
    foreach ($nome in @($Script:Provedores.Keys)) {
        $p = $Script:Provedores[$nome]
        $iguais = @($lista | Where-Object {
                (-not $_.ipv4Automatico -and (Test-MesmoConjunto $_.ipv4 $p.ipv4)) -and
                (-not $_.temIpv6 -or (-not $_.ipv6Automatico -and (Test-MesmoConjunto $_.ipv6 $p.ipv6)))
            })
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
        temIpv6        = ($Fonte.temIpv6 -ne $false)
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

function Get-SubchaveDoh {
    # Puro: <base>\<guid>\DohInterfaceSettings\Doh|Doh6\<ip>; $null se guid, familia ou ip nao forem validos (Doh so com
    # IPv4, Doh6 so com IPv6): nada lido de arquivo decide sozinho que chave apagar.
    param([string]$Guid, [string]$Familia, [string]$Ip, [bool]$Teste)
    if (-not (Test-GuidInterface $Guid)) { return $null }
    $fam = Get-FamiliaIp $Ip
    if (-not (($Familia -ceq 'Doh' -and $fam -eq 'IPv4') -or ($Familia -ceq 'Doh6' -and $fam -eq 'IPv6'))) { return $null }
    $base = if ($Teste) { 'Software\NexTuneTeste\Dnscache\InterfaceSpecificParameters' } else { 'SYSTEM\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters' }
    return ($base + '\' + $Guid + '\DohInterfaceSettings\' + $Familia + '\' + $Ip)
}

function Get-FamiliaDoh {
    param([string]$Ip)
    if ((Get-FamiliaIp $Ip) -eq 'IPv6') { return 'Doh6' }
    return 'Doh'
}

function Get-ProblemaBackup {
    # Puro: '' se o objeto lido tem o formato do backup; senao o motivo.
    param($O)
    if ($O -isnot [pscustomobject]) { return 'a raiz não é um objeto' }
    $nomes = @($O.PSObject.Properties.Name)
    if ($nomes -notcontains 'versao' -or -not ($O.versao -is [int] -or $O.versao -is [long]) -or $O.versao -ne 1) { return 'versão desconhecida' }
    if ($nomes -notcontains 'adaptadores' -or $O.adaptadores -isnot [array]) { return 'sem a lista de adaptadores' }
    if ($nomes -contains 'dohAdicionados' -and $O.dohAdicionados -isnot [array]) { return 'dohAdicionados não é uma lista' }
    foreach ($e in @($O.adaptadores)) {
        if ($e -isnot [pscustomobject] -or -not (Test-GuidInterface ([string]$e.guid))) { return 'adaptador com guid inválido' }
        foreach ($ip in @(Get-ListaIp $e.ipv4)) { if ((Get-FamiliaIp $ip) -ne 'IPv4') { return "endereço IPv4 inválido: $ip" } }
        foreach ($ip in @(Get-ListaIp $e.ipv6)) { if ((Get-FamiliaIp $ip) -ne 'IPv6') { return "endereço IPv6 inválido: $ip" } }
    }
    if ($nomes -contains 'dohAdicionados') {
        foreach ($d in @($O.dohAdicionados)) {
            if ($d -isnot [pscustomobject] -or $null -eq (Get-SubchaveDoh ([string]$d.guid) ([string]$d.familia) ([string]$d.ip) $false)) {
                return 'chave DoH inválida'
            }
        }
    }
    return ''
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

function Test-IndiceSimulado {
    # Em teste: simular.<Campo> aponta para este adaptador?
    param($Sim, [string]$Campo, $Adaptador)
    if ($null -eq $Sim -or $null -eq $Sim.$Campo) { return $false }
    return ([int]$Sim.$Campo -eq [int]$Adaptador.indice)
}

# ---------- leitura do sistema ----------

function Test-DhcpRegistro {
    # NameServer vazio (ou ausente) em <Servico>\Parameters\Interfaces\<guid> = servidores vindos do DHCP.
    param([string]$Servico, [string]$Guid)
    $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$Servico\Parameters\Interfaces\$Guid"
    try { $v = (Get-ItemProperty -LiteralPath $k -Name NameServer -ErrorAction Stop).NameServer }
    catch { return $true }
    return [string]::IsNullOrWhiteSpace([string]$v)
}

function Test-DohBloqueado {
    # Politica "Configure DNS over HTTPS": DoHPolicy = 1 proibe o DoH. So leitura; o NexTune nunca apaga politica.
    param([bool]$Teste)
    $k = if ($Teste) { 'HKCU:\Software\NexTuneTeste\Policies\Microsoft\Windows NT\DNSClient' } else { 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' }
    try { return ([int64](Get-ItemProperty -LiteralPath $k -Name DoHPolicy -ErrorAction Stop).DoHPolicy -eq 1) }
    catch { return $false }
}

function Get-AdaptadorReal {
    # Adaptadores fisicos (so os ativos com $SoAtivos) com os servidores das duas familias. temIpv6 = ha entrada IPv6
    # no Get-DnsClientServerAddress (o protocolo esta ligado no adaptador).
    param([bool]$SoAtivos)
    $saida = New-Object System.Collections.Generic.List[object]
    foreach ($n in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)) {
        if ($SoAtivos -and [string]$n.Status -ne 'Up') { continue }
        $guid = [string]$n.InterfaceGuid
        if (-not (Test-GuidInterface $guid)) { continue }
        $i = [int]$n.ifIndex
        $e4 = @(Get-DnsClientServerAddress -InterfaceIndex $i -AddressFamily IPv4 -ErrorAction SilentlyContinue)
        $e6 = @(Get-DnsClientServerAddress -InterfaceIndex $i -AddressFamily IPv6 -ErrorAction SilentlyContinue)
        $fonte = [ordered]@{
            indice         = $i
            guid           = $guid
            nome           = [string]$n.Name
            descricao      = [string]$n.InterfaceDescription
            ipv4           = @($e4 | ForEach-Object { $_.ServerAddresses })
            ipv6           = @($e6 | ForEach-Object { $_.ServerAddresses })
            ipv4Automatico = (Test-DhcpRegistro 'Tcpip' $guid)
            ipv6Automatico = (Test-DhcpRegistro 'Tcpip6' $guid)
            temIpv6        = ($e6.Count -gt 0)
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

function Test-NomeResolve {
    # A unica consulta de rede do modulo: dns.msftncsi.com resolve? Em teste vem de simular.resolve.<Momento>
    # (valor ou lista por tentativa; ausente = resolve).
    param([bool]$Teste, $Sim, [string]$Momento, [int]$Tentativa = 0)
    if ($Teste) {
        if ($null -eq $Sim -or $null -eq $Sim.resolve -or $null -eq $Sim.resolve.$Momento) { return $true }
        $v = @($Sim.resolve.$Momento)
        return ($v[[math]::Min($Tentativa, $v.Count - 1)] -eq $true)
    }
    try {
        $null = Resolve-DnsName -Name $Script:NomeTesteResolucao -DnsOnly -QuickTimeout -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Get-AvisoRota {
    # Se a rota ate o provedor sai por uma interface fora da lista (VPN, vEthernet), avisa: ela nao foi alterada.
    param($Adaptadores, $Provedor, [bool]$Teste, $Sim)
    $indice = $null
    $nome = ''
    if ($Teste) {
        if ($null -eq $Sim -or $null -eq $Sim.rota) { return '' }
        $indice = [int]$Sim.rota.indice
        $nome = [string]$Sim.rota.nome
    } else {
        try {
            $r = @(Find-NetRoute -RemoteIPAddress ([string]@($Provedor.ipv4)[0]) -ErrorAction Stop | Where-Object { $null -ne $_.InterfaceIndex })
            if ($r.Count -eq 0) { return '' }
            $indice = [int]$r[0].InterfaceIndex
            $nome = [string]$r[0].InterfaceAlias
        } catch { return '' }
    }
    foreach ($a in @($Adaptadores)) { if ([int]$a.indice -eq $indice) { return '' } }
    if ([string]::IsNullOrWhiteSpace($nome)) { $nome = "a interface $indice" }
    return "A conexão em uso passa por $nome, que não foi alterada."
}

# ---------- escrita: servidores ----------

function Set-ServidorFamilia {
    # Uma familia ('IPv4' | 'IPv6') do adaptador: lista vazia = volta ao DHCP (netsh ... source=dhcp); senao lista fixa.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param($Adaptador, [string]$Familia, [string[]]$Lista, [bool]$Teste, $Sim)
    $ips = @(Get-ListaIp $Lista)
    foreach ($ip in $ips) { if ((Get-FamiliaIp $ip) -ne $Familia) { throw "endereço de DNS inválido para ${Familia}: $ip" } }
    if ($Teste) {
        if (Test-IndiceSimulado $Sim 'falharIndice' $Adaptador) { throw "falha simulada no adaptador $($Adaptador.indice)" }
        if ($Familia -eq 'IPv6' -and (Test-IndiceSimulado $Sim 'falharIpv6Indice' $Adaptador)) { throw "falha simulada no IPv6 do adaptador $($Adaptador.indice)" }
        $todos = @(Read-EstadoFalso $Sim)
        $a = Find-AdaptadorPorGuid $todos ([string]$Adaptador.guid)
        if ($null -eq $a) { throw 'o adaptador não foi encontrado' }
        $f = $Familia.ToLowerInvariant()
        if ($ips.Count -eq 0) {
            $a.$f = @($a.($f + 'Dhcp'))
            $a.($f + 'Automatico') = $true
        } else {
            $a.$f = $ips
            $a.($f + 'Automatico') = $false
        }
        Write-EstadoFalso $todos
        return
    }
    $indice = [int]$Adaptador.indice
    if ($ips.Count -gt 0) {
        Set-DnsClientServerAddress -InterfaceIndex $indice -ServerAddresses $ips -ErrorAction Stop
        return
    }
    $netsh = Join-Path $env:windir 'System32\netsh.exe'
    $argumentos = @('interface', $Familia.ToLowerInvariant(), 'set', 'dnsservers', ('name=' + $indice), 'source=dhcp')
    $null = & $netsh $argumentos 2>&1
    if ($LASTEXITCODE -ne 0) { throw ('netsh interface {0} set dnsservers terminou com o código {1}' -f $Familia.ToLowerInvariant(), $LASTEXITCODE) }
}

function Restore-AdaptadorDoBackup {
    # Cada familia volta como estava: DHCP (ou sem servidor guardado) com source=dhcp, fixa com a lista. O IPv6 so e
    # tocado se o adaptador tem IPv6 agora.
    param($Entrada, $Adaptador, [bool]$Teste, $Sim)
    $v4 = @(Get-ListaIp $Entrada.ipv4)
    $v6 = @(Get-ListaIp $Entrada.ipv6)
    $l4 = @()
    if (-not ($Entrada.ipv4Automatico -eq $true -or $v4.Count -eq 0)) { $l4 = $v4 }
    $l6 = @()
    if (-not ($Entrada.ipv6Automatico -eq $true -or $v6.Count -eq 0)) { $l6 = $v6 }
    Set-ServidorFamilia $Adaptador 'IPv4' $l4 $Teste $Sim
    if ($Adaptador.temIpv6) { Set-ServidorFamilia $Adaptador 'IPv6' $l6 $Teste $Sim }
}

# ---------- escrita: chaves DoH ----------

function Get-HiveDoh {
    param([bool]$Teste)
    if ($Teste) { return [Microsoft.Win32.Registry]::CurrentUser }
    return [Microsoft.Win32.Registry]::LocalMachine
}

function Test-ChaveDoh {
    param([string]$Subchave, [bool]$Teste)
    $k = (Get-HiveDoh $Teste).OpenSubKey($Subchave)
    if ($null -eq $k) { return $false }
    $k.Dispose()
    return $true
}

function Add-ChaveDoh {
    # Cria a chave DoH com DohFlags (QWord 2) e DohTemplate, como o Sophia; se nao conseguir gravar, nao deixa a chave.
    param([string]$Subchave, [string]$Modelo, [bool]$Teste)
    $hive = Get-HiveDoh $Teste
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
}

function Remove-ChaveDoh {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Subchave, [bool]$Teste)
    (Get-HiveDoh $Teste).DeleteSubKeyTree($Subchave, $false)
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
    # Chaves DoH do provedor no adaptador (Doh6 so com $ComIpv6); as que o NexTune criou para outros IPs saem.
    # Ordem por chave: chave que ja existia antes do NexTune fica como estava; senao a chave entra em dohAdicionados e
    # o backup vai para o disco ANTES de criar a chave (se cair no meio, o restaurar ainda sabe dela).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param($Backup, $Adaptador, $Provedor, [bool]$ComIpv6, [bool]$Teste, $Sim)
    $guid = [string]$Adaptador.guid
    $ips = @($Provedor.ipv4)
    if ($ComIpv6) { $ips += @($Provedor.ipv6) }
    Remove-DohAdaptador $Backup $guid $Teste $ips
    foreach ($ip in $ips) {
        $fam = Get-FamiliaDoh $ip
        $sub = Get-SubchaveDoh $guid $fam $ip $Teste
        if ($null -eq $sub) { throw "não foi possível montar a chave DoH de $ip" }
        $nosso = Test-DohDoNexTune $Backup $guid $fam $ip
        if (Test-ChaveDoh $sub $Teste) {
            if (-not $nosso) { Write-AppLog ('rede: chave DoH já existia e não foi alterada: ' + $sub) $Teste }
            continue
        }
        $entrada = $null
        if (-not $nosso) {
            $entrada = [ordered]@{ guid = $guid; familia = $fam; ip = $ip }
            $Backup.dohAdicionados.Add($entrada)
            Write-BackupRede $Backup $Teste
        }
        try {
            if ($Teste -and (Test-IndiceSimulado $Sim 'falharDohIndice' $Adaptador)) { throw 'falha simulada ao gravar a chave DoH' }
            Add-ChaveDoh $sub ([string]$Provedor.modelo) $Teste
        } catch {
            if ($null -ne $entrada) { $null = $Backup.dohAdicionados.Remove($entrada) }
            throw
        }
        Write-AppLog ('rede: chave DoH criada: ' + $sub + ' -> ' + $Provedor.modelo) $Teste
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
    # $null se nao ha backup. Ilegivel ou com formato inesperado lanca e o arquivo fica como esta.
    param([bool]$Teste)
    $arq = Get-ArquivoBackupRede $Teste
    if (-not (Test-Path -LiteralPath $arq -PathType Leaf)) { return $null }
    try { $o = Read-ArquivoJson $arq } catch { throw "backup do DNS ilegível ($arq); nada foi alterado: $($_.Exception.Message)" }
    $problema = Get-ProblemaBackup $o
    if ($problema -ne '') { throw "backup do DNS com formato inesperado ($arq); nada foi alterado: $problema" }
    $b = New-BackupRede
    $b.data = [string]$o.data
    foreach ($e in @($o.adaptadores)) { $b.adaptadores.Add((ConvertTo-EntradaBackup $e)) }
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

function Save-BackupRede {
    # Grava o backup; vazio (nada a restaurar e nenhuma chave DoH do NexTune) apaga o arquivo.
    param($Backup, [bool]$Teste)
    $arq = Get-ArquivoBackupRede $Teste
    if ($Backup.adaptadores.Count -eq 0 -and $Backup.dohAdicionados.Count -eq 0) {
        if (Test-Path -LiteralPath $arq -PathType Leaf) {
            Remove-Item -LiteralPath $arq -Force -ErrorAction Stop
            Write-AppLog ('rede: nada mais a restaurar; backup do DNS apagado: ' + $arq) $Teste
        }
        return
    }
    Write-BackupRede $Backup $Teste
}

function Restore-AdaptadorCompleto {
    # Adaptador de volta a sua entrada do backup, sem as chaves DoH do NexTune; a entrada sai do backup (o chamador
    # grava com Save-BackupRede).
    param($Backup, $Adaptador, [bool]$Teste, $Sim)
    $e = Find-AdaptadorPorGuid $Backup.adaptadores ([string]$Adaptador.guid)
    if ($null -eq $e) { throw 'este adaptador não está no backup' }
    Restore-AdaptadorDoBackup $e $Adaptador $Teste $Sim
    Remove-DohAdaptador $Backup ([string]$e.guid) $Teste
    $null = $Backup.adaptadores.Remove($e)
    Write-AppLog ('rede: DNS de {0} ({1}) restaurado do backup (IPv4 {2}, IPv6 {3})' -f $Adaptador.nome, $Adaptador.indice,
        $(if ($e.ipv4Automatico) { 'automático' } else { @($e.ipv4) -join ', ' }),
        $(if ($e.ipv6Automatico) { 'automático' } else { @($e.ipv6) -join ', ' })) $Teste
}

# ---------- dnsSeguro ----------

function New-ItemResultado {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param($Adaptador)
    return [ordered]@{ indice = [int]$Adaptador.indice; nome = [string]$Adaptador.nome; ok = $false; erro = ''; mantido = $false; revertido = $false }
}

function Invoke-AplicarProvedor {
    # Backup antes da primeira troca (entradas existentes nunca mudam); depois IPv4, IPv6 e DoH, adaptador por
    # adaptador; por fim confere a resolucao e desfaz os adaptadores trocados se ela parou.
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
    $resolviaAntes = Test-NomeResolve $Teste $Sim 'antes'
    $saida = New-Object System.Collections.Generic.List[object]
    $trocados = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($a in $lista) {
        Send-Progress $Id (10 + [int](70 * $i / $lista.Count)) ('Configurando o DNS de ' + $a.nome)
        $i++
        $item = New-ItemResultado $a
        $saida.Add($item)
        try {
            Set-ServidorFamilia $a 'IPv4' @($prov.ipv4) $Teste $Sim
        } catch {
            $item.erro = $_.Exception.Message
            Write-AppLog ('rede: falha ao configurar o DNS IPv4 de {0} ({1}): {2}' -f $a.nome, $a.indice, $_.Exception.Message) $Teste
            continue
        }
        Write-AppLog ('rede: DNS IPv4 de {0} ({1}) -> {2} ({3})' -f $a.nome, $a.indice, (@($prov.ipv4) -join ', '), $Nome) $Teste
        $erro6 = ''
        $ok6 = $false
        if ($a.temIpv6) {
            try {
                Set-ServidorFamilia $a 'IPv6' @($prov.ipv6) $Teste $Sim
                $ok6 = $true
                Write-AppLog ('rede: DNS IPv6 de {0} ({1}) -> {2} ({3})' -f $a.nome, $a.indice, (@($prov.ipv6) -join ', '), $Nome) $Teste
            } catch {
                $erro6 = $_.Exception.Message
                Write-AppLog ('rede: falha ao configurar o DNS IPv6 de {0} ({1}); o IPv4 ficou: {2}' -f $a.nome, $a.indice, $erro6) $Teste
            }
        }
        try {
            Update-DohAdaptador $backup $a $prov $ok6 $Teste $Sim
        } catch {
            $item.erro = 'Não foi possível ativar o DNS seguro: ' + $_.Exception.Message
            Write-AppLog ('rede: falha ao gravar o DoH de {0} ({1}): {2}' -f $a.nome, $a.indice, $_.Exception.Message) $Teste
            try {
                Restore-AdaptadorCompleto $backup $a $Teste $Sim
                $item.revertido = $true
                $item.erro += ' O adaptador voltou ao DNS anterior.'
            } catch {
                $item.erro += ' Também não deu para voltar ao DNS anterior: ' + $_.Exception.Message
                Write-AppLog ('rede: falha ao desfazer {0} ({1}): {2}' -f $a.nome, $a.indice, $_.Exception.Message) $Teste
            }
            Save-BackupRede $backup $Teste
            continue
        }
        Save-BackupRede $backup $Teste
        if ($erro6 -ne '') { $item.erro = 'O DNS IPv4 foi trocado, mas o IPv6 não: ' + $erro6 }
        else { $item.ok = $true }
        $trocados.Add(@{ item = $item; adaptador = $a })
    }
    if (-not $Teste) { Clear-DnsClientCache -ErrorAction SilentlyContinue }
    if ($resolviaAntes -and $trocados.Count -gt 0) {
        Send-Progress $Id 85 'Conferindo se os nomes ainda resolvem'
        $resolve = $false
        for ($t = 0; $t -lt 2 -and -not $resolve; $t++) { $resolve = Test-NomeResolve $Teste $Sim 'depois' $t }
        if (-not $resolve) {
            Write-AppLog ('rede: {0} não resolveu depois de aplicar {1}; voltando os adaptadores trocados' -f $Script:NomeTesteResolucao, $Nome) $Teste
            foreach ($m in $trocados) {
                $m.item.ok = $false
                $m.item.erro = $Script:MsgNaoRespondeu
                try {
                    Restore-AdaptadorCompleto $backup $m.adaptador $Teste $Sim
                    $m.item.revertido = $true
                } catch {
                    $m.item.erro += ' Mas não deu para voltar este adaptador: ' + $_.Exception.Message
                    Write-AppLog ('rede: falha ao desfazer {0}: {1}' -f $m.adaptador.nome, $_.Exception.Message) $Teste
                }
            }
            Save-BackupRede $backup $Teste
            if (-not $Teste) { Clear-DnsClientCache -ErrorAction SilentlyContinue }
        }
    }
    return $saida.ToArray()
}

function Invoke-VoltarAutomatico {
    # Com backup: restaura cada adaptador guardado e remove as chaves DoH do NexTune; o que voltou sai do backup e o
    # arquivo some quando nada sobra. Sem backup: volta ao DHCP so as familias com servidores fixos de um dos
    # provedores; o resto fica como esta (mantido).
    param([string]$Id, [bool]$Teste, $Sim)
    $saida = New-Object System.Collections.Generic.List[object]
    $backup = Read-BackupRede $Teste
    if ($null -eq $backup) {
        foreach ($a in @(Get-AdaptadorRede $Teste $Sim $true)) {
            $item = New-ItemResultado $a
            $saida.Add($item)
            $f4 = (-not $a.ipv4Automatico) -and (Test-ListaDeProvedor $a.ipv4 'ipv4')
            $f6 = $a.temIpv6 -and (-not $a.ipv6Automatico) -and (Test-ListaDeProvedor $a.ipv6 'ipv6')
            if (-not $f4 -and -not $f6) {
                $item.ok = $true
                $item.mantido = $true
                continue
            }
            Send-Progress $Id 50 ('Voltando o DNS de ' + $a.nome + ' ao automático')
            try {
                if ($f4) { Set-ServidorFamilia $a 'IPv4' @() $Teste $Sim }
                if ($f6) { Set-ServidorFamilia $a 'IPv6' @() $Teste $Sim }
                Write-AppLog ('rede: DNS de {0} ({1}) -> automático sem backup (IPv4 {2}, IPv6 {3})' -f $a.nome, $a.indice, $f4, $f6) $Teste
                $item.ok = $true
            } catch {
                $item.erro = $_.Exception.Message
                Write-AppLog ('rede: falha ao voltar o DNS de {0} ({1}) ao automático: {2}' -f $a.nome, $a.indice, $_.Exception.Message) $Teste
            }
        }
        return $saida.ToArray()
    }
    $atuais = @(Get-AdaptadorRede $Teste $Sim $false)
    foreach ($e in @($backup.adaptadores)) {
        Send-Progress $Id 50 ('Restaurando o DNS de ' + $e.nome)
        $item = New-ItemResultado $e
        $saida.Add($item)
        $a = Find-AdaptadorPorGuid $atuais ([string]$e.guid)
        if ($null -eq $a) {
            $item.erro = 'O adaptador não foi encontrado (desconectado ou removido); o backup dele foi mantido.'
            Write-AppLog ('rede: adaptador {0} ({1}) do backup não encontrado' -f $e.nome, $e.guid) $Teste
            continue
        }
        $item.indice = [int]$a.indice
        $item.nome = [string]$a.nome
        try {
            Restore-AdaptadorCompleto $backup $a $Teste $Sim
            $item.ok = $true
        } catch {
            $item.erro = $_.Exception.Message
            Write-AppLog ('rede: falha ao restaurar o DNS de {0} ({1}): {2}' -f $a.nome, $a.indice, $_.Exception.Message) $Teste
        }
    }
    # Chaves DoH de adaptadores que nao estao mais no backup tambem saem.
    foreach ($g in @($backup.dohAdicionados | ForEach-Object { [string]$_.guid } | Sort-Object -Unique)) {
        if ($null -ne (Find-AdaptadorPorGuid $backup.adaptadores $g)) { continue }
        try { Remove-DohAdaptador $backup $g $Teste }
        catch { Write-AppLog ('rede: falha ao remover chave DoH de {0}: {1}' -f $g, $_.Exception.Message) $Teste }
    }
    Save-BackupRede $backup $Teste
    if ($backup.adaptadores.Count -gt 0 -or $backup.dohAdicionados.Count -gt 0) {
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
    $bloqueado = Test-DohBloqueado $Teste
    $dados = [ordered]@{
        adaptadores          = $lista
        provedor             = (Get-ProvedorDetectado $adaptadores)
        dohDisponivel        = (((Get-BuildWindows $Teste $sim) -ge $Script:BuildWin11) -and -not $bloqueado)
        bloqueadoPorPolitica = $bloqueado
        temBackup            = (Test-Path -LiteralPath (Get-ArquivoBackupRede $Teste) -PathType Leaf)
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
    $frases = New-Object System.Collections.Generic.List[string]
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
        if ($codigo -eq 0) { continue }
        if ($passo.chave -eq 'ip') {
            # O int ip reset costuma sair com erro por um item que o Windows protege, mesmo tendo redefinido o resto.
            $frases.Add('O "' + $comando + '" avisou que não conseguiu redefinir algum item (código ' + $codigo + '); isso costuma ser inofensivo.')
        } else {
            $frases.Add('O comando "' + $comando + '" terminou com o código ' + $codigo + '.')
        }
    }
    if ($Teste) { Write-MarcadorRede 'redefinir' $marcador.ToArray() }
    $inicio = if ($frases.Count -eq 0) { 'O Winsock e o TCP/IP voltaram ao padrão do Windows.' } else { $frases.ToArray() -join ' ' }
    $detalhe = $inicio + ' Se o PC usava IP fixo ou DNS configurado à mão, eles podem ter sido apagados: confira nas configurações de rede. Reinicie o PC para concluir.'
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
    $aviso = ''
    if ($provedor -ceq 'automatico') {
        Send-Progress $Id 5 'Lendo os adaptadores de rede'
        $resultado = @(Invoke-VoltarAutomatico $Id $Teste $sim)
        if (-not $Teste) { Clear-DnsClientCache -ErrorAction SilentlyContinue }
    } else {
        if ((Get-BuildWindows $Teste $sim) -lt $Script:BuildWin11) { Send-Result $Id $null $false 'DNS seguro precisa do Windows 11'; return }
        if (Test-DohBloqueado $Teste) { Send-Result $Id $null $false 'DNS seguro bloqueado por uma política do Windows'; return }
        Send-Progress $Id 5 'Lendo os adaptadores de rede'
        $adaptadores = @(Get-AdaptadorRede $Teste $sim $true)
        if ($adaptadores.Count -eq 0) { Send-Result $Id $null $false 'nenhum adaptador de rede físico ativo foi encontrado'; return }
        $aviso = Get-AvisoRota $adaptadores $Script:Provedores[$provedor] $Teste $sim
        $resultado = @(Invoke-AplicarProvedor $Id $provedor $adaptadores $Teste $sim)
    }
    $dados = [ordered]@{ adaptadores = $resultado; provedor = $provedor }
    if ($aviso -ne '') {
        $dados['aviso'] = $aviso
        Write-AppLog ('rede: aviso: ' + $aviso) $Teste
    }
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id $dados
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
