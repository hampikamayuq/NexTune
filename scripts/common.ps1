# common.ps1 - funcoes compartilhadas (protocolo, pastas, perfil, caminhos protegidos).
# Uso nos modulos: . "$PSScriptRoot\common.ps1"
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { $null = $_ }
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

Set-Variable -Name AppNome -Value 'Otimizador' -Scope Global
$Script:Saida = $null

function Set-Saida {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    # Define o escritor do protocolo ($null = volta ao console).
    param($Writer)
    $Script:Saida = $Writer
}

function Write-Linha {
    param([string]$Linha)
    if ($null -ne $Script:Saida) { $Script:Saida.WriteLine($Linha) }
    else { [Console]::Out.WriteLine($Linha) }
}

function Get-AppPastas {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    param([bool]$Teste = $false)
    if ($Teste) { $base = Join-Path $env:TEMP 'OtimizadorTeste' }
    else { $base = Join-Path $env:ProgramData 'Otimizador' }
    $p = @{
        Base       = $base
        Quarentena = Join-Path $base 'Quarentena'
        Logs       = Join-Path $base 'Logs'
        Backups    = Join-Path $base 'Backups'
        Estado     = Join-Path $base 'Estado'
        Ajustes    = Join-Path $base 'Ajustes'
    }
    foreach ($k in $p.Keys) {
        if (-not (Test-Path -LiteralPath $p[$k])) {
            New-Item -ItemType Directory -Path $p[$k] -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
    return $p
}

function Send-Progress {
    param([string]$Id, [int]$Pct, [string]$Msg)
    $o = [ordered]@{ id = $Id; pct = $Pct; msg = $Msg }
    Write-Linha ('@@PROGRESS ' + ($o | ConvertTo-Json -Compress))
}

function Send-Log {
    param([string]$Id, [string]$Tipo, [string]$Msg, [string]$Ruta = '')
    $o = [ordered]@{ id = $Id; tipo = $Tipo; msg = $Msg; ruta = $Ruta }
    Write-Linha ('@@LOG ' + ($o | ConvertTo-Json -Compress))
}

function Send-Result {
    param([string]$Id, $Dados, [bool]$Ok = $true, [string]$Erro = '')
    $o = [ordered]@{ id = $Id; ok = $Ok; dados = $Dados; erro = $Erro }
    Write-Linha ('@@RESULT ' + ($o | ConvertTo-Json -Depth 8 -Compress))
}

function Write-AppLog {
    param([string]$Msg, [bool]$Teste = $false)
    $p = Get-AppPastas $Teste
    $arq = Join-Path $p.Logs ((Get-Date).ToString('yyyy-MM') + '.log')
    $linha = '{0} {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Msg
    try { Add-Content -LiteralPath $arq -Value $linha -Encoding UTF8 } catch { $null = $_ }
}

function Get-PathSize {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path)) { return [int64]0 }
    $total = [int64]0
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return [int64]0 }
    if (-not $item.PSIsContainer) { return [int64]$item.Length }
    Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $total += $_.Length }
    return [int64]$total
}

function Test-ProtectedPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    try { $full = [IO.Path]::GetFullPath($Path) } catch { return $true }
    # Expande nomes 8.3 no ancestral existente mais proximo e reanexa o restante
    $existente = $full
    $resto = ''
    while ($existente.Length -gt 3 -and -not (Test-Path -LiteralPath $existente)) {
        $resto = '\' + (Split-Path -Leaf $existente) + $resto
        $existente = Split-Path -Parent $existente
        if ([string]::IsNullOrEmpty($existente)) { break }
    }
    if (-not [string]::IsNullOrEmpty($existente) -and (Test-Path -LiteralPath $existente)) {
        try {
            if ($null -eq $Script:Fso) { $Script:Fso = New-Object -ComObject Scripting.FileSystemObject }
            if (Test-Path -LiteralPath $existente -PathType Container) { $exp = $Script:Fso.GetFolder($existente).Path }
            else { $exp = $Script:Fso.GetFile($existente).Path }
            $full = $exp.TrimEnd('\') + $resto
        } catch { $null = $_ }
    }
    $n = $full.TrimEnd('\').ToLowerInvariant()
    if ($n.Length -le 3) { return $true }   # raiz de unidade

    $base = Join-Path $env:ProgramData 'Otimizador'
    $prefixos = @($env:windir, $base)
    foreach ($pre in $prefixos) {
        if ([string]::IsNullOrEmpty($pre)) { continue }
        $x = $pre.TrimEnd('\').ToLowerInvariant()
        if ($n -eq $x -or $n.StartsWith($x + '\')) { return $true }
    }

    $pf = $env:ProgramFiles
    $pf86 = ${env:ProgramFiles(x86)}
    $exatos = @(
        $env:SystemDrive, $env:windir,
        (Join-Path $env:windir 'System32'), (Join-Path $env:windir 'SysWOW64'),
        $pf, $pf86, $env:ProgramData, $env:APPDATA, $env:LOCALAPPDATA,
        (Join-Path $env:LOCALAPPDATA 'Programs'), $env:USERPROFILE,
        (Join-Path $env:USERPROFILE 'Documents'), (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $pf 'Common Files'), (Join-Path $pf86 'Common Files'),
        (Join-Path $pf 'WindowsApps'),
        (Join-Path $env:ProgramData 'Microsoft'), (Join-Path $env:APPDATA 'Microsoft'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft'),
        (Join-Path $pf 'Microsoft'), (Join-Path $pf86 'Microsoft'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
        $base
    )
    foreach ($e in $exatos) {
        if ([string]::IsNullOrEmpty($e)) { continue }
        if ($n -eq $e.TrimEnd('\').ToLowerInvariant()) { return $true }
    }

    if ($n -match '\\(windows defender|windows nt|windowsapps|windows kits|dotnet|microsoft\.net|common files|edgewebview|edgecore|edgeupdate|microsoft\\edge)(\\|$)') { return $true }
    return $false
}

function Get-Perfil {
    param([bool]$Teste = $false)
    $arq = Join-Path (Get-AppPastas $Teste).Estado 'perfil.json'
    if (-not (Test-Path -LiteralPath $arq)) { return $null }
    try {
        $r = Get-Content -LiteralPath $arq -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($r -isnot [pscustomobject]) { return $null }
        $classe = [string]$r.classe
        $disco = [string]$r.disco
        if ([string]::IsNullOrEmpty($classe) -or [string]::IsNullOrEmpty($disco)) { return $null }
        return [pscustomobject]@{ classe = $classe; disco = $disco; manual = [bool]$r.manual }
    } catch { return $null }
}

function Set-Perfil {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param($Perfil, [bool]$Teste = $false)
    $arq = Join-Path (Get-AppPastas $Teste).Estado 'perfil.json'
    $o = [ordered]@{ classe = $Perfil.classe; disco = $Perfil.disco; manual = $Perfil.manual }
    $json = $o | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($arq, $json, (New-Object System.Text.UTF8Encoding $false))
}
