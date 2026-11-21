# NexTune — Plano 6: Release, site, desinstalador e pastas do sistema

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deixar o NexTune publicável: Release assinada por tag no GitHub Actions (instalador, `.sig`, `latest.json`, `SHA256.txt`), desinstalador que não deixa resto, app elevado que não confia nas variáveis de ambiente, site de uma página e README para quem baixa.

**Architecture:** O workflow continua um só (`build.yml` → `tools/ci-local.ps1`); em tag `v*` ele liga os artefatos do atualizador por `--config` e cria a Release como rascunho com o `gh` do runner. O desinstalador ganha um hook NSIS `PREUNINSTALL` que chama `scripts/desinstalar.ps1` (ainda instalado nesse momento). No Rust, uma struct `Sistema` lê as pastas pela API do Windows e o host PowerShell recebe essas pastas como variáveis de ambiente, então os scripts seguem usando `$env:windir` etc. sem mudar.

**Tech Stack:** Tauri 2 (NSIS hooks, updater), PowerShell 5.1 + Pester 6, windows-sys 0.61 (`SHGetKnownFolderPath`, `GetWindowsDirectoryW`), GitHub Actions (`gh release`).

**Spec:** `docs/superpowers/specs/2026-11-20-otimizador-design.md`, seções 8.7 (atualizador), 9 (segurança), 10 (distribuição, desinstalador, site, Smart App Control), 12 (instalador ≤ 15 MB), 13 (manual antes da release).

## Global Constraints

- Todo texto visível ao usuário em pt-BR; `.ps1` novos em UTF-8 com BOM e CRLF (CI passo 0); PSScriptAnalyzer sem avisos (sem `Write-Host`, verbos aprovados, `[CmdletBinding()]` + `SuppressMessage` em `New-`/plurais).
- Binários do sistema sempre por caminho absoluto; o app elevado nunca resolve pastas pela busca do PATH nem, a partir deste plano, pelas variáveis de ambiente (spec 9, item estrutural).
- Nunca seguir junctions/links ao apagar (`Remove-PastaSegura`); o instalador/desinstalador nunca mexe em ACLs (spec 9.8).
- Chave privada do atualizador só no secret `TAURI_SIGNING_PRIVATE_KEY`; nunca no repositório (spec 10).
- Instalador ≤ 15 MB (CI falha acima disso).
- Release sai como **rascunho**: publicar é clique do usuário, depois do checklist manual (spec 13).

## Review Focus

1. Desinstalação durante atualização (`/UPDATE`): o hook não pode desfazer Modo Jogo, remover a tarefa nem apagar dados — o hook só age com `$UpdateMode <> 1` (revisão do `.nsh`; não há teste automatizado de NSIS).
2. Desinstalação silenciosa (`/S`): a pergunta "apagar dados?" assume **sim** (`/SD IDYES`), como a spec pede.
3. Junction plantada em `%ProgramData%\NexTune\...` apontando para fora: só o link é removido — teste `com -ApagarDados apaga a pasta de dados sem entrar em junctions`.
4. `HKCU\Environment` com `windir`/`ProgramFiles` falsos: o host PowerShell recebe as pastas reais — teste `variaveis_para_o_host_vem_da_api`.
5. Tag sem o secret configurado: `ci-local.ps1 -Release` falha antes do build de 10 min, com mensagem clara.

---

### Tarefa 1: `scripts/desinstalar.ps1`

**Files:**
- Create: `scripts/desinstalar.ps1`, `scripts/tests/desinstalar.Tests.ps1`
- Modify: `scripts/common.ps1` (recebe `Remove-PastaSegura`), `scripts/quarentena.ps1` (perde a cópia)

**Interfaces:**
- Consumes: `Read-EstadoJogo`, `Restore-EstadoAnterior`, `Get-ArquivoEstado`, `Write-MarcadorJogo` (modojogo.ps1); `Get-AppPastas`, `Write-AppLog`, `Write-Linha`, `Write-JsonAtomico` (common.ps1); `New-Juncao` (_helpers.ps1).
- Produces: `desinstalar.ps1 [-ApagarDados] [-Teste]` (chamado pela Tarefa 2 com `-ApagarDados` opcional); `Remove-PastaSegura` em `common.ps1`.

- [ ] **Passo 1: mover `Remove-PastaSegura` de `quarentena.ps1` para `common.ps1`** (mesmo corpo); `Invoke-Pester -Path scripts/tests/quarentena.Tests.ps1` → todos passam.
- [ ] **Passo 2: escrever `scripts/tests/desinstalar.Tests.ps1`** (BOM + CRLF):

```powershell
BeforeAll {
    . "$PSScriptRoot\..\common.ps1"
    . "$PSScriptRoot\..\modojogo.ps1"
    . "$PSScriptRoot\_helpers.ps1"
    $Script:Script = Join-Path (Split-Path -Parent $PSScriptRoot) 'desinstalar.ps1'
    $Script:Base = (Get-AppPastas $true).Base
    $Script:Marcadores = Join-Path $Script:Base 'modojogo'
    $Script:Fora = Join-Path $env:TEMP 'NexTuneForaTeste'
    $Script:Guid = '381b4222-f694-41f0-9685-ff5bb260df2e'
    function Write-EstadoFalso {
        $e = [ordered]@{ ativo = $true; preset = 'suave'; desde = '2026-11-21T10:00:00'; fechados = @(); naoFechados = @(); servicosPausados = @(); planoAplicado = $true; planoAnterior = $Script:Guid; notificacoesAplicadas = $false }
        Write-JsonAtomico (Join-Path (Get-AppPastas $true).Estado 'modojogo.json') $e
    }
}
AfterAll {
    foreach ($p in @((Join-Path $env:TEMP 'NexTuneTeste'), $Script:Fora)) {
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
Describe 'desinstalar.ps1' {
    BeforeEach {
        if (Test-Path -LiteralPath $Script:Base) { Remove-Item -LiteralPath $Script:Base -Recurse -Force -ErrorAction SilentlyContinue }
        $null = Get-AppPastas $true
    }
    It 'desfaz o Modo Jogo pendente e remove a tarefa de inicio' {
        Write-EstadoFalso
        & $Script:Script -Teste
        (Join-Path (Get-AppPastas $true).Estado 'modojogo.json') | Should -Not -Exist
        (Join-Path $Script:Marcadores ('powercfg-' + $Script:Guid + '.txt')) | Should -Exist
        (Join-Path $Script:Marcadores 'schtasks-delete.txt') | Should -Exist
        (Join-Path $Script:Base 'Quarentena') | Should -Exist
    }
    It 'sem estado so remove a tarefa e mantem os dados' {
        & $Script:Script -Teste
        (Join-Path $Script:Marcadores 'schtasks-delete.txt') | Should -Exist
        (Join-Path $Script:Base 'Quarentena') | Should -Exist
    }
    It 'com -ApagarDados apaga a pasta de dados sem entrar em junctions' {
        New-Item -ItemType Directory -Path $Script:Fora -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Script:Fora 'alvo.txt') -Value 'fica'
        New-Juncao (Join-Path $Script:Base 'Quarentena\link') $Script:Fora
        & $Script:Script -Teste -ApagarDados
        $Script:Base | Should -Not -Exist
        (Join-Path $Script:Fora 'alvo.txt') | Should -Exist
    }
}
```

- [ ] **Passo 3: rodar e ver falhar** (`Invoke-Pester -Path scripts/tests/desinstalar.Tests.ps1`): 3 falhas, script inexistente.
- [ ] **Passo 4: escrever `scripts/desinstalar.ps1`** — `param([switch]$ApagarDados, [switch]$Teste)`; dot-source `common.ps1` e `modojogo.ps1`; (1) se `Read-EstadoJogo` existe e legível → `Restore-EstadoAnterior`, apagar o arquivo de estado, `Write-AppLog`; (2) `-Teste` → `Write-MarcadorJogo 'schtasks-delete.txt'`, senão `schtasks.exe /Delete /TN NexTune /F` por caminho absoluto em `[Environment]::GetFolderPath('Windows')` (API, não `$env:`); (3) `-ApagarDados` → `Remove-PastaSegura (Get-AppPastas $Teste).Base` com `try/catch` → `Write-Linha` do erro. Nunca `Write-Host`.
- [ ] **Passo 5: rodar e ver passar**; `Invoke-ScriptAnalyzer -Path scripts -Recurse -Severity Warning,Error` → 0.
- [ ] **Passo 6: commit** `feat(desinstalar): script do desinstalador (Modo Jogo, tarefa de início, dados sem seguir junctions)`.

### Tarefa 2: hooks NSIS

**Files:**
- Create: `src-tauri/windows/hooks.nsh` (UTF-8 com BOM, CRLF)
- Modify: `src-tauri/tauri.conf.json` (`bundle.windows.nsis.installerHooks: "./windows/hooks.nsh"`)

**Interfaces:** consome `scripts/desinstalar.ps1 [-ApagarDados]` instalado em `$INSTDIR\scripts\`; variáveis do template Tauri `$UpdateMode` e `$DeleteAppDataCheckboxState` (conferidas em `installer.nsi` do tauri-bundler: o hook `NSIS_HOOK_PREUNINSTALL` roda antes de `CheckIfAppIsRunning` e da remoção dos recursos).

- [ ] **Passo 1: `hooks.nsh`** com só `NSIS_HOOK_PREUNINSTALL`: `${If} $UpdateMode <> 1` → `$R9 = ""`; se `$DeleteAppDataCheckboxState = 1` → `$R9 = "-ApagarDados"`, senão `MessageBox MB_YESNO|MB_ICONQUESTION "Apagar também a quarentena, os backups e os registros do NexTune (C:\ProgramData\NexTune)?$\r$\nA quarentena pode guardar itens removidos nos últimos 7 dias." /SD IDYES IDNO +2` → `StrCpy $R9 "-ApagarDados"`; `${DisableX64FSRedirection}`; `nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\scripts\desinstalar.ps1" $R9'`; `Pop $R8`; `${EnableX64FSRedirection}`; `${EndIf}`.
- [ ] **Passo 2: `installerHooks` no `tauri.conf.json`.**
- [ ] **Passo 3: verificação** só no Actions (sem NSIS local): o build precisa gerar o instalador. Commit `feat(instalador): hook de desinstalação chama desinstalar.ps1 (fora de atualização)`.

### Tarefa 3: pastas do sistema pela API (Rust) e ambiente do host

**Files:**
- Modify: `src-tauri/src/caminhos.rs` (struct `Sistema`, `sistema()`, remove `env_ou`/`env_opt`/`env_pasta`), `src-tauri/src/bandeja.rs` (`exe_em_program_files`), `src-tauri/src/host.rs` (`pasta_system32` fallback; `iniciar` injeta o ambiente), `src-tauri/Cargo.toml` (feature `Win32_System_Com`).

**Interfaces:**
- Produces: `pub struct Sistema { pub windir, pub program_files, pub program_files_x86, pub program_data, pub appdata, pub local_appdata, pub perfil: PathBuf }`; `pub fn sistema() -> &'static Sistema` (OnceLock); `impl Sistema { pub fn system_drive(&self) -> PathBuf; pub fn variaveis(&self) -> Vec<(&'static str, PathBuf)> }` com as chaves `windir, SystemRoot, SystemDrive, ProgramFiles, ProgramFiles(x86), ProgramData, APPDATA, LOCALAPPDATA, USERPROFILE, TEMP, TMP` (TEMP/TMP = `local_appdata\Temp`).
- Windows: `GetWindowsDirectoryW` e `SHGetKnownFolderPath(FOLDERID_ProgramFiles | ProgramFilesX86 | ProgramData | RoamingAppData | LocalAppData | Profile, KF_FLAG_DEFAULT, null)` + `CoTaskMemFree`; falha → padrões `C:\Windows`, `C:\Program Files`… Não-Windows: variáveis de ambiente (só compilação/testes fora do Windows).

- [ ] **Passo 1: testes** em `caminhos.rs`: `sistema_devolve_caminhos_absolutos` (todos `is_absolute()`, `windir` termina em `windows` sem caixa, `variaveis()` tem 11 pares com valores absolutos); em `host.rs`: `variaveis_para_o_host_vem_da_api` (`ambiente_host(&mut cmd)` aplica exatamente as chaves de `Sistema::variaveis`; conferir pela lista, não pelo processo).
- [ ] **Passo 2: implementar**; trocar todo `env_ou`/`env_opt`/`env_pasta` por `sistema()`; `iniciar` chama `ambiente_host(&mut cmd)`.
- [ ] **Passo 3: `cargo test` e `clippy -D warnings` só no Actions** (sem Rust local): push e ler as anotações. Commit `feat(rust): pastas do sistema pela API do Windows; host PowerShell recebe o ambiente saneado`.

### Tarefa 4: Release por tag, `-Release` no ci-local e Cargo.lock automático

**Files:**
- Create: `src-tauri/tauri.release.conf.json` = `{"bundle":{"createUpdaterArtifacts":true}}`
- Modify: `tools/ci-local.ps1` (switch `-Release`), `.github/workflows/build.yml`

- [ ] **Passo 1: `ci-local.ps1 -Release`**: antes de qualquer passo, se `-Release` e `$env:TAURI_SIGNING_PRIVATE_KEY` vazio → `Stop-ComFalha 'TAURI_SIGNING_PRIVATE_KEY ausente: configure o secret antes de criar a tag'`; o build vira `npm run build -- --config src-tauri/tauri.release.conf.json`; depois do build exige `*-setup.exe.sig` ao lado do instalador.
- [ ] **Passo 2: `build.yml`**: `permissions: contents: write`; passo de build com `env: TAURI_SIGNING_PRIVATE_KEY: ${{ secrets.TAURI_SIGNING_PRIVATE_KEY }}` e `-Release` quando `github.ref_type == 'tag'`; em tag, antes do build, falhar se `v<version do tauri.conf.json> != github.ref_name`; novo passo "Commitar Cargo.lock" (`if: !cancelled() && github.ref == 'refs/heads/main'`; commit como `github-actions[bot]` + `git push` só se `git status --porcelain src-tauri/Cargo.lock` não vazio); novo passo "Release (rascunho)" em tag: monta `latest.json` (`version`, `pub_date` RFC 3339, `notes`, `platforms.windows-x86_64.{signature = conteúdo do .sig, url = …/releases/download/<tag>/<exe>}`) e `gh release create <tag> --draft --generate-notes --title "NexTune <tag>" <exe> <exe>.sig latest.json SHA256.txt` com `GH_TOKEN: ${{ github.token }}`; remover `src-tauri/Cargo.lock` do artefato.
- [ ] **Passo 3: verificação**: push em `main` → run verde + commit do bot com `Cargo.lock`; a trilha de tag só pode ser verificada depois do secret (usuário). Commit `ci: release em rascunho por tag (instalador assinado, latest.json) e Cargo.lock commitado pelo Actions`.

### Tarefa 5: site e README

**Files:**
- Create: `docs/index.html` (uma página, CSS embutido, sem JS, pt-BR), `docs/.nojekyll`
- Modify: `README.md`

- [ ] **Passo 1: `docs/index.html`** com: o que o NexTune faz (um parágrafo + lista curta por módulo); o que nunca faz (sem rede a partir da interface, só HTTPS ao GitHub para atualizar; nada apagado sem quarentena/backup; nunca mexe em ACLs; nunca `kill` em programas; sem telemetria); botão "Baixar" → `https://github.com/hampikamayuq/NexTune/releases/latest`; requisitos (Windows 10/11 64 bits, conta de administrador); "Conferir o SHA-256" (`certutil -hashfile … SHA256` × `SHA256.txt`); "Por que o Windows avisa" (SmartScreen: Mais informações → Executar assim mesmo; **Smart App Control**: o que é, que a decisão de desligar é do usuário e irreversível até reinstalar o Windows, e que a versão assinada é prioridade da 1.x — spec 10); "Código aberto": link do repositório e como auditar (`scripts/` em PowerShell legível, Actions público). Verificar no navegador (servidor estático + Playwright, uma captura).
- [ ] **Passo 2: README**: topo para quem baixa (mesmas seções, resumidas, link do site); seção "Para desenvolvedores" com o conteúdo atual (o que existe, verificação, chave); "Publicar uma versão" (passos: secret, `version` em `tauri.conf.json`/`Cargo.toml`/`package.json`, `git tag vX.Y.Z && git push origin vX.Y.Z`, revisar o rascunho, checklist manual da spec 13, publicar); pendências sem os itens resolvidos aqui (Cargo.lock, `createUpdaterArtifacts`, hooks).
- [ ] **Passo 3: commit** `docs: site de uma página e README para quem baixa`.

### Fechamento

- [ ] Rodar `tools/ci-local.ps1 -SoTestes` local (BOM, PSSA, Pester, greps da interface); push; run verde no Actions.
- [ ] Revisão independente (subagentes): Rust (`caminhos.rs`/`host.rs`), PowerShell + NSIS + workflow. Corrigir CRITICAL/HIGH.
- [ ] Atualizar este plano (caixas, "Decisões durante a execução"), memória do projeto.
