BeforeAll {
    . "$PSScriptRoot\..\common.ps1"
    . "$PSScriptRoot\..\rede.ps1"
    . "$PSScriptRoot\_helpers.ps1"
    $Script:BaseT = Join-Path $env:TEMP 'NexTuneTeste'
    $Script:PastaT = Join-Path $Script:BaseT 'rede'
    $Script:ArqEstadoT = Join-Path $Script:PastaT 'adaptadores.json'
    $Script:ArqBackupT = Join-Path (Join-Path $Script:BaseT 'Backups') 'dns.json'
    $Script:SubDohT = 'Software\NexTuneTeste\Dnscache'
    $Script:SubPoliticaT = 'Software\NexTuneTeste\Policies'
    $Script:G1 = '{11111111-1111-1111-1111-111111111111}'
    $Script:G2 = '{22222222-2222-2222-2222-222222222222}'
    $Script:G3 = '{33333333-3333-3333-3333-333333333333}'
    $Script:G4 = '{44444444-4444-4444-4444-444444444444}'
    $Script:G5 = '{55555555-5555-5555-5555-555555555555}'
    $Script:Todos = @($Script:G1, $Script:G2, $Script:G3, $Script:G4)
    $Script:Cloudflare = @('1.1.1.1', '1.0.0.1')
    $Script:Cloudflare6 = @('2606:4700:4700::1111', '2606:4700:4700::1001')
    $Script:Google = @('8.8.8.8', '8.8.4.4')
    $Script:Google6 = @('2001:4860:4860::8888', '2001:4860:4860::8844')
    $Script:Quad9 = @('9.9.9.9', '149.112.112.112')
    $Script:Quad96 = @('2620:fe::fe', '2620:fe::9')
    $Script:Utf8 = New-Object System.Text.UTF8Encoding $false

    function Invoke-Rede {
        param([string]$Acao, $Params = @{})
        $sw = New-Object System.IO.StringWriter
        Set-Saida $sw
        try { Invoke-Acao 'r1' $Acao $Params $true } finally { Set-Saida $null }
        $linhas = @($sw.ToString() -split "`r?`n" | Where-Object { $_.StartsWith('@@RESULT ') })
        if ($linhas.Count -ne 1) { return $null }
        return $linhas[0].Substring(9) | ConvertFrom-Json
    }

    function Reset-RedeTeste {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param()
        Remove-Item -LiteralPath $Script:PastaT -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $Script:ArqBackupT -Force -ErrorAction SilentlyContinue
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($Script:SubDohT, $false)
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($Script:SubPoliticaT, $false)
    }

    function Get-AdaptadorPadrao {
        # 11: tudo do DHCP; 12: tudo fixo; 13: IPv4 fixo e IPv6 do DHCP; 14: IPv4 do DHCP e IPv6 fixo. Todos com IPv6.
        # ipv4Dhcp/ipv6Dhcp: o que o "DHCP" entrega se a familia voltar ao automatico.
        return @(
            @{ indice = 11; guid = $Script:G1; nome = 'Ethernet'; descricao = 'Intel(R) Ethernet Connection'; ipv4 = @('192.168.0.1'); ipv6 = @('fd00::1'); ipv4Automatico = $true; ipv6Automatico = $true },
            @{ indice = 12; guid = $Script:G2; nome = 'Wi-Fi'; descricao = 'Realtek Wi-Fi'; ipv4 = @('10.0.0.53', '10.0.0.54'); ipv6 = @('2001:db8::53'); ipv4Automatico = $false; ipv6Automatico = $false },
            @{ indice = 13; guid = $Script:G3; nome = 'Ethernet 2'; descricao = 'Realtek PCIe GbE'; ipv4 = @('192.168.1.10'); ipv6 = @('fd00::2'); ipv4Automatico = $false; ipv6Automatico = $true; ipv4Dhcp = @('192.168.1.1') },
            @{ indice = 14; guid = $Script:G4; nome = 'Ethernet 3'; descricao = 'USB Ethernet'; ipv4 = @('192.168.2.1'); ipv6 = @('2001:db8::64'); ipv4Automatico = $true; ipv6Automatico = $false; ipv6Dhcp = @('fd00::3') }
        )
    }

    function Read-EstadoT { return @((Get-Content -LiteralPath $Script:ArqEstadoT -Raw -Encoding UTF8 | ConvertFrom-Json).adaptadores) }
    function Read-BackupT { return (Get-Content -LiteralPath $Script:ArqBackupT -Raw -Encoding UTF8 | ConvertFrom-Json) }
    function Write-EstadoT {
        param($Adaptadores)
        [IO.File]::WriteAllText($Script:ArqEstadoT, ((@{ adaptadores = @($Adaptadores) }) | ConvertTo-Json -Depth 6), $Script:Utf8)
    }
    function Write-BackupT {
        param([string]$Texto)
        New-Item -ItemType Directory -Path (Split-Path -Parent $Script:ArqBackupT) -Force | Out-Null
        [IO.File]::WriteAllText($Script:ArqBackupT, $Texto, $Script:Utf8)
    }
    function Get-BytesBackupT { return [Convert]::ToBase64String([IO.File]::ReadAllBytes($Script:ArqBackupT)) }
    function Format-AdaptadorT {
        param($A)
        return ('{0}|{1}|{2}|{3}|{4}|{5}' -f $A.indice, $A.guid, (@($A.ipv4) -join ','), (@($A.ipv6) -join ','), [bool]$A.ipv4Automatico, [bool]$A.ipv6Automatico)
    }
    function Get-DohT {
        # Valores da chave DoH de teste ($null se ela nao existe); lido pelo .NET (nome IPv6 tem ':').
        param([string]$Guid, [string]$Ip, [string]$Familia = 'Doh')
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$Script:SubDohT\InterfaceSpecificParameters\$Guid\DohInterfaceSettings\$Familia\$Ip")
        if ($null -eq $k) { return $null }
        try { return @{ DohFlags = $k.GetValue('DohFlags'); DohTemplate = $k.GetValue('DohTemplate') } } finally { $k.Dispose() }
    }
    function New-DohT {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param([string]$Guid, [string]$Ip, [string]$Familia = 'Doh', [string]$Modelo = '')
        $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("$Script:SubDohT\InterfaceSpecificParameters\$Guid\DohInterfaceSettings\$Familia\$Ip")
        if ($Modelo -ne '') { $k.SetValue('DohTemplate', $Modelo, [Microsoft.Win32.RegistryValueKind]::String) }
        $k.Dispose()
    }
    function Set-PoliticaT {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param([int]$Valor)
        $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("$Script:SubPoliticaT\Microsoft\Windows NT\DNSClient")
        $k.SetValue('DoHPolicy', $Valor, [Microsoft.Win32.RegistryValueKind]::DWord)
        $k.Dispose()
    }
    function Invoke-DnsSeguroT {
        param([string]$Provedor, $Sim)
        return (Invoke-Rede 'dnsSeguro' @{ provedor = $Provedor; confirmado = $true; simular = $Sim })
    }
    function Test-EstadoOriginalT {
        # O estado falso voltou exatamente aos adaptadores padrao?
        $orig = @(Get-AdaptadorPadrao)
        $estado = @(Read-EstadoT)
        $estado.Count | Should -Be $orig.Count
        for ($i = 0; $i -lt $orig.Count; $i++) { Format-AdaptadorT $estado[$i] | Should -Be (Format-AdaptadorT $orig[$i]) }
    }
}

AfterAll {
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($Script:SubDohT, $false)
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($Script:SubPoliticaT, $false)
    Remove-Item -LiteralPath $Script:BaseT -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'rede.ps1: funcoes puras' {
    It 'Get-FamiliaIp: <ip> -> "<esperado>"' -ForEach @(
        @{ ip = '1.1.1.1'; esperado = 'IPv4' }
        @{ ip = '149.112.112.112'; esperado = 'IPv4' }
        @{ ip = '2606:4700:4700::1111'; esperado = 'IPv6' }
        @{ ip = '2620:fe::fe'; esperado = 'IPv6' }
        @{ ip = '::ffff:1.2.3.4'; esperado = 'IPv6' }
        @{ ip = '999.1.1.1'; esperado = '' }
        @{ ip = '1.1'; esperado = '' }
        @{ ip = '1.1.1.1\x'; esperado = '' }
        @{ ip = '..\x'; esperado = '' }
        @{ ip = 'fe80::1%12'; esperado = '' }
        @{ ip = 'cafe'; esperado = '' }
        @{ ip = ''; esperado = '' }
    ) {
        [string](Get-FamiliaIp $ip) | Should -Be $esperado
    }

    It 'Get-SubchaveDoh valido: <familia>\<ip>' -ForEach @(
        @{ familia = 'Doh'; ip = '1.1.1.1' }
        @{ familia = 'Doh6'; ip = '2606:4700:4700::1111' }
    ) {
        $s = Get-SubchaveDoh '{11111111-1111-1111-1111-111111111111}' $familia $ip $true
        $s | Should -Be ('Software\NexTuneTeste\Dnscache\InterfaceSpecificParameters\{11111111-1111-1111-1111-111111111111}\DohInterfaceSettings\' + $familia + '\' + $ip)
        Get-SubchaveDoh '{11111111-1111-1111-1111-111111111111}' $familia $ip $false | Should -Match '^SYSTEM\\CurrentControlSet\\Services\\Dnscache\\InterfaceSpecificParameters\\'
    }

    It 'Get-SubchaveDoh recusa guid <guid>, familia <familia>, ip <ip>' -ForEach @(
        @{ guid = '..\x'; familia = 'Doh'; ip = '1.1.1.1' }
        @{ guid = '11111111-1111-1111-1111-111111111111'; familia = 'Doh'; ip = '1.1.1.1' }
        @{ guid = '{11111111-1111-1111-1111-111111111111}\..'; familia = 'Doh'; ip = '1.1.1.1' }
        @{ guid = '{11111111-1111-1111-1111-111111111111}'; familia = 'Doh\..'; ip = '1.1.1.1' }
        @{ guid = '{11111111-1111-1111-1111-111111111111}'; familia = 'doh'; ip = '1.1.1.1' }
        @{ guid = '{11111111-1111-1111-1111-111111111111}'; familia = 'Doh'; ip = '1.1.1.1\x' }
        @{ guid = '{11111111-1111-1111-1111-111111111111}'; familia = 'Doh'; ip = '2606:4700:4700::1111' }
        @{ guid = '{11111111-1111-1111-1111-111111111111}'; familia = 'Doh6'; ip = '1.1.1.1' }
        @{ guid = '{11111111-1111-1111-1111-111111111111}'; familia = 'Doh'; ip = '' }
    ) {
        [string](Get-SubchaveDoh $guid $familia $ip $true) | Should -Be ''
    }
}

Describe 'rede.ps1: estado' {
    BeforeEach { Reset-RedeTeste }

    It 'todos do DHCP: automatico; lista os adaptadores com dns (sem os fec0 padrao) e automatico' {
        $sim = @{ build = 22631; adaptadores = @(
                @{ indice = 11; guid = $Script:G1; nome = 'Ethernet'; descricao = 'Intel'; ipv4 = @('192.168.0.1'); ipv6 = @('fec0:0:0:ffff::1', 'fec0:0:0:ffff::2', 'fec0:0:0:ffff::3'); ipv4Automatico = $true; ipv6Automatico = $true },
                @{ indice = 12; guid = $Script:G2; nome = 'Wi-Fi'; descricao = 'Realtek'; ipv4 = @('10.0.0.1'); ipv6 = @('fd00::1'); ipv4Automatico = $true; ipv6Automatico = $true }) }
        $r = Invoke-Rede 'estado' @{ simular = $sim }
        $r.ok | Should -BeTrue
        $r.dados.provedor | Should -Be 'automatico'
        $lista = @($r.dados.adaptadores)
        $lista.Count | Should -Be 2
        $lista[0].indice | Should -Be 11
        $lista[0].nome | Should -Be 'Ethernet'
        $lista[0].descricao | Should -Be 'Intel'
        (@($lista[0].dns) -join ',') | Should -Be '192.168.0.1'
        $lista[0].automatico | Should -BeTrue
        (@($lista[1].dns) -join ',') | Should -Be '10.0.0.1,fd00::1'
        $r.dados.temBackup | Should -BeFalse
    }

    It 'DHCP que entrega os servidores de um provedor continua automatico' {
        $sim = @{ adaptadores = @(@{ indice = 11; guid = $Script:G1; nome = 'Ethernet'; ipv4 = $Script:Cloudflare; ipv6 = $Script:Cloudflare6; ipv4Automatico = $true; ipv6Automatico = $true }) }
        (Invoke-Rede 'estado' @{ simular = $sim }).dados.provedor | Should -Be 'automatico'
    }

    It 'servidores fixos de um provedor nas duas familias (ou so IPv4 sem IPv6), em qualquer ordem: o provedor' {
        foreach ($caso in @(
                @{ v4 = $Script:Cloudflare; v6 = $Script:Cloudflare6; nome = 'cloudflare' },
                @{ v4 = $Script:Google; v6 = $Script:Google6; nome = 'google' },
                @{ v4 = $Script:Quad9; v6 = $Script:Quad96; nome = 'quad9' })) {
            $sim = @{ adaptadores = @(
                    @{ indice = 11; guid = $Script:G1; nome = 'Ethernet'; ipv4 = $caso.v4; ipv6 = @($caso.v6[1], $caso.v6[0]); ipv4Automatico = $false; ipv6Automatico = $false },
                    @{ indice = 12; guid = $Script:G2; nome = 'Wi-Fi'; ipv4 = @($caso.v4[1], $caso.v4[0]); ipv6 = @(); ipv4Automatico = $false; ipv6Automatico = $true; temIpv6 = $false }) }
            (Invoke-Rede 'estado' @{ simular = $sim }).dados.provedor | Should -Be $caso.nome
        }
    }

    It 'adaptador com IPv6 que ainda usa o IPv6 do roteador nao conta como provedor' {
        $sim = @{ adaptadores = @(@{ indice = 11; guid = $Script:G1; nome = 'Ethernet'; ipv4 = $Script:Cloudflare; ipv6 = @('fd00::1'); ipv4Automatico = $false; ipv6Automatico = $true }) }
        (Invoke-Rede 'estado' @{ simular = $sim }).dados.provedor | Should -Be 'outro'
    }

    It 'servidores fixos de fora, provedores diferentes, mistura com DHCP ou so um servidor do provedor: outro' {
        $cf = @{ indice = 11; guid = $Script:G1; nome = 'Ethernet'; ipv4 = $Script:Cloudflare; ipv6 = @(); ipv4Automatico = $false; ipv6Automatico = $true; temIpv6 = $false }
        $fora = @{ indice = 12; guid = $Script:G2; nome = 'Wi-Fi'; ipv4 = @('10.0.0.53'); ipv6 = @(); ipv4Automatico = $false; ipv6Automatico = $true; temIpv6 = $false }
        $gg = @{ indice = 12; guid = $Script:G2; nome = 'Wi-Fi'; ipv4 = $Script:Google; ipv6 = @(); ipv4Automatico = $false; ipv6Automatico = $true; temIpv6 = $false }
        $dhcp = @{ indice = 12; guid = $Script:G2; nome = 'Wi-Fi'; ipv4 = @('10.0.0.1'); ipv6 = @(); ipv4Automatico = $true; ipv6Automatico = $true; temIpv6 = $false }
        $meio = @{ indice = 11; guid = $Script:G1; nome = 'Ethernet'; ipv4 = @('1.1.1.1'); ipv6 = @(); ipv4Automatico = $false; ipv6Automatico = $true; temIpv6 = $false }
        (Invoke-Rede 'estado' @{ simular = @{ adaptadores = @($cf, $fora) } }).dados.provedor | Should -Be 'outro'
        (Invoke-Rede 'estado' @{ simular = @{ adaptadores = @($cf, $gg) } }).dados.provedor | Should -Be 'outro'
        (Invoke-Rede 'estado' @{ simular = @{ adaptadores = @($cf, $dhcp) } }).dados.provedor | Should -Be 'outro'
        (Invoke-Rede 'estado' @{ simular = @{ adaptadores = @($meio) } }).dados.provedor | Should -Be 'outro'
    }

    It 'dohDisponivel segue so o build; bloqueadoPorPolitica segue a DoHPolicy; temBackup segue o arquivo de backup' {
        $r = Invoke-Rede 'estado' @{ simular = @{ build = 19045 } }
        $r.dados.dohDisponivel | Should -BeFalse
        $r.dados.bloqueadoPorPolitica | Should -BeFalse
        (Invoke-Rede 'estado' @{ simular = @{ build = 22000 } }).dados.dohDisponivel | Should -BeTrue
        Set-PoliticaT 2
        (Invoke-Rede 'estado' @{ simular = @{ build = 22631 } }).dados.bloqueadoPorPolitica | Should -BeFalse
        Set-PoliticaT 1
        $r = Invoke-Rede 'estado' @{ simular = @{ build = 22631 } }
        $r.dados.dohDisponivel | Should -BeTrue
        $r.dados.bloqueadoPorPolitica | Should -BeTrue
        Write-BackupT '{}'
        (Invoke-Rede 'estado' @{ simular = @{ build = 22631 } }).dados.temBackup | Should -BeTrue
    }

    It 'acao desconhecida falha' {
        (Invoke-Rede 'apagar').ok | Should -BeFalse
    }
}

Describe 'rede.ps1: limparDns' {
    BeforeEach { Reset-RedeTeste }

    It 'roda o ipconfig /flushdns pelo caminho absoluto (marcador) e devolve ok' {
        $r = Invoke-Rede 'limparDns'
        $r.ok | Should -BeTrue
        $r.dados.ok | Should -BeTrue
        $m = Join-Path $Script:PastaT 'limparDns.txt'
        Test-Path -LiteralPath $m | Should -BeTrue
        (Get-Content -LiteralPath $m -Raw) | Should -Match ([regex]::Escape((Join-Path $env:windir 'System32\ipconfig.exe') + ' /flushdns'))
    }
    It 'codigo de saida diferente de zero devolve ok falso' {
        (Invoke-Rede 'limparDns' @{ simular = @{ codigo = 1 } }).dados.ok | Should -BeFalse
    }
}

Describe 'rede.ps1: redefinir' {
    BeforeEach { Reset-RedeTeste }

    It 'exige confirmado:true estrito' {
        foreach ($p in @(@{}, @{ confirmado = 'true' }, @{ confirmado = 1 })) {
            $r = Invoke-Rede 'redefinir' $p
            $r.ok | Should -BeFalse
            $r.erro | Should -Match 'confirma'
        }
        Test-Path -LiteralPath (Join-Path $Script:PastaT 'redefinir.txt') | Should -BeFalse
    }
    It 'roda netsh winsock reset e netsh int ip reset pelo caminho absoluto, avisa do IP fixo e pede reinicio' {
        $r = Invoke-Rede 'redefinir' @{ confirmado = $true }
        $r.ok | Should -BeTrue
        $r.dados.precisaReiniciar | Should -BeTrue
        $r.dados.detalhe | Should -Match 'Reinicie'
        $r.dados.detalhe | Should -Match 'IP fixo'
        $r.dados.detalhe | Should -Match 'DNS configurado à mão'
        $netsh = Join-Path $env:windir 'System32\netsh.exe'
        $linhas = @(Get-Content -LiteralPath (Join-Path $Script:PastaT 'redefinir.txt'))
        $linhas.Count | Should -Be 2
        $linhas[0] | Should -Be "$netsh winsock reset"
        $linhas[1] | Should -Be "$netsh int ip reset"
    }
    It 'int ip reset com codigo diferente de zero: frase branda no detalhe e ainda pede reinicio' {
        $r = Invoke-Rede 'redefinir' @{ confirmado = $true; simular = @{ netsh = @{ ip = 1 } } }
        $r.ok | Should -BeTrue
        $r.dados.precisaReiniciar | Should -BeTrue
        $r.dados.detalhe | Should -Match 'int ip reset'
        $r.dados.detalhe | Should -Match 'código 1'
        $r.dados.detalhe | Should -Match 'inofensivo'
        $r.dados.detalhe | Should -Not -Match 'winsock'
    }
    It 'winsock reset com codigo diferente de zero entra no detalhe sem a frase branda' {
        $r = Invoke-Rede 'redefinir' @{ confirmado = $true; simular = @{ netsh = @{ winsock = 5 } } }
        $r.dados.precisaReiniciar | Should -BeTrue
        $r.dados.detalhe | Should -Match 'winsock reset'
        $r.dados.detalhe | Should -Match 'código 5'
        $r.dados.detalhe | Should -Not -Match 'inofensivo'
    }
}

Describe 'rede.ps1: dnsSeguro' {
    BeforeEach {
        Reset-RedeTeste
        $Script:Sim = @{ build = 22631; adaptadores = @(Get-AdaptadorPadrao) }
    }

    It 'exige confirmado:true estrito' {
        foreach ($c in @($null, 'true', 1)) {
            $p = @{ provedor = 'cloudflare'; simular = $Script:Sim }
            if ($null -ne $c) { $p.confirmado = $c }
            $r = Invoke-Rede 'dnsSeguro' $p
            $r.ok | Should -BeFalse
            $r.erro | Should -Match 'confirma'
        }
        Test-Path -LiteralPath $Script:ArqBackupT | Should -BeFalse
        Test-Path -LiteralPath $Script:ArqEstadoT | Should -BeFalse
    }

    It 'provedor invalido falha sem mexer em nada' {
        foreach ($pv in @('opendns', 'Cloudflare', '', 'adguard')) {
            $r = Invoke-DnsSeguroT $pv $Script:Sim
            $r.ok | Should -BeFalse
            $r.erro | Should -Match 'provedor'
        }
        (Invoke-Rede 'dnsSeguro' @{ confirmado = $true; simular = $Script:Sim }).ok | Should -BeFalse
        (Invoke-Rede 'dnsSeguro' @{ provedor = @('cloudflare'); confirmado = $true; simular = $Script:Sim }).ok | Should -BeFalse
        Test-Path -LiteralPath $Script:ArqBackupT | Should -BeFalse
        Test-Path -LiteralPath $Script:ArqEstadoT | Should -BeFalse
    }

    It 'Windows 10 recusa cloudflare, google e quad9 com mensagem clara' {
        foreach ($pv in @('cloudflare', 'google', 'quad9')) {
            $r = Invoke-DnsSeguroT $pv @{ build = 19045; adaptadores = @(Get-AdaptadorPadrao) }
            $r.ok | Should -BeFalse
            $r.erro | Should -Be 'DNS seguro precisa do Windows 11'
        }
        Test-Path -LiteralPath $Script:ArqBackupT | Should -BeFalse
        Test-Path -LiteralPath $Script:ArqEstadoT | Should -BeFalse
        Test-Path -LiteralPath "HKCU:\$Script:SubDohT" | Should -BeFalse
    }

    It 'Windows 10 aceita automatico (sem backup e sem restos de provedor: nada muda, todos mantidos)' {
        $r = Invoke-DnsSeguroT 'automatico' @{ build = 19045; adaptadores = @(Get-AdaptadorPadrao) }
        $r.ok | Should -BeTrue
        $r.dados.provedor | Should -Be 'automatico'
        @($r.dados.adaptadores).Count | Should -Be 4
        foreach ($x in @($r.dados.adaptadores)) {
            $x.ok | Should -BeTrue
            $x.mantido | Should -BeTrue
            $x.revertido | Should -BeFalse
        }
    }

    It 'politica DoHPolicy = 1 recusa os provedores, aceita automatico e nunca apaga a politica' {
        Set-PoliticaT 1
        foreach ($pv in @('cloudflare', 'google', 'quad9')) {
            $r = Invoke-DnsSeguroT $pv $Script:Sim
            $r.ok | Should -BeFalse
            $r.erro | Should -Be 'DNS seguro bloqueado por uma política do Windows'
        }
        Test-Path -LiteralPath $Script:ArqBackupT | Should -BeFalse
        Test-Path -LiteralPath $Script:ArqEstadoT | Should -BeFalse
        (Invoke-DnsSeguroT 'automatico' $Script:Sim).ok | Should -BeTrue
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$Script:SubPoliticaT\Microsoft\Windows NT\DNSClient")
        try { $k.GetValue('DoHPolicy') | Should -Be 1 } finally { $k.Dispose() }
    }

    It 'grava o backup uma vez e exato antes da primeira troca; fixa IPv4 e IPv6 e cria Doh e Doh6' {
        $r = Invoke-DnsSeguroT 'cloudflare' $Script:Sim
        $r.ok | Should -BeTrue
        $r.dados.provedor | Should -Be 'cloudflare'
        $r.dados.PSObject.Properties.Name | Should -Not -Contain 'aviso'
        $res = @($r.dados.adaptadores)
        $res.Count | Should -Be 4
        foreach ($x in $res) {
            $x.ok | Should -BeTrue
            $x.erro | Should -BeNullOrEmpty
            $x.mantido | Should -BeFalse
            $x.revertido | Should -BeFalse
        }
        $res[0].indice | Should -Be 11
        $res[0].nome | Should -Be 'Ethernet'

        $b = Read-BackupT
        $b.versao | Should -Be 1
        $orig = @(Get-AdaptadorPadrao)
        @($b.adaptadores).Count | Should -Be 4
        for ($i = 0; $i -lt 4; $i++) { Format-AdaptadorT $b.adaptadores[$i] | Should -Be (Format-AdaptadorT $orig[$i]) }
        $b.adaptadores[1].nome | Should -Be 'Wi-Fi'
        (@($b.adaptadores[0].PSObject.Properties.Name) -join ',') | Should -Be 'indice,guid,nome,ipv4,ipv6,ipv4Automatico,ipv6Automatico'
        @($b.dohAdicionados).Count | Should -Be 16

        foreach ($a in Read-EstadoT) {
            (@($a.ipv4) -join ',') | Should -Be ($Script:Cloudflare -join ',')
            (@($a.ipv6) -join ',') | Should -Be ($Script:Cloudflare6 -join ',')
            $a.ipv4Automatico | Should -BeFalse
            $a.ipv6Automatico | Should -BeFalse
        }
        foreach ($g in $Script:Todos) {
            foreach ($ip in $Script:Cloudflare) {
                $k = Get-DohT $g $ip
                $k.DohFlags | Should -Be 2
                $k.DohTemplate | Should -Be 'https://cloudflare-dns.com/dns-query'
            }
            foreach ($ip in $Script:Cloudflare6) {
                $k = Get-DohT $g $ip 'Doh6'
                $k.DohFlags | Should -Be 2
                $k.DohTemplate | Should -Be 'https://cloudflare-dns.com/dns-query'
            }
        }
        $e = Invoke-Rede 'estado' @{ simular = @{ build = 22631 } }
        $e.dados.provedor | Should -Be 'cloudflare'
        $e.dados.temBackup | Should -BeTrue
    }

    It 'adaptador sem IPv6 recebe so o IPv4, sem Doh6, e ainda conta como o provedor' {
        $sim = @{ build = 22631; adaptadores = @(@{ indice = 15; guid = $Script:G5; nome = 'Ethernet 4'; ipv4 = @('192.168.5.1'); ipv6 = @(); ipv4Automatico = $true; ipv6Automatico = $true; temIpv6 = $false }) }
        $r = Invoke-DnsSeguroT 'quad9' $sim
        @($r.dados.adaptadores)[0].ok | Should -BeTrue
        $a = @(Read-EstadoT)[0]
        (@($a.ipv4) -join ',') | Should -Be ($Script:Quad9 -join ',')
        @($a.ipv6).Count | Should -Be 0
        $a.ipv6Automatico | Should -BeTrue
        Get-DohT $Script:G5 '9.9.9.9' | Should -Not -BeNullOrEmpty
        Get-DohT $Script:G5 '2620:fe::fe' 'Doh6' | Should -BeNullOrEmpty
        (Invoke-Rede 'estado' @{ simular = @{ build = 22631 } }).dados.provedor | Should -Be 'quad9'
    }

    It 'falha no IPv6 nao desfaz o IPv4 e aparece no erro do adaptador' {
        $sim = @{ build = 22631; adaptadores = @(Get-AdaptadorPadrao); falharIpv6Indice = 12 }
        $r = Invoke-DnsSeguroT 'cloudflare' $sim
        $x = @($r.dados.adaptadores | Where-Object { $_.indice -eq 12 })[0]
        $x.ok | Should -BeFalse
        $x.revertido | Should -BeFalse
        $x.erro | Should -Match 'IPv6'
        $a = @(Read-EstadoT)[1]
        (@($a.ipv4) -join ',') | Should -Be ($Script:Cloudflare -join ',')
        (@($a.ipv6) -join ',') | Should -Be '2001:db8::53'
        Get-DohT $Script:G2 '1.1.1.1' | Should -Not -BeNullOrEmpty
        Get-DohT $Script:G2 '2606:4700:4700::1111' 'Doh6' | Should -BeNullOrEmpty
        @($r.dados.adaptadores | Where-Object { $_.indice -ne 12 -and -not $_.ok }).Count | Should -Be 0
    }

    It 'segunda troca (outro provedor) nao sobrescreve o backup e troca as chaves DoH do NexTune' {
        (Invoke-DnsSeguroT 'cloudflare' $Script:Sim).ok | Should -BeTrue
        $antes = (Read-BackupT).adaptadores | ConvertTo-Json -Depth 5 -Compress
        $r = Invoke-DnsSeguroT 'google' $Script:Sim
        $r.ok | Should -BeTrue
        @($r.dados.adaptadores | Where-Object { -not $_.ok }).Count | Should -Be 0
        $b = Read-BackupT
        ($b.adaptadores | ConvertTo-Json -Depth 5 -Compress) | Should -Be $antes
        @($b.dohAdicionados).Count | Should -Be 16
        @($b.dohAdicionados | Where-Object { ($Script:Google + $Script:Google6) -notcontains $_.ip }).Count | Should -Be 0
        foreach ($g in $Script:Todos) {
            foreach ($ip in $Script:Cloudflare) { Get-DohT $g $ip | Should -BeNullOrEmpty }
            foreach ($ip in $Script:Cloudflare6) { Get-DohT $g $ip 'Doh6' | Should -BeNullOrEmpty }
            foreach ($ip in $Script:Google) { (Get-DohT $g $ip).DohTemplate | Should -Be 'https://dns.google/dns-query' }
            foreach ($ip in $Script:Google6) { (Get-DohT $g $ip 'Doh6').DohTemplate | Should -Be 'https://dns.google/dns-query' }
        }
        (Invoke-Rede 'estado' @{ simular = @{ build = 22631 } }).dados.provedor | Should -Be 'google'
    }

    It 'adaptador novo numa segunda troca entra no backup sem mexer nas entradas existentes' {
        (Invoke-DnsSeguroT 'cloudflare' $Script:Sim).ok | Should -BeTrue
        $antes = @((Read-BackupT).adaptadores) | ConvertTo-Json -Depth 5 -Compress
        $novo = [pscustomobject]@{ indice = 15; guid = $Script:G5; nome = 'Ethernet 4'; descricao = 'USB'; ipv4 = @('192.168.5.5'); ipv6 = @(); ipv4Automatico = $false; ipv6Automatico = $true; temIpv6 = $false }
        Write-EstadoT (@(Read-EstadoT) + $novo)
        (Invoke-DnsSeguroT 'google' $Script:Sim).ok | Should -BeTrue
        $b = @((Read-BackupT).adaptadores)
        $b.Count | Should -Be 5
        (@($b[0..3]) | ConvertTo-Json -Depth 5 -Compress) | Should -Be $antes
        Format-AdaptadorT $b[4] | Should -Be ('15|' + $Script:G5 + '|192.168.5.5||False|True')
        (Invoke-Rede 'estado' @{ simular = @{ build = 22631 } }).dados.provedor | Should -Be 'google'
    }

    It 'automatico restaura exatamente (fixos e DHCP, IPv4 e IPv6), remove o DoH do NexTune e apaga o backup' {
        (Invoke-DnsSeguroT 'cloudflare' $Script:Sim).ok | Should -BeTrue
        (Invoke-DnsSeguroT 'quad9' $Script:Sim).ok | Should -BeTrue
        $r = Invoke-DnsSeguroT 'automatico' $Script:Sim
        $r.ok | Should -BeTrue
        $r.dados.provedor | Should -Be 'automatico'
        @($r.dados.adaptadores).Count | Should -Be 4
        @($r.dados.adaptadores | Where-Object { -not $_.ok -or $_.mantido }).Count | Should -Be 0
        Test-EstadoOriginalT
        Test-Path -LiteralPath $Script:ArqBackupT | Should -BeFalse
        foreach ($g in $Script:Todos) {
            foreach ($ip in ($Script:Cloudflare + $Script:Quad9)) { Get-DohT $g $ip | Should -BeNullOrEmpty }
            foreach ($ip in ($Script:Cloudflare6 + $Script:Quad96)) { Get-DohT $g $ip 'Doh6' | Should -BeNullOrEmpty }
        }
        $e = Invoke-Rede 'estado' @{ simular = @{ build = 22631 } }
        $e.dados.provedor | Should -Be 'outro'
        $e.dados.temBackup | Should -BeFalse
    }

    It 'automatico remove so as chaves DoH que o NexTune criou, nunca as que ja existiam' {
        New-DohT $Script:G1 '1.1.1.1' 'Doh' 'https://exemplo.invalid/dns-query'
        New-DohT $Script:G1 '2606:4700:4700::1111' 'Doh6' 'https://exemplo.invalid/dns-query'
        New-DohT $Script:G2 '192.0.2.53'

        (Invoke-DnsSeguroT 'cloudflare' $Script:Sim).ok | Should -BeTrue
        $k = Get-DohT $Script:G1 '1.1.1.1'
        $k.DohTemplate | Should -Be 'https://exemplo.invalid/dns-query'
        $k.DohFlags | Should -BeNullOrEmpty
        $b = Read-BackupT
        @($b.dohAdicionados | Where-Object { $_.guid -eq $Script:G1 -and ($_.ip -eq '1.1.1.1' -or $_.ip -eq '2606:4700:4700::1111') }).Count | Should -Be 0
        @($b.dohAdicionados).Count | Should -Be 14

        (Invoke-DnsSeguroT 'automatico' $Script:Sim).ok | Should -BeTrue
        (Get-DohT $Script:G1 '1.1.1.1').DohTemplate | Should -Be 'https://exemplo.invalid/dns-query'
        (Get-DohT $Script:G1 '2606:4700:4700::1111' 'Doh6').DohTemplate | Should -Be 'https://exemplo.invalid/dns-query'
        Get-DohT $Script:G2 '192.0.2.53' | Should -Not -BeNullOrEmpty
        Get-DohT $Script:G1 '1.0.0.1' | Should -BeNullOrEmpty
        Get-DohT $Script:G2 '1.1.1.1' | Should -BeNullOrEmpty
        Test-Path -LiteralPath $Script:ArqBackupT | Should -BeFalse
    }

    It 'automatico sem backup volta ao DHCP so as familias com servidores de provedor; o resto fica mantido' {
        # 15: resto do Sophia (IPv4 da Cloudflare fixo, IPv6 manual de fora); 16: IPv6 do Google fixo, IPv4 do DHCP.
        $sim = @{ build = 22631; adaptadores = @(Get-AdaptadorPadrao) + @(
                @{ indice = 15; guid = $Script:G5; nome = 'Ethernet 4'; ipv4 = $Script:Cloudflare; ipv6 = @('2001:db8::99'); ipv4Automatico = $false; ipv6Automatico = $false; ipv4Dhcp = @('192.168.5.1') },
                @{ indice = 16; guid = '{66666666-6666-6666-6666-666666666666}'; nome = 'Ethernet 5'; ipv4 = @('192.168.6.1'); ipv6 = $Script:Google6; ipv4Automatico = $true; ipv6Automatico = $false; ipv6Dhcp = @('fd00::6') }) }
        $r = Invoke-DnsSeguroT 'automatico' $sim
        $r.ok | Should -BeTrue
        $res = @($r.dados.adaptadores)
        $res.Count | Should -Be 6
        foreach ($x in $res) { $x.ok | Should -BeTrue; $x.erro | Should -BeNullOrEmpty }
        (@($res | Where-Object { $_.mantido } | ForEach-Object { $_.indice }) -join ',') | Should -Be '11,12,13,14'
        $estado = @(Read-EstadoT)
        $orig = @(Get-AdaptadorPadrao)
        for ($i = 0; $i -lt 4; $i++) { Format-AdaptadorT $estado[$i] | Should -Be (Format-AdaptadorT $orig[$i]) }
        (@($estado[1].ipv4) -join ',') | Should -Be '10.0.0.53,10.0.0.54'
        Format-AdaptadorT $estado[4] | Should -Be ('15|' + $Script:G5 + '|192.168.5.1|2001:db8::99|True|False')
        Format-AdaptadorT $estado[5] | Should -Be '16|{66666666-6666-6666-6666-666666666666}|192.168.6.1|fd00::6|True|True'
        Test-Path -LiteralPath $Script:ArqBackupT | Should -BeFalse
    }

    It 'automatico com adaptador sumido: os outros voltam e o sumido fica no backup com as chaves dele' {
        (Invoke-DnsSeguroT 'cloudflare' $Script:Sim).ok | Should -BeTrue
        Write-EstadoT @(Read-EstadoT | Where-Object { $_.indice -ne 14 })
        $r = Invoke-DnsSeguroT 'automatico' $Script:Sim
        $r.ok | Should -BeTrue
        $sumido = @($r.dados.adaptadores | Where-Object { $_.indice -eq 14 })[0]
        $sumido.ok | Should -BeFalse
        $sumido.erro | Should -Match 'não foi encontrado'
        @($r.dados.adaptadores | Where-Object { $_.indice -ne 14 -and -not $_.ok }).Count | Should -Be 0
        $b = Read-BackupT
        (@($b.adaptadores | ForEach-Object { $_.indice }) -join ',') | Should -Be '14'
        @($b.dohAdicionados).Count | Should -Be 4
        @($b.dohAdicionados | Where-Object { $_.guid -ne $Script:G4 }).Count | Should -Be 0
        Get-DohT $Script:G4 '1.1.1.1' | Should -Not -BeNullOrEmpty
        Get-DohT $Script:G4 '2606:4700:4700::1111' 'Doh6' | Should -Not -BeNullOrEmpty
        Get-DohT $Script:G1 '1.1.1.1' | Should -BeNullOrEmpty
        $orig = @(Get-AdaptadorPadrao)
        $estado = @(Read-EstadoT)
        for ($i = 0; $i -lt 3; $i++) { Format-AdaptadorT $estado[$i] | Should -Be (Format-AdaptadorT $orig[$i]) }
    }

    It 'um adaptador que falha nao impede os outros e informa o erro' {
        $sim = @{ build = 22631; adaptadores = @(Get-AdaptadorPadrao); falharIndice = 12 }
        $r = Invoke-DnsSeguroT 'cloudflare' $sim
        $r.ok | Should -BeTrue
        $res = @($r.dados.adaptadores)
        $res.Count | Should -Be 4
        $falhou = @($res | Where-Object { $_.indice -eq 12 })[0]
        $falhou.ok | Should -BeFalse
        $falhou.revertido | Should -BeFalse
        $falhou.erro | Should -Match 'falha simulada'
        foreach ($x in @($res | Where-Object { $_.indice -ne 12 })) {
            $x.ok | Should -BeTrue
            $x.erro | Should -BeNullOrEmpty
        }
        $orig = @(Get-AdaptadorPadrao)
        $estado = @(Read-EstadoT)
        Format-AdaptadorT $estado[1] | Should -Be (Format-AdaptadorT $orig[1])
        (@($estado[0].ipv4) -join ',') | Should -Be ($Script:Cloudflare -join ',')
        Get-DohT $Script:G1 '1.1.1.1' | Should -Not -BeNullOrEmpty
        Get-DohT $Script:G2 '1.1.1.1' | Should -BeNullOrEmpty
        @((Read-BackupT).adaptadores).Count | Should -Be 4

        # restaurar com o mesmo adaptador falhando: os outros voltam e o backup fica so com ele
        $r = Invoke-DnsSeguroT 'automatico' $sim
        $r.ok | Should -BeTrue
        @($r.dados.adaptadores | Where-Object { -not $_.ok }).Count | Should -Be 1
        $b = Read-BackupT
        (@($b.adaptadores | ForEach-Object { $_.indice }) -join ',') | Should -Be '12'
        @($b.dohAdicionados).Count | Should -Be 0
        Test-EstadoOriginalT

        # sem a falha, o backup restante e consumido e apagado
        $r = Invoke-DnsSeguroT 'automatico' $Script:Sim
        @($r.dados.adaptadores | Where-Object { -not $_.ok }).Count | Should -Be 0
        Test-Path -LiteralPath $Script:ArqBackupT | Should -BeFalse
    }

    It 'resolvia antes e parou depois de duas tentativas: todos os trocados voltam (revertido) e o backup some' {
        $sim = @{ build = 22631; adaptadores = @(Get-AdaptadorPadrao); resolve = @{ antes = $true; depois = $false } }
        $r = Invoke-DnsSeguroT 'cloudflare' $sim
        $r.ok | Should -BeTrue
        foreach ($x in @($r.dados.adaptadores)) {
            $x.ok | Should -BeFalse
            $x.revertido | Should -BeTrue
            $x.erro | Should -Match 'não respondeu nesta rede'
        }
        Test-EstadoOriginalT
        Test-Path -LiteralPath $Script:ArqBackupT | Should -BeFalse
        foreach ($g in $Script:Todos) {
            Get-DohT $g '1.1.1.1' | Should -BeNullOrEmpty
            Get-DohT $g '2606:4700:4700::1111' 'Doh6' | Should -BeNullOrEmpty
        }
    }

    It 'conferencia da resolucao: segunda tentativa que responde mantem; sem resolver antes nao desfaz' {
        $r = Invoke-DnsSeguroT 'cloudflare' @{ build = 22631; adaptadores = @(Get-AdaptadorPadrao); resolve = @{ antes = $true; depois = @($false, $true) } }
        @($r.dados.adaptadores | Where-Object { -not $_.ok -or $_.revertido }).Count | Should -Be 0
        Reset-RedeTeste
        $r = Invoke-DnsSeguroT 'cloudflare' @{ build = 22631; adaptadores = @(Get-AdaptadorPadrao); resolve = @{ antes = $false; depois = $false } }
        @($r.dados.adaptadores | Where-Object { -not $_.ok -or $_.revertido }).Count | Should -Be 0
        (Invoke-Rede 'estado' @{ simular = @{ build = 22631 } }).dados.provedor | Should -Be 'cloudflare'
    }

    It 'falha ao gravar o DoH devolve o adaptador ao anterior (revertido) e nao deixa chave nem entrada dele' {
        $sim = @{ build = 22631; adaptadores = @(Get-AdaptadorPadrao); falharDohIndice = 12 }
        $r = Invoke-DnsSeguroT 'cloudflare' $sim
        $r.ok | Should -BeTrue
        $x = @($r.dados.adaptadores | Where-Object { $_.indice -eq 12 })[0]
        $x.ok | Should -BeFalse
        $x.revertido | Should -BeTrue
        $x.erro | Should -Match 'DNS seguro'
        $x.erro | Should -Match 'voltou'
        foreach ($o in @($r.dados.adaptadores | Where-Object { $_.indice -ne 12 })) {
            $o.ok | Should -BeTrue
            $o.revertido | Should -BeFalse
        }
        Format-AdaptadorT @(Read-EstadoT)[1] | Should -Be (Format-AdaptadorT @(Get-AdaptadorPadrao)[1])
        Get-DohT $Script:G2 '1.1.1.1' | Should -BeNullOrEmpty
        Get-DohT $Script:G2 '2606:4700:4700::1111' 'Doh6' | Should -BeNullOrEmpty
        $b = Read-BackupT
        @($b.adaptadores | Where-Object { $_.guid -eq $Script:G2 }).Count | Should -Be 0
        @($b.dohAdicionados | Where-Object { $_.guid -eq $Script:G2 }).Count | Should -Be 0
        @($b.adaptadores).Count | Should -Be 3
    }

    It 'rota em uso por uma interface fora da lista (VPN) gera aviso; rota por um adaptador da lista nao' {
        $r = Invoke-DnsSeguroT 'cloudflare' @{ build = 22631; adaptadores = @(Get-AdaptadorPadrao); rota = @{ indice = 99; nome = 'VPN da empresa' } }
        $r.ok | Should -BeTrue
        $r.dados.aviso | Should -Match 'VPN da empresa'
        $r.dados.aviso | Should -Match 'não foi alterada'
        Reset-RedeTeste
        $r = Invoke-DnsSeguroT 'cloudflare' @{ build = 22631; adaptadores = @(Get-AdaptadorPadrao); rota = @{ indice = 11; nome = 'Ethernet' } }
        $r.dados.PSObject.Properties.Name | Should -Not -Contain 'aviso'
    }

    It 'backup em formato inesperado (<caso>) recusa a acao e fica identico' -ForEach @(
        @{ caso = 'nao e JSON'; texto = 'isto não é json {' }
        @{ caso = 'lista na raiz'; texto = '[]' }
        @{ caso = 'objeto vazio'; texto = '{}' }
        @{ caso = 'versao 2'; texto = '{"versao":2,"adaptadores":[],"dohAdicionados":[]}' }
        @{ caso = 'sem versao'; texto = '{"adaptadores":[],"dohAdicionados":[]}' }
        @{ caso = 'adaptadores nao e lista'; texto = '{"versao":1,"adaptadores":{},"dohAdicionados":[]}' }
        @{ caso = 'dohAdicionados nao e lista'; texto = '{"versao":1,"adaptadores":[],"dohAdicionados":"x"}' }
    ) {
        Write-BackupT $texto
        $antes = Get-BytesBackupT
        foreach ($pv in @('cloudflare', 'automatico')) {
            $r = Invoke-DnsSeguroT $pv $Script:Sim
            $r.ok | Should -BeFalse
            $r.erro | Should -Match 'backup do DNS'
        }
        Get-BytesBackupT | Should -Be $antes
        Test-Path -LiteralPath $Script:ArqEstadoT | Should -BeFalse
    }

    It 'backup adulterado (<caso>) e recusado e a chave vizinha sobrevive' -ForEach @(
        @{ caso = 'guid ..\x no adaptador'; guidAd = '..\\x'; guid = '{11111111-1111-1111-1111-111111111111}'; familia = 'Doh'; ip = '1.1.1.1' }
        @{ caso = 'guid ..\x na chave DoH'; guidAd = '{11111111-1111-1111-1111-111111111111}'; guid = '..\\x'; familia = 'Doh'; ip = '1.1.1.1' }
        @{ caso = 'familia Doh\..'; guidAd = '{11111111-1111-1111-1111-111111111111}'; guid = '{11111111-1111-1111-1111-111111111111}'; familia = 'Doh\\..'; ip = '1.1.1.1' }
        @{ caso = 'ip 1.1.1.1\x'; guidAd = '{11111111-1111-1111-1111-111111111111}'; guid = '{11111111-1111-1111-1111-111111111111}'; familia = 'Doh'; ip = '1.1.1.1\\x' }
    ) {
        New-DohT $Script:G1 '1.1.1.1' 'Doh' 'https://vizinha.invalid/dns-query'
        New-DohT $Script:G1 'x'
        Write-BackupT ('{"versao":1,"data":"2026-11-23T00:00:00","adaptadores":[{"indice":11,"guid":"' + $guidAd +
            '","nome":"Ethernet","ipv4":["192.168.0.1"],"ipv6":[],"ipv4Automatico":true,"ipv6Automatico":true}],' +
            '"dohAdicionados":[{"guid":"' + $guid + '","familia":"' + $familia + '","ip":"' + $ip + '"}]}')
        $antes = Get-BytesBackupT
        $r = Invoke-DnsSeguroT 'automatico' $Script:Sim
        $r.ok | Should -BeFalse
        $r.erro | Should -Match 'formato inesperado'
        (Invoke-DnsSeguroT 'google' $Script:Sim).ok | Should -BeFalse
        Get-BytesBackupT | Should -Be $antes
        (Get-DohT $Script:G1 '1.1.1.1').DohTemplate | Should -Be 'https://vizinha.invalid/dns-query'
        Get-DohT $Script:G1 'x' | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $Script:ArqEstadoT | Should -BeFalse
    }
}
