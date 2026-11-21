# diagnostico.ps1 - coleta de hardware/sistema e perfil da maquina (classe + disco).
# Acao: coletar. Params opcionais: forcarPerfil {classe, disco}; simular (somente em modo de teste).
. "$PSScriptRoot\common.ps1"

$Script:ClassesValidas = @('basico', 'medio', 'gamer')
$Script:DiscosValidos = @('hdd', 'ssd')

function Get-RegrasPerfil {
    param([string]$DataDir = (Join-Path $PSScriptRoot '..\data'))
    $arq = Join-Path $DataDir 'perfis.json'
    try { return (Get-Content -LiteralPath $arq -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw "perfis.json ilegivel em ${DataDir}: $($_.Exception.Message)" }
}

function Get-ClasseEDisco {
    # Classificador puro: basico se QUALQUER criterio bater; gamer se TODOS baterem; senao padrao.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    param($Bruto, $Regras)
    $ram = $Bruto.ramGb
    $nuc = $Bruto.nucleos
    $rb = $Regras.classes.basico
    $rg = $Regras.classes.gamer

    $basico = $false
    if ($null -ne $ram -and $null -ne $rb.ramGbMax -and [double]$ram -le [double]$rb.ramGbMax) { $basico = $true }
    if ($null -ne $nuc -and $null -ne $rb.nucleosMax -and [double]$nuc -le [double]$rb.nucleosMax) { $basico = $true }

    $gamer = $true
    if ($null -ne $rg.gpuDedicada -and ([bool]$Bruto.gpuDedicada -ne [bool]$rg.gpuDedicada)) { $gamer = $false }
    if ($null -ne $rg.ramGbMin -and ($null -eq $ram -or [double]$ram -lt [double]$rg.ramGbMin)) { $gamer = $false }

    if ($basico) { $classe = 'basico' }
    elseif ($gamer) { $classe = 'gamer' }
    else { $classe = [string]$Regras.classes.padrao }

    # Disco: HDD -> hdd; SSD/SCM -> ssd; Unspecified com NVMe -> ssd; ilegivel -> hdd (conservador).
    $media = [string]$Bruto.discoSistemaMediaType
    $bus = [string]$Bruto.discoSistemaBusType
    if ($media -eq 'HDD') { $disco = 'hdd' }
    elseif ($media -eq 'SSD' -or $media -eq 'SCM') { $disco = 'ssd' }
    elseif ($bus -eq 'NVMe') { $disco = 'ssd' }
    else { $disco = 'hdd' }

    return @{ classe = $classe; disco = $disco }
}

function Get-BrutoSimulado {
    # 'simular' so vale em modo de teste; fora dele e ignorado.
    param($Params, [bool]$Teste)
    if (-not $Teste -or $null -eq $Params) { return $null }
    return $Params.simular
}

function Get-FabricanteGpu {
    param([string]$Nome, [string]$Compat)
    $t = "$Nome $Compat"
    if ($t -match 'NVIDIA') { return 'nvidia' }
    if ($t -match 'AMD|ATI |Radeon|Advanced Micro') { return 'amd' }
    if ($t -match 'Intel') { return 'intel' }
    return 'outro'
}

function Test-GpuDedicada {
    param([string]$Fabricante, [string]$Nome)
    if ($Fabricante -ne 'nvidia' -and $Fabricante -ne 'amd') { return $false }
    if ($Nome -match 'Radeon\(TM\) Graphics|Vega|Iris|UHD|HD Graphics|Graphics \d{3,4}$') { return $false }
    return $true
}

function Get-InfoDiscoFisico {
    # Devolve @{ Lista = object[]; MediaSistema; BusSistema }
    $sysDev = $null
    $mediaSis = $null
    $busSis = $null
    try {
        $letra = $env:SystemDrive[0]
        $pd = Get-Partition -DriveLetter $letra -ErrorAction Stop | Get-Disk -ErrorAction Stop | Get-PhysicalDisk -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $pd) {
            $sysDev = [string]$pd.DeviceId
            $mediaSis = [string]$pd.MediaType
            $busSis = [string]$pd.BusType
        }
    } catch { $null = $_ }

    $lista = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($d in @(Get-PhysicalDisk -ErrorAction Stop)) {
            $rc = $null
            try { $rc = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch { $null = $_ }
            $erros = $null
            if ($null -ne $rc -and ($null -ne $rc.ReadErrorsTotal -or $null -ne $rc.WriteErrorsTotal)) {
                $erros = [int64]$rc.ReadErrorsTotal + [int64]$rc.WriteErrorsTotal
            }
            $lista.Add([ordered]@{
                nome        = [string]$d.FriendlyName
                tipo        = Get-TipoDisco ([string]$d.MediaType) ([string]$d.BusType)
                bus         = [string]$d.BusType
                tamanho     = [int64]$d.Size
                saude       = [string]$d.HealthStatus
                desgaste    = if ($null -ne $rc) { $rc.Wear } else { $null }
                temperatura = if ($null -ne $rc) { $rc.Temperature } else { $null }
                horas       = if ($null -ne $rc) { $rc.PowerOnHours } else { $null }
                erros       = $erros
                sistema     = ($null -ne $sysDev -and [string]$d.DeviceId -eq $sysDev)
            })
        }
    } catch { $null = $_ }

    if ($lista.Count -eq 0) {
        # Fallback: Win32_DiskDrive (sem contadores de confiabilidade)
        try {
            foreach ($d in @(Get-CimInstance Win32_DiskDrive -ErrorAction Stop)) {
                $lista.Add([ordered]@{
                    nome        = [string]$d.Model
                    tipo        = if ([string]$d.Model -match 'NVMe') { 'NVMe' } elseif ([string]$d.Model -match 'SSD') { 'SSD' } else { 'HDD' }
                    bus         = [string]$d.InterfaceType
                    tamanho     = [int64]$d.Size
                    saude       = [string]$d.Status
                    desgaste    = $null
                    temperatura = $null
                    horas       = $null
                    erros       = $null
                    sistema     = ([string]$d.Index -eq '0')
                })
            }
        } catch { $null = $_ }
    }

    # Garante exatamente um disco do sistema quando houver discos (fallback: o primeiro).
    $marcados = @($lista | Where-Object { $_.sistema -eq $true }).Count
    if ($lista.Count -gt 0 -and $marcados -ne 1) {
        for ($i = 0; $i -lt $lista.Count; $i++) { $lista[$i].sistema = ($i -eq 0) }
    }
    return @{ Lista = $lista.ToArray(); MediaSistema = $mediaSis; BusSistema = $busSis }
}

function Get-EstadoServico {
    param([string]$Nome)
    try {
        $s = Get-Service -Name $Nome -ErrorAction Stop
        if ($s.StartType -eq 'Disabled') { return 'Disabled' }
        return [string]$s.Status
    } catch { return $null }
}

function Get-Coleta {
    param([string]$Id)
    Send-Progress $Id 10 'Lendo sistema e processador'
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue | Select-Object -First 1
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue | Select-Object -First 1
    $cpus = @(Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue)

    $nucleos = 0; $hilos = 0; $mhz = 0
    foreach ($c in $cpus) {
        $nucleos += [int]$c.NumberOfCores
        $hilos += [int]$c.NumberOfLogicalProcessors
        if ([int]$c.MaxClockSpeed -gt $mhz) { $mhz = [int]$c.MaxClockSpeed }
    }
    if ($nucleos -le 0) { $nucleos = [Environment]::ProcessorCount }
    if ($hilos -le 0) { $hilos = [Environment]::ProcessorCount }

    $temp = $null
    try {
        $z = Get-CimInstance -Namespace 'root/wmi' -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $z) { $temp = [math]::Round(([double]$z.CurrentTemperature / 10) - 273.15, 1) }
    } catch { $null = $_ }

    $versao = $null
    try { $versao = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).DisplayVersion } catch { $null = $_ }
    if ([string]::IsNullOrEmpty($versao) -and $null -ne $os) { $versao = [string]$os.Version }

    $inicioRapido = Get-InicioRapido

    $dias = 0
    if ($null -ne $os -and $null -ne $os.LastBootUpTime) { $dias = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1) }

    Send-Progress $Id 35 'Lendo memoria e video'
    $totalBytes = 0
    if ($null -ne $cs) { $totalBytes = [int64]$cs.TotalPhysicalMemory }
    $livreBytes = 0
    if ($null -ne $os) { $livreBytes = [int64]$os.FreePhysicalMemory * 1024 }
    $modulos = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue).Count

    $gpus = New-Object System.Collections.Generic.List[object]
    $temDedicada = $false
    foreach ($g in @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)) {
        $fab = Get-FabricanteGpu ([string]$g.Name) ([string]$g.AdapterCompatibility)
        $ded = Test-GpuDedicada $fab ([string]$g.Name)
        if ($ded) { $temDedicada = $true }
        $gpus.Add([ordered]@{
            nome       = [string]$g.Name
            fabricante = $fab
            dedicada   = $ded
            driver     = [string]$g.DriverVersion
            vram       = if ($null -ne $g.AdapterRAM) { [int64]$g.AdapterRAM } else { $null }
        })
    }

    Send-Progress $Id 55 'Lendo discos'
    $dd = Get-InfoDiscoFisico

    $unidades = New-Object System.Collections.Generic.List[object]
    foreach ($u in [IO.DriveInfo]::GetDrives()) {
        try {
            if ($u.DriveType -eq 'Fixed' -and $u.IsReady) {
                $unidades.Add([ordered]@{
                    letra  = $u.Name.TrimEnd('\')
                    rotulo = [string]$u.VolumeLabel
                    total  = [int64]$u.TotalSize
                    livre  = [int64]$u.AvailableFreeSpace
                })
            }
        } catch { $null = $_ }
    }

    Send-Progress $Id 80 'Lendo bateria e servicos'
    $bateria = $null
    try {
        $b = Get-CimInstance Win32_Battery -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $b) {
            $saude = $null
            try {
                $cheia = (Get-CimInstance -Namespace 'root/wmi' -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1).FullChargedCapacity
                $proj = (Get-CimInstance -Namespace 'root/wmi' -ClassName BatteryStaticData -ErrorAction Stop | Select-Object -First 1).DesignedCapacity
                if ($proj -gt 0) { $saude = [math]::Round(100 * [double]$cheia / [double]$proj) }
            } catch { $null = $_ }
            $bateria = [ordered]@{ carga = $b.EstimatedChargeRemaining; saude = $saude }
        }
    } catch { $null = $_ }

    $modelo = $null; $fabricante = $null; $nome = $env:COMPUTERNAME
    if ($null -ne $cs) { $modelo = [string]$cs.Model; $fabricante = [string]$cs.Manufacturer }

    $nomeSo = $null; $build = $null; $arq = $null
    if ($null -ne $os) { $nomeSo = [string]$os.Caption; $build = [string]$os.BuildNumber; $arq = [string]$os.OSArchitecture }

    return @{
        equipo   = [ordered]@{ fabricante = $fabricante; modelo = $modelo; nome = $nome }
        sistema  = [ordered]@{ nome = $nomeSo; versao = $versao; build = $build; arquitetura = $arq; diasLigado = $dias; inicioRapido = [bool]$inicioRapido }
        cpu      = [ordered]@{ nome = $(if ($cpus.Count -gt 0) { [string]$cpus[0].Name } else { $null }); nucleos = $nucleos; hilos = $hilos; mhz = $mhz; temp = $temp }
        ram      = [ordered]@{ totalBytes = $totalBytes; livreBytes = $livreBytes; modulos = $modulos }
        gpus     = $gpus.ToArray()
        discos   = $dd.Lista
        unidades = $unidades.ToArray()
        bateria  = $bateria
        servicos = [ordered]@{ sysmain = (Get-EstadoServico 'SysMain'); wsearch = (Get-EstadoServico 'WSearch') }
        bruto    = @{
            # RAM arredondada ao GB inteiro: "16 GB" reportam ~15,9 por causa da reserva da GPU integrada.
            ramGb                 = [math]::Round($totalBytes / 1GB, 0)
            nucleos               = $nucleos
            gpuDedicada           = $temDedicada
            discoSistemaMediaType = $dd.MediaSistema
            discoSistemaBusType   = $dd.BusSistema
        }
    }
}

function Invoke-Coletar {
    param([string]$Id, $Params, [bool]$Teste)
    $forcar = $null
    $resetar = $false
    if ($null -ne $Params) {
        $forcar = $Params.forcarPerfil
        # Somente o booleano $true vale (mesma regra do Rust).
        $resetar = ($Params.resetarPerfil -is [bool] -and $Params.resetarPerfil)
    }
    if ($null -ne $forcar -and $null -ne $Params.resetarPerfil) {
        Send-Result $Id $null $false 'forcarPerfil e resetarPerfil não podem vir juntos'
        return
    }
    if ($null -ne $forcar) {
        # Normaliza para minusculas antes de validar e gravar (Rust so aceita minusculas).
        $c = ([string]$forcar.classe).ToLowerInvariant()
        $d = ([string]$forcar.disco).ToLowerInvariant()
        if ($Script:ClassesValidas -cnotcontains $c -or $Script:DiscosValidos -cnotcontains $d) {
            Send-Result $Id $null $false 'perfil inválido'
            return
        }
    }

    $dataDir = Join-Path $PSScriptRoot '..\data'
    # dataDir so vale em modo de teste (mesmo criterio de 'simular').
    if ($Teste -and $null -ne $Params -and -not [string]::IsNullOrEmpty([string]$Params.dataDir)) { $dataDir = [string]$Params.dataDir }
    $regras = Get-RegrasPerfil $dataDir
    $sim = Get-BrutoSimulado $Params $Teste
    if ($null -ne $sim) {
        # Simulacao (somente teste): substitui a coleta real, sem tocar no hardware.
        $dados = @{
            equipo   = [ordered]@{ fabricante = 'Simulado'; modelo = 'Simulado'; nome = 'SIMULADO' }
            sistema  = [ordered]@{ nome = 'Simulado'; versao = ''; build = ''; arquitetura = ''; diasLigado = 0; inicioRapido = $false }
            cpu      = [ordered]@{ nome = 'Simulado'; nucleos = [int]$sim.nucleos; hilos = [int]$sim.nucleos; mhz = 0; temp = $null }
            ram      = [ordered]@{ totalBytes = [int64]([double]$sim.ramGb * 1GB); livreBytes = 0; modulos = 0 }
            gpus     = @()
            discos   = @()
            unidades = @()
            bateria  = $null
            servicos = [ordered]@{ sysmain = $null; wsearch = $null }
        }
        $bruto = $sim
    } else {
        $dados = Get-Coleta $Id
        $bruto = $dados.bruto
        $dados.Remove('bruto')
    }

    Send-Progress $Id 90 'Classificando a maquina'
    $existente = Get-Perfil $Teste
    if ($null -ne $forcar) {
        $perfil = [pscustomobject]@{ classe = $c; disco = $d; manual = $true }
        Set-Perfil $perfil $Teste
    } elseif (-not $resetar -and $null -ne $existente -and $existente.manual -and
              $Script:ClassesValidas -ccontains $existente.classe -and $Script:DiscosValidos -ccontains $existente.disco) {
        $perfil = $existente
    } else {
        $r = Get-ClasseEDisco $bruto $regras
        $perfil = [pscustomobject]@{ classe = $r.classe; disco = $r.disco; manual = $false }
        Set-Perfil $perfil $Teste
    }
    $dados.perfil = [ordered]@{ classe = $perfil.classe; disco = $perfil.disco; manual = [bool]$perfil.manual }

    Write-AppLog ("diagnostico: perfil {0}/{1} manual={2}" -f $perfil.classe, $perfil.disco, $perfil.manual) $Teste
    Send-Result $Id $dados
}

function Invoke-Acao {
    param([string]$Id, [string]$Acao, $Params, [bool]$Teste)
    if ($Acao -ne 'coletar') {
        Send-Result $Id $null $false 'ação desconhecida'
        return
    }
    try {
        Invoke-Coletar $Id $Params $Teste
    } catch {
        $msg = 'diagnóstico falhou: ' + $_.Exception.Message
        Write-AppLog $msg $Teste
        Send-Result $Id $null $false $msg
    }
}
