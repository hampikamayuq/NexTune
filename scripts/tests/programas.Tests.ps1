BeforeAll {
    . "$PSScriptRoot\..\common.ps1"
    . "$PSScriptRoot\..\programas.ps1"
    . "$PSScriptRoot\_helpers.ps1"
    $Script:Base = Join-Path $env:TEMP 'NexTuneTeste'
    $Script:Prog = Join-Path $Script:Base 'prog'            # desinstalador falso + marcador
    $Script:Apps = Join-Path $Script:Base 'apps'            # pastas de instalacao dos programas falsos
    $Script:Restos = Join-Path $Script:Base 'restos'        # raizes de restos do modo teste
    $Script:Quar = (Get-AppPastas $true).Quarentena
    $Script:UninstallT = 'HKCU:\Software\NexTuneTeste\Uninstall'
    $Script:RestosReg = 'HKCU:\Software\NexTuneTeste\Restos'
    $Script:Cmd = Join-Path $Script:Prog 'desinstalador.cmd'
    $Script:Marcador = Join-Path $Script:Prog 'marcador.txt'
    $Script:ChaveOrfa = 'HKCU\Software\NexTuneTeste\Restos\HKCU\Editor Teste\Programa Qualquer'

    New-Item -ItemType Directory -Path $Script:Prog -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\desinstalador.cmd') -Destination $Script:Cmd -Force

    # Executa uma acao do modulo capturando o protocolo; devolve o @@RESULT (objeto) ou $null.
    function Invoke-P {
        param([string]$Acao, $Params = @{})
        $sw = New-Object System.IO.StringWriter
        Set-Saida $sw
        try { Invoke-Acao 'p1' $Acao $Params $true } finally { Set-Saida $null }
        $Script:UltimaSaida = $sw.ToString()
        $linhas = @($sw.ToString() -split "`r?`n" | Where-Object { $_.StartsWith('@@RESULT ') })
        if ($linhas.Count -ne 1) { return $null }
        return $linhas[0].Substring(9) | ConvertFrom-Json
    }
    function New-ProgramaFalso {
        # Chave do Uninstall falso: valores [int] viram DWord, o resto String.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param([string]$Chave, [hashtable]$Valores, [string]$Hive = 'hkcu')
        $k = Join-Path (Join-Path $Script:UninstallT $Hive) $Chave
        New-Item -Path $k -Force | Out-Null
        foreach ($n in $Valores.Keys) {
            $v = $Valores[$n]
            if ($v -is [int]) { Set-ItemProperty -LiteralPath $k -Name $n -Value $v -Type DWord }
            else { Set-ItemProperty -LiteralPath $k -Name $n -Value ([string]$v) -Type String }
        }
    }
    function New-ArquivoTeste {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param([string]$Caminho, [int]$Bytes = 10, [int]$DiasAtras = 0)
        $pai = Split-Path -Parent $Caminho
        if (-not (Test-Path -LiteralPath $pai)) { New-Item -ItemType Directory -Path $pai -Force | Out-Null }
        [IO.File]::WriteAllBytes($Caminho, (New-Object byte[] $Bytes))
        if ($DiasAtras -gt 0) {
            $data = (Get-Date).AddDays(-$DiasAtras)
            (Get-Item -LiteralPath $Caminho).LastWriteTime = $data
            (Get-Item -LiteralPath $pai).LastWriteTime = $data
        }
    }
    function New-AtalhoTeste {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param([string]$Caminho, [string]$Alvo)
        $pai = Split-Path -Parent $Caminho
        if (-not (Test-Path -LiteralPath $pai)) { New-Item -ItemType Directory -Path $pai -Force | Out-Null }
        $ws = New-Object -ComObject WScript.Shell
        $s = $ws.CreateShortcut($Caminho)
        $s.TargetPath = $Alvo
        $s.Save()
    }
    function New-ChaveOrfa {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param()
        $k = Join-Path $Script:RestosReg 'HKCU\Editor Teste\Programa Qualquer'
        New-Item -Path $k -Force | Out-Null
        Set-ItemProperty -LiteralPath $k -Name 'Opcao' -Value 'valor' -Type String
    }
    function Get-Prog { param($R, [string]$Id) return @($R.dados.programas | Where-Object { $_.id -eq $Id })[0] }
    function Get-UninstallString {
        # UninstallString que chama o desinstalador falso com a propria chave e o codigo de saida pedido.
        param([string]$Chave, [int]$Codigo = 0)
        return ('"' + $Script:Cmd + '" "HKCU\Software\NexTuneTeste\Uninstall\hkcu\' + $Chave + '" ' + $Codigo)
    }
    function Get-Manifesto1 { param([string]$Id) return (Get-Content -LiteralPath (Join-Path (Join-Path $Script:Quar $Id) 'manifesto.json') -Raw -Encoding UTF8 | ConvertFrom-Json) }
    function New-StoreFalsa {
        # Lista simulada da Store (simular.store).
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param()
        $ms = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
        return @(
            @{ PackageFullName = 'Microsoft.BingNews_4.2.27001.0_x64__8wekyb3d8bbwe'; PackageFamilyName = 'Microsoft.BingNews_8wekyb3d8bbwe'; Name = 'Microsoft.BingNews'; Publisher = $ms; Version = '4.2.27001.0'; InstallLocation = ''; SignatureKind = 'Store'; IsFramework = $false; NonRemovable = $false },
            @{ PackageFullName = 'Microsoft.VCLibs.140.00_14.0.30704.0_x64__8wekyb3d8bbwe'; PackageFamilyName = 'Microsoft.VCLibs.140.00_8wekyb3d8bbwe'; Name = 'Microsoft.VCLibs.140.00'; Publisher = $ms; Version = '14.0.30704.0'; InstallLocation = ''; SignatureKind = 'Store'; IsFramework = $true; NonRemovable = $false },
            @{ PackageFullName = 'Microsoft.SecHealthUI_1000.25873.9001.0_x64__8wekyb3d8bbwe'; PackageFamilyName = 'Microsoft.SecHealthUI_8wekyb3d8bbwe'; Name = 'Microsoft.SecHealthUI'; Publisher = $ms; Version = '1000.25873.9001.0'; InstallLocation = ''; SignatureKind = 'System'; IsFramework = $false; NonRemovable = $false },
            @{ PackageFullName = 'Microsoft.XboxApp_48.49.31001.0_x64__8wekyb3d8bbwe'; PackageFamilyName = 'Microsoft.XboxApp_8wekyb3d8bbwe'; Name = 'Microsoft.XboxApp'; Publisher = $ms; Version = '48.49.31001.0'; InstallLocation = ''; SignatureKind = 'Store'; IsFramework = $false; NonRemovable = $true },
            @{ PackageFullName = 'Microsoft.WindowsStore_22410.1401.3.0_x64__8wekyb3d8bbwe'; PackageFamilyName = 'Microsoft.WindowsStore_8wekyb3d8bbwe'; Name = 'Microsoft.WindowsStore'; Publisher = $ms; Version = '22410.1401.3.0'; InstallLocation = ''; SignatureKind = 'Store'; IsFramework = $false; NonRemovable = $false },
            @{ PackageFullName = 'Fabricante.AppQualquer_1.0.0.0_x64__abcdefghijklm'; PackageFamilyName = 'Fabricante.AppQualquer_abcdefghijklm'; Name = 'Fabricante.AppQualquer'; Publisher = 'CN=Fabricante Ltda'; Version = '1.0.0.0'; InstallLocation = ''; SignatureKind = 'Store'; IsFramework = $false; NonRemovable = $false }
        )
    }
}

AfterAll {
    $t = Join-Path $env:TEMP 'NexTuneTeste'
    if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath 'HKCU:\Software\NexTuneTeste' -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'programas.ps1' {
    BeforeEach {
        foreach ($k in @($Script:UninstallT, $Script:RestosReg)) {
            if (Test-Path -LiteralPath $k) { Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction SilentlyContinue }
        }
        foreach ($p in @($Script:Apps, $Script:Restos, $Script:Quar)) {
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
            New-Item -ItemType Directory -Path $p -Force | Out-Null
        }
        if (Test-Path -LiteralPath $Script:Marcador) { Remove-Item -LiteralPath $Script:Marcador -Force }
        New-ArquivoTeste (Join-Path $Script:Apps 'Qualquer\config.txt') 300
        # Os 6 programas do plano, todos na hive hkcu do Uninstall falso.
        New-ProgramaFalso 'PositivoUtil' @{ DisplayName = 'Positivo Utilities'; Publisher = 'Positivo Tecnologia S.A.'; DisplayVersion = '2.1'; EstimatedSize = 2048; InstallDate = '20240115'; UninstallString = '"C:\Program Files\Positivo\unins000.exe"' }
        New-ProgramaFalso 'LenovoVantage' @{ DisplayName = 'Lenovo Vantage'; Publisher = 'Lenovo'; UninstallString = 'MsiExec.exe /I{11111111-2222-3333-4444-555555555555}'; WindowsInstaller = 1 }
        New-ProgramaFalso 'EdgeWebView' @{ DisplayName = 'Microsoft Edge WebView2 Runtime'; Publisher = 'Microsoft Corporation'; UninstallString = '"C:\Program Files (x86)\Microsoft\EdgeWebView\Application\1.0\Installer\setup.exe" --uninstall' }
        New-ProgramaFalso 'Qualquer' @{ DisplayName = 'Programa Qualquer'; Publisher = 'Editor Teste'; UninstallString = '"C:\Programas\Qualquer\uninst.exe"'; InstallLocation = (Join-Path $Script:Apps 'Qualquer') }
        New-ProgramaFalso 'KB5000' @{ DisplayName = 'Security Update for KB5000'; Publisher = 'Microsoft Corporation' }
        New-ProgramaFalso 'Oculto' @{ DisplayName = 'Oculto'; SystemComponent = 1 }
    }

    Context 'listar' {
        It 'devolve 4 programas com cores, protegido e ids cl:hkcu:<chave>' {
            $r = Invoke-P 'listar'
            $r.ok | Should -BeTrue
            @($r.dados.programas).Count | Should -Be 4
            @($r.dados.programas | ForEach-Object { $_.id } | Sort-Object) | Should -Be @('cl:hkcu:EdgeWebView', 'cl:hkcu:LenovoVantage', 'cl:hkcu:PositivoUtil', 'cl:hkcu:Qualquer')
            $pos = Get-Prog $r 'cl:hkcu:PositivoUtil'
            $pos.nome | Should -Be 'Positivo Utilities'
            $pos.editor | Should -Be 'Positivo Tecnologia S.A.'
            $pos.versao | Should -Be '2.1'
            $pos.tipo | Should -Be 'classico'
            $pos.cor | Should -Be 'verde'
            $pos.motivoCor | Should -Not -BeNullOrEmpty
            $pos.protegido | Should -BeFalse
            $pos.instalador | Should -Be 'inno'
            $pos.instaladoEm | Should -Be '2024-01-15'
            $pos.tamanhoBytes | Should -Be (2048 * 1024)
            @($pos.servicos).Count | Should -Be 0
            $pos.ramBytes | Should -Be 0
            $len = Get-Prog $r 'cl:hkcu:LenovoVantage'
            $len.cor | Should -Be 'amarelo'
            $len.protegido | Should -BeFalse
            $len.instalador | Should -Be 'msi'
            $len.siteReinstalar | Should -Not -BeNullOrEmpty
            $len.tamanhoBytes | Should -Be -1
            $len.instaladoEm | Should -BeNullOrEmpty
            $wv = Get-Prog $r 'cl:hkcu:EdgeWebView'
            $wv.cor | Should -Be 'vermelho'
            $wv.protegido | Should -BeTrue
            $wv.motivoProtegido | Should -Not -BeNullOrEmpty
            $q = Get-Prog $r 'cl:hkcu:Qualquer'
            $q.cor | Should -BeNullOrEmpty
            $q.protegido | Should -BeFalse
            $q.motivoCor | Should -Be ''
            $q.instalador | Should -Be 'nsis'
            $q.tamanhoBytes | Should -Be 300
            $q.local | Should -Be (Join-Path $Script:Apps 'Qualquer')
            $Script:UltimaSaida | Should -Match '"cor":null'
        }
        It 'ignora SystemComponent=1, atualizacoes KB, sem DisplayName e com ParentKeyName' {
            New-ProgramaFalso 'SemNome' @{ Publisher = 'Alguem' }
            New-ProgramaFalso 'Filho' @{ DisplayName = 'Parte de Outro'; ParentKeyName = 'Qualquer' }
            New-ProgramaFalso 'Hotfix' @{ DisplayName = 'Hotfix for Windows (KB123456)' }
            $ids = @((Invoke-P 'listar').dados.programas | ForEach-Object { $_.id })
            $ids | Should -Not -Contain 'cl:hkcu:Oculto'
            $ids | Should -Not -Contain 'cl:hkcu:KB5000'
            $ids | Should -Not -Contain 'cl:hkcu:SemNome'
            $ids | Should -Not -Contain 'cl:hkcu:Filho'
            $ids | Should -Not -Contain 'cl:hkcu:Hotfix'
            $ids.Count | Should -Be 4
        }
        It 'le as tres hives e poe a hive no id' {
            New-ProgramaFalso 'Em64' @{ DisplayName = 'Programa 64' } 'hklm64'
            New-ProgramaFalso 'Em32' @{ DisplayName = 'Programa 32' } 'hklm32'
            $r = Invoke-P 'listar'
            @($r.dados.programas).Count | Should -Be 6
            (Get-Prog $r 'cl:hklm64:Em64').nome | Should -Be 'Programa 64'
            (Get-Prog $r 'cl:hklm32:Em32').nome | Should -Be 'Programa 32'
        }
        It 'em modo teste nao chama Get-AppxPackage: a Store vem de simular.store, filtrada e classificada' {
            Mock Get-AppxPackage { throw 'Get-AppxPackage não deve ser chamado em modo teste' }
            $r = Invoke-P 'listar' @{ simular = @{ store = (New-StoreFalsa) } }
            $r.ok | Should -BeTrue
            Should -Invoke Get-AppxPackage -Times 0 -Exactly
            $store = @($r.dados.programas | Where-Object { $_.tipo -eq 'store' })
            @($store | ForEach-Object { $_.id } | Sort-Object) | Should -Be @('st:Fabricante.AppQualquer_1.0.0.0_x64__abcdefghijklm', 'st:Microsoft.BingNews_4.2.27001.0_x64__8wekyb3d8bbwe', 'st:Microsoft.WindowsStore_22410.1401.3.0_x64__8wekyb3d8bbwe')
            $news = Get-Prog $r 'st:Microsoft.BingNews_4.2.27001.0_x64__8wekyb3d8bbwe'
            $news.cor | Should -Be 'verde'
            $news.protegido | Should -BeFalse
            $news.instalador | Should -Be 'loja'
            $news.editor | Should -Be 'Microsoft Corporation'
            $news.packageFamilyName | Should -Be 'Microsoft.BingNews_8wekyb3d8bbwe'
            $news.productId | Should -Be '9WZDNCRFHVFW'
            $news.tamanhoBytes | Should -Be -1
            $loja = Get-Prog $r 'st:Microsoft.WindowsStore_22410.1401.3.0_x64__8wekyb3d8bbwe'
            $loja.cor | Should -Be 'vermelho'
            $loja.protegido | Should -BeTrue
            $outro = Get-Prog $r 'st:Fabricante.AppQualquer_1.0.0.0_x64__abcdefghijklm'
            $outro.cor | Should -BeNullOrEmpty
            $outro.editor | Should -Be 'Fabricante Ltda'
            @($r.dados.programas).Count | Should -Be 7
        }
        It 'app da Store instalado em WindowsApps nao e protegido pela pasta (so por lista, System ou NonRemovable)' {
            $loja = New-StoreFalsa
            $loja[0].InstallLocation = Join-Path $env:ProgramFiles 'WindowsApps\Microsoft.BingNews_x'
            $loja[5].InstallLocation = Join-Path $env:ProgramFiles 'WindowsApps\Fabricante.AppQualquer_x'
            $r = Invoke-P 'listar' @{ simular = @{ store = $loja } }
            $news = Get-Prog $r 'st:Microsoft.BingNews_4.2.27001.0_x64__8wekyb3d8bbwe'
            $news.protegido | Should -BeFalse
            $news.cor | Should -Be 'verde'
            $news.local | Should -Be (Join-Path $env:ProgramFiles 'WindowsApps\Microsoft.BingNews_x')
            $outro = Get-Prog $r 'st:Fabricante.AppQualquer_1.0.0.0_x64__abcdefghijklm'
            $outro.protegido | Should -BeFalse
            $outro.cor | Should -BeNullOrEmpty
            # programa classico na mesma pasta continua protegido pela regra da pasta
            (Get-Classificacao 'Coisa' 'Alguem' '' (Join-Path $env:ProgramFiles 'WindowsApps\Coisa') 'classico').protegido | Should -BeTrue
        }
        It 'InstallLocation em raiz de unidade ou pasta-base do sistema vira vazio e nao protege' {
            New-ProgramaFalso 'RaizC' @{ DisplayName = 'Programa Raiz'; InstallLocation = 'C:\' }
            New-ProgramaFalso 'EmPF' @{ DisplayName = 'Programa Em PF'; InstallLocation = ($env:ProgramFiles + '\') }
            New-ProgramaFalso 'EmLocal' @{ DisplayName = 'Programa Em Local'; InstallLocation = ('"' + $env:LOCALAPPDATA + '"') }
            $r = Invoke-P 'listar'
            foreach ($id in @('cl:hkcu:RaizC', 'cl:hkcu:EmPF', 'cl:hkcu:EmLocal')) {
                $p = Get-Prog $r $id
                $p.local | Should -Be ''
                $p.protegido | Should -BeFalse
                $p.tamanhoBytes | Should -Be -1
            }
            Get-LocalNormalizado 'C:\' | Should -Be ''
            Get-LocalNormalizado 'c:' | Should -Be ''
            Get-LocalNormalizado ($env:ProgramData.ToUpperInvariant() + '\') | Should -Be ''
            Get-LocalNormalizado ('"' + (Join-Path $Script:Apps 'Qualquer') + '\"') | Should -Be (Join-Path $Script:Apps 'Qualquer')
        }
        It 'sem simular.store a lista da Store e vazia' {
            $r = Invoke-P 'listar'
            @($r.dados.programas | Where-Object { $_.tipo -eq 'store' }).Count | Should -Be 0
        }
        It 'Get-ProgramaPorId resolve contra a lista e nunca vira caminho' {
            (Get-ProgramaPorId 'cl:hkcu:Qualquer' $true).nome | Should -Be 'Programa Qualquer'
            Get-ProgramaPorId 'cl:hkcu:..\..\Qualquer' $true | Should -BeNullOrEmpty
            Get-ProgramaPorId 'cl:hkcu:NaoExiste' $true | Should -BeNullOrEmpty
            Get-ProgramaPorId 'cl:outra:Qualquer' $true | Should -BeNullOrEmpty
            Get-ProgramaPorId 'xx:Qualquer' $true | Should -BeNullOrEmpty
            Get-ProgramaPorId '' $true | Should -BeNullOrEmpty
            (Get-ProgramaPorId 'st:Microsoft.BingNews_4.2.27001.0_x64__8wekyb3d8bbwe' $true @{ store = (New-StoreFalsa) }).nome | Should -Be 'Microsoft.BingNews'
            Get-ProgramaPorId 'st:Microsoft.SecHealthUI_1000.25873.9001.0_x64__8wekyb3d8bbwe' $true @{ store = (New-StoreFalsa) } | Should -BeNullOrEmpty
        }
    }

    Context 'funcoes puras (Review Focus 4)' {
        It 'Split-UninstallString separa exe entre aspas com espacos dos argumentos' {
            $s = Split-UninstallString '"C:\Program Files\X\unins000.exe" /PARAM'
            $s.exe | Should -Be 'C:\Program Files\X\unins000.exe'
            $s.args | Should -Be '/PARAM'
            $s.guid | Should -BeNullOrEmpty
            $s = Split-UninstallString '"C:\Program Files\X\unins000.exe"'
            $s.exe | Should -Be 'C:\Program Files\X\unins000.exe'
            $s.args | Should -Be ''
        }
        It 'Split-UninstallString aceita exe sem aspas (com e sem espacos no caminho)' {
            $s = Split-UninstallString 'C:\X\u.exe'
            $s.exe | Should -Be 'C:\X\u.exe'
            $s.args | Should -Be ''
            $s = Split-UninstallString 'C:\Program Files\X\u.exe /SILENT'
            $s.exe | Should -Be 'C:\Program Files\X\u.exe'
            $s.args | Should -Be '/SILENT'
            (Split-UninstallString '').exe | Should -Be ''
            (Split-UninstallString $null).exe | Should -Be ''
        }
        It 'Split-UninstallString reconhece MsiExec com GUID' {
            $s = Split-UninstallString 'MsiExec.exe /I{11111111-2222-3333-4444-555555555555}'
            $s.exe | Should -Be 'msiexec.exe'
            $s.args | Should -Be '/I{11111111-2222-3333-4444-555555555555}'
            $s.guid | Should -Be '{11111111-2222-3333-4444-555555555555}'
            (Split-UninstallString 'C:\Windows\System32\msiexec.exe /X{11111111-2222-3333-4444-555555555555} /qn').exe | Should -Be 'msiexec.exe'
        }
        It 'Get-TipoInstalador reconhece msi, inno, nsis, installshield, quiet, loja e desconhecido' {
            Get-TipoInstalador -UninstallString 'MsiExec.exe /I{11111111-2222-3333-4444-555555555555}' | Should -Be 'msi'
            Get-TipoInstalador -UninstallString '"C:\P\bootstrap.exe" /uninstall {11111111-2222-3333-4444-555555555555}' -WindowsInstaller 1 | Should -Be 'msi'
            Get-TipoInstalador -UninstallString '"C:\Program Files\X\unins000.exe"' | Should -Be 'inno'
            Get-TipoInstalador -UninstallString '"C:\Program Files\X\unins001.exe" /PARAM' | Should -Be 'inno'
            Get-TipoInstalador -UninstallString 'C:\X\uninst.exe' | Should -Be 'nsis'
            Get-TipoInstalador -UninstallString '"C:\X\Uninstall.exe"' | Should -Be 'nsis'
            Get-TipoInstalador -UninstallString '"C:\X\Un_A.exe"' | Should -Be 'nsis'
            Get-TipoInstalador -UninstallString '"C:\Program Files (x86)\InstallShield Installation Information\{11111111-2222-3333-4444-555555555555}\setup.exe" -runfromtemp -l0x0416 -removeonly' | Should -Be 'installshield'
            Get-TipoInstalador -UninstallString 'C:\X\setup.exe -runfromtemp' | Should -Be 'installshield'
            Get-TipoInstalador -UninstallString '"C:\X\remover.exe"' -QuietUninstallString '"C:\X\remover.exe" /quiet' | Should -Be 'quiet'
            Get-TipoInstalador -Tipo 'store' | Should -Be 'loja'
            Get-TipoInstalador -UninstallString '"C:\X\remover.exe" --uninstall' | Should -Be 'desconhecido'
            Get-TipoInstalador -UninstallString '' | Should -Be 'desconhecido'
        }
        It 'Get-TipoInstalador acha a marca Nullsoft dentro do arquivo' {
            $nsis = Join-Path $Script:Base 'nsis\remover.exe'
            $outro = Join-Path $Script:Base 'nsis\outro.exe'
            New-ArquivoTeste $nsis 10
            [IO.File]::WriteAllText($nsis, 'MZ lixo Nullsoft Install System v3 lixo', [Text.Encoding]::ASCII)
            [IO.File]::WriteAllText($outro, 'MZ lixo sem marca nenhuma', [Text.Encoding]::ASCII)
            Get-TipoInstalador -UninstallString ('"' + $nsis + '" /X') | Should -Be 'nsis'
            Get-TipoInstalador -UninstallString ('"' + $outro + '" /X') | Should -Be 'desconhecido'
        }
        It 'Get-ArgumentosSilenciosos acrescenta no fim e nao duplica o que ja esta presente' {
            Get-ArgumentosSilenciosos 'inno' '/PARAM' | Should -Be '/PARAM /VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
            $a = Get-ArgumentosSilenciosos 'inno' '/VERYSILENT /PARAM'
            $a | Should -Be '/VERYSILENT /PARAM /SUPPRESSMSGBOXES /NORESTART'
            ([regex]::Matches($a, 'VERYSILENT')).Count | Should -Be 1
            Get-ArgumentosSilenciosos 'inno' '/verysilent /suppressmsgboxes /norestart' | Should -Be '/verysilent /suppressmsgboxes /norestart'
            Get-ArgumentosSilenciosos 'inno' '' | Should -Be '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
            Get-ArgumentosSilenciosos 'nsis' '' | Should -Be '/S'
            Get-ArgumentosSilenciosos 'nsis' '/S' | Should -Be '/S'
            Get-ArgumentosSilenciosos 'nsis' '/SILENTE' | Should -Be '/SILENTE /S'
            Get-ArgumentosSilenciosos 'msi' '/I{11111111-2222-3333-4444-555555555555}' | Should -Be '/X{11111111-2222-3333-4444-555555555555} /qn /norestart'
            Get-ArgumentosSilenciosos 'msi' '/X{11111111-2222-3333-4444-555555555555} /qn' | Should -Be '/X{11111111-2222-3333-4444-555555555555} /qn /norestart'
            Get-ArgumentosSilenciosos 'installshield' '-runfromtemp -removeonly' | Should -Be '-runfromtemp -removeonly /s /v"/qn"'
            Get-ArgumentosSilenciosos 'installshield' '/s /v"/qn"' | Should -Be '/s /v"/qn"'
            Get-ArgumentosSilenciosos 'desconhecido' '--uninstall' | Should -Be '--uninstall'
            Get-ArgumentosSilenciosos 'quiet' '/quiet' | Should -Be '/quiet'
        }
        It 'Get-PlanoDesinstalacao escolhe quiet, msiexec /X{guid}, silencioso por tipo ou assistente' {
            $g = '{11111111-2222-3333-4444-555555555555}'
            $prog = @{ instalador = 'quiet'; uninstallString = '"C:\X\u.exe" /a'; quietUninstallString = '"C:\X\u.exe" /quiet' }
            $pl = Get-PlanoDesinstalacao $prog
            $pl.modo | Should -Be 'silencioso'
            $pl.args | Should -Be '/quiet'
            $prog = @{ instalador = 'msi'; uninstallString = "MsiExec.exe /I$g"; quietUninstallString = '' }
            $pl = Get-PlanoDesinstalacao $prog
            $pl.exe | Should -Be 'msiexec.exe'
            $pl.args | Should -Be "/X$g /qn /norestart"
            $prog = @{ instalador = 'msi'; uninstallString = "`"C:\P\bootstrap.exe`" /uninstall $g"; quietUninstallString = '' }
            $pl = Get-PlanoDesinstalacao $prog
            $pl.exe | Should -Be 'msiexec.exe'
            $pl.args | Should -Be "/X$g /qn /norestart"
            $prog = @{ instalador = 'inno'; uninstallString = '"C:\Program Files\X\unins000.exe" /PARAM'; quietUninstallString = '' }
            $pl = Get-PlanoDesinstalacao $prog
            $pl.exe | Should -Be 'C:\Program Files\X\unins000.exe'
            $pl.args | Should -Be '/PARAM /VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
            $pl.modo | Should -Be 'silencioso'
            $prog = @{ instalador = 'desconhecido'; uninstallString = '"C:\X\remover.exe" --uninstall'; quietUninstallString = '' }
            $pl = Get-PlanoDesinstalacao $prog
            $pl.modo | Should -Be 'assistente'
            $pl.args | Should -Be '--uninstall'
            # tipo forcado (simular) so vale se for conhecido
            (Get-PlanoDesinstalacao $prog 'nsis').args | Should -Be '--uninstall /S'
            (Get-PlanoDesinstalacao $prog 'invencao').modo | Should -Be 'assistente'
        }
        It 'Test-ChaveRestoPermitida aceita so HKCU\Software e HKLM\SOFTWARE com 3+ segmentos fora das areas do Windows' {
            Test-ChaveRestoPermitida 'HKCU\Software\Editor Teste\Programa Qualquer' | Should -BeTrue
            Test-ChaveRestoPermitida 'hklm\software\Editor Teste' | Should -BeTrue
            Test-ChaveRestoPermitida 'HKEY_CURRENT_USER\Software\Editor' | Should -BeTrue
            Test-ChaveRestoPermitida $Script:ChaveOrfa | Should -BeTrue
            Test-ChaveRestoPermitida 'HKCU\Software' | Should -BeFalse
            Test-ChaveRestoPermitida 'HKCU\Software\' | Should -BeFalse
            Test-ChaveRestoPermitida 'HKLM\SYSTEM\X' | Should -BeFalse
            Test-ChaveRestoPermitida 'HKLM\SOFTWARE\Microsoft\Windows' | Should -BeFalse
            Test-ChaveRestoPermitida 'HKCU\Software\NexTuneTeste\Restos\HKCU\Microsoft\X' | Should -BeFalse
            Test-ChaveRestoPermitida 'HKCU\Software\Classes\X' | Should -BeFalse
            Test-ChaveRestoPermitida 'HKCU\Software\Editor\Policies' | Should -BeFalse
            Test-ChaveRestoPermitida 'HKLM\SOFTWARE\WOW6432Node\Editor' | Should -BeFalse
            Test-ChaveRestoPermitida 'HKU\S-1-5-18\Software\X' | Should -BeFalse
            Test-ChaveRestoPermitida 'C:\Software\X' | Should -BeFalse
            Test-ChaveRestoPermitida '' | Should -BeFalse
            Test-SubchaveProibida 'Editor\Windows' | Should -BeTrue
            Test-SubchaveProibida 'Editor Teste\Programa Qualquer' | Should -BeFalse
        }
        It 'Get-SegmentoSeguro e Get-SubcaminhoResto nunca produzem separadores nem . e ..' {
            Get-SegmentoSeguro '..\..\Programa Qualquer' | Should -Not -Match '[\\/:*?"<>|]'
            Get-SegmentoSeguro 'a:b*c' | Should -Be 'abc'
            Get-SegmentoSeguro '..' | Should -Be ''
            Get-SegmentoSeguro ' . ' | Should -Be ''
            Get-SegmentoSeguro 'Nome.' | Should -Be 'Nome'
            Get-SegmentoSeguro '' | Should -Be ''
            $subs = @(Get-SubcaminhoResto '..\..\Programa Qualquer' '..')
            $subs.Count | Should -Be 1
            foreach ($seg in @($subs -split '\\')) {
                $seg | Should -Not -Match '[/:*?"<>|]'
                $seg | Should -Not -Match '^\.{1,2}$'
                $seg | Should -Not -BeNullOrEmpty
            }
            @(Get-SubcaminhoResto 'Programa Qualquer' 'Editor Teste') | Should -Be @('Editor Teste\Programa Qualquer', 'Programa Qualquer')
            @(Get-SubcaminhoResto 'Programa Qualquer' 'programa qualquer') | Should -Be @('Programa Qualquer')
            @(Get-SubcaminhoResto '..' 'Editor').Count | Should -Be 0
        }
        It 'Get-Classificacao segue a ordem: protegidos, pasta protegida, pacote de sistema, bloatware' {
            $c = Get-Classificacao 'Positivo Utilities' 'Positivo Tecnologia S.A.' '' '' 'classico'
            $c.cor | Should -Be 'verde'
            $c.protegido | Should -BeFalse
            # a excecao amarela vem antes da entrada verde generica da Positivo
            (Get-Classificacao 'Positivo Hotkey Utility' 'Positivo Tecnologia S.A.' '' '' 'classico').cor | Should -Be 'amarelo'
            $c = Get-Classificacao 'Microsoft Edge' 'Microsoft Corporation' '' '' 'classico'
            $c.cor | Should -Be 'vermelho'
            $c.protegido | Should -BeTrue
            $c.motivoProtegido | Should -Not -BeNullOrEmpty
            $c = Get-Classificacao 'Ferramenta X' 'Fabricante' '' (Join-Path $env:ProgramFiles 'Common Files\X') 'classico'
            $c.protegido | Should -BeTrue
            $c.cor | Should -Be 'vermelho'
            (Get-Classificacao 'Fabricante.X' 'Fabricante' 'Fabricante.X_abc' '' 'store' 'System' $false).protegido | Should -BeTrue
            (Get-Classificacao 'Fabricante.X' 'Fabricante' 'Fabricante.X_abc' '' 'store' 'Store' $true).protegido | Should -BeTrue
            (Get-Classificacao 'Fabricante.X' 'Fabricante' 'Fabricante.X_abc' '' 'store' 'Store' $false).protegido | Should -BeFalse
            $c = Get-Classificacao 'Microsoft.BingNews' 'Microsoft Corporation' 'Microsoft.BingNews_8wekyb3d8bbwe' (Join-Path $env:ProgramFiles 'WindowsApps\Microsoft.BingNews_x') 'store' 'Store' $false
            $c.protegido | Should -BeFalse
            $c.cor | Should -Be 'verde'
            $c = Get-Classificacao 'Programa Qualquer' 'Editor Teste' '' '' 'classico'
            $c.cor | Should -BeNullOrEmpty
            $c.protegido | Should -BeFalse
            $c.motivoCor | Should -Be ''
        }
    }

    Context 'desinstalar' {
        It 'sem confirmado recusa' {
            $r = Invoke-P 'desinstalar' @{ id = 'cl:hkcu:Qualquer' }
            $r.ok | Should -BeFalse
            $r.erro | Should -Match 'confirma'
            $r = Invoke-P 'desinstalar' @{ id = 'cl:hkcu:Qualquer'; confirmado = 'true' }
            $r.ok | Should -BeFalse
        }
        It 'id inexistente ou vazio recusa' {
            (Invoke-P 'desinstalar' @{ id = 'cl:hkcu:NaoExiste'; confirmado = $true }).ok | Should -BeFalse
            (Invoke-P 'desinstalar' @{ id = ''; confirmado = $true }).ok | Should -BeFalse
            (Invoke-P 'desinstalar' @{ confirmado = $true }).ok | Should -BeFalse
        }
        It 'Review Focus 5: programa protegido nunca desinstala, mesmo com confirmado e avancado' {
            $r = Invoke-P 'desinstalar' @{ id = 'cl:hkcu:EdgeWebView'; confirmado = $true; avancado = $true; desprovisionar = $true }
            $r.ok | Should -BeFalse
            $r.erro | Should -Match 'protegido'
            Test-Path -LiteralPath (Join-Path $Script:UninstallT 'hkcu\EdgeWebView') | Should -BeTrue
            # app da Store protegido tambem
            Mock Remove-AppxPackage { throw 'não deve ser chamado' }
            $r = Invoke-P 'desinstalar' @{ id = 'st:Microsoft.WindowsStore_22410.1401.3.0_x64__8wekyb3d8bbwe'; confirmado = $true; avancado = $true; simular = @{ store = (New-StoreFalsa) } }
            $r.ok | Should -BeFalse
            $r.erro | Should -Match 'protegido'
            Should -Invoke Remove-AppxPackage -Times 0 -Exactly
        }
        It 'roda o desinstalador falso em silencio com os argumentos silenciosos no fim, apaga a chave e devolve os restos' {
            New-ArquivoTeste (Join-Path $Script:Apps 'ProgTeste\config.txt') 40
            New-ProgramaFalso 'ProgTeste' @{ DisplayName = 'Programa Teste'; Publisher = 'Editor Teste'; InstallLocation = (Join-Path $Script:Apps 'ProgTeste'); UninstallString = (Get-UninstallString 'ProgTeste' 0) }
            $r = Invoke-P 'desinstalar' @{ id = 'cl:hkcu:ProgTeste'; confirmado = $true; simular = @{ tipoInstalador = 'inno' } }
            $r.ok | Should -BeTrue
            $r.dados.modo | Should -Be 'silencioso'
            $r.dados.codigo | Should -Be 0
            Test-Path -LiteralPath $Script:Marcador | Should -BeTrue
            $marca = (Get-Content -LiteralPath $Script:Marcador -Raw).Trim()
            # %1 (chave) e %2 (codigo) ficam na frente; o silencioso vem depois
            $marca | Should -Match '^"HKCU\\Software\\NexTuneTeste\\Uninstall\\hkcu\\ProgTeste" 0 /VERYSILENT /SUPPRESSMSGBOXES /NORESTART$'
            # o proprio .cmd apagou a chave do Uninstall
            Test-Path -LiteralPath (Join-Path $Script:UninstallT 'hkcu\ProgTeste') | Should -BeFalse
            @((Invoke-P 'listar').dados.programas | Where-Object { $_.id -eq 'cl:hkcu:ProgTeste' }).Count | Should -Be 0
            # restos: a pasta local (sem .exe) e candidata
            $restos = @($r.dados.restos)
            $restos.Count | Should -Be 1
            $restos[0].tipo | Should -Be 'pasta'
            Get-CaminhoLongo $restos[0].caminho | Should -Be (Get-CaminhoLongo (Join-Path $Script:Apps 'ProgTeste'))
            $restos[0].tamanhoBytes | Should -Be 40
            $restos[0].confianca | Should -Be 'media'
            $restos[0].motivo | Should -Not -BeNullOrEmpty
        }
        It 'QuietUninstallString tem prioridade e roda em silencio sem acrescentar argumentos' {
            New-ProgramaFalso 'ProgQuiet' @{ DisplayName = 'Programa Quieto'; UninstallString = (Get-UninstallString 'ProgQuiet' 5); QuietUninstallString = (Get-UninstallString 'ProgQuiet' 0) }
            $r = Invoke-P 'desinstalar' @{ id = 'cl:hkcu:ProgQuiet'; confirmado = $true }
            $r.ok | Should -BeTrue
            $r.dados.modo | Should -Be 'silencioso'
            $r.dados.codigo | Should -Be 0
            (Get-Content -LiteralPath $Script:Marcador -Raw).Trim() | Should -Be '"HKCU\Software\NexTuneTeste\Uninstall\hkcu\ProgQuiet" 0'
            Test-Path -LiteralPath (Join-Path $Script:UninstallT 'hkcu\ProgQuiet') | Should -BeFalse
            @($r.dados.restos).Count | Should -Be 0
            $Script:UltimaSaida | Should -Match '"restos":\[\]'
        }
        It 'tipo desconhecido roda como assistente e devolve o codigo de saida do desinstalador' {
            New-ProgramaFalso 'ProgAssist' @{ DisplayName = 'Programa Assistente'; UninstallString = (Get-UninstallString 'ProgAssist' 3) }
            $r = Invoke-P 'desinstalar' @{ id = 'cl:hkcu:ProgAssist'; confirmado = $true }
            $r.ok | Should -BeTrue
            $r.dados.modo | Should -Be 'assistente'
            $r.dados.codigo | Should -Be 3
            Test-Path -LiteralPath (Join-Path $Script:UninstallT 'hkcu\ProgAssist') | Should -BeFalse
        }
        It 'em modo teste recusa desinstalador fora de %TEMP%\NexTuneTeste e nada roda' {
            New-ProgramaFalso 'ProgFora' @{ DisplayName = 'Programa Fora'; UninstallString = ('"' + (Join-Path $env:windir 'System32\cmd.exe') + '" /c exit 0') }
            $r = Invoke-P 'desinstalar' @{ id = 'cl:hkcu:ProgFora'; confirmado = $true }
            $r.ok | Should -BeFalse
            $r.erro | Should -Match 'NexTuneTeste'
            Test-Path -LiteralPath (Join-Path $Script:UninstallT 'hkcu\ProgFora') | Should -BeTrue
            Test-Path -LiteralPath $Script:Marcador | Should -BeFalse
        }
        It 'simular.tipoInstalador aceita so tipos conhecidos' {
            New-ProgramaFalso 'ProgTipo' @{ DisplayName = 'Programa Tipo'; UninstallString = (Get-UninstallString 'ProgTipo' 0) }
            $r = Invoke-P 'desinstalar' @{ id = 'cl:hkcu:ProgTipo'; confirmado = $true; simular = @{ tipoInstalador = 'invencao' } }
            $r.ok | Should -BeTrue
            $r.dados.modo | Should -Be 'assistente'
        }
        It 'desinstalador ausente recusa sem lancar' {
            New-ProgramaFalso 'ProgSumiu' @{ DisplayName = 'Programa Sumido'; UninstallString = ('"' + (Join-Path $Script:Prog 'nao-existe.cmd') + '" x') }
            $r = Invoke-P 'desinstalar' @{ id = 'cl:hkcu:ProgSumiu'; confirmado = $true }
            $r.ok | Should -BeFalse
            $r.erro | Should -Match 'não encontrado'
            New-ProgramaFalso 'ProgVazio' @{ DisplayName = 'Programa Vazio'; UninstallString = '' }
            (Invoke-P 'desinstalar' @{ id = 'cl:hkcu:ProgVazio'; confirmado = $true }).ok | Should -BeFalse
        }
        It 'desinstalador relativo, nome solto ou UNC e recusado antes de rodar' {
            New-ProgramaFalso 'ProgRel' @{ DisplayName = 'Programa Relativo'; UninstallString = 'prog\desinstalador.cmd "x" 0' }
            New-ProgramaFalso 'ProgSolto' @{ DisplayName = 'Programa Solto'; UninstallString = 'desinstalador.cmd "x" 0' }
            New-ProgramaFalso 'ProgUnc' @{ DisplayName = 'Programa UNC'; UninstallString = '"\\servidor\share\desinstalador.cmd" "x" 0' }
            foreach ($id in @('cl:hkcu:ProgRel', 'cl:hkcu:ProgSolto', 'cl:hkcu:ProgUnc')) {
                $r = Invoke-P 'desinstalar' @{ id = $id; confirmado = $true }
                $r.ok | Should -BeFalse
                $r.erro | Should -Match 'desinstalador'
            }
            Test-Path -LiteralPath $Script:Marcador | Should -BeFalse
            Resolve-Desinstalador 'msiexec.exe' | Should -Be (Join-Path $env:windir 'System32\msiexec.exe')
            Resolve-Desinstalador 'C:\X\..\Y\u.exe' | Should -Be 'C:\Y\u.exe'
            Resolve-Desinstalador '\\.\pipe\x' | Should -BeNullOrEmpty
            Resolve-Desinstalador '' | Should -BeNullOrEmpty
        }
        It 'app da Store em modo teste devolve modo loja e codigo 0 sem executar nada' {
            Mock Remove-AppxPackage { throw 'não deve ser chamado' }
            $r = Invoke-P 'desinstalar' @{ id = 'st:Microsoft.BingNews_4.2.27001.0_x64__8wekyb3d8bbwe'; confirmado = $true; avancado = $true; desprovisionar = $true; simular = @{ store = (New-StoreFalsa) } }
            $r.ok | Should -BeTrue
            $r.dados.modo | Should -Be 'loja'
            $r.dados.codigo | Should -Be 0
            Should -Invoke Remove-AppxPackage -Times 0 -Exactly
        }
    }

    Context 'restos' {
        It 'sem nome recusa' {
            (Invoke-P 'restos' @{ id = 'cl:hkcu:Qualquer' }).ok | Should -BeFalse
        }
        It 'local sem executaveis e candidato (programa fora da lista); com .dll dentro nao' {
            $local = Join-Path $Script:Apps 'Qualquer'
            $r = Invoke-P 'restos' @{ id = 'cl:hkcu:Removido'; nome = 'Programa Qualquer'; editor = 'Editor Teste'; local = $local }
            $r.ok | Should -BeTrue
            $c = @($r.dados.candidatos)
            $c.Count | Should -Be 1
            $c[0].tipo | Should -Be 'pasta'
            Get-CaminhoLongo $c[0].caminho | Should -Be (Get-CaminhoLongo $local)
            $c[0].tamanhoBytes | Should -Be 300
            $c[0].confianca | Should -Be 'media'
            New-ArquivoTeste (Join-Path $local 'sub\x.dll') 5
            @((Invoke-P 'restos' @{ id = 'cl:hkcu:Removido'; nome = 'Programa Qualquer'; local = $local }).dados.candidatos).Count | Should -Be 0
            # local inexistente ou relativo: nada
            @((Invoke-P 'restos' @{ id = 'cl:hkcu:Removido'; nome = 'Programa Qualquer'; local = (Join-Path $Script:Apps 'Nada') }).dados.candidatos).Count | Should -Be 0
            @((Invoke-P 'restos' @{ id = 'cl:hkcu:Removido'; nome = 'Programa Qualquer'; local = 'apps\Qualquer' }).dados.candidatos).Count | Should -Be 0
        }
        It 'pasta de instalacao de programa ainda na lista nao e resto' {
            $local = Join-Path $Script:Apps 'Qualquer'
            $r = Invoke-P 'restos' @{ id = 'cl:hkcu:Qualquer'; nome = 'Programa Qualquer'; editor = 'Editor Teste'; local = $local }
            $r.ok | Should -BeTrue
            @($r.dados.candidatos).Count | Should -Be 0
            Test-Path -LiteralPath (Join-Path $local 'config.txt') | Should -BeTrue
        }
        It 'pasta com juncao dentro (ou acima) nao e candidata' {
            $pasta = Join-Path $Script:Restos 'LocalAppData\Programa Qualquer'
            New-ArquivoTeste (Join-Path $pasta 'dados.txt') 10 40
            $jn = Join-Path $pasta 'jn'
            New-Juncao $jn $Script:Apps
            try {
                (Get-Item -LiteralPath $pasta).LastWriteTime = (Get-Date).AddDays(-40)
                Test-PastaCandidata $pasta $true | Should -BeFalse
                @((Invoke-P 'restos' @{ id = 'cl:hkcu:Removido'; nome = 'Programa Qualquer' }).dados.candidatos).Count | Should -Be 0
                # local que e a propria juncao tambem nao
                @((Invoke-P 'restos' @{ id = 'cl:hkcu:Removido'; nome = 'Programa Qualquer'; local = $jn }).dados.candidatos).Count | Should -Be 0
            } finally { Remove-Juncao $jn }
            (Get-Item -LiteralPath $pasta).LastWriteTime = (Get-Date).AddDays(-40)
            Test-PastaCandidata $pasta $true | Should -BeTrue
            @((Invoke-P 'restos' @{ id = 'cl:hkcu:Removido'; nome = 'Programa Qualquer' }).dados.candidatos).Count | Should -Be 1
        }
        It 'pastas de dados <editor>\<nome> e <nome> so com mais de 30 dias e sem executaveis' {
            New-ArquivoTeste (Join-Path $Script:Restos 'LocalAppData\Editor Teste\Programa Qualquer\dados.txt') 70 40
            New-ArquivoTeste (Join-Path $Script:Restos 'AppData\Programa Qualquer\recente.txt') 10 0
            New-ArquivoTeste (Join-Path $Script:Restos 'ProgramData\Editor Teste\Programa Qualquer\lib.dll') 10 40
            New-ArquivoTeste (Join-Path $Script:Restos 'ProgramData\Outro Programa\velho.txt') 10 40
            $r = Invoke-P 'restos' @{ id = 'cl:hkcu:Qualquer'; nome = 'Programa Qualquer'; editor = 'Editor Teste' }
            $r.ok | Should -BeTrue
            $c = @($r.dados.candidatos)
            $c.Count | Should -Be 1
            $c[0].tipo | Should -Be 'pasta'
            Get-CaminhoLongo $c[0].caminho | Should -Be (Get-CaminhoLongo (Join-Path $Script:Restos 'LocalAppData\Editor Teste\Programa Qualquer'))
            $c[0].tamanhoBytes | Should -Be 70
            # a pasta recente passa a valer quando envelhece
            $rec = Join-Path $Script:Restos 'AppData\Programa Qualquer'
            $data = (Get-Date).AddDays(-31)
            (Get-Item -LiteralPath (Join-Path $rec 'recente.txt')).LastWriteTime = $data
            (Get-Item -LiteralPath $rec).LastWriteTime = $data
            $c = @((Invoke-P 'restos' @{ id = 'cl:hkcu:Qualquer'; nome = 'Programa Qualquer'; editor = 'Editor Teste' }).dados.candidatos)
            @($c | ForEach-Object { Get-CaminhoLongo $_.caminho }) | Should -Contain (Get-CaminhoLongo $rec)
            $c.Count | Should -Be 2
        }
        It 'atalho quebrado com o nome do programa e candidato; alheio ou inteiro nao' {
            New-AtalhoTeste (Join-Path $Script:Restos 'Menu\Programa Qualquer\Programa Qualquer.lnk') 'C:\nao-existe-nextune\pq.exe'
            New-AtalhoTeste (Join-Path $Script:Restos 'Menu\Outro.lnk') 'C:\nao-existe-nextune\outro.exe'
            New-AtalhoTeste (Join-Path $Script:Restos 'Desktop\Programa Qualquer.lnk') (Join-Path $env:windir 'System32\notepad.exe')
            New-AtalhoTeste (Join-Path $Script:Restos 'Desktop\Atalho qualquer.lnk') 'C:\nao-existe-nextune\Programa Qualquer\pq.exe'
            $r = Invoke-P 'restos' @{ id = 'cl:hkcu:Qualquer'; nome = 'Programa Qualquer'; editor = 'Editor Teste' }
            $r.ok | Should -BeTrue
            $c = @($r.dados.candidatos)
            $c.Count | Should -Be 2
            foreach ($x in $c) { $x.tipo | Should -Be 'atalho' }
            @($c | ForEach-Object { Get-CaminhoLongo $_.caminho } | Sort-Object) | Should -Be @((Get-CaminhoLongo (Join-Path $Script:Restos 'Desktop\Atalho qualquer.lnk')), (Get-CaminhoLongo (Join-Path $Script:Restos 'Menu\Programa Qualquer\Programa Qualquer.lnk')))
            $c[0].tamanhoBytes | Should -BeGreaterThan 0
            # nome com menos de 3 caracteres casaria com qualquer atalho: nenhum e oferecido
            New-AtalhoTeste (Join-Path $Script:Restos 'Menu\Xyz.lnk') 'C:\nao-existe-nextune\q.exe'
            @((Invoke-P 'restos' @{ id = 'cl:hkcu:Removido'; nome = 'Xy' }).dados.candidatos | Where-Object { $_.tipo -eq 'atalho' }).Count | Should -Be 0
            @((Invoke-P 'restos' @{ id = 'cl:hkcu:Removido'; nome = 'Xyz' }).dados.candidatos | Where-Object { $_.tipo -eq 'atalho' }).Count | Should -Be 1
        }
        It 'chave orfa vira candidato chave so quando o programa nao esta mais na lista' {
            New-ChaveOrfa
            $instalado = Invoke-P 'restos' @{ id = 'cl:hkcu:Qualquer'; nome = 'Programa Qualquer'; editor = 'Editor Teste' }
            @($instalado.dados.candidatos | Where-Object { $_.tipo -eq 'chave' }).Count | Should -Be 0
            $r = Invoke-P 'restos' @{ id = 'cl:hkcu:Removido'; nome = 'Programa Qualquer'; editor = 'Editor Teste' }
            $r.ok | Should -BeTrue
            $c = @($r.dados.candidatos | Where-Object { $_.tipo -eq 'chave' })
            $c.Count | Should -Be 1
            $c[0].caminho | Should -Be $Script:ChaveOrfa
            $c[0].tamanhoBytes | Should -Be 0
            $c[0].confianca | Should -Be 'media'
        }
        It 'chave em area proibida (Microsoft, Windows...) nunca vira candidato, mesmo dentro da area de teste' {
            foreach ($sub in @('HKCU\Microsoft\Programa Qualquer', 'HKCU\Editor Teste\Windows', 'HKLM\Classes\Programa Qualquer')) {
                New-Item -Path (Join-Path $Script:RestosReg $sub) -Force | Out-Null
            }
            @((Invoke-P 'restos' @{ id = 'cl:hkcu:Removido'; nome = 'Programa Qualquer'; editor = 'Microsoft' }).dados.candidatos | Where-Object { $_.tipo -eq 'chave' }).Count | Should -Be 0
            @((Invoke-P 'restos' @{ id = 'cl:hkcu:Removido'; nome = 'Windows'; editor = 'Editor Teste' }).dados.candidatos | Where-Object { $_.tipo -eq 'chave' }).Count | Should -Be 0
            @((Invoke-P 'restos' @{ id = 'cl:hkcu:Removido'; nome = 'Programa Qualquer'; editor = 'Classes' }).dados.candidatos | Where-Object { $_.tipo -eq 'chave' }).Count | Should -Be 0
        }
        It 'Review Focus 7: nunca devolve caminho protegido' {
            $r = Invoke-P 'restos' @{ id = 'cl:hkcu:X'; nome = 'Common Files'; local = (Join-Path $env:ProgramFiles 'Common Files') }
            $r.ok | Should -BeTrue
            @($r.dados.candidatos).Count | Should -Be 0
            $r = Invoke-P 'restos' @{ id = 'cl:hkcu:X'; nome = 'Temp'; local = (Join-Path $env:windir 'Temp') }
            @($r.dados.candidatos).Count | Should -Be 0
            $r = Invoke-P 'restos' @{ id = 'cl:hkcu:X'; nome = 'System32'; local = (Join-Path $env:windir 'System32') }
            @($r.dados.candidatos).Count | Should -Be 0
            # e com restos reais semeados, nenhum candidato cai em caminho protegido
            New-ArquivoTeste (Join-Path $Script:Restos 'LocalAppData\Editor Teste\Programa Qualquer\dados.txt') 70 40
            New-AtalhoTeste (Join-Path $Script:Restos 'Menu\Programa Qualquer.lnk') 'C:\nao-existe-nextune\pq.exe'
            New-ChaveOrfa
            $r = Invoke-P 'restos' @{ id = 'cl:hkcu:Removido'; nome = 'Programa Qualquer'; editor = 'Editor Teste'; local = (Join-Path $Script:Apps 'Qualquer') }
            $c = @($r.dados.candidatos)
            $c.Count | Should -Be 4
            foreach ($x in $c) { if ($x.tipo -ne 'chave') { Test-ProtectedPath $x.caminho | Should -BeFalse } }
        }
        It 'programa protegido nao gera candidatos' {
            $r = Invoke-P 'restos' @{ id = 'cl:hkcu:X'; nome = 'Microsoft Edge'; editor = 'Microsoft Corporation'; local = (Join-Path $Script:Apps 'Qualquer') }
            $r.ok | Should -BeTrue
            @($r.dados.candidatos).Count | Should -Be 0
        }
    }

    Context 'limparRestos' {
        It 'sem confirmado recusa' {
            $r = Invoke-P 'limparRestos' @{ itens = @(@{ tipo = 'pasta'; caminho = (Join-Path $Script:Apps 'Qualquer') }) }
            $r.ok | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $Script:Apps 'Qualquer\config.txt') | Should -BeTrue
        }
        It 'sem itens recusa' {
            (Invoke-P 'limparRestos' @{ itens = @(); confirmado = $true }).ok | Should -BeFalse
            (Invoke-P 'limparRestos' @{ confirmado = $true }).ok | Should -BeFalse
        }
        It 'Review Focus 7: caminho protegido vai para falhas com "protegido" e nada e movido' {
            $r = Invoke-P 'limparRestos' @{ itens = @(@{ tipo = 'pasta'; caminho = (Join-Path $env:windir 'Temp\x') }, @{ tipo = 'arquivo'; caminho = (Join-Path $env:ProgramFiles 'Common Files\x.txt') }); confirmado = $true }
            $r.ok | Should -BeTrue
            $r.dados.movidos | Should -Be 0
            $r.dados.quarentenaId | Should -BeNullOrEmpty
            @($r.dados.falhas).Count | Should -Be 2
            foreach ($f in @($r.dados.falhas)) { $f.erro | Should -Match 'protegido' }
            @(Get-ChildItem -LiteralPath $Script:Quar -Directory).Count | Should -Be 0
        }
        It 'move 1 pasta + 1 atalho quebrado numa unica entrada da quarentena com modulo programas' {
            $pasta = Join-Path $Script:Restos 'LocalAppData\Editor Teste\Programa Qualquer'
            $lnk = Join-Path $Script:Restos 'Menu\Programa Qualquer.lnk'
            New-ArquivoTeste (Join-Path $pasta 'dados.txt') 70 40
            New-AtalhoTeste $lnk 'C:\nao-existe-nextune\pq.exe'
            $r = Invoke-P 'limparRestos' @{ itens = @(@{ tipo = 'pasta'; caminho = $pasta }, @{ tipo = 'atalho'; caminho = $lnk }); confirmado = $true; nome = 'Programa Qualquer' }
            $r.ok | Should -BeTrue
            $r.dados.movidos | Should -Be 2
            @($r.dados.falhas).Count | Should -Be 0
            $r.dados.quarentenaId | Should -Match '^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$'
            Test-Path -LiteralPath $pasta | Should -BeFalse
            Test-Path -LiteralPath $lnk | Should -BeFalse
            $m = Get-Manifesto1 $r.dados.quarentenaId
            $m.modulo | Should -Be 'programas'
            $m.descricao | Should -Be 'Restos de Programa Qualquer'
            @($m.itens).Count | Should -Be 2
            $m.itens[0].tipo | Should -Be 'pasta'
            $m.itens[0].origem | Should -Match 'Editor Teste\\Programa Qualquer$'
            $m.itens[1].tipo | Should -Be 'arquivo'
            $m.itens[1].origem | Should -Match 'Menu\\Programa Qualquer\.lnk$'
            Test-Path -LiteralPath (Join-Path $Script:Quar "$($r.dados.quarentenaId)\itens\1\Programa Qualquer\dados.txt") | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $Script:Quar "$($r.dados.quarentenaId)\itens\2\Programa Qualquer.lnk") | Should -BeTrue
            @(Get-ChildItem -LiteralPath $Script:Quar -Directory).Count | Should -Be 1
        }
        It 'chave orfa vai para a quarentena como .reg e sai do registro' {
            New-ChaveOrfa
            $r = Invoke-P 'limparRestos' @{ itens = @(@{ tipo = 'chave'; caminho = $Script:ChaveOrfa }); confirmado = $true }
            $r.ok | Should -BeTrue
            $r.dados.movidos | Should -Be 1
            @($r.dados.falhas).Count | Should -Be 0
            Test-Path -LiteralPath (Join-Path $Script:RestosReg 'HKCU\Editor Teste\Programa Qualquer') | Should -BeFalse
            $reg = Join-Path $Script:Quar "$($r.dados.quarentenaId)\itens\1\chave.reg"
            Test-Path -LiteralPath $reg | Should -BeTrue
            $m = Get-Manifesto1 $r.dados.quarentenaId
            $m.itens[0].tipo | Should -Be 'chave'
            $m.itens[0].origem | Should -Be $Script:ChaveOrfa
        }
        It 'chave permitida mas fora da area de teste e recusada em modo teste' {
            $r = Invoke-P 'limparRestos' @{ itens = @(@{ tipo = 'chave'; caminho = 'HKCU\Software\Editor Teste\Programa Qualquer' }); confirmado = $true }
            $r.ok | Should -BeTrue
            $r.dados.movidos | Should -Be 0
            $r.dados.quarentenaId | Should -BeNullOrEmpty
            @($r.dados.falhas).Count | Should -Be 1
            $r.dados.falhas[0].erro | Should -Match 'NexTuneTeste'
            Test-Path -LiteralPath 'HKCU:\Software\Editor Teste' | Should -BeFalse
        }
        It 'chave fora de HKCU\Software ou HKLM\SOFTWARE, rasa ou em area proibida e recusada mesmo com confirmado' {
            $sub = Join-Path $Script:RestosReg 'HKCU\Microsoft\X'
            New-Item -Path $sub -Force | Out-Null
            $itens = @(
                @{ tipo = 'chave'; caminho = 'HKCU\Software\NexTuneTeste\Restos\HKCU\Microsoft\X' },
                @{ tipo = 'chave'; caminho = 'HKLM\SYSTEM\X' },
                @{ tipo = 'chave'; caminho = 'HKCU\Software' }
            )
            $r = Invoke-P 'limparRestos' @{ itens = $itens; confirmado = $true }
            $r.ok | Should -BeTrue
            $r.dados.movidos | Should -Be 0
            $r.dados.quarentenaId | Should -BeNullOrEmpty
            @($r.dados.falhas).Count | Should -Be 3
            foreach ($f in @($r.dados.falhas)) { $f.erro | Should -Match 'não permitida' }
            Test-Path -LiteralPath $sub | Should -BeTrue
            @(Get-ChildItem -LiteralPath $Script:Quar -Directory).Count | Should -Be 0
        }
        It 'tipo invalido, caminho relativo e atalho que nao e .lnk vao para falhas' {
            $r = Invoke-P 'limparRestos' @{ itens = @(@{ tipo = 'x'; caminho = 'C:\a' }, @{ tipo = 'pasta'; caminho = 'relativo\x' }, @{ tipo = 'atalho'; caminho = (Join-Path $Script:Apps 'Qualquer\config.txt') }); confirmado = $true }
            $r.ok | Should -BeTrue
            $r.dados.movidos | Should -Be 0
            $r.dados.quarentenaId | Should -BeNullOrEmpty
            @($r.dados.falhas).Count | Should -Be 3
            Test-Path -LiteralPath (Join-Path $Script:Apps 'Qualquer\config.txt') | Should -BeTrue
        }
        It 'item inexistente vira falha e os demais seguem na mesma entrada' {
            $pasta = Join-Path $Script:Restos 'LocalAppData\Programa Qualquer'
            New-ArquivoTeste (Join-Path $pasta 'dados.txt') 10 40
            $r = Invoke-P 'limparRestos' @{ itens = @(@{ tipo = 'pasta'; caminho = (Join-Path $Script:Restos 'LocalAppData\Nada') }, @{ tipo = 'pasta'; caminho = $pasta }); confirmado = $true }
            $r.ok | Should -BeTrue
            $r.dados.movidos | Should -Be 1
            @($r.dados.falhas).Count | Should -Be 1
            $r.dados.falhas[0].caminho | Should -Be (Join-Path $Script:Restos 'LocalAppData\Nada')
            $r.dados.quarentenaId | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath $pasta | Should -BeFalse
        }
    }

    Context 'restosAntigos' {
        # Decisao (documentada no plano): pasta que e de um programa instalado (mesmo nome limpo ou cru, local de
        # instalacao, pasta do desinstalador/icone/servico/destino de atalho) ou de um editor instalado NAO aparece;
        # "contem" (nos dois sentidos) e igualdade com exe/subpasta do InstallLocation, icone, servico ou destino de
        # atalho aparecem com seguro:false e o motivo. Subpasta da pasta de um editor instalado aparece, nunca segura.
        # AppData/LocalAppData nunca sao 'seguro'.
        BeforeAll {
            $Script:RA = Join-Path $Script:Base 'restosAntigos'
            function Set-IdadeArvore {
                # LastWriteTime e CreationTime de toda a arvore (e da propria pasta) para $Dias atras. Chamar antes de criar juncoes.
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
                [CmdletBinding()]
                param([string]$Pasta, [int]$Dias)
                $data = (Get-Date).AddDays(-$Dias)
                foreach ($i in @(@(Get-ChildItem -LiteralPath $Pasta -Recurse -Force) + @(Get-Item -LiteralPath $Pasta -Force))) {
                    $i.LastWriteTime = $data
                    $i.CreationTime = $data
                }
            }
            function New-PastaVelha {
                # Pasta com um arquivo de $Bytes bytes, toda envelhecida $Dias dias (padrao 40: passa da regra dos 30 dias).
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
                [CmdletBinding()]
                param([string]$Pasta, [string]$Arquivo = 'dados.txt', [int]$Bytes = 10, [int]$Dias = 40)
                New-ArquivoTeste (Join-Path $Pasta $Arquivo) $Bytes
                Set-IdadeArvore $Pasta $Dias
            }
            function Get-ItemRA {
                # Itens do resultado com esse caminho (comparando a forma longa dos dois lados).
                param($R, [string]$Caminho)
                $alvo = Get-CaminhoLongo $Caminho
                return @(@($R.dados.itens) | Where-Object { $null -ne $_ -and (Get-CaminhoLongo $_.caminho) -eq $alvo })
            }
        }
        BeforeEach {
            if (Test-Path -LiteralPath $Script:RA) { Remove-Item -LiteralPath $Script:RA -Recurse -Force -ErrorAction SilentlyContinue }
            foreach ($n in @('ProgramFiles', 'ProgramFilesX86', 'ProgramData', 'AppData', 'LocalAppData', 'Menu')) {
                New-Item -ItemType Directory -Path (Join-Path $Script:RA $n) -Force | Out-Null
            }
        }

        It 'sem nada para mostrar devolve itens vazio e incompleto:false' {
            $r = Invoke-P 'restosAntigos'
            $r.ok | Should -BeTrue
            @($r.dados.itens).Count | Should -Be 0
            $r.dados.incompleto | Should -BeFalse
            $Script:UltimaSaida | Should -Match '"itens":\[\],"incompleto":false'
        }
        It 'pasta de programa removido em Program Files ou ProgramData aparece com seguro:true, motivo e bytes corretos' {
            $pasta = Join-Path $Script:RA 'ProgramFiles\Programa Removido'
            New-ArquivoTeste (Join-Path $pasta 'sub\b.txt') 66
            New-PastaVelha $pasta 'dados.txt' 1234
            $r = Invoke-P 'restosAntigos' @{}
            $r.ok | Should -BeTrue
            $it = @(Get-ItemRA $r $pasta)
            $it.Count | Should -Be 1
            @($it[0].PSObject.Properties.Name) | Should -Be @('tipo', 'caminho', 'nome', 'bytes', 'seguro', 'motivo')
            $it[0].tipo | Should -Be 'pasta'
            $it[0].nome | Should -Be 'Programa Removido'
            $it[0].bytes | Should -Be 1300
            $it[0].seguro | Should -BeTrue
            $it[0].motivo | Should -Not -BeNullOrEmpty
            foreach ($raiz in @('ProgramFilesX86', 'ProgramData')) {
                New-PastaVelha (Join-Path $Script:RA "$raiz\Outro Removido")
            }
            $r = Invoke-P 'restosAntigos'
            foreach ($raiz in @('ProgramFilesX86', 'ProgramData')) {
                $x = @(Get-ItemRA $r (Join-Path $Script:RA "$raiz\Outro Removido"))
                $x.Count | Should -Be 1
                $x[0].seguro | Should -BeTrue
            }
        }
        It 'item em AppData ou LocalAppData aparece, mas nunca e seguro' {
            foreach ($raiz in @('AppData', 'LocalAppData')) { New-PastaVelha (Join-Path $Script:RA "$raiz\Outro Removido") }
            $r = Invoke-P 'restosAntigos'
            foreach ($raiz in @('AppData', 'LocalAppData')) {
                $x = @(Get-ItemRA $r (Join-Path $Script:RA "$raiz\Outro Removido"))
                $x.Count | Should -Be 1
                $x[0].seguro | Should -BeFalse
                $x[0].motivo | Should -Be 'Dados do usuário (configurações, chaves, jogos salvos): confira antes de mover.'
            }
        }
        It 'pasta com jogos salvos, chaves ou licencas aparece sem ser segura' {
            $jogo = Join-Path $Script:RA 'ProgramData\Jogo Antigo'
            New-PastaVelha (Join-Path $jogo 'Saved\SaveGames')
            Set-IdadeArvore $jogo 40
            $chaves = Join-Path $Script:RA 'ProgramFiles\Chaveiro'
            New-PastaVelha $chaves 'pubring.kbx'
            $lic = Join-Path $Script:RA 'ProgramFilesX86\Licenciado'
            New-PastaVelha $lic 'produto.lic'
            $r = Invoke-P 'restosAntigos'
            foreach ($p in @($jogo, $chaves, $lic)) {
                $x = @(Get-ItemRA $r $p)
                $x.Count | Should -Be 1
                $x[0].seguro | Should -BeFalse
                $x[0].motivo | Should -Match 'jogos salvos, chaves ou licenças'
            }
            (@(Get-ItemRA $r $jogo))[0].motivo | Should -Match 'Saved$'
            (@(Get-ItemRA $r $chaves))[0].motivo | Should -Match 'pubring\.kbx$'
        }
        It 'Review Focus 4: pasta "Adobe" com "Adobe Acrobat" instalado aparece com seguro:false e o motivo' {
            New-ProgramaFalso 'Acrobat' @{ DisplayName = 'Adobe Acrobat'; DisplayVersion = '24.1' }
            $adobe = Join-Path $Script:RA 'AppData\Adobe'
            New-PastaVelha $adobe
            $r = Invoke-P 'restosAntigos'
            $it = @(Get-ItemRA $r $adobe)
            $it.Count | Should -Be 1
            $it[0].seguro | Should -BeFalse
            $it[0].motivo | Should -Be 'Nome parecido com um programa instalado: Adobe Acrobat'
            # no outro sentido: a pasta contem o nome do instalado
            $servico = Join-Path $Script:RA 'ProgramData\Lenovo Vantage Service'
            New-PastaVelha $servico
            # e pelo editor
            New-ProgramaFalso 'Ferramenta' @{ DisplayName = 'Ferramenta Xyz'; Publisher = 'Distribuidora Grande Ltda' }
            $dist = Join-Path $Script:RA 'ProgramFiles\Distribuidora'
            New-PastaVelha $dist
            $r = Invoke-P 'restosAntigos'
            $x = @(Get-ItemRA $r $servico)
            $x.Count | Should -Be 1
            $x[0].seguro | Should -BeFalse
            $x[0].motivo | Should -Be 'Nome parecido com um programa instalado: Lenovo Vantage'
            $x = @(Get-ItemRA $r $dist)
            $x.Count | Should -Be 1
            $x[0].seguro | Should -BeFalse
            $x[0].motivo | Should -Be 'Nome parecido com o editor de um programa instalado: Distribuidora Grande Ltda'
            @($r.dados.itens | Where-Object { $_.seguro }).Count | Should -Be 0
        }
        It 'Review Focus 4: com o editor "Adobe Inc." a pasta Adobe vira pasta do editor: nao aparece e a subpasta antiga aparece sem ser segura' {
            New-ProgramaFalso 'Acrobat' @{ DisplayName = 'Adobe Acrobat DC (64-bit)'; Publisher = 'Adobe Inc.' }
            $adobe = Join-Path $Script:RA 'ProgramFilesX86\Adobe'
            New-PastaVelha (Join-Path $adobe 'Photoshop CS6')
            New-PastaVelha (Join-Path $adobe 'Acrobat DC')
            Set-IdadeArvore $adobe 40
            $r = Invoke-P 'restosAntigos'
            @(Get-ItemRA $r $adobe).Count | Should -Be 0
            $ps = @(Get-ItemRA $r (Join-Path $adobe 'Photoshop CS6'))
            $ps.Count | Should -Be 1
            $ps[0].seguro | Should -BeFalse
            $ps[0].motivo | Should -Match 'Adobe Inc\.'
            $ac = @(Get-ItemRA $r (Join-Path $adobe 'Acrobat DC'))
            $ac.Count | Should -Be 1
            $ac[0].seguro | Should -BeFalse
            $ac[0].motivo | Should -Be 'Nome parecido com um programa instalado: Adobe Acrobat DC (64-bit)'
        }
        It 'pasta de programa instalado (nome limpo igual, local, pasta do desinstalador, SystemComponent ou editor) nao aparece' {
            New-PastaVelha (Join-Path $Script:RA 'AppData\Programa Qualquer')
            New-PastaVelha (Join-Path $Script:RA 'ProgramFiles\Lenovo Vantage 10.2 (x64)')
            New-PastaVelha (Join-Path $Script:RA 'LocalAppData\Oculto')
            New-PastaVelha (Join-Path $Script:RA 'ProgramData\Positivo Tecnologia')
            $semNome = Join-Path $Script:RA 'ProgramFiles\Pasta Sem Nome'
            New-PastaVelha $semNome
            New-ProgramaFalso 'PorLocal' @{ DisplayName = 'Coisa Diferente'; InstallLocation = $semNome }
            $xyz = Join-Path $Script:RA 'ProgramFilesX86\XyzApp'
            New-PastaVelha $xyz
            New-ProgramaFalso 'PorDesinstalador' @{ DisplayName = 'Outro Nome'; UninstallString = ('"' + (Join-Path $xyz 'unins000.exe') + '" /x') }
            $icone = Join-Path $Script:RA 'ProgramData\IconeApp'
            New-PastaVelha $icone
            New-ProgramaFalso 'PorIcone' @{ DisplayName = 'Terceiro Nome'; DisplayIcon = ('"' + (Join-Path $icone 'app.exe') + '",0') }
            # pasta do editor 'Editor Teste' (de Programa Qualquer): ela nao aparece; dentro dela a do programa tambem nao
            $editor = Join-Path $Script:RA 'ProgramData\Editor Teste'
            New-PastaVelha (Join-Path $editor 'Programa Qualquer')
            New-PastaVelha (Join-Path $editor 'Plugin Velho')
            Set-IdadeArvore $editor 40
            $r = Invoke-P 'restosAntigos'
            $r.ok | Should -BeTrue
            $nomes = @($r.dados.itens | ForEach-Object { $_.nome })
            foreach ($n in @('Programa Qualquer', 'Lenovo Vantage 10.2 (x64)', 'Oculto', 'Positivo Tecnologia', 'Pasta Sem Nome', 'XyzApp', 'IconeApp', 'Editor Teste')) {
                $nomes | Should -Not -Contain $n
            }
            $plugin = @(Get-ItemRA $r (Join-Path $editor 'Plugin Velho'))
            $plugin.Count | Should -Be 1
            $plugin[0].seguro | Should -BeFalse
            $plugin[0].motivo | Should -Match 'Editor Teste'
            @($r.dados.itens).Count | Should -Be 1
        }
        It 'local de instalacao mais fundo (Editor\App): a pasta de cima so serve para descer e o terceiro nivel nunca e visitado' {
            $vendor = Join-Path $Script:RA 'ProgramFiles\Vendor'
            New-PastaVelha (Join-Path $vendor 'App')
            New-PastaVelha (Join-Path $vendor 'Outro')
            Set-IdadeArvore $vendor 40
            New-ProgramaFalso 'Fundo' @{ DisplayName = 'Aplicativo Fundo'; InstallLocation = (Join-Path $vendor 'App') }
            $suite = Join-Path $Script:RA 'ProgramFilesX86\Suite'
            New-PastaVelha (Join-Path $suite 'Pacote\App')
            New-PastaVelha (Join-Path $suite 'Pacote\Velho')
            New-PastaVelha (Join-Path $suite 'Pacote2')
            Set-IdadeArvore $suite 40
            New-ProgramaFalso 'MaisFundo' @{ DisplayName = 'Suite Profunda'; InstallLocation = (Join-Path $suite 'Pacote\App') }
            $r = Invoke-P 'restosAntigos'
            @(Get-ItemRA $r $vendor).Count | Should -Be 0
            @(Get-ItemRA $r (Join-Path $vendor 'App')).Count | Should -Be 0
            $outro = @(Get-ItemRA $r (Join-Path $vendor 'Outro'))
            $outro.Count | Should -Be 1
            $outro[0].seguro | Should -BeFalse
            $outro[0].motivo | Should -Match 'Aplicativo Fundo'
            @(Get-ItemRA $r $suite).Count | Should -Be 0
            @(Get-ItemRA $r (Join-Path $suite 'Pacote')).Count | Should -Be 0
            @(Get-ItemRA $r (Join-Path $suite 'Pacote\Velho')).Count | Should -Be 0
            $p2 = @(Get-ItemRA $r (Join-Path $suite 'Pacote2'))
            $p2.Count | Should -Be 1
            $p2[0].seguro | Should -BeFalse
            $Script:UltimaSaida | Should -Not -Match 'Pacote\\\\Velho'
        }
        It 'nome de exe ou subpasta sob o InstallLocation (FactoryGame.exe) faz a pasta de mesmo nome nao ser segura' {
            $sat = Join-Path $Script:Apps 'Satisfactory'
            New-ArquivoTeste (Join-Path $sat 'FactoryGame.exe') 5
            New-ArquivoTeste (Join-Path $sat 'Engine\x.txt') 5
            New-ProgramaFalso 'Satisfactory' @{ DisplayName = 'Satisfactory'; Publisher = 'Coffee Stain Studios'; InstallLocation = $sat }
            $fg = Join-Path $Script:RA 'LocalAppData\FactoryGame'
            New-PastaVelha $fg
            $fgPd = Join-Path $Script:RA 'ProgramData\FactoryGame'
            New-PastaVelha $fgPd
            $eng = Join-Path $Script:RA 'ProgramFiles\Engine'
            New-PastaVelha $eng
            $r = Invoke-P 'restosAntigos'
            foreach ($p in @($fg, $fgPd, $eng)) {
                foreach ($x in @(Get-ItemRA $r $p)) { $x.seguro | Should -BeFalse }
            }
            (@(Get-ItemRA $r $fgPd))[0].motivo | Should -Be 'Mesmo nome de algo que ainda está instalado: FactoryGame.exe de Satisfactory'
            (@(Get-ItemRA $r $eng))[0].motivo | Should -Match 'Mesmo nome de algo que ainda está instalado'
            @($r.dados.itens | Where-Object { $_.seguro }).Count | Should -Be 0
        }
        It 'VS Code instalado: %APPDATA%\Code nao e seguro' {
            $vs = Join-Path $Script:Apps 'Microsoft VS Code'
            New-ArquivoTeste (Join-Path $vs 'Code.exe') 5
            New-ProgramaFalso 'VSCode' @{ DisplayName = 'Microsoft Visual Studio Code'; Publisher = 'Microsoft Corporation'; InstallLocation = $vs }
            $code = Join-Path $Script:RA 'AppData\Code'
            New-PastaVelha (Join-Path $code 'User')
            Set-IdadeArvore $code 40
            $r = Invoke-P 'restosAntigos'
            foreach ($x in @(Get-ItemRA $r $code)) { $x.seguro | Should -BeFalse }
            @($r.dados.itens | Where-Object { $_.seguro }).Count | Should -Be 0
        }
        It 'servicos (simular.servicos): nome, nome de exibicao e pasta do executavel contam como instalado' {
            $pastaSvc = Join-Path $Script:RA 'ProgramFiles\PastaServico'
            New-PastaVelha $pastaSvc
            $svcVelho = Join-Path $Script:RA 'ProgramData\SvcVelho'
            New-PastaVelha $svcVelho
            $agente = Join-Path $Script:RA 'ProgramFilesX86\Agente Antigo'
            New-PastaVelha $agente
            $servicos = @(
                @{ nome = 'SvcVelho'; exibicao = 'Agente Antigo'; imagem = ('"' + (Join-Path $pastaSvc 'svc.exe') + '" -k rede') },
                @{ nome = 'OutroSvc'; exibicao = '@%SystemRoot%\system32\x.dll,-100'; imagem = '\SystemRoot\System32\drivers\x.sys' }
            )
            $r = Invoke-P 'restosAntigos' @{ simular = @{ servicos = $servicos } }
            $r.ok | Should -BeTrue
            @(Get-ItemRA $r $pastaSvc).Count | Should -Be 0
            foreach ($p in @($svcVelho, $agente)) {
                $x = @(Get-ItemRA $r $p)
                $x.Count | Should -Be 1
                $x[0].seguro | Should -BeFalse
                $x[0].motivo | Should -Match 'serviço SvcVelho'
            }
            Get-ImagemServico '\SystemRoot\System32\drivers\x.sys' | Should -Be (Join-Path $env:windir 'System32\drivers\x.sys')
            Get-ImagemServico 'system32\DRIVERS\y.sys' | Should -Be (Join-Path $env:windir 'system32\DRIVERS\y.sys')
            Get-ImagemServico '\??\C:\Programa\z.sys' | Should -Be 'C:\Programa\z.sys'
            Get-ImagemServico '' | Should -Be ''
        }
        It 'Store (simular.store): pasta com o editor de um app da Store nao aparece' {
            $fab = Join-Path $Script:RA 'ProgramData\Fabricante'
            New-PastaVelha $fab
            $sem = @(Get-ItemRA (Invoke-P 'restosAntigos') $fab)
            $sem.Count | Should -Be 1
            $sem[0].seguro | Should -BeTrue
            Mock Get-AppxPackage { throw 'Get-AppxPackage não deve ser chamado em modo teste' }
            $r = Invoke-P 'restosAntigos' @{ simular = @{ store = (New-StoreFalsa) } }
            $r.ok | Should -BeTrue
            Should -Invoke Get-AppxPackage -Times 0 -Exactly
            @(Get-ItemRA $r $fab).Count | Should -Be 0
        }
        It 'Store ilegivel (simular.erroStore): nenhuma pasta sai segura e o motivo diz por que' {
            $pasta = Join-Path $Script:RA 'ProgramFiles\Programa Removido'
            New-PastaVelha $pasta
            $r = Invoke-P 'restosAntigos' @{ simular = @{ erroStore = 'falha simulada' } }
            $r.ok | Should -BeTrue
            $x = @(Get-ItemRA $r $pasta)
            $x.Count | Should -Be 1
            $x[0].seguro | Should -BeFalse
            $x[0].motivo | Should -Match 'apps da Store'
            @($r.dados.itens | Where-Object { $_.tipo -eq 'pasta' -and $_.seguro }).Count | Should -Be 0
            $Script:UltimaSaida | Should -Match 'falha simulada'
        }
        It 'caminho protegido, nome de protegidos.json e pastas do Windows/Microsoft nunca aparecem' {
            $pastas = @(
                'ProgramFiles\Common Files', 'ProgramFiles\Microsoft Shared', 'ProgramFiles\Windows Defender', 'ProgramFiles\WindowsApps',
                'ProgramFiles\ModifiableWindowsApps', 'ProgramFiles\Internet Explorer', 'ProgramFiles\Reference Assemblies', 'ProgramFiles\dotnet',
                'ProgramFilesX86\Microsoft Office', 'ProgramFilesX86\MSBuild', 'ProgramData\Package Cache', 'ProgramData\Packages',
                'ProgramData\regid.1991-06.com.microsoft', 'ProgramData\Intel', 'ProgramData\NVIDIA Corporation', 'ProgramFiles\AMD',
                'ProgramFiles\Realtek', 'LocalAppData\Temp', 'LocalAppData\Programs', 'LocalAppData\Packages', 'AppData\.config',
                'ProgramData\NexTune Antigo', 'ProgramData\Dados do NexTune', 'ProgramFiles\Jogos DirectX', 'ProgramFiles\edgecore',
                'ProgramFiles\GameInput Extra', 'ProgramData\FLEXnet', 'ProgramData\Flexera Software', 'ProgramFiles\CodeMeter',
                'ProgramData\SafeNet Sentinel', 'ProgramData\Sentinel', 'AppData\gnupg', 'AppData\gcloud', 'LocalAppData\Apps',
                'LocalAppData\Deployment', 'ProgramData\Macrovision'
            )
            foreach ($p in $pastas) { New-PastaVelha (Join-Path $Script:RA $p) }
            New-PastaVelha (Join-Path $Script:RA 'ProgramFiles\Programa Removido')
            # 'edgecore' so e barrada por Test-ProtectedPath (nao esta na lista nem em protegidos.json)
            Test-ProtectedPath (Join-Path $Script:RA 'ProgramFiles\edgecore') | Should -BeTrue
            Test-NomeNuncaResto 'edgecore' | Should -BeFalse
            $r = Invoke-P 'restosAntigos'
            $r.ok | Should -BeTrue
            $itens = @($r.dados.itens)
            $itens.Count | Should -Be 1
            $itens[0].nome | Should -Be 'Programa Removido'
            foreach ($x in $itens) { Test-ProtectedPath $x.caminho | Should -BeFalse }
            foreach ($n in @('Microsoft Shared', 'Common Files', 'Windows Defender', 'WindowsApps', 'Package Cache', 'regid.1991-06.com.microsoft', 'NVIDIA Corporation', 'Temp', 'Programs', '.config', 'Dados do NexTune', 'gnupg', 'FLEXnet')) {
                Test-NomeNuncaResto $n | Should -BeTrue
            }
            Test-NomeNuncaResto 'Programa Removido' | Should -BeFalse
            Test-NomeNuncaResto 'Adobe' | Should -BeFalse
            Test-NomeNuncaResto 'IntelliJ' | Should -BeFalse
        }
        It 'juncao: a pasta que e juncao, a que tem juncao dentro e as que ficam abaixo de juncao nunca aparecem' {
            $jPasta = Join-Path $Script:RA 'ProgramFiles\Juncao Velha'
            $com = Join-Path $Script:RA 'ProgramData\Com Juncao'
            New-PastaVelha $com
            $jDentro = Join-Path $com 'jn'
            $alvo = Join-Path $Script:Base 'alvoJuncao'
            New-PastaVelha (Join-Path $alvo 'Programa Atras')
            $local = Join-Path $Script:RA 'LocalAppData'
            Remove-Item -LiteralPath $local -Force
            New-Juncao $jPasta $Script:Apps
            New-Juncao $jDentro $Script:Apps
            New-Juncao $local $alvo
            try {
                $r = Invoke-P 'restosAntigos'
                $r.ok | Should -BeTrue
                @(Get-ItemRA $r $jPasta).Count | Should -Be 0
                @(Get-ItemRA $r $com).Count | Should -Be 0
                @($r.dados.itens | Where-Object { $_.caminho -match 'Programa Atras' }).Count | Should -Be 0
                @($r.dados.itens).Count | Should -Be 0
            } finally {
                Remove-Juncao $jPasta
                Remove-Juncao $jDentro
                Remove-Juncao $local
            }
            # sem a juncao dentro, a pasta volta a aparecer (a juncao era o motivo)
            @(Get-ItemRA (Invoke-P 'restosAntigos') $com).Count | Should -Be 1
        }
        It 'pasta com programa ou script alterado ou criado ha menos de 30 dias nunca aparece; com executavel antigo aparece sem ser segura' {
            $dll = Join-Path $Script:RA 'ProgramFiles\Programa Dll'
            New-PastaVelha $dll
            New-ArquivoTeste (Join-Path $dll 'lib\x.dll') 5
            $sys = Join-Path $Script:RA 'ProgramData\Driver Velho'
            New-PastaVelha $sys
            New-ArquivoTeste (Join-Path $sys 'd.sys') 5
            $bat = Join-Path $Script:RA 'ProgramData\Script Novo'
            New-PastaVelha $bat
            New-ArquivoTeste (Join-Path $bat 'rodar.bat') 5
            # alterado ha 40 dias, mas copiado (criado) agora: tambem fica de fora
            $copiado = Join-Path $Script:RA 'ProgramFilesX86\Programa Copiado'
            New-ArquivoTeste (Join-Path $copiado 'app.exe') 5 40
            $velho = Join-Path $Script:RA 'ProgramFiles\Programa Exe Velho'
            New-PastaVelha $velho 'app.exe' 7
            $jar = Join-Path $Script:RA 'ProgramFiles\Programa Jar Velho'
            New-PastaVelha $jar 'app.jar' 9
            $r = Invoke-P 'restosAntigos'
            foreach ($p in @($dll, $sys, $bat, $copiado)) { @(Get-ItemRA $r $p).Count | Should -Be 0 }
            $x = @(Get-ItemRA $r $velho)
            $x.Count | Should -Be 1
            $x[0].seguro | Should -BeFalse
            $x[0].motivo | Should -Match 'programas ou scripts'
            $x[0].bytes | Should -Be 7
            $x = @(Get-ItemRA $r $jar)
            $x.Count | Should -Be 1
            $x[0].seguro | Should -BeFalse
        }
        It 'pasta alterada ou criada nos ultimos 30 dias ou com nome curto aparece sem ser segura' {
            $recente = Join-Path $Script:RA 'ProgramFiles\Pasta Recente'
            New-ArquivoTeste (Join-Path $recente 'dados.txt') 10
            $criada = Join-Path $Script:RA 'ProgramFilesX86\Pasta Copiada'
            New-ArquivoTeste (Join-Path $criada 'dados.txt') 10 40   # LastWriteTime antigo, CreationTime de agora
            $curta = Join-Path $Script:RA 'ProgramData\Xy'
            New-PastaVelha $curta
            $r = Invoke-P 'restosAntigos'
            foreach ($p in @($recente, $criada)) {
                $x = @(Get-ItemRA $r $p)
                $x.Count | Should -Be 1
                $x[0].seguro | Should -BeFalse
                $x[0].motivo | Should -Match 'últimos 30 dias'
            }
            $x = @(Get-ItemRA $r $curta)
            $x.Count | Should -Be 1
            $x[0].seguro | Should -BeFalse
            $x[0].motivo | Should -Match 'curto'
        }
        It 'pasta que estoura o teto de tempo por pasta fica de fora' {
            $pasta = Join-Path $Script:RA 'ProgramFiles\Programa Grande'
            New-PastaVelha $pasta
            $r = Invoke-P 'restosAntigos' @{ simular = @{ tetoPastaMs = 0 } }
            $r.ok | Should -BeTrue
            @(Get-ItemRA $r $pasta).Count | Should -Be 0
            $Script:UltimaSaida | Should -Match 'grande demais'
            @(Get-ItemRA (Invoke-P 'restosAntigos') $pasta).Count | Should -Be 1
        }
        It 'teto total: para, avisa e devolve incompleto:true' {
            New-PastaVelha (Join-Path $Script:RA 'ProgramFiles\Programa Removido')
            New-AtalhoTeste (Join-Path $Script:RA 'Menu\Removido.lnk') 'C:\nao-existe-nextune\pr.exe'
            $r = Invoke-P 'restosAntigos' @{ simular = @{ tetoTotalMs = 0 } }
            $r.ok | Should -BeTrue
            $r.dados.incompleto | Should -BeTrue
            @($r.dados.itens | Where-Object { $_.tipo -eq 'pasta' }).Count | Should -Be 0
            @($r.dados.itens | Where-Object { $_.tipo -eq 'atalho' }).Count | Should -Be 1
            $Script:UltimaSaida | Should -Match 'tempo máximo'
        }
        It 'atalho quebrado do Menu Iniciar aparece com tipo atalho; atalho valido nao, e a pasta do destino valido conta como instalada' {
            $quebrado = Join-Path $Script:RA 'Menu\Programa Removido\Programa Removido.lnk'
            New-AtalhoTeste $quebrado 'C:\nao-existe-nextune\pr.exe'
            New-AtalhoTeste (Join-Path $Script:RA 'Menu\Bloco de Notas.lnk') (Join-Path $env:windir 'System32\notepad.exe')
            $destino = Join-Path $Script:RA 'ProgramFilesX86\AtalhoApp'
            New-PastaVelha $destino 'leia.txt'
            New-AtalhoTeste (Join-Path $Script:RA 'Menu\Leia.lnk') (Join-Path $destino 'leia.txt')
            $r = Invoke-P 'restosAntigos'
            $r.ok | Should -BeTrue
            $itens = @($r.dados.itens)
            $itens.Count | Should -Be 1
            $itens[0].tipo | Should -Be 'atalho'
            Get-CaminhoLongo $itens[0].caminho | Should -Be (Get-CaminhoLongo $quebrado)
            $itens[0].nome | Should -Be 'Programa Removido'
            $itens[0].seguro | Should -BeTrue
            $itens[0].motivo | Should -Match 'não existe mais'
            $itens[0].bytes | Should -Be (Get-Item -LiteralPath $quebrado).Length
            $itens[0].bytes | Should -BeGreaterThan 0
        }
        It 'atalho quebrado com a pasta do destino ainda existindo ou destino em pasta protegida aparece sem ser seguro' {
            New-AtalhoTeste (Join-Path $Script:RA 'Menu\Atualizado.lnk') (Join-Path $Script:Apps 'Qualquer\sumiu.exe')
            New-AtalhoTeste (Join-Path $Script:RA 'Menu\Do Windows.lnk') (Join-Path $env:windir 'nao-existe-nextune.exe')
            $r = Invoke-P 'restosAntigos'
            $a = @(Get-ItemRA $r (Join-Path $Script:RA 'Menu\Atualizado.lnk'))
            $a.Count | Should -Be 1
            $a[0].seguro | Should -BeFalse
            $a[0].motivo | Should -Match 'ainda existe'
            $w = @(Get-ItemRA $r (Join-Path $Script:RA 'Menu\Do Windows.lnk'))
            $w.Count | Should -Be 1
            $w[0].seguro | Should -BeFalse
            $w[0].motivo | Should -Match 'pasta do Windows'
        }
        It 'atalho com destino em disco ausente aparece sem ser seguro' {
            $usadas = @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpperInvariant() })
            $livre = @('Z', 'Y', 'X', 'W', 'V', 'U', 'T', 'S', 'R', 'Q') | Where-Object { $usadas -notcontains $_ } | Select-Object -First 1
            if ($null -eq $livre) { Set-ItResult -Skipped -Because 'nenhuma letra de unidade livre'; return }
            $lnk = Join-Path $Script:RA 'Menu\Jogo no USB.lnk'
            $destino = $livre + ':\Jogos\jogo.exe'
            New-AtalhoTeste $lnk $destino
            if ((Get-AlvoAtalho $lnk) -notlike ($livre + ':\*')) { Set-ItResult -Skipped -Because 'o WScript nao guardou destino em unidade inexistente'; return }
            $r = Invoke-P 'restosAntigos'
            $x = @(Get-ItemRA $r $lnk)
            $x.Count | Should -Be 1
            $x[0].tipo | Should -Be 'atalho'
            $x[0].seguro | Should -BeFalse
            $x[0].motivo | Should -Match 'não está conectado'
        }
        It 'Get-NomeLimpo tira versao, arquitetura, parenteses e sufixos de empresa (funcao pura)' {
            Get-NomeLimpo 'Adobe Acrobat DC (64-bit)' | Should -Be 'Adobe Acrobat DC'
            Get-NomeLimpo '7-Zip 23.01 (x64)' | Should -Be '7-Zip'
            Get-NomeLimpo 'Mozilla Firefox (x64 pt-BR)' | Should -Be 'Mozilla Firefox'
            Get-NomeLimpo 'Positivo Tecnologia S.A.' | Should -Be 'Positivo Tecnologia'
            Get-NomeLimpo 'Notepad++ 8.6.2 x64' | Should -Be 'Notepad++'
            Get-NomeLimpo 'Python 3.12.1 (64-bit)' | Should -Be 'Python'
            Get-NomeLimpo 'Microsoft Visual C++ 2015-2022 Redistributable (x64) - 14.38.33135' | Should -Be 'Microsoft Visual C++ 2015-2022 Redistributable'
            Get-NomeLimpo 'Adobe Systems, Inc.' | Should -Be 'Adobe Systems'
            Get-NomeLimpo 'Google LLC' | Should -Be 'Google'
            Get-NomeLimpo 'Adobe Systems Incorporated' | Should -Be 'Adobe Systems'
            Get-NomeLimpo 'Spotify AB' | Should -Be 'Spotify'
            Get-NomeLimpo 'VLC media player v3.0.20' | Should -Be 'VLC media player'
            Get-NomeLimpo 'Inc' | Should -Be 'Inc'
            Get-NomeLimpo '' | Should -Be ''
            Get-NomeLimpo $null | Should -Be ''
            ConvertTo-NomeCompacto 'OBS Studio 30.0 (64-bit)' | Should -Be (ConvertTo-NomeCompacto 'obs-studio')
            ConvertTo-NomeCompacto 'Ferramentas Avançadas' | Should -Be 'ferramentasavancadas'
            ConvertTo-NomeCompacto 'Notepad++' | Should -Be 'notepad'
            @(Get-CompactoNome '7-Zip 23.01 (x64)') | Should -Be @('7zip', '7zip2301x64')
            @(Get-CompactoNome 'Steam') | Should -Be @('steam')
            @(Get-CompactoNome '').Count | Should -Be 0
            Test-NomeParecido 'adobe' 'adobeacrobat' | Should -BeTrue
            Test-NomeParecido 'lenovovantageservice' 'lenovovantage' | Should -BeTrue
            Test-NomeParecido 'rufus' 'r' | Should -BeFalse
            Test-NomeParecido 'programaremovido' 'programaqualquer' | Should -BeFalse
            Test-NomeParecido '' 'x' | Should -BeFalse
        }
        It 'texto com surrogate solto vira nome compacto vazio (nunca seguro) em vez de lancar' {
            $ruim = 'Programa' + [char]0xD800
            Test-TextoUnicode $ruim | Should -BeFalse
            Test-TextoUnicode ('a' + [char]0xDC00 + 'b') | Should -BeFalse
            Test-TextoUnicode ('Jogo ' + [char]0xD83D + [char]0xDE00) | Should -BeTrue
            Test-TextoUnicode 'Ferramentas Avançadas' | Should -BeTrue
            { ConvertTo-NomeCompacto $ruim } | Should -Not -Throw
            ConvertTo-NomeCompacto $ruim | Should -Be ''
            ConvertTo-Compacto ('a' + [char]0xDC00) | Should -Be ''
            @(Get-CompactoNome $ruim).Count | Should -Be 0
        }
        It 'raiz fora de disco local nao e percorrida e caminhos do Uninstall sao expandidos' {
            $sw = New-Object System.IO.StringWriter
            Set-Saida $sw
            try {
                Get-RaizValida 'p1' '\\servidor\perfis\AppData' | Should -Be ''
                Get-RaizValida 'p1' 'relativo\x' | Should -Be ''
            } finally { Set-Saida $null }
            $sw.ToString() | Should -Match 'não é percorrida'
            Get-CaminhoLongoResto '%windir%\System32' | Should -Be (Join-Path $env:windir 'System32')
            Get-CaminhoLongoResto '"%windir%\nao-existe-nextune\x"' | Should -Be (Join-Path $env:windir 'nao-existe-nextune\x')
            Get-CaminhoLongoResto '\\servidor\x' | Should -Be ''
            Get-CaminhoLongoResto '' | Should -Be ''
            Get-TipoUnidade $env:windir | Should -Be 'fixa'
            Get-TipoUnidade '\\servidor\x' | Should -Be 'ausente'
        }
    }

    Context 'acao desconhecida' {
        It 'devolve ok:false' {
            $r = Invoke-P 'formatar'
            $r.ok | Should -BeFalse
            $r.erro | Should -Be 'ação desconhecida'
        }
    }
}
