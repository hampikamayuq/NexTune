BeforeAll {
    . "$PSScriptRoot\..\common.ps1"
    . "$PSScriptRoot\..\rede.ps1"
    . "$PSScriptRoot\_helpers.ps1"
    $Script:BaseT = Join-Path $env:TEMP 'NexTuneTeste'
    $Script:PastaT = Join-Path $Script:BaseT 'rede'
    $Script:ArqEstadoT = Join-Path $Script:PastaT 'adaptadores.json'
    $Script:ArqBackupT = Join-Path (Join-Path $Script:BaseT 'Backups') 'dns.json'
    $Script:RaizDohT = 'HKCU:\Software\NexTuneTeste\Dnscache'
    $Script:G1 = '{11111111-1111-1111-1111-111111111111}'
    $Script:G2 = '{22222222-2222-2222-2222-222222222222}'
    $Script:G3 = '{33333333-3333-3333-3333-333333333333}'
    $Script:G4 = '{44444444-4444-4444-4444-444444444444}'
    $Script:Cloudflare = @('1.1.1.1', '1.0.0.1')
    $Script:Google = @('8.8.8.8', '8.8.4.4')
    $Script:Quad9 = @('9.9.9.9', '149.112.112.112')

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
        Remove-Item -LiteralPath $Script:RaizDohT -Recurse -Force -ErrorAction SilentlyContinue
    }

    function Get-AdaptadorPadrao {
        # 11: tudo do DHCP; 12: tudo fixo; 13: IPv4 fixo e IPv6 do DHCP; 14: IPv4 do DHCP e IPv6 fixo.
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
    function Format-AdaptadorT {
        param($A)
        return ('{0}|{1}|{2}|{3}|{4}|{5}' -f $A.indice, $A.guid, (@($A.ipv4) -join ','), (@($A.ipv6) -join ','), [bool]$A.ipv4Automatico, [bool]$A.ipv6Automatico)
    }
    function Get-ChaveDohT {
        param([string]$Guid, [string]$Ip, [string]$Familia = 'Doh')
        return "$Script:RaizDohT\InterfaceSpecificParameters\$Guid\DohInterfaceSettings\$Familia\$Ip"
    }
    function Invoke-DnsSeguroT {
        param([string]$Provedor, $Sim)
        return (Invoke-Rede 'dnsSeguro' @{ provedor = $Provedor; confirmado = $true; simular = $Sim })
    }
}

AfterAll {
    Remove-Item -LiteralPath $Script:RaizDohT -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Script:BaseT -Recurse -Force -ErrorAction SilentlyContinue
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
        $sim = @{ adaptadores = @(@{ indice = 11; guid = $Script:G1; nome = 'Ethernet'; ipv4 = $Script:Cloudflare; ipv6 = @(); ipv4Automatico = $true; ipv6Automatico = $true }) }
        (Invoke-Rede 'estado' @{ simular = $sim }).dados.provedor | Should -Be 'automatico'
    }

    It 'servidores IPv4 fixos de um provedor em todos os adaptadores, em qualquer ordem: o provedor' {
        foreach ($caso in @(@{ ips = $Script:Cloudflare; nome = 'cloudflare' }, @{ ips = $Script:Google; nome = 'google' }, @{ ips = $Script:Quad9; nome = 'quad9' })) {
            $sim = @{ adaptadores = @(
                    @{ indice = 11; guid = $Script:G1; nome = 'Ethernet'; ipv4 = $caso.ips; ipv6 = @(); ipv4Automatico = $false; ipv6Automatico = $true },
                    @{ indice = 12; guid = $Script:G2; nome = 'Wi-Fi'; ipv4 = @($caso.ips[1], $caso.ips[0]); ipv6 = @('fd00::1'); ipv4Automatico = $false; ipv6Automatico = $true }) }
            (Invoke-Rede 'estado' @{ simular = $sim }).dados.provedor | Should -Be $caso.nome
        }
    }

    It 'servidores fixos de fora, provedores diferentes, mistura com DHCP ou so um servidor do provedor: outro' {
        $cf = @{ indice = 11; guid = $Script:G1; nome = 'Ethernet'; ipv4 = $Script:Cloudflare; ipv6 = @(); ipv4Automatico = $false; ipv6Automatico = $true }
        $fora = @{ indice = 12; guid = $Script:G2; nome = 'Wi-Fi'; ipv4 = @('10.0.0.53'); ipv6 = @(); ipv4Automatico = $false; ipv6Automatico = $true }
        $gg = @{ indice = 12; guid = $Script:G2; nome = 'Wi-Fi'; ipv4 = $Script:Google; ipv6 = @(); ipv4Automatico = $false; ipv6Automatico = $true }
        $dhcp = @{ indice = 12; guid = $Script:G2; nome = 'Wi-Fi'; ipv4 = @('10.0.0.1'); ipv6 = @(); ipv4Automatico = $true; ipv6Automatico = $true }
        $meio = @{ indice = 11; guid = $Script:G1; nome = 'Ethernet'; ipv4 = @('1.1.1.1'); ipv6 = @(); ipv4Automatico = $false; ipv6Automatico = $true }
        (Invoke-Rede 'estado' @{ simular = @{ adaptadores = @($cf, $fora) } }).dados.provedor | Should -Be 'outro'
        (Invoke-Rede 'estado' @{ simular = @{ adaptadores = @($cf, $gg) } }).dados.provedor | Should -Be 'outro'
        (Invoke-Rede 'estado' @{ simular = @{ adaptadores = @($cf, $dhcp) } }).dados.provedor | Should -Be 'outro'
        (Invoke-Rede 'estado' @{ simular = @{ adaptadores = @($meio) } }).dados.provedor | Should -Be 'outro'
    }

    It 'dohDisponivel segue o build; temBackup segue o arquivo de backup' {
        (Invoke-Rede 'estado' @{ simular = @{ build = 19045 } }).dados.dohDisponivel | Should -BeFalse
        (Invoke-Rede 'estado' @{ simular = @{ build = 22000 } }).dados.dohDisponivel | Should -BeTrue
        New-Item -ItemType Directory -Path (Split-Path -Parent $Script:ArqBackupT) -Force | Out-Null
        Set-Content -LiteralPath $Script:ArqBackupT -Value '{}' -Encoding UTF8
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
    It 'roda netsh winsock reset e netsh int ip reset pelo caminho absoluto e pede reinicio' {
        $r = Invoke-Rede 'redefinir' @{ confirmado = $true }
        $r.ok | Should -BeTrue
        $r.dados.precisaReiniciar | Should -BeTrue
        $r.dados.detalhe | Should -Match 'Reinicie'
        $netsh = Join-Path $env:windir 'System32\netsh.exe'
        $linhas = @(Get-Content -LiteralPath (Join-Path $Script:PastaT 'redefinir.txt'))
        $linhas.Count | Should -Be 2
        $linhas[0] | Should -Be "$netsh winsock reset"
        $linhas[1] | Should -Be "$netsh int ip reset"
    }
    It 'codigo diferente de zero entra no detalhe e ainda pede reinicio' {
        $r = Invoke-Rede 'redefinir' @{ confirmado = $true; simular = @{ netsh = @{ ip = 1 } } }
        $r.ok | Should -BeTrue
        $r.dados.precisaReiniciar | Should -BeTrue
        $r.dados.detalhe | Should -Match 'int ip reset'
        $r.dados.detalhe | Should -Match 'código 1'
        $r.dados.detalhe | Should -Not -Match 'winsock'
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
        Test-Path -LiteralPath $Script:RaizDohT | Should -BeFalse
    }

    It 'Windows 10 aceita automatico' {
        $r = Invoke-DnsSeguroT 'automatico' @{ build = 19045; adaptadores = @(Get-AdaptadorPadrao) }
        $r.ok | Should -BeTrue
        $r.dados.provedor | Should -Be 'automatico'
        @($r.dados.adaptadores).Count | Should -Be 4
        @($r.dados.adaptadores | Where-Object { -not $_.ok }).Count | Should -Be 0
        foreach ($a in Read-EstadoT) {
            $a.ipv4Automatico | Should -BeTrue
            $a.ipv6Automatico | Should -BeTrue
        }
    }

    It 'grava o backup uma vez e exato antes da primeira troca; aplica servidores e DoH' {
        $r = Invoke-DnsSeguroT 'cloudflare' $Script:Sim
        $r.ok | Should -BeTrue
        $r.dados.provedor | Should -Be 'cloudflare'
        $res = @($r.dados.adaptadores)
        $res.Count | Should -Be 4
        foreach ($x in $res) {
            $x.ok | Should -BeTrue
            $x.erro | Should -BeNullOrEmpty
        }
        $res[0].indice | Should -Be 11
        $res[0].nome | Should -Be 'Ethernet'

        $b = Read-BackupT
        $orig = @(Get-AdaptadorPadrao)
        @($b.adaptadores).Count | Should -Be 4
        for ($i = 0; $i -lt 4; $i++) { Format-AdaptadorT $b.adaptadores[$i] | Should -Be (Format-AdaptadorT $orig[$i]) }
        $b.adaptadores[1].nome | Should -Be 'Wi-Fi'
        (@($b.adaptadores[0].PSObject.Properties.Name) -join ',') | Should -Be 'indice,guid,nome,ipv4,ipv6,ipv4Automatico,ipv6Automatico'
        @($b.dohAdicionados).Count | Should -Be 8

        # IPv4 vai para o provedor; IPv6 fica como estava (o Sophia so configura IPv4)
        $estado = @(Read-EstadoT)
        for ($i = 0; $i -lt 4; $i++) {
            (@($estado[$i].ipv4) -join ',') | Should -Be ($Script:Cloudflare -join ',')
            $estado[$i].ipv4Automatico | Should -BeFalse
            (@($estado[$i].ipv6) -join ',') | Should -Be (@($orig[$i].ipv6) -join ',')
            $estado[$i].ipv6Automatico | Should -Be $orig[$i].ipv6Automatico
        }
        foreach ($g in @($Script:G1, $Script:G2, $Script:G3, $Script:G4)) {
            foreach ($ip in $Script:Cloudflare) {
                $k = Get-ItemProperty -LiteralPath (Get-ChaveDohT $g $ip)
                $k.DohFlags | Should -Be 2
                $k.DohTemplate | Should -Be 'https://cloudflare-dns.com/dns-query'
            }
        }
        $e = Invoke-Rede 'estado' @{ simular = @{ build = 22631 } }
        $e.dados.provedor | Should -Be 'cloudflare'
        $e.dados.temBackup | Should -BeTrue
    }

    It 'segunda troca (outro provedor) nao sobrescreve o backup e troca as chaves DoH do NexTune' {
        (Invoke-DnsSeguroT 'cloudflare' $Script:Sim).ok | Should -BeTrue
        $antes = (Read-BackupT).adaptadores | ConvertTo-Json -Depth 5 -Compress
        $r = Invoke-DnsSeguroT 'google' $Script:Sim
        $r.ok | Should -BeTrue
        @($r.dados.adaptadores | Where-Object { -not $_.ok }).Count | Should -Be 0
        $b = Read-BackupT
        ($b.adaptadores | ConvertTo-Json -Depth 5 -Compress) | Should -Be $antes
        @($b.dohAdicionados).Count | Should -Be 8
        @($b.dohAdicionados | Where-Object { $Script:Google -notcontains $_.ip }).Count | Should -Be 0
        foreach ($g in @($Script:G1, $Script:G2, $Script:G3, $Script:G4)) {
            foreach ($ip in $Script:Cloudflare) { Test-Path -LiteralPath (Get-ChaveDohT $g $ip) | Should -BeFalse }
            foreach ($ip in $Script:Google) { (Get-ItemProperty -LiteralPath (Get-ChaveDohT $g $ip)).DohTemplate | Should -Be 'https://dns.google/dns-query' }
        }
        (Invoke-Rede 'estado' @{ simular = @{ build = 22631 } }).dados.provedor | Should -Be 'google'
    }

    It 'automatico restaura exatamente (fixos e DHCP, IPv4 e IPv6), remove o DoH do NexTune e apaga o backup' {
        (Invoke-DnsSeguroT 'cloudflare' $Script:Sim).ok | Should -BeTrue
        (Invoke-DnsSeguroT 'quad9' $Script:Sim).ok | Should -BeTrue
        $r = Invoke-DnsSeguroT 'automatico' $Script:Sim
        $r.ok | Should -BeTrue
        $r.dados.provedor | Should -Be 'automatico'
        @($r.dados.adaptadores).Count | Should -Be 4
        @($r.dados.adaptadores | Where-Object { -not $_.ok }).Count | Should -Be 0
        $orig = @(Get-AdaptadorPadrao)
        $estado = @(Read-EstadoT)
        for ($i = 0; $i -lt 4; $i++) { Format-AdaptadorT $estado[$i] | Should -Be (Format-AdaptadorT $orig[$i]) }
        Test-Path -LiteralPath $Script:ArqBackupT | Should -BeFalse
        foreach ($g in @($Script:G1, $Script:G2, $Script:G3, $Script:G4)) {
            foreach ($ip in ($Script:Cloudflare + $Script:Quad9)) { Test-Path -LiteralPath (Get-ChaveDohT $g $ip) | Should -BeFalse }
        }
        $e = Invoke-Rede 'estado' @{ simular = @{ build = 22631 } }
        $e.dados.provedor | Should -Be 'outro'
        $e.dados.temBackup | Should -BeFalse
    }

    It 'automatico remove so as chaves DoH que o NexTune criou, nunca as que ja existiam' {
        $pre = Get-ChaveDohT $Script:G1 '1.1.1.1'
        New-Item -Path $pre -Force | Out-Null
        New-ItemProperty -LiteralPath $pre -Name DohTemplate -Value 'https://exemplo.invalid/dns-query' -PropertyType String | Out-Null
        $alheia = Get-ChaveDohT $Script:G2 '192.0.2.53'
        New-Item -Path $alheia -Force | Out-Null

        (Invoke-DnsSeguroT 'cloudflare' $Script:Sim).ok | Should -BeTrue
        # a chave que ja existia nao foi tocada nem entrou na lista do NexTune
        $k = Get-ItemProperty -LiteralPath $pre
        $k.DohTemplate | Should -Be 'https://exemplo.invalid/dns-query'
        $k.PSObject.Properties.Name | Should -Not -Contain 'DohFlags'
        $b = Read-BackupT
        @($b.dohAdicionados | Where-Object { $_.guid -eq $Script:G1 -and $_.ip -eq '1.1.1.1' }).Count | Should -Be 0
        @($b.dohAdicionados).Count | Should -Be 7

        (Invoke-DnsSeguroT 'automatico' $Script:Sim).ok | Should -BeTrue
        Test-Path -LiteralPath $pre | Should -BeTrue
        (Get-ItemProperty -LiteralPath $pre).DohTemplate | Should -Be 'https://exemplo.invalid/dns-query'
        Test-Path -LiteralPath $alheia | Should -BeTrue
        Test-Path -LiteralPath (Get-ChaveDohT $Script:G1 '1.0.0.1') | Should -BeFalse
        Test-Path -LiteralPath (Get-ChaveDohT $Script:G2 '1.1.1.1') | Should -BeFalse
        Test-Path -LiteralPath $Script:ArqBackupT | Should -BeFalse
    }

    It 'automatico sem backup volta todos os adaptadores ao DHCP' {
        $r = Invoke-DnsSeguroT 'automatico' $Script:Sim
        $r.ok | Should -BeTrue
        @($r.dados.adaptadores).Count | Should -Be 4
        @($r.dados.adaptadores | Where-Object { -not $_.ok }).Count | Should -Be 0
        $estado = @(Read-EstadoT)
        foreach ($a in $estado) {
            $a.ipv4Automatico | Should -BeTrue
            $a.ipv6Automatico | Should -BeTrue
        }
        (@($estado[0].ipv4) -join ',') | Should -Be '192.168.0.1'
        (@($estado[2].ipv4) -join ',') | Should -Be '192.168.1.1'
        Test-Path -LiteralPath $Script:ArqBackupT | Should -BeFalse
    }

    It 'um adaptador que falha nao impede os outros e informa o erro' {
        $sim = @{ build = 22631; adaptadores = @(Get-AdaptadorPadrao); falharIndice = 12 }
        $r = Invoke-DnsSeguroT 'cloudflare' $sim
        $r.ok | Should -BeTrue
        $res = @($r.dados.adaptadores)
        $res.Count | Should -Be 4
        $falhou = @($res | Where-Object { $_.indice -eq 12 })[0]
        $falhou.ok | Should -BeFalse
        $falhou.erro | Should -Match 'falha simulada'
        foreach ($x in @($res | Where-Object { $_.indice -ne 12 })) {
            $x.ok | Should -BeTrue
            $x.erro | Should -BeNullOrEmpty
        }
        $orig = @(Get-AdaptadorPadrao)
        $estado = @(Read-EstadoT)
        Format-AdaptadorT $estado[1] | Should -Be (Format-AdaptadorT $orig[1])
        (@($estado[0].ipv4) -join ',') | Should -Be ($Script:Cloudflare -join ',')
        Test-Path -LiteralPath (Get-ChaveDohT $Script:G1 '1.1.1.1') | Should -BeTrue
        Test-Path -LiteralPath (Get-ChaveDohT $Script:G2 '1.1.1.1') | Should -BeFalse
        @((Read-BackupT).adaptadores).Count | Should -Be 4

        # restaurar com o mesmo adaptador falhando: os outros voltam e o backup fica so com ele
        $r = Invoke-DnsSeguroT 'automatico' $sim
        $r.ok | Should -BeTrue
        @($r.dados.adaptadores | Where-Object { -not $_.ok }).Count | Should -Be 1
        $b = Read-BackupT
        (@($b.adaptadores | ForEach-Object { $_.indice }) -join ',') | Should -Be '12'
        @($b.dohAdicionados).Count | Should -Be 0
        $estado = @(Read-EstadoT)
        for ($i = 0; $i -lt 4; $i++) { Format-AdaptadorT $estado[$i] | Should -Be (Format-AdaptadorT $orig[$i]) }

        # sem a falha, o backup restante e consumido e apagado
        $r = Invoke-DnsSeguroT 'automatico' $Script:Sim
        @($r.dados.adaptadores | Where-Object { -not $_.ok }).Count | Should -Be 0
        Test-Path -LiteralPath $Script:ArqBackupT | Should -BeFalse
    }
}
