# Helpers compartilhados pelos testes Pester.
function New-PastaTeste {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Nome)
    $p = Join-Path (Join-Path $env:TEMP 'OtimizadorTeste') $Nome
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    return $p
}

function Start-HostTeste {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([int]$Ocioso = 30)
    $host1 = Join-Path (Split-Path -Parent $PSScriptRoot) 'host.ps1'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""$host1"" -OciosoSegundos $Ocioso -AllowlistExtra eco"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
    $psi.CreateNoWindow = $true
    return [System.Diagnostics.Process]::Start($psi)
}

function Send-Comando {
    param($Proc, $Obj, [string]$Bruto = $null)
    $texto = if (-not [string]::IsNullOrEmpty($Bruto)) { $Bruto } else { $Obj | ConvertTo-Json -Compress -Depth 8 }
    # grava em UTF-8 sem BOM direto no stream (o encoding padrao do stdin seria o da OEM)
    $w = New-Object System.IO.StreamWriter($Proc.StandardInput.BaseStream, (New-Object System.Text.UTF8Encoding $false))
    $w.Write($texto + "`n")
    $w.Flush()
}

function Read-Linha {
    param($Proc, [int]$TimeoutMs = 10000)
    if ($null -eq $Proc.Pendente) {
        $Proc | Add-Member -NotePropertyName Pendente -NotePropertyValue $Proc.StandardOutput.ReadLineAsync() -Force
    }
    $tarefa = $Proc.Pendente
    if (-not $tarefa.Wait($TimeoutMs)) { return $null }
    $Proc.Pendente = $null
    return $tarefa.Result
}

function Read-Resultado {
    param($Proc, [string]$Id, [int]$TimeoutMs = 10000)
    $limite = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ($true) {
        $resta = [int]($limite - [DateTime]::UtcNow).TotalMilliseconds
        if ($resta -le 0) { return $null }
        $linha = Read-Linha $Proc $resta
        if ($null -eq $linha) { return $null }
        if ($linha.StartsWith('@@RESULT ')) {
            $o = $linha.Substring(9) | ConvertFrom-Json
            if ($o.id -eq $Id) { return $o }
        }
    }
}
