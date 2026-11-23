BeforeAll {
    . "$PSScriptRoot\..\common.ps1"
    . "$PSScriptRoot\..\drivers.ps1"
    $Script:PastaT = Join-Path (Join-Path $env:TEMP 'NexTuneTeste') 'drivers-passos'
    $Script:RaizBackup = Join-Path (Join-Path $env:TEMP 'NexTuneTeste') 'Drivers'

    function Invoke-Drv {
        param([string]$Acao, $Params = @{})
        $sw = New-Object System.IO.StringWriter
        Set-Saida $sw
        try { Invoke-Acao 'd1' $Acao $Params $true } finally { Set-Saida $null }
        $linhas = @($sw.ToString() -split "`r?`n" | Where-Object { $_.StartsWith('@@RESULT ') })
        if ($linhas.Count -ne 1) { return $null }
        return $linhas[0].Substring(9) | ConvertFrom-Json
    }
    function Test-Marcador {
        param([string]$Passo)
        return (Test-Path -LiteralPath (Join-Path $Script:PastaT ($Passo + '.txt')))
    }
    function Get-PastaBackupCriada {
        return @(Get-ChildItem -LiteralPath $Script:RaizBackup -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{8}-\d{6}' })
    }

    $Script:IdWebcam = 'USB\VID_046D&PID_0825&MI_00\6&2A0A5C8&0&0000'
    $Script:IdDisco = 'SCSI\DISK&VEN_NVME&PROD_SAMSUNG\5&1A2B3C&0&000000'
    $Script:IdRede = 'PCI\VEN_8086&SUBSYS_00008086&DEV_15B8\3&11583659&0&FE'
    $Script:IdRede2 = 'PCI\VEN_10EC&DEV_8168\4&2C1D7A0&0&00E4'
    $Script:Lista = @(
        @{ id = $Script:IdWebcam; nome = 'Webcam C270'; classe = 'Image'; codigo = 28 },
        @{ id = 'ROOT\DESATIVADO\0000'; nome = 'Desativado pelo usuario'; classe = 'Media'; codigo = 22 },
        @{ id = 'HDAUDIO\FUNC_01\0001'; nome = 'Alto-falantes'; classe = 'Media'; codigo = 0 },
        @{ id = $Script:IdDisco; nome = 'Samsung SSD'; classe = 'DiskDrive'; codigo = 10 },
        @{ id = 'BTH\MS_BTHPAN\7&1B2C'; nome = ''; descricao = 'Rede pessoal Bluetooth'; classe = 'Bluetooth'; codigo = 99 },
        @{ id = 'SWD\SEM\NOME'; classe = 'SoftwareDevice'; codigo = 31 }
    )
    $Script:Conhecidos = @(1, 3, 10, 12, 14, 16, 18, 19, 21, 24, 28, 29, 31, 32, 33, 34, 35, 37, 38, 39, 40, 41, 42, 43, 44,
        45, 46, 47, 48, 49, 50, 51, 52, 53, 54)
}

AfterAll { Remove-Item -LiteralPath (Join-Path $env:TEMP 'NexTuneTeste') -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'drivers.ps1: funcoes puras' {
    Context 'ConvertTo-FiltroWql' {
        It 'dobra a barra invertida do id' {
            ConvertTo-FiltroWql 'USB\VID_046D&PID_0825\6&2A0A5C8&0&0000' | Should -BeExactly 'PNPDeviceID = ''USB\\VID_046D&PID_0825\\6&2A0A5C8&0&0000'''
        }
        It 'escapa o apostrofo com barra' {
            ConvertTo-FiltroWql 'ROOT\X''Y' | Should -BeExactly 'PNPDeviceID = ''ROOT\\X\''Y'''
        }
        It 'barra antes de apostrofo nao abre o texto: a barra e dobrada antes de escapar o apostrofo' {
            ConvertTo-FiltroWql 'A\'' OR 1=1' | Should -BeExactly 'PNPDeviceID = ''A\\\'' OR 1=1'''
        }
    }

    Context 'Test-IdSeguro' {
        It 'aceita ids reais, inclusive com & e ? (WPD)' {
            Test-IdSeguro $Script:IdWebcam | Should -BeTrue
            Test-IdSeguro 'SWD\WPDBUSENUM\_??_USBSTOR#DISK&VEN_SANDISK#4C53&0#{53F56307-B6BF-11D0-94F2-00A0C91EFB8B}' | Should -BeTrue
        }
        It 'recusa espaco, aspas, controle, nao-ASCII e vazio' {
            Test-IdSeguro 'ROOT\COM ESPACO\0000' | Should -BeFalse
            Test-IdSeguro 'ROOT\X"Y\0000' | Should -BeFalse
            Test-IdSeguro ('ROOT\X' + [char]9 + 'Y') | Should -BeFalse
            Test-IdSeguro 'ROOT\AÇÃO\0000' | Should -BeFalse
            Test-IdSeguro '' | Should -BeFalse
        }
    }

    Context 'Get-ExplicacaoCodigo' {
        It 'todo codigo da tabela tem texto proprio, diferente do generico' {
            $generico = Get-ExplicacaoCodigo 9999
            foreach ($c in $Script:Conhecidos) {
                $t = Get-ExplicacaoCodigo $c
                $t | Should -Not -BeNullOrEmpty
                $t | Should -Not -Be ($generico -replace '9999', [string]$c)
            }
        }
        It 'codigo desconhecido tem texto generico com o numero' {
            Get-ExplicacaoCodigo 99 | Should -Match '\b99\b'
            Get-ExplicacaoCodigo 99 | Should -Match 'código de erro'
        }
        It 'textos em pt-BR dizem o que fazer' {
            Get-ExplicacaoCodigo 14 | Should -Match 'Reinicie'
            Get-ExplicacaoCodigo 28 | Should -Match 'driver'
        }
    }

    Context 'Test-DispositivoCritico' {
        It 'classes criticas nunca sao reinstaladas' {
            foreach ($c in @('DiskDrive', 'HDC', 'SCSIAdapter', 'Display', 'System', 'Processor', 'Computer', 'Volume', 'VolumeSnapshot', 'Keyboard', 'Mouse', 'HIDClass', 'USB', 'Firmware', 'SecurityDevices', 'SDHost', 'Battery')) {
                Test-DispositivoCritico $c 'X\1' @() | Should -BeTrue -Because $c
            }
        }
        It 'classe comum nao e critica' {
            foreach ($c in @('Image', 'Media', 'Bluetooth', 'Printer', '')) {
                Test-DispositivoCritico $c 'X\1' @() | Should -BeFalse -Because $c
            }
        }
        It 'Net e critica so quando e o unico adaptador fisico ativo' {
            Test-DispositivoCritico 'Net' $Script:IdRede @($Script:IdRede) | Should -BeTrue
            Test-DispositivoCritico 'Net' $Script:IdRede @($Script:IdRede.ToLowerInvariant()) | Should -BeTrue
            Test-DispositivoCritico 'Net' $Script:IdRede @($Script:IdRede, $Script:IdRede2) | Should -BeFalse
            Test-DispositivoCritico 'Net' $Script:IdRede @($Script:IdRede2) | Should -BeFalse
            Test-DispositivoCritico 'Net' $Script:IdRede @() | Should -BeFalse
        }
        It 'Net sem conseguir ler os adaptadores conta como critica' {
            Test-DispositivoCritico 'Net' $Script:IdRede $null | Should -BeTrue
        }
    }
}

Describe 'drivers.ps1: listar' {
    It 'lista so codigos diferentes de 0 e 22, com a explicacao em pt-BR' {
        $r = Invoke-Drv 'listar' @{ simular = @{ dispositivos = $Script:Lista } }
        $r.ok | Should -BeTrue
        $d = @($r.dados.dispositivos)
        $d.Count | Should -Be 4
        $d.id | Should -Not -Contain 'ROOT\DESATIVADO\0000'
        $d.id | Should -Not -Contain 'HDAUDIO\FUNC_01\0001'
        $web = $d | Where-Object { $_.id -eq $Script:IdWebcam }
        $web.codigo | Should -Be 28
        $web.classe | Should -Be 'Image'
        $web.explicacao | Should -BeExactly (Get-ExplicacaoCodigo 28)
    }
    It 'codigo desconhecido vem com o texto generico e o numero' {
        $r = Invoke-Drv 'listar' @{ simular = @{ dispositivos = $Script:Lista } }
        $bt = @($r.dados.dispositivos) | Where-Object { $_.codigo -eq 99 }
        $bt.explicacao | Should -Match '\b99\b'
    }
    It 'nome cai para a descricao e depois para o id' {
        $d = @((Invoke-Drv 'listar' @{ simular = @{ dispositivos = $Script:Lista } }).dados.dispositivos)
        ($d | Where-Object { $_.codigo -eq 99 }).nome | Should -Be 'Rede pessoal Bluetooth'
        ($d | Where-Object { $_.codigo -eq 31 }).nome | Should -Be 'SWD\SEM\NOME'
    }
    It 'critico por classe' {
        $d = @((Invoke-Drv 'listar' @{ simular = @{ dispositivos = $Script:Lista } }).dados.dispositivos)
        ($d | Where-Object { $_.id -eq $Script:IdDisco }).critico | Should -BeTrue
        ($d | Where-Object { $_.id -eq $Script:IdWebcam }).critico | Should -BeFalse
    }
    It 'adaptador de rede com problema e critico so se for o unico ativo' {
        $rede = @(@{ id = $Script:IdRede; nome = 'Intel Ethernet'; classe = 'Net'; codigo = 10 })
        $r = Invoke-Drv 'listar' @{ simular = @{ dispositivos = $rede; adaptadoresAtivos = @($Script:IdRede) } }
        @($r.dados.dispositivos)[0].critico | Should -BeTrue
        $r = Invoke-Drv 'listar' @{ simular = @{ dispositivos = $rede; adaptadoresAtivos = @($Script:IdRede, $Script:IdRede2) } }
        @($r.dados.dispositivos)[0].critico | Should -BeFalse
    }
    It 'dispositivo nao presente (fantasma) fica fora da lista' {
        $lista = @(
            @{ id = $Script:IdWebcam; nome = 'Webcam C270'; classe = 'Image'; codigo = 28; presente = $false },
            @{ id = $Script:IdDisco; nome = 'Samsung SSD'; classe = 'DiskDrive'; codigo = 10; presente = $true }
        )
        $d = @((Invoke-Drv 'listar' @{ simular = @{ dispositivos = $lista } }).dados.dispositivos)
        $d.Count | Should -Be 1
        $d[0].id | Should -Be $Script:IdDisco
    }
    It 'sem simulacao em teste nao le o sistema e devolve lista vazia' {
        Mock Get-CimInstance { throw 'nao deveria rodar' }
        $r = Invoke-Drv 'listar'
        $r.ok | Should -BeTrue
        @($r.dados.dispositivos).Count | Should -Be 0
        Should -Invoke Get-CimInstance -Times 0
    }
    It 'acao desconhecida falha' {
        (Invoke-Drv 'apagar').ok | Should -BeFalse
    }
}

Describe 'drivers.ps1: reparar' {
    BeforeEach { Remove-Item -LiteralPath $Script:PastaT -Recurse -Force -ErrorAction SilentlyContinue }

    It 'exige confirmado:true (ausente, false ou texto)' {
        $sim = @{ dispositivos = $Script:Lista }
        foreach ($p in @(@{ id = $Script:IdWebcam; simular = $sim }, @{ id = $Script:IdWebcam; confirmado = $false; simular = $sim }, @{ id = $Script:IdWebcam; confirmado = 'true'; simular = $sim })) {
            $r = Invoke-Drv 'reparar' $p
            $r.ok | Should -BeFalse
            $r.erro | Should -Match 'confirma'
        }
        Test-Marcador 'reiniciar' | Should -BeFalse
    }
    It 'id fora da lista falha sem rodar nada' {
        $r = Invoke-Drv 'reparar' @{ id = 'USB\NAO\EXISTE'; confirmado = $true; simular = @{ dispositivos = $Script:Lista } }
        $r.ok | Should -BeFalse
        $r.erro | Should -Be 'dispositivo não encontrado ou já sem problema'
        Test-Marcador 'reiniciar' | Should -BeFalse
        Test-Marcador 'procurar' | Should -BeFalse
    }
    It 'dispositivo nao presente (fantasma) nao e reparado' {
        $sim = @{ dispositivos = @(@{ id = $Script:IdWebcam; nome = 'Webcam'; classe = 'Image'; codigo = 28; presente = $false; resolveNo = 'reiniciar' }) }
        $r = Invoke-Drv 'reparar' @{ id = $Script:IdWebcam; confirmado = $true; simular = $sim }
        $r.ok | Should -BeFalse
        $r.erro | Should -Be 'dispositivo não encontrado ou já sem problema'
        Test-Marcador 'reiniciar' | Should -BeFalse
    }
    It 'id com espaco ou aspas e recusado antes de qualquer passo' {
        foreach ($id in @('ROOT\COM ESPACO\0000', 'ROOT\COM"ASPAS\0000')) {
            $sim = @{ dispositivos = @(@{ id = $id; nome = 'Estranho'; classe = 'Image'; codigo = 28; resolveNo = 'reiniciar' }) }
            $r = Invoke-Drv 'reparar' @{ id = $id; confirmado = $true; simular = $sim }
            $r.ok | Should -BeFalse
            $r.erro | Should -Match 'inválidos'
        }
        Test-Marcador 'reiniciar' | Should -BeFalse
        Test-Marcador 'desligar' | Should -BeFalse
        Test-Marcador 'procurar' | Should -BeFalse
    }
    It 'desligar que falha ainda religa o dispositivo (finally)' {
        $sim = @{ dispositivos = @(@{ id = $Script:IdWebcam; nome = 'Webcam'; classe = 'Image'; codigo = 43 }); falharDesligar = $true }
        $r = Invoke-Drv 'reparar' @{ id = $Script:IdWebcam; confirmado = $true; simular = $sim }
        $r.ok | Should -BeTrue
        $r.dados.passos[0].passo | Should -Be 'reiniciar'
        $r.dados.passos[0].ok | Should -BeFalse
        Test-Marcador 'desligar' | Should -BeTrue
        Test-Marcador 'religar' | Should -BeTrue
    }
    It 'religar que falha marca o passo como falho e segue para o proximo' {
        $sim = @{ dispositivos = @(@{ id = $Script:IdWebcam; nome = 'Webcam'; classe = 'Image'; codigo = 43; resolveNo = 'reinstalar' }); falharReligar = $true }
        $r = Invoke-Drv 'reparar' @{ id = $Script:IdWebcam; confirmado = $true; simular = $sim }
        $r.dados.passos[0].ok | Should -BeFalse
        @($r.dados.passos).passo | Should -Be @('reiniciar', 'reinstalar')
        $r.dados.resolvido | Should -BeTrue
    }
    It 'dispositivo desativado (22) ou funcionando (0) nao e reparado' {
        foreach ($id in @('ROOT\DESATIVADO\0000', 'HDAUDIO\FUNC_01\0001')) {
            (Invoke-Drv 'reparar' @{ id = $id; confirmado = $true; simular = @{ dispositivos = $Script:Lista } }).ok | Should -BeFalse
        }
        Test-Marcador 'reiniciar' | Should -BeFalse
    }
    It 'para no primeiro passo quando desligar e ligar resolve' {
        $sim = @{ dispositivos = @(@{ id = $Script:IdWebcam; nome = 'Webcam'; classe = 'Image'; codigo = 43; resolveNo = 'reiniciar' }) }
        $r = Invoke-Drv 'reparar' @{ id = $Script:IdWebcam; confirmado = $true; simular = $sim }
        $r.ok | Should -BeTrue
        $r.dados.resolvido | Should -BeTrue
        $r.dados.precisaReiniciar | Should -BeFalse
        @($r.dados.passos).Count | Should -Be 1
        $r.dados.passos[0].passo | Should -Be 'reiniciar'
        $r.dados.passos[0].ok | Should -BeTrue
        $r.dados.passos[0].codigoDepois | Should -Be 0
        Test-Marcador 'reiniciar' | Should -BeTrue
        Test-Marcador 'desligar' | Should -BeTrue
        Test-Marcador 'religar' | Should -BeTrue
        Test-Marcador 'reinstalar' | Should -BeFalse
        Test-Marcador 'procurar' | Should -BeFalse
    }
    It 'para no segundo passo quando reinstalar resolve' {
        $sim = @{ dispositivos = @(@{ id = $Script:IdWebcam; nome = 'Webcam'; classe = 'Image'; codigo = 28; resolveNo = 'reinstalar' }) }
        $r = Invoke-Drv 'reparar' @{ id = $Script:IdWebcam; confirmado = $true; simular = $sim }
        $r.dados.resolvido | Should -BeTrue
        @($r.dados.passos).passo | Should -Be @('reiniciar', 'reinstalar')
        $r.dados.passos[0].codigoDepois | Should -Be 28
        $r.dados.passos[1].codigoDepois | Should -Be 0
        Test-Marcador 'reinstalar' | Should -BeTrue
        Test-Marcador 'procurar' | Should -BeFalse
    }
    It 'roda os tres passos quando so procurar hardware resolve' {
        $sim = @{ dispositivos = @(@{ id = $Script:IdWebcam; nome = 'Webcam'; classe = 'Image'; codigo = 24; resolveNo = 'procurar' }) }
        $r = Invoke-Drv 'reparar' @{ id = $Script:IdWebcam; confirmado = $true; simular = $sim }
        $r.dados.resolvido | Should -BeTrue
        @($r.dados.passos).passo | Should -Be @('reiniciar', 'reinstalar', 'procurar')
        $r.dados.passos[2].codigoDepois | Should -Be 0
        Test-Marcador 'procurar' | Should -BeTrue
    }
    It 'nada resolve: tres passos e resolvido false' {
        $sim = @{ dispositivos = @(@{ id = $Script:IdWebcam; nome = 'Webcam'; classe = 'Image'; codigo = 10 }) }
        $r = Invoke-Drv 'reparar' @{ id = $Script:IdWebcam; confirmado = $true; simular = $sim }
        $r.ok | Should -BeTrue
        $r.dados.resolvido | Should -BeFalse
        @($r.dados.passos).Count | Should -Be 3
        @($r.dados.passos).codigoDepois | Should -Be @(10, 10, 10)
    }
    It 'classe critica so procura hardware: nem desliga nem reinstala' {
        foreach ($resolve in @('reiniciar', 'reinstalar')) {
            Remove-Item -LiteralPath $Script:PastaT -Recurse -Force -ErrorAction SilentlyContinue
            $sim = @{ dispositivos = @(@{ id = $Script:IdDisco; nome = 'Samsung SSD'; classe = 'DiskDrive'; codigo = 10; resolveNo = $resolve }) }
            $r = Invoke-Drv 'reparar' @{ id = $Script:IdDisco; confirmado = $true; simular = $sim }
            $r.ok | Should -BeTrue
            $r.dados.resolvido | Should -BeFalse
            @($r.dados.passos).Count | Should -Be 1
            $r.dados.passos[0].passo | Should -Be 'procurar'
            Test-Marcador 'reiniciar' | Should -BeFalse
            Test-Marcador 'desligar' | Should -BeFalse
            Test-Marcador 'reinstalar' | Should -BeFalse
            Test-Marcador 'procurar' | Should -BeTrue
        }
    }
    It 'classe critica resolvida ao procurar hardware' {
        $sim = @{ dispositivos = @(@{ id = $Script:IdDisco; nome = 'Samsung SSD'; classe = 'DiskDrive'; codigo = 10; resolveNo = 'procurar' }) }
        $r = Invoke-Drv 'reparar' @{ id = $Script:IdDisco; confirmado = $true; simular = $sim }
        $r.dados.resolvido | Should -BeTrue
        @($r.dados.passos).passo | Should -Be 'procurar'
    }
    It 'unico adaptador de rede ativo so procura hardware' {
        $sim = @{ dispositivos = @(@{ id = $Script:IdRede; nome = 'Intel Ethernet'; classe = 'Net'; codigo = 10; resolveNo = 'reinstalar' }); adaptadoresAtivos = @($Script:IdRede) }
        $r = Invoke-Drv 'reparar' @{ id = $Script:IdRede; confirmado = $true; simular = $sim }
        @($r.dados.passos).Count | Should -Be 1
        $r.dados.passos[0].passo | Should -Be 'procurar'
        Test-Marcador 'reiniciar' | Should -BeFalse
        Test-Marcador 'reinstalar' | Should -BeFalse
    }
    It 'adaptador de rede com outro ativo nao e critico e segue os tres passos' {
        $sim = @{ dispositivos = @(@{ id = $Script:IdRede; nome = 'Intel Ethernet'; classe = 'Net'; codigo = 10; resolveNo = 'reinstalar' }); adaptadoresAtivos = @($Script:IdRede, $Script:IdRede2) }
        $r = Invoke-Drv 'reparar' @{ id = $Script:IdRede; confirmado = $true; simular = $sim }
        $r.dados.resolvido | Should -BeTrue
        @($r.dados.passos).passo | Should -Be @('reiniciar', 'reinstalar')
    }
    It 'id casa sem diferenciar maiusculas' {
        $sim = @{ dispositivos = @(@{ id = $Script:IdWebcam; nome = 'Webcam'; classe = 'Image'; codigo = 43; resolveNo = 'reiniciar' }) }
        $r = Invoke-Drv 'reparar' @{ id = $Script:IdWebcam.ToLowerInvariant(); confirmado = $true; simular = $sim }
        $r.ok | Should -BeTrue
        $r.dados.resolvido | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $Script:PastaT 'reiniciar.txt') -Raw) | Should -MatchExactly ([regex]::Escape($Script:IdWebcam))
    }
    It 'codigo 14 ou 21 antes de qualquer passo: nao toca o dispositivo e pede reinicio' {
        foreach ($c in @(14, 21)) {
            $sim = @{ dispositivos = @(@{ id = $Script:IdWebcam; nome = 'Webcam'; classe = 'Image'; codigo = $c; resolveNo = 'reiniciar' }) }
            $r = Invoke-Drv 'reparar' @{ id = $Script:IdWebcam; confirmado = $true; simular = $sim }
            $r.ok | Should -BeTrue
            $r.dados.resolvido | Should -BeFalse
            $r.dados.precisaReiniciar | Should -BeTrue
            @($r.dados.passos).Count | Should -Be 0
        }
        Test-Marcador 'reiniciar' | Should -BeFalse
        Test-Marcador 'desligar' | Should -BeFalse
        Test-Marcador 'procurar' | Should -BeFalse
    }
    It 'pnputil com 3010 pede reinicio' {
        $sim = @{ dispositivos = @(@{ id = $Script:IdWebcam; nome = 'Webcam'; classe = 'Image'; codigo = 28; resolveNo = 'reinstalar' }); codigoPnputil = 3010 }
        $r = Invoke-Drv 'reparar' @{ id = $Script:IdWebcam; confirmado = $true; simular = $sim }
        $r.dados.resolvido | Should -BeTrue
        $r.dados.passos[1].ok | Should -BeTrue
        $r.dados.precisaReiniciar | Should -BeTrue
    }
}

Describe 'drivers.ps1: backup' {
    BeforeEach { Remove-Item -LiteralPath $Script:RaizBackup -Recurse -Force -ErrorAction SilentlyContinue }

    It 'exige confirmado:true (ausente, false ou texto)' {
        foreach ($p in @(@{ simular = @{ exportados = 2 } }, @{ confirmado = $false; simular = @{ exportados = 2 } }, @{ confirmado = 'true'; simular = @{ exportados = 2 } })) {
            $r = Invoke-Drv 'backup' $p
            $r.ok | Should -BeFalse
            $r.erro | Should -Match 'confirma'
        }
        @(Get-PastaBackupCriada).Count | Should -Be 0
    }
    It 'cria a pasta AAAAMMDD-HHMMSS e conta so as pastas com .inf' {
        $r = Invoke-Drv 'backup' @{ confirmado = $true; simular = @{ exportados = 3; pastasSemInf = 1 } }
        $r.ok | Should -BeTrue
        $r.dados.quantidade | Should -Be 3
        $r.dados.codigo | Should -Be 0
        Split-Path -Leaf $r.dados.pasta | Should -Match '^\d{8}-\d{6}$'
        Split-Path -Parent $r.dados.pasta | Should -Be $Script:RaizBackup
        Test-Path -LiteralPath $r.dados.pasta | Should -BeTrue
    }
    It 'usa a data e a hora do backup no nome; no mesmo segundo ganha -2 e -3' {
        $p = @{ confirmado = $true; simular = @{ exportados = 1; quando = '2026-11-23T10:20:30' } }
        Split-Path -Leaf (Invoke-Drv 'backup' $p).dados.pasta | Should -Be '20261123-102030'
        Split-Path -Leaf (Invoke-Drv 'backup' $p).dados.pasta | Should -Be '20261123-102030-2'
        Split-Path -Leaf (Invoke-Drv 'backup' $p).dados.pasta | Should -Be '20261123-102030-3'
    }
    It 'codigo de erro sem nenhum driver exportado falha com mensagem' {
        $r = Invoke-Drv 'backup' @{ confirmado = $true; simular = @{ exportados = 0; codigo = 5 } }
        $r.ok | Should -BeFalse
        $r.erro | Should -Match 'código 5'
        @(Get-PastaBackupCriada).Count | Should -Be 0
    }
    It 'codigo de erro com drivers exportados devolve a quantidade e o codigo' {
        $r = Invoke-Drv 'backup' @{ confirmado = $true; simular = @{ exportados = 2; codigo = 1 } }
        $r.ok | Should -BeTrue
        $r.dados.quantidade | Should -Be 2
        $r.dados.codigo | Should -Be 1
    }
}
