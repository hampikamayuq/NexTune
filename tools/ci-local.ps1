param([switch]$SoTestes)

# Verificação local equivalente ao CI. Sai com código 1 na primeira falha.
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

$LimiteInstaladorMB = 16.5   # 15 MB de meta + 1,5 MB de tolerância

function Stop-ComFalha([string]$Mensagem) {
    Write-Host "FALHA: $Mensagem" -ForegroundColor Red
    exit 1
}

function Invoke-Passo([string]$Nome, [scriptblock]$Bloco) {
    Write-Host "==> $Nome" -ForegroundColor Cyan
    & $Bloco
    if ($LASTEXITCODE -ne 0) { Stop-ComFalha "$Nome (código $LASTEXITCODE)" }
}

# 0. Todo .ps1 deve ser UTF-8 com BOM (EF BB BF), senão o PowerShell 5.1 lê como ANSI
Write-Host "==> BOM UTF-8" -ForegroundColor Cyan
$semBom = @(Get-ChildItem -Path scripts, tools -Filter "*.ps1" -Recurse | Where-Object {
    $b = [System.IO.File]::ReadAllBytes($_.FullName)
    $b.Length -lt 3 -or $b[0] -ne 0xEF -or $b[1] -ne 0xBB -or $b[2] -ne 0xBF
})
if ($semBom.Count -gt 0) {
    $semBom | ForEach-Object { Write-Host "Sem BOM: $($_.FullName)" }
    Stop-ComFalha "arquivos .ps1 sem BOM UTF-8"
}

# 1. PSScriptAnalyzer
Write-Host '==> PSScriptAnalyzer' -ForegroundColor Cyan
$achados = @(Invoke-ScriptAnalyzer -Path scripts -Recurse -Severity Warning, Error)
if ($achados.Count -gt 0) {
    $achados | Format-Table RuleName, Severity, ScriptName, Line, Message -AutoSize | Out-String | Write-Host
    Stop-ComFalha 'PSScriptAnalyzer encontrou problemas'
}

# 2. Pester (sem arquivos de teste ainda não é falha)
Write-Host '==> Pester' -ForegroundColor Cyan
$testes = @(Get-ChildItem -Path scripts/tests -Filter '*.Tests.ps1' -Recurse -ErrorAction SilentlyContinue)
if ($testes.Count -eq 0) {
    Write-Host 'Nenhum teste Pester encontrado; ignorando.'
} else {
    Import-Module Pester -MinimumVersion 5.5
    $resultado = Invoke-Pester -Path scripts/tests -CI -PassThru
    if ($resultado.FailedCount -gt 0) { Stop-ComFalha 'Pester com testes falhando' }
}

# 3. Rust
Invoke-Passo 'cargo clippy' { cargo clippy --manifest-path src-tauri/Cargo.toml -- -D warnings }
Invoke-Passo 'cargo test'   { cargo test --manifest-path src-tauri/Cargo.toml }

# 4. Build e tamanho do instalador (somente sem -SoTestes)
if (-not $SoTestes) {
    Invoke-Passo 'npm run build' { npm run build }
    $instaladores = @(Get-ChildItem -Path 'src-tauri/target/release/bundle/nsis' -Filter '*.exe' -ErrorAction SilentlyContinue)
    if ($instaladores.Count -eq 0) { Stop-ComFalha 'instalador NSIS não encontrado' }
    foreach ($exe in $instaladores) {
        $mb = [math]::Round($exe.Length / 1MB, 2)
        Write-Host "$($exe.Name): $mb MB (limite $LimiteInstaladorMB MB)"
        if ($exe.Length -gt $LimiteInstaladorMB * 1MB) { Stop-ComFalha "instalador acima de $LimiteInstaladorMB MB" }
    }
}

Write-Host 'OK' -ForegroundColor Green
exit 0
