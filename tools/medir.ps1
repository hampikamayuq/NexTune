# Mede o consumo real do Otimizador instalado (orçamento da spec §12).
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File tools/medir.ps1 [-Exe <caminho>] [-Instalar]
#   -Exe       caminho do otimizador.exe a medir (sem ele, procura o app instalado).
#   -Instalar  se não houver app instalado, instala o setup mais novo de
#              src-tauri/target/release/bundle/nsis com /S, mede e desinstala depois.
# Soma TODOS os processos do app: otimizador.exe, msedgewebview2.exe da sua árvore
# e powershell.exe filho (o host). Só abre, observa e fecha; nunca envia entrada ao app.
# Sai com código 1 se ramAbertaMB > 120 ou cpuOciosoPct >= 0.5.
param(
    [string]$Exe = '',
    [switch]$Instalar
)

$ErrorActionPreference = 'Stop'
$LimiteRamMB = 120
$LimiteCpuPct = 0.5
$raiz = Split-Path -Parent $PSScriptRoot
$pastaSetup = Join-Path $raiz 'src-tauri\target\release\bundle\nsis'

function Get-AppInstalado {
    $chaves = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
              'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
              'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $k = Get-ItemProperty $chaves -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'Otimizador*' } | Select-Object -First 1
    if (-not $k) { return $null }
    $pasta = $null
    if ($k.InstallLocation) { $pasta = $k.InstallLocation.Trim('"') }
    elseif ($k.UninstallString) { $pasta = Split-Path ($k.UninstallString.Trim('"').Split('"')[0]) }
    if (-not $pasta) { return $null }
    $caminho = Join-Path $pasta 'otimizador.exe'
    if (Test-Path -LiteralPath $caminho) { return $caminho }
    return $null
}

# Processos da árvore do app (PID raiz + descendentes), filtrados pelos três nomes que contam.
function Get-ProcessoDoApp([int]$RaizPid) {
    $todos = @(Get-CimInstance Win32_Process)
    $filhos = @{}
    foreach ($p in $todos) {
        $pai = [int]$p.ParentProcessId
        if (-not $filhos.ContainsKey($pai)) { $filhos[$pai] = New-Object System.Collections.Generic.List[object] }
        $filhos[$pai].Add($p)
    }
    $visto = @{ $RaizPid = $true }
    $fila = New-Object System.Collections.Generic.Queue[int]
    $fila.Enqueue($RaizPid)
    while ($fila.Count -gt 0) {
        $atual = $fila.Dequeue()
        if (-not $filhos.ContainsKey($atual)) { continue }
        foreach ($f in $filhos[$atual]) {
            $id = [int]$f.ProcessId
            if (-not $visto.ContainsKey($id)) { $visto[$id] = $true; $fila.Enqueue($id) }
        }
    }
    $nomes = 'otimizador.exe', 'msedgewebview2.exe', 'powershell.exe'
    $todos | Where-Object { $visto.ContainsKey([int]$_.ProcessId) -and ($nomes -contains $_.Name.ToLowerInvariant()) }
}

function Measure-Arvore([int]$RaizPid) {
    $lista = @()
    $ram = 0.0
    $cpu = 0.0
    $janela = $false
    $temHost = $false
    foreach ($c in @(Get-ProcessoDoApp $RaizPid)) {
        $p = Get-Process -Id $c.ProcessId -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        $ram += $p.WorkingSet64
        if ($null -ne $p.CPU) { $cpu += $p.CPU }
        if ($p.MainWindowHandle -ne 0) { $janela = $true }
        if ($c.Name -ieq 'powershell.exe') { $temHost = $true }
        $lista += [pscustomobject]@{ nome = $c.Name; pid = [int]$c.ProcessId; ramMB = [math]::Round($p.WorkingSet64 / 1MB, 1) }
    }
    [pscustomobject]@{
        processos = $lista.Count
        ramMB     = [math]::Round($ram / 1MB, 1)
        cpuSeg    = $cpu
        janela    = $janela
        temHost   = $temHost
        detalhe   = $lista
    }
}

# Instalação / localização
$instaladoPorMim = $false
if (-not $Exe) { $Exe = Get-AppInstalado }
if (-not $Exe) {
    if (-not $Instalar) {
        Write-Warning 'Otimizador não está instalado. Instale-o ou use -Instalar (ou -Exe <caminho>).'
        exit 1
    }
    $setup = Get-ChildItem $pastaSetup -Filter '*-setup.exe' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $setup) { Write-Warning 'Instalador não encontrado em src-tauri\target\release\bundle\nsis (rode npm run build).'; exit 1 }
    Start-Process -FilePath $setup.FullName -ArgumentList '/S' -Wait
    $instaladoPorMim = $true
    for ($i = 0; $i -lt 30 -and -not $Exe; $i++) { $Exe = Get-AppInstalado; if (-not $Exe) { Start-Sleep -Seconds 1 } }
    if (-not $Exe) { Write-Warning 'A instalação silenciosa não deixou o app registrado.'; exit 1 }
}
if (-not (Test-Path -LiteralPath $Exe)) { Write-Warning "Não encontrei o executável: $Exe"; exit 1 }
$Exe = (Resolve-Path -LiteralPath $Exe).Path
$pasta = Split-Path $Exe

$saida = 0
try {
    if (Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Exe)) -ErrorAction SilentlyContinue) {
        Write-Warning 'O Otimizador já está aberto: feche-o e meça de novo para um arranque limpo.'
        $saida = 1
    } else {
        $pesoMB = [math]::Round(((Get-ChildItem -LiteralPath $pasta -Recurse -File | Measure-Object Length -Sum).Sum) / 1MB, 1)
        $setupRef = Get-ChildItem $pastaSetup -Filter '*-setup.exe' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $instaladorMB = if ($setupRef) { [math]::Round($setupRef.Length / 1MB, 2) } else { $null }

        # 1) Arranque: da chamada até haver uma janela na árvore do app
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $app = Start-Process -FilePath $Exe -PassThru
        $arranque = $null
        while ($sw.Elapsed.TotalSeconds -lt 30) {
            if ((Measure-Arvore $app.Id).janela) { $arranque = [math]::Round($sw.Elapsed.TotalSeconds, 2); break }
            Start-Sleep -Milliseconds 100
        }

        # 2) Com o host vivo (logo após o diagnóstico inicial): espera até 30 s ele aparecer
        $ramHost = $null
        for ($i = 0; $i -lt 60; $i++) {
            $m = Measure-Arvore $app.Id
            if ($m.temHost) { $ramHost = $m.ramMB; break }
            Start-Sleep -Milliseconds 500
        }

        # 3) Espera o host terminar (até 150 s)
        $hostVivo = $false
        if ($null -ne $ramHost) {
            $hostVivo = $true
            for ($i = 0; $i -lt 150; $i++) {
                if (-not (Measure-Arvore $app.Id).temHost) { $hostVivo = $false; break }
                Start-Sleep -Seconds 1
            }
        }

        # 4) Em repouso, janela aberta, sem tocar em nada: 5 s de acomodação e 10 s de medição
        Start-Sleep -Seconds 5
        $a = Measure-Arvore $app.Id
        Start-Sleep -Seconds 10
        $b = Measure-Arvore $app.Id
        $cpuPct = [math]::Round((($b.cpuSeg - $a.cpuSeg) / 10 / [Environment]::ProcessorCount) * 100, 2)

        $res = [ordered]@{
            versao          = (Get-Item -LiteralPath $Exe).VersionInfo.ProductVersion
            pesoInstaladoMB = $pesoMB
            instaladorMB    = $instaladorMB
            arranqueSeg     = $arranque
            processos       = $b.processos
            ramAbertaMB     = $b.ramMB
            ramHostMB       = $ramHost
            cpuOciosoPct    = $cpuPct
            hostVivo        = $hostVivo
            detalhe         = @($b.detalhe)
        }

        # 5) Fecha o app; o que sobrar da árvore depois de 5 s é encerrado à força
        $restantes = @(Get-ProcessoDoApp $app.Id | ForEach-Object { [int]$_.ProcessId })
        Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
        foreach ($id in $restantes) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }

        $res | ConvertTo-Json -Depth 4
        if ($b.ramMB -gt $LimiteRamMB -or $cpuPct -ge $LimiteCpuPct) { $saida = 1 }
    }
} finally {
    if ($instaladoPorMim) {
        $desinst = Join-Path $pasta 'uninstall.exe'
        if (Test-Path -LiteralPath $desinst) {
            Start-Process -FilePath $desinst -ArgumentList '/S' -Wait
            for ($i = 0; $i -lt 30 -and (Test-Path -LiteralPath $pasta); $i++) { Start-Sleep -Seconds 1 }
        }
    }
}
exit $saida
