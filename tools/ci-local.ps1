param([switch]$SoTestes, [switch]$SoBuild, [switch]$Release)

# Verificação local equivalente ao CI. Sai com código 1 na primeira falha.
# -SoTestes: tudo menos o build. -SoBuild: só o build e o tamanho (o CI separa os dois para a chave de
# assinatura só existir no passo do build). -Release: artefatos assinados do atualizador, com --locked.
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

$LimiteInstaladorMB = 16.5   # 15 MB de meta + 1,5 MB de tolerância

# -Release (build de tag): gera também os artefatos assinados do atualizador (.sig), o que exige a chave
# privada no ambiente. Falha aqui, antes dos 10 minutos de build, se o secret não estiver configurado.
if ($Release -and [string]::IsNullOrWhiteSpace($env:TAURI_SIGNING_PRIVATE_KEY)) {
    Write-Host 'FALHA: TAURI_SIGNING_PRIVATE_KEY ausente: configure o secret antes de criar a tag' -ForegroundColor Red
    exit 1
}

function Stop-ComFalha([string]$Mensagem) {
    Write-Host "FALHA: $Mensagem" -ForegroundColor Red
    exit 1
}

function Invoke-Passo([string]$Nome, [scriptblock]$Bloco) {
    Write-Host "==> $Nome" -ForegroundColor Cyan
    # Captura a saída (stderr incluído: cargo escreve tudo nele) para, em caso de falha, publicar as linhas de
    # erro como anotação do GitHub Actions, já que o log completo exige login. Preferência 'Continue' porque,
    # com 'Stop', a primeira linha de stderr redirecionada de um comando nativo vira exceção no PowerShell 5.1.
    $linhas = New-Object System.Collections.Generic.List[string]
    $anterior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Bloco 2>&1 | ForEach-Object { $s = [string]$_; Write-Host $s; $linhas.Add($s) }
        $codigo = $LASTEXITCODE
    } finally { $ErrorActionPreference = $anterior }
    if ($codigo -ne 0) {
        $rel = @($linhas | Where-Object { $_ -match '^(error|warning)(\[|:| )|^\s*-->|^\s*=\s*(note|help)|^test .* FAILED|^failures:|panicked at|^thread ' })
        if ($rel.Count -eq 0) { $rel = @($linhas | Select-Object -Last 40) }
        $texto = ($rel | Select-Object -First 80) -join '%0A'
        if ($texto.Length -gt 3800) { $texto = $texto.Substring(0, 3800) }
        Write-Host ("::error title={0} (código {1})::{2}" -f $Nome, $codigo, $texto)
        Stop-ComFalha "$Nome (código $codigo)"
    }
}

if (-not $SoBuild) {
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
    # O runner do GitHub expõe %TEMP% com nome curto 8.3 (C:\Users\RUNNER~1\...), mas o PowerShell devolve os
    # caminhos na forma longa; os testes comparam os dois. Normaliza TEMP/TMP para a forma longa antes do Pester.
    $tipo = Add-Type -Namespace NexTuneCi -Name Caminho -PassThru -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern uint GetLongPathNameW(string curto, System.Text.StringBuilder longo, uint tamanho);
'@
    $sb = New-Object System.Text.StringBuilder 1024
    if ($tipo::GetLongPathNameW($env:TEMP, $sb, 1024) -gt 0) { $env:TEMP = $sb.ToString(); $env:TMP = $env:TEMP }
    Write-Host "TEMP dos testes: $env:TEMP"
    # Sem -CI: ele chama exit antes de devolver o resultado, e as anotações abaixo nunca sairiam.
    $cfg = New-PesterConfiguration
    $cfg.Run.Path = 'scripts/tests'
    $cfg.Run.PassThru = $true
    $cfg.TestResult.Enabled = $true
    $cfg.Output.CIFormat = 'GithubActions'
    $cfg.Output.Verbosity = 'Detailed'
    $resultado = Invoke-Pester -Configuration $cfg
    if ($resultado.FailedCount -gt 0) {
        # Anotações do GitHub Actions com a mensagem de cada falha (o log completo exige login; as anotações não).
        foreach ($t in @($resultado.Failed)) {
            $msg = (@($t.ErrorRecord | ForEach-Object { [string]$_.Exception.Message }) -join ' | ') -replace "`r?`n", '%0A'
            Write-Host ("::error title=Pester::{0}%0A{1}" -f $t.ExpandedPath, $msg)
        }
        Stop-ComFalha 'Pester com testes falhando'
    }
}

# 2b. Interface: sem interpolação em innerHTML sem esc(), e sem texto visível fora do i18n
Write-Host '==> UI: innerHTML sem esc()' -ForegroundColor Cyan
$ruins = @()
if (Test-Path ui/js) {
    $ruins = @(Get-ChildItem -Path ui/js -Filter '*.js' -Recurse | Select-String -Pattern 'innerHTML\s*[+]?=\s*[^;]*\$\{(?![^}]*esc\()')
}
if ($ruins.Count -gt 0) {
    $ruins | ForEach-Object { Write-Host ("{0}:{1}: {2}" -f $_.Path, $_.LineNumber, $_.Line.Trim()) }
    Stop-ComFalha 'innerHTML com interpolação sem esc()'
}

Write-Host '==> UI: texto visível sem data-i18n' -ForegroundColor Cyan
$semI18n = @()
if (Test-Path ui/index.html) {
    $n = 0
    foreach ($linha in (Get-Content -Path ui/index.html -Encoding UTF8)) {
        $n++
        foreach ($m in [regex]::Matches($linha, '<(\w+)([^>]*)>([^<{]*[A-Za-zÀ-ÿ]{3,}[^<]*)<')) {
            $tag = $m.Groups[1].Value.ToLowerInvariant()
            if ($tag -in 'title', 'noscript', 'script', 'style') { continue }
            if ($m.Groups[2].Value -notmatch 'data-i18n') { $semI18n += "ui/index.html:${n}: $($linha.Trim())" }
        }
    }
}
if ($semI18n.Count -gt 0) {
    $semI18n | ForEach-Object { Write-Host $_ }
    Stop-ComFalha 'texto visível em ui/index.html sem data-i18n'
}

# 3. Rust
Invoke-Passo 'cargo clippy' { cargo clippy --manifest-path src-tauri/Cargo.toml -- -D warnings }
Invoke-Passo 'cargo test'   { cargo test --manifest-path src-tauri/Cargo.toml }
}

# 4. Build e tamanho do instalador (somente sem -SoTestes)
if (-not $SoTestes) {
    # Em release o Cargo.lock commitado é lei (--locked): o que foi testado em main é o que vai no instalador.
    if ($Release) { Invoke-Passo 'npm run build (release)' { npm run build -- --config src-tauri/tauri.release.conf.json -- --locked } }
    else { Invoke-Passo 'npm run build' { npm run build } }
    $instaladores = @(Get-ChildItem -Path 'src-tauri/target/release/bundle/nsis' -Filter '*.exe' -ErrorAction SilentlyContinue)
    if ($instaladores.Count -eq 0) { Stop-ComFalha 'instalador NSIS não encontrado' }
    foreach ($exe in $instaladores) {
        $mb = [math]::Round($exe.Length / 1MB, 2)
        Write-Host "$($exe.Name): $mb MB (limite $LimiteInstaladorMB MB)"
        if ($exe.Length -gt $LimiteInstaladorMB * 1MB) { Stop-ComFalha "instalador acima de $LimiteInstaladorMB MB" }
        if ($Release -and -not (Test-Path -LiteralPath ($exe.FullName + '.sig'))) { Stop-ComFalha "assinatura $($exe.Name).sig não gerada" }
    }
}

Write-Host 'OK' -ForegroundColor Green
exit 0
