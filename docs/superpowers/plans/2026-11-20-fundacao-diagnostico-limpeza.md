# NexTune — Plano 1: Fundação, Diagnóstico e Limpeza

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Entregar um aplicativo Tauri instalável que detecta o perfil da máquina e faz a Limpeza, com a ponte Rust ↔ PowerShell, a validação de parâmetros, os testes e o CI que todos os módulos seguintes vão reaproveitar.

**Architecture:** Janela WebView2 com HTML/CSS/JS puro fala com o núcleo Rust (Tauri 2) por comandos; o Rust valida cada ação contra uma allowlist, mantém **um** processo `powershell.exe` persistente (`scripts/host.ps1`) e roteia por `id` as linhas `@@PROGRESS`/`@@LOG`/`@@RESULT` que o host escreve. Os scripts PowerShell 5.1 em `scripts/` fazem o trabalho no sistema e têm um modo `teste` que redireciona registro e pastas para locais descartáveis.

**Tech Stack:** Tauri 2 (Rust estável, MSVC), WebView2, HTML/CSS/JS sem framework, Windows PowerShell 5.1, Pester 5, PSScriptAnalyzer, GitHub Actions `windows-latest`, NSIS (bundler do Tauri).

**Spec:** `docs/superpowers/specs/2026-11-20-otimizador-design.md`

**Planos seguintes (fora deste):** 2 Programas + quarentena; 3 Inicialização + Ajustes do Windows; 4 Disco + Atualizações; 5 Modo Jogo + bandeja + lembretes + atualizador; 6 site, README e primeira release.

**Nome:** o nome provisório `Otimizador` foi trocado por **NexTune** em 2026-11-20 (identificador `io.github.hampikamayuq.nextune`, repositório github.com/hampikamayuq/NexTune). As menções a `Otimizador` e `br.otimizador.app` abaixo são históricas e descrevem os comandos como foram planejados.

## Global Constraints

- Windows 10 build 19045+ e Windows 11, 64 bits. Windows PowerShell **5.1** (nada que exija PowerShell 7).
- Executável pede elevação: `requestedExecutionLevel="requireAdministrator"` no manifesto.
- Interface: HTML/CSS/JS puro, sem framework. CSP `default-src 'self'; connect-src 'none'`. Texto do motor nunca entra em `innerHTML` sem passar por `esc()`.
- Textos da interface em `ui/i18n/pt-BR.json`; nenhum texto visível hardcoded no HTML/JS.
- Dados do usuário: `%APPDATA%\Otimizador\ajustes.json`. Dados do sistema: `%ProgramData%\Otimizador\{Quarentena,logs,backups,estado}`. Sem `icacls`.
- Scripts: sem `Invoke-Expression`; comandos externos sempre com lista de argumentos; saída UTF-8 sem BOM; cada arquivo `.ps1` salvo em UTF-8 **com** BOM (PowerShell 5.1 lê acentos errado sem ele).
- Toda ação de escrita confere `Test-ProtectedPath` no Rust **e** no PowerShell.
- Orçamento (spec §12): instalador ≤ 15 MB + 1,5 MB do bootstrapper WebView2 (CI falha acima); RAM ociosa com janela ≤ 120 MB; CPU ociosa < 0,5 %.
- Anti-objetivos (spec §3) valem para todo código: nada de limpar registro "por velocidade", pagefile, Defender, Windows Update, Edge/WebView2.
- Commits pequenos, em português, no imperativo (`feat: ...`, `test: ...`, `chore: ...`), terminando com a linha `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

## Review Focus

Entradas que a spec implica mas que um teste precisa fixar (cada uma tem seu teste na tarefa dona):

1. **`perfil.json` ausente ou corrompido** (primeira abertura, ou disco cheio no meio da gravação): o Rust deve assumir o perfil mais conservador, `classe=basico`, `disco=hdd`, e não travar. → Tarefa 6.
2. **Linhas fora do protocolo no stdout do host** (avisos do PowerShell, `Write-Host` esquecido, BOM): o roteador ignora e segue; nunca derruba a ação. → Tarefa 4.
3. **Caminhos com acento, espaço e aspas nos parâmetros** (`C:\Users\João Ção\Área de Trabalho\"x"`): atravessam Rust → stdin → PowerShell intactos. → Tarefa 3.
4. **Arquivo em uso durante a Limpeza** (navegador aberto, dump sendo escrito): pula o arquivo, informa quantos pulou, termina com `ok:true`. → Tarefa 8.
5. **Caminho protegido com variação de grafia** (`c:\windows\`, barra final, caixa alta, `C:\PROGRA~1`): continua protegido. → Tarefa 2.

---

## Estrutura de arquivos

```
otimizador/
  package.json                  scripts npm: dev, build, test:ps, test:rs, lint:ps
  .gitignore                    node_modules/, src-tauri/target/, dist/, *.log
  README.md                     esboço (o conteúdo completo é do Plano 6)
  src-tauri/
    Cargo.toml                  crate `otimizador`
    build.rs                    manifesto Windows com requireAdministrator
    tauri.conf.json             janela, CSP, bundle NSIS perMachine, WebView2 embedBootstrapper, resources scripts/ e data/
    capabilities/default.json   permissões Tauri da janela principal
    icons/                      gerados por `tauri icon`
    src/main.rs                 só chama otimizador::executar()
    src/lib.rs                  monta o app Tauri, registra comandos e estado
    src/protocolo.rs            parse das linhas @@PROGRESS/@@LOG/@@RESULT → enum Mensagem
    src/acoes.rs                allowlist (módulo, ação) + validação de params → Result<Value, ErroValidacao>
    src/host.rs                 HostPowerShell: spawn, stdin/stdout, roteamento por id, cancelar, relançar, ocioso
    src/ajustes.rs              Ajustes (serde) com padrões, ler/gravar em %APPDATA%
    src/perfil.rs               Perfil {classe, disco, manual}, ler de %ProgramData%, fallback conservador, modo_leve()
    src/caminhos.rs             pastas do app (%APPDATA%, %ProgramData%, scripts e data empacotados) + caminho_protegido()
    src/comandos.rs             #[tauri::command]: executar, cancelar, ajustes_ler, ajustes_gravar, dados, info
  ui/
    index.html                  esqueleto: barra de título, nav lateral, <main>, toasts, modal
    styles.css                  tema escuro padrão, modo leve (sem animações), zoom por CSS var
    js/esc.js                   esc(v)
    js/i18n.js                  t(chave, vars), carrega pt-BR.json
    js/api.js                   wrappers de invoke + assinatura de eventos de progresso
    js/estado.js                S = { info, ajustes, perfil, diagnostico, limpeza }
    js/vistas/inicio.js         resumo + recomendações
    js/vistas/diagnostico.js    hardware, perfil detectado, botão trocar
    js/vistas/limpeza.js        categorias, seleção, progresso, resultado
    js/demo.js                  dados falsos quando info().demo
    js/arranque.js              carrega i18n, info, ajustes, perfil; monta nav; roteia vistas
    i18n/pt-BR.json
  scripts/
    common.ps1                  Send-Progress/Send-Log/Send-Result com id, Write-AppLog, Get-PathSize, Test-ProtectedPath, Get-Perfil/Set-Perfil, Get-AppPastas (modo teste)
    host.ps1                    loop stdin → runspaces → stdout; ping, cancelar, sair, ocioso
    diagnostico.ps1             Invoke-Acao 'coletar' → hardware + perfil; grava perfil.json
    limpeza.ps1                 Invoke-Acao 'analisar' | 'limpar'
    tests/common.Tests.ps1
    tests/host.Tests.ps1
    tests/diagnostico.Tests.ps1
    tests/limpeza.Tests.ps1
    tests/_helpers.ps1          Start-HostTeste (processo com stdin/stdout redirecionados), New-PastaTeste
  data/
    perfis.json                 regras de classe e limites
  tools/
    medir.ps1                   RAM/CPU/tempo até a janela (spec §12)
    ci-local.ps1                roda localmente os mesmos passos do CI
  .github/workflows/build.yml
```

---

### Task 1: Esqueleto do repositório e toolchain

**Files:**
- Create: `package.json`, `.gitignore`, `README.md`, `src-tauri/*` (scaffold), `ui/index.html` (placeholder), `tools/ci-local.ps1`

**Interfaces:**
- Produces: comandos `npm run dev` (= `tauri dev`), `npm run build` (= `tauri build`), `npm run test:ps` (= `powershell -NoProfile -File tools/ci-local.ps1 -SoTestes`), `npm run test:rs` (= `cargo test --manifest-path src-tauri/Cargo.toml`), `npm run lint:ps` (PSScriptAnalyzer).

- [ ] **Step 1: Instalar o toolchain Rust** (assume-se a opção "local" da pergunta aberta 4; se o usuário escolher "só CI", pule e marque no README que `cargo` só roda no Actions)

Run (PowerShell como administrador):
```powershell
winget install --id Rustlang.Rustup -e --accept-source-agreements --accept-package-agreements
winget install --id Microsoft.VisualStudio.2022.BuildTools -e --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
rustup default stable-x86_64-pc-windows-msvc
cargo --version
```
Expected: `cargo 1.x` impresso.

- [ ] **Step 2: Instalar Pester 5 e PSScriptAnalyzer**

Run:
```powershell
Install-Module Pester -MinimumVersion 5.5 -Force -SkipPublisherCheck -Scope CurrentUser
Install-Module PSScriptAnalyzer -Force -Scope CurrentUser
Import-Module Pester -MinimumVersion 5.5; (Get-Module Pester).Version
```
Expected: versão ≥ 5.5.

- [ ] **Step 3: Criar o projeto Tauri 2 com frontend vanilla**

Run, dentro de `C:\Users\UPASC\Documents\Nova pasta\otimizador`:
```powershell
git init -b main
npm create tauri-app@latest . -- --template vanilla --manager npm --identifier br.otimizador.app --force
npm install
```
Depois: renomear a pasta `src/` gerada para `ui/` e ajustar `build.frontendDist` em `tauri.conf.json` para `../ui`; `productName` = `Otimizador`; remover `devUrl` (não há bundler de frontend). Adicionar ao `package.json` os scripts da seção Interfaces.

- [ ] **Step 4: `.gitignore` e README esboço**

`.gitignore`: `node_modules/`, `src-tauri/target/`, `src-tauri/gen/`, `dist/`, `*.log`, `TestResults/`.
`README.md`: nome provisório, uma frase do que é, link para a spec, aviso "em desenvolvimento".

- [ ] **Step 5: `tools/ci-local.ps1`**

Assinatura: `param([switch]$SoTestes)`. Executa em ordem: `Invoke-ScriptAnalyzer -Path scripts -Recurse -Severity Warning,Error` (falha se houver resultado), `Invoke-Pester -Path scripts/tests -CI`, `cargo clippy --manifest-path src-tauri/Cargo.toml -- -D warnings`, `cargo test --manifest-path src-tauri/Cargo.toml`; sem `-SoTestes` também roda `npm run build` e falha se `src-tauri/target/release/bundle/nsis/*.exe` passar de **16,5 MB** (15 + 1,5). Sai com código 1 na primeira falha.

- [ ] **Step 6: Verificar que a janela abre**

Run: `npm run dev`
Expected: janela com título `Otimizador` abre; fechar.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "chore: esqueleto Tauri 2 + ferramentas de teste"
```

---

### Task 2: `scripts/common.ps1`

**Files:**
- Create: `scripts/common.ps1`, `scripts/tests/common.Tests.ps1`, `scripts/tests/_helpers.ps1`

**Interfaces:**
- Produces (todas as funções abaixo ficam disponíveis a qualquer módulo que fizer `. "$PSScriptRoot\common.ps1"`):
  - `$Global:AppNome = 'Otimizador'`
  - `Get-AppPastas([bool]$Teste)` → `@{ Base; Quarentena; Logs; Backups; Estado; Ajustes }`. Com `$Teste`, `Base = "$env:TEMP\OtimizadorTeste"` e `Ajustes` dentro dela; sem, `Base = "$env:ProgramData\Otimizador"`. Cria as pastas se faltarem.
  - `Send-Progress([string]$Id, [int]$Pct, [string]$Msg)` → escreve `@@PROGRESS {"id":..,"pct":..,"msg":..}`
  - `Send-Log([string]$Id, [string]$Tipo, [string]$Msg, [string]$Ruta = '')` → `@@LOG {...}`; `$Tipo` ∈ `paso|info|buscar|hallado|ok|aviso|error`
  - `Send-Result([string]$Id, $Dados, [bool]$Ok = $true, [string]$Erro = '')` → `@@RESULT {"id":..,"ok":..,"dados":..,"erro":..}` (`ConvertTo-Json -Depth 8 -Compress`)
  - `Write-AppLog([string]$Msg, [bool]$Teste)` → anexa em `<Logs>\AAAA-MM.log` com timestamp
  - `Get-PathSize([string]$Path)` → `[int64]`
  - `Test-ProtectedPath([string]$Path)` → `[bool]`
  - `Get-Perfil([bool]$Teste)` → objeto `{ classe; disco; manual }` ou `$null`; `Set-Perfil($Perfil, [bool]$Teste)` grava `<Estado>\perfil.json`
- `_helpers.ps1` produz `New-PastaTeste([string]$Nome)` (cria e devolve `"$env:TEMP\OtimizadorTeste\$Nome"`, limpa se existir).

- [ ] **Step 1: Escrever os testes**

`scripts/tests/common.Tests.ps1` (Pester 5, `BeforeAll { . "$PSScriptRoot\..\common.ps1"; . "$PSScriptRoot\_helpers.ps1" }`):
- `Send-Result` escreve uma linha que começa com `@@RESULT ` e cujo JSON tem `id = 'a1'`, `ok = $true`, `dados.x = 1` (capturar com `[Console]::SetOut` para um `StringWriter`, restaurar no `AfterEach`).
- `Send-Result` com `-Ok $false -Erro 'falhou'` → `ok = $false`, `erro = 'falhou'`.
- `Send-Progress 'a1' 40 'Medindo'` → linha `@@PROGRESS` com `pct = 40`.
- `Test-ProtectedPath` devolve `$true` para: `$env:windir`, `"$env:windir\"`, `($env:windir).ToUpper()`, `"$env:SystemDrive\PROGRA~1"` (resolver com `[IO.Path]::GetFullPath` + expansão 8.3 via `(New-Object -ComObject Scripting.FileSystemObject).GetFolder(...).Path` quando existir), `"$env:ProgramFiles\Microsoft\EdgeWebView"`, `"${env:ProgramFiles(x86)}\Microsoft\EdgeCore\1.2.3"`, `"$env:ProgramFiles\Microsoft\Edge"`, `"$env:ProgramFiles\WindowsApps\X"`, `"$env:ProgramData\Otimizador\Quarentena"`, `''`, `$null`.
- `Test-ProtectedPath` devolve `$false` para `"$env:ProgramFiles\ProgramaQualquer"` e `"$env:LOCALAPPDATA\Programs\Editor"`.
- `Get-AppPastas $true` devolve `Base` começando com `$env:TEMP` e cria as 5 subpastas.
- `Set-Perfil @{classe='gamer';disco='hdd';manual=$false} $true` seguido de `Get-Perfil $true` devolve `classe = 'gamer'`; `Get-Perfil $true` sem arquivo devolve `$null`.
- `Get-PathSize` de uma pasta de teste com dois arquivos de 10 e 20 bytes devolve `30`.

- [ ] **Step 2: Rodar e ver falhar**

Run: `Invoke-Pester -Path scripts/tests/common.Tests.ps1 -Output Detailed`
Expected: FAIL (`common.ps1` não existe).

- [ ] **Step 3: Implementar `scripts/common.ps1` e `_helpers.ps1`**

`Test-ProtectedPath`: normalizar com `[IO.Path]::GetFullPath`, `TrimEnd('\')`, `ToLowerInvariant()`; expandir nome curto 8.3 quando o caminho existir; lista bloqueada = a do RetroLimpia (`common.ps1` dele, linhas 73–85) **mais** `Microsoft\EdgeWebView`, `Microsoft\EdgeCore`, `Microsoft\Edge`, `Microsoft\EdgeUpdate`, `dotnet`, `Microsoft.NET`, `Common Files`, `WindowsApps`, e `<Base>` do app; prefixos `$env:windir` e `<Base>` sempre protegidos.
Encoding de saída: `[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false` no topo.

- [ ] **Step 4: Rodar e ver passar**

Run: `Invoke-Pester -Path scripts/tests/common.Tests.ps1 -Output Detailed`
Expected: PASS, 0 falhas.

- [ ] **Step 5: Lint e commit**

Run: `Invoke-ScriptAnalyzer -Path scripts -Recurse -Severity Warning,Error` → nenhuma saída.
```bash
git add scripts
git commit -m "feat(scripts): common.ps1 com protocolo, pastas, perfil e caminhos protegidos"
```

---

### Task 3: `scripts/host.ps1` (processo persistente)

**Files:**
- Create: `scripts/host.ps1`, `scripts/tests/host.Tests.ps1`
- Modify: `scripts/tests/_helpers.ps1`

**Interfaces:**
- Consumes: Task 2.
- Produces o **protocolo** que o Rust (Task 4/5) implementa:
  - stdin, uma linha JSON por comando: `{"id":"<string>","modulo":"<nome>","acao":"<nome>","params":{...},"teste":false}`
  - módulo especial `host`: ação `ping` → `@@RESULT {id, ok:true, dados:{pid, versao:"5.1...", ocioso:true}}`; ação `cancelar` com `params.alvo = "<id>"` → cancela aquela ação e responde `@@RESULT {id, ok:true}`; ação `sair` → host termina com código 0.
  - demais módulos: carrega `scripts/<modulo>.ps1` (dot-source, uma vez), que deve definir `function Invoke-Acao([string]$Id, [string]$Acao, $Params, [bool]$Teste)`; executa em um **runspace próprio** (`[PowerShell]::Create()` com `InitialSessionState` que já importou `common.ps1` e o módulo); a saída do runspace é coletada numa `ConcurrentQueue[string]` compartilhada e drenada para stdout pelo loop principal.
  - módulo fora da allowlist `@('diagnostico','limpeza')` (cresce nos planos seguintes) → `@@RESULT {id, ok:false, erro:"modulo nao permitido"}`.
  - ação que lança exceção → `@@RESULT {id, ok:false, erro:<mensagem>}`.
  - cancelamento: `$ps.Stop()` + matar processos cujo `ParentProcessId -eq $PID` (`Get-CimInstance Win32_Process`); a ação cancelada responde `@@RESULT {id:<alvo>, ok:false, erro:"cancelado"}`.
  - **ocioso**: sem comando e sem ação em curso por 120 s → sai com código 0 (parametrizável por `-OciosoSegundos`, padrão 120; os testes usam 2).
  - stdout em UTF-8 sem BOM; nada além das linhas `@@` chega ao stdout (erros não tratados vão para stderr).
- `_helpers.ps1` ganha `Start-HostTeste([int]$Ocioso = 30)` → `[Diagnostics.Process]` com `RedirectStandardInput/Output/Error`, `StandardOutputEncoding UTF8`, e `Send-Comando($Proc, $Obj)` / `Read-Linha($Proc, [int]$TimeoutMs = 10000)`.

- [ ] **Step 1: Escrever os testes**

`scripts/tests/host.Tests.ps1`:
- `ping` responde `@@RESULT` com `id` igual, `ok = $true`, `dados.pid` inteiro.
- módulo `inexistente` → `ok = $false`, `erro -match 'nao permitido'`.
- módulo de teste `scripts/tests/fixtures/eco.ps1` (criado pelo teste, copiado para `scripts/` só durante o teste e removido no `AfterAll`; allowlist aceita módulos cujo arquivo exista **e** estejam na lista, então o teste passa `-AllowlistExtra eco` ao host): ação `eco` devolve `params` intactos. Enviar `params.caminho = 'C:\Users\João Ção\Área de Trabalho\"x" y'` e conferir que volta idêntico (Review Focus 3).
- ação `demorar` do `eco.ps1` (`Start-Sleep 30`) + `cancelar` com `alvo` → resposta de cancelamento chega em < 5 s com `erro = 'cancelado'`.
- duas ações `demorar` com durações 2 s e 0,5 s enviadas em sequência: a de 0,5 s responde primeiro (paralelismo).
- host com `-OciosoSegundos 2` sem comandos termina em < 5 s com `ExitCode 0`.
- `sair` → processo termina com `ExitCode 0`.
- linha de stdin inválida (`isto nao e json`) → `@@RESULT` com `id = ''`, `ok = $false`, e o host **continua** respondendo a um `ping` seguinte.

- [ ] **Step 2: Rodar e ver falhar**

Run: `Invoke-Pester -Path scripts/tests/host.Tests.ps1 -Output Detailed`
Expected: FAIL.

- [ ] **Step 3: Implementar `scripts/host.ps1`**

`param([int]$OciosoSegundos = 120, [string[]]$AllowlistExtra = @())`. Loop principal: `$leitura = [Console]::In.ReadLineAsync()`; `while ($true) { if ($leitura.Wait(50)) { tratar; $leitura = ReadLineAsync() }; drenar fila; recolher runspaces terminados (`IsCompleted`) e liberar; se fila vazia, nenhum runspace ativo e `(Get-Date) - $ultimoComando > Ocioso`, sair }`. Cada runspace recebe `$Id`, `$Acao`, `$Params`, `$Teste` e a fila via `AddArgument`; dentro dele, `common.ps1` é re-importado e as funções `Send-*` escrevem na fila em vez do console (implementar `Send-*` sobre uma variável `$Script:Saida` que é `[Console]::Out` por padrão e a fila quando definida).

- [ ] **Step 4: Rodar e ver passar**

Run: `Invoke-Pester -Path scripts/tests/host.Tests.ps1 -Output Detailed`
Expected: PASS.

- [ ] **Step 5: Lint e commit**

```bash
git add scripts
git commit -m "feat(scripts): host.ps1 persistente com runspaces, cancelamento e ocioso"
```

---

### Task 4: Rust — `protocolo.rs` e `acoes.rs`

**Files:**
- Create: `src-tauri/src/protocolo.rs`, `src-tauri/src/acoes.rs`
- Modify: `src-tauri/Cargo.toml` (deps: `serde`, `serde_json`, `thiserror`)

**Interfaces:**
- Produces:
  ```rust
  // protocolo.rs
  pub enum Mensagem { Progresso { id: String, pct: u8, msg: String },
                      Log { id: String, tipo: String, msg: String, ruta: String },
                      Resultado { id: String, ok: bool, dados: serde_json::Value, erro: String } }
  pub fn parse_linha(linha: &str) -> Option<Mensagem>;   // None para linhas fora do protocolo
  pub fn comando_json(id: &str, modulo: &str, acao: &str, params: &serde_json::Value, teste: bool) -> String; // uma linha, sem '\n' interno
  // acoes.rs
  #[derive(thiserror::Error, Debug)] pub enum ErroValidacao { #[error("ação não permitida: {0}")] NaoPermitida(String), #[error("parâmetro inválido: {0}")] Parametro(String) }
  pub fn validar(modulo: &str, acao: &str, params: &serde_json::Value) -> Result<serde_json::Value, ErroValidacao>; // devolve params saneados
  pub const CATEGORIAS_LIMPEZA: &[&str] = &["temp_usuario","temp_windows","wu_cache","entrega","informes","miniaturas","launchers","navegadores","minidumps","lixeira","shaders","dism_componentes","windows_old","pontos_antigos"];
  ```
  Tabela de `validar` neste plano: `("host","ping")` sem params; `("diagnostico","coletar")` params opcionais `{ "simular": object }` **só aceito quando `teste == true`** (o Rust passa `teste` para `validar` como 4º argumento: `validar(modulo, acao, params, teste)`); `("limpeza","analisar")` sem params; `("limpeza","limpar")` exige `{ "categorias": [string] }` não vazio, cada item em `CATEGORIAS_LIMPEZA`, sem repetição, e `"confirmado": true` obrigatório se contiver `windows_old` ou `pontos_antigos`. Qualquer chave desconhecida em `params` → `Parametro`.

- [ ] **Step 1: Escrever os testes** (módulo `#[cfg(test)]` em cada arquivo)

`protocolo.rs`:
- `parse_linha("@@RESULT {\"id\":\"a1\",\"ok\":true,\"dados\":{\"x\":1},\"erro\":\"\"}")` → `Resultado{ id:"a1", ok:true, dados["x"]==1 }`.
- `parse_linha("@@PROGRESS {\"id\":\"a1\",\"pct\":40,\"msg\":\"Medindo\"}")` → `Progresso{pct:40}`.
- `parse_linha("AVISO: algo")`, `parse_linha("")`, `parse_linha("\u{feff}@@RESULT {}")` (BOM: deve ser aceito após `trim_start_matches('\u{feff}')`) → os dois primeiros `None`, o terceiro `Some(Resultado{..})` com `id == ""`. (Review Focus 2)
- `parse_linha("@@RESULT {json quebrado")` → `None`.
- `comando_json("a1","limpeza","limpar",&json!({"categorias":["temp_usuario"]}),false)` não contém `'\n'` e re-parseia com `id == "a1"`.

`acoes.rs`:
- `validar("limpeza","limpar",&json!({"categorias":["temp_usuario","lixeira"]}),false)` → `Ok`.
- `validar("limpeza","limpar",&json!({"categorias":[]}),false)` → `Err(Parametro)`.
- `validar("limpeza","limpar",&json!({"categorias":["temp_usuario","temp_usuario"]}),false)` → `Err(Parametro)`.
- `validar("limpeza","limpar",&json!({"categorias":["registro"]}),false)` → `Err(Parametro)`.
- `validar("limpeza","limpar",&json!({"categorias":["windows_old"]}),false)` → `Err(Parametro)`; com `"confirmado":true` → `Ok`.
- `validar("limpeza","limpar",&json!({"categorias":["lixeira"],"extra":1}),false)` → `Err(Parametro)`.
- `validar("programas","listar",&json!({}),false)` → `Err(NaoPermitida)`.
- `validar("diagnostico","coletar",&json!({"simular":{}}),false)` → `Err(Parametro)`; com `teste=true` → `Ok`.

- [ ] **Step 2: Rodar e ver falhar**

Run: `cargo test --manifest-path src-tauri/Cargo.toml protocolo acoes`
Expected: erro de compilação (módulos não existem).

- [ ] **Step 3: Implementar os dois arquivos e declará-los em `lib.rs`**

- [ ] **Step 4: Rodar e ver passar**

Run: `cargo test --manifest-path src-tauri/Cargo.toml`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src-tauri
git commit -m "feat(rust): protocolo do host e validação de ações"
```

---

### Task 5: Rust — `host.rs` (gerente do PowerShell)

**Files:**
- Create: `src-tauri/src/host.rs`, `src-tauri/src/caminhos.rs`
- Modify: `src-tauri/Cargo.toml` (deps: `tokio` com `process`, `io-util`, `sync`, `time`; `windows-sys` com `Win32_System_Threading` para prioridade)

**Interfaces:**
- Consumes: `protocolo::{parse_linha, comando_json, Mensagem}`, `acoes::validar`.
- Produces:
  ```rust
  // caminhos.rs
  pub struct Pastas { pub appdata: PathBuf, pub programdata: PathBuf, pub scripts: PathBuf, pub data: PathBuf }
  pub fn pastas(app: &tauri::AppHandle) -> Pastas;        // scripts/ e data/ via app.path().resource_dir() quando empacotado, ../../scripts e ../../data em dev
  pub fn caminho_protegido(p: &Path) -> bool;             // mesma lista de Test-ProtectedPath (Task 2), em Rust
  // host.rs
  pub struct HostPowerShell { /* privado */ }
  pub struct Evento { pub id: String, pub mensagem: Mensagem }
  impl HostPowerShell {
      pub fn novo(script: PathBuf, prioridade_baixa: bool, ocioso_segundos: u32) -> Self;   // não inicia o processo
      pub async fn executar(&self, modulo: &str, acao: &str, params: serde_json::Value, teste: bool,
                            progresso: impl Fn(Evento) + Send + 'static) -> Result<serde_json::Value, ErroHost>;
      pub async fn cancelar(&self, id: &str) -> Result<(), ErroHost>;
      pub async fn cancelar_tudo(&self);
      pub async fn encerrar(&self);
  }
  #[derive(thiserror::Error, Debug)] pub enum ErroHost { #[error("{0}")] Validacao(#[from] ErroValidacao), #[error("host não respondeu")] Timeout, #[error("{0}")] Acao(String), #[error("cancelado")] Cancelado, #[error("falha ao iniciar powershell: {0}")] Spawn(String) }
  ```
  Comportamento: `executar` valida (Task 4), inicia o processo se não estiver vivo (`powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File <script> -OciosoSegundos <n>`, `CREATE_NO_WINDOW`), gera `id` = contador hex, escreve a linha no stdin, e resolve quando chega `Resultado` com aquele `id` (`ok:false` → `Err(Acao(erro))`; `erro == "cancelado"` → `Err(Cancelado)`). Uma tarefa de leitura única drena o stdout e distribui por `id` via `HashMap<String, Sender>`. Se o processo morrer, todos os pendentes recebem `Err(Timeout)` e o próximo `executar` relança. `cancelar` envia `host/cancelar` e, se não houver `Resultado` em 5 s, mata o processo (`kill`) e relança no próximo uso. Prioridade abaixo do normal via `SetPriorityClass(BELOW_NORMAL_PRIORITY_CLASS)` quando `prioridade_baixa`.

- [ ] **Step 1: Escrever os testes** (integração, usam o `scripts/host.ps1` real; `#[cfg(test)]` em `host.rs`, `#[tokio::test]`)

- `ping` via `executar("host","ping",json!({}),false,|_|{})` → `Ok(dados)` com `dados["pid"]` número.
- `executar("programas","listar",...)` → `Err(Validacao(NaoPermitida))` **sem** iniciar o processo (checar que `pid` interno continua `None`).
- Com o módulo de teste `eco` (reaproveitar `scripts/tests/fixtures/eco.ps1`, passando `-AllowlistExtra eco` em modo teste): `executar("eco","demorar",json!({"segundos":30}),true,..)` em uma task e `cancelar(id)` 200 ms depois → `Err(Cancelado)` em < 5 s.
- Matar o processo por fora (`taskkill /PID`) durante um `demorar` → o pendente resolve `Err(Timeout)`; um `ping` seguinte funciona (relançou).
- Host com `ocioso_segundos = 2`: após `ping`, esperar 4 s, `pid` interno é `None` (o Rust detecta a saída pelo fim do stdout); `ping` de novo funciona.
- `caminho_protegido(Path::new("C:\\Windows\\"))`, `("c:\\WINDOWS\\System32")`, `("C:\\Program Files\\Microsoft\\EdgeWebView")` → `true`; `("C:\\Program Files\\Qualquer")` → `false`.

- [ ] **Step 2: Rodar e ver falhar**

Run: `cargo test --manifest-path src-tauri/Cargo.toml host caminhos`
Expected: erro de compilação.

- [ ] **Step 3: Implementar `host.rs` e `caminhos.rs`**

- [ ] **Step 4: Rodar e ver passar**

Run: `cargo test --manifest-path src-tauri/Cargo.toml`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src-tauri
git commit -m "feat(rust): gerente do host PowerShell com roteamento por id e cancelamento"
```

---

### Task 6: Rust — `ajustes.rs`, `perfil.rs`, `comandos.rs`, `lib.rs`

**Files:**
- Create: `src-tauri/src/ajustes.rs`, `src-tauri/src/perfil.rs`, `src-tauri/src/comandos.rs`
- Modify: `src-tauri/src/lib.rs`, `src-tauri/src/main.rs`, `src-tauri/capabilities/default.json`, `src-tauri/tauri.conf.json` (`bundle.resources`: `../scripts/**/*` exceto `tests/`, `../data/*`)

**Interfaces:**
- Consumes: Task 5.
- Produces (comandos Tauri chamados por `ui/js/api.js`):
  ```rust
  // ajustes.rs
  #[derive(Serialize, Deserialize, Clone)] pub struct Ajustes { pub idioma: String /* "pt-BR" */, pub modo_avancado: bool, pub ponto_restauracao: String /* "perguntar"|"ligar"|"pular" */, pub dias_quarentena: u32 /* 7 */, pub modo_leve: String /* "auto"|"on"|"off" */, pub tour_visto: bool, pub ultima_versao: String }
  impl Default for Ajustes;  pub fn ler(pastas: &Pastas) -> Ajustes;  pub fn gravar(pastas: &Pastas, a: &Ajustes) -> std::io::Result<()>;
  // perfil.rs
  #[derive(Serialize, Deserialize, Clone, PartialEq, Debug)] pub struct Perfil { pub classe: String /* basico|medio|gamer */, pub disco: String /* hdd|ssd */, pub manual: bool }
  pub fn ler(pastas: &Pastas) -> Perfil;            // ausente/corrompido → Perfil{classe:"basico",disco:"hdd",manual:false}
  pub fn modo_leve(p: &Perfil, a: &Ajustes) -> bool; // a.modo_leve=="on" || (a.modo_leve!="off" && (p.classe=="basico" || p.disco=="hdd"))
  // comandos.rs (#[tauri::command])
  executar(modulo: String, acao: String, params: Value, window: Window, estado: State<Estado>) -> Result<Value, String>  // emite evento "progresso" {id, modulo, tipo:"progresso"|"log", ...} na janela
  cancelar(estado) -> Result<(), String>          // cancelar_tudo
  ajustes_ler(estado) -> Ajustes ; ajustes_gravar(a: Ajustes, estado) -> Result<Ajustes, String>  // regrava e, se modo_leve mudou, recria o HostPowerShell com a prioridade nova
  dados(nome: String, estado) -> Result<Value, String>   // só nomes em ["perfis"] neste plano; lê data/<nome>.json
  info(estado) -> Info { versao, demo: bool, es_admin: bool, perfil: Perfil, modo_leve: bool, equipo: String }
  ```
  `Estado` guarda `Pastas`, `Mutex<HostPowerShell>`, `demo: bool` (argumento `--demo` na linha de comando ou plataforma ≠ windows). Em `demo`, `executar` devolve `Err("demo")` e a interface usa `demo.js`. `es_admin` via `net session` (como o RetroLimpia) ou `IsUserAnAdmin` do `windows-sys`.

- [ ] **Step 1: Escrever os testes**

`ajustes.rs`: `ler` em pasta vazia devolve `Default` (`dias_quarentena == 7`, `ponto_restauracao == "perguntar"`); `gravar` + `ler` preserva; arquivo com JSON parcial `{"modo_avancado":true}` → `modo_avancado == true` e o resto padrão (merge).
`perfil.rs`: `ler` sem arquivo → `Perfil{basico,hdd,false}` (Review Focus 1); arquivo com `{"classe":"gamer","disco":"ssd"` (corrompido) → mesmo fallback; `modo_leve` para `(medio,ssd,"auto")` → `false`; `(medio,hdd,"auto")` → `true`; `(gamer,ssd,"on")` → `true`; `(basico,hdd,"off")` → `false`.
`comandos.rs`: `dados("perfis")` lê o arquivo; `dados("../ajustes")` → `Err`.

- [ ] **Step 2: Rodar e ver falhar** — `cargo test --manifest-path src-tauri/Cargo.toml ajustes perfil comandos` → erro de compilação.

- [ ] **Step 3: Implementar; registrar comandos em `lib.rs` (`tauri::Builder::default().manage(Estado).invoke_handler(tauri::generate_handler![...])`); em `capabilities/default.json` permitir `core:default` e os comandos próprios para a janela `main`; `main.rs` chama `otimizador::executar()`.**

- [ ] **Step 4: Rodar e ver passar** — `cargo test --manifest-path src-tauri/Cargo.toml` → PASS; `npm run dev` abre a janela sem erro no console do Rust.

- [ ] **Step 5: Commit**

```bash
git add src-tauri
git commit -m "feat(rust): ajustes, perfil com fallback conservador e comandos Tauri"
```

---

### Task 7: `data/perfis.json` e `scripts/diagnostico.ps1`

**Files:**
- Create: `data/perfis.json`, `scripts/diagnostico.ps1`, `scripts/tests/diagnostico.Tests.ps1`

**Interfaces:**
- Consumes: Task 2 (`Get-Perfil`, `Set-Perfil`, `Send-*`).
- Produces:
  - `data/perfis.json`:
    ```json
    { "classes": { "basico": { "ramGbMax": 4.5, "nucleosMax": 2 }, "gamer": { "gpuDedicada": true, "ramGbMin": 16 }, "padrao": "medio" },
      "limites": { "lixoNotificarMB": 500, "diasSemVerificarDisco": 90 } }
    ```
    Regra de precedência: `basico` se **qualquer** critério seu bater; senão `gamer` se **todos** os seus baterem; senão `padrao`. `disco` = `hdd` se o disco do sistema tiver `MediaType = HDD`; qualquer outro (`SSD`, `NVMe`, `Unspecified` com `BusType NVMe`) = `ssd`; se não der para ler, `hdd` (conservador).
  - `Invoke-Acao $Id 'coletar' $Params $Teste` → `@@RESULT dados = { equipo{fabricante,modelo,nome}, sistema{nome,versao,build,arquitetura,diasLigado,inicioRapido:bool}, cpu{nome,nucleos,hilos,mhz,temp}, ram{totalBytes,livreBytes,modulos}, gpus[{nome,fabricante:nvidia|amd|intel|outro,dedicada:bool,driver,vram}], discos[{nome,tipo:HDD|SSD|NVMe,bus,tamanho,saude,desgaste,temperatura,horas,erros,sistema:bool}], unidades[{letra,rotulo,total,livre}], bateria{carga,saude}|null, servicos{sysmain:Running|Stopped|Disabled, wsearch:...}, perfil{classe,disco,manual} }`. Grava `perfil.json` via `Set-Perfil`; se já existir com `manual = $true`, mantém `classe`/`disco` gravados e só atualiza o resto.
  - `Params.simular` (só em `$Teste`): objeto com os mesmos campos brutos (`ramGb`, `nucleos`, `gpuDedicada`, `discoSistemaMediaType`, `discoSistemaBusType`) que substitui a coleta real, para os testes de classificação.
  - Função pública `Get-ClasseEDisco($Bruto, $Regras)` → `@{classe; disco}` (pura, testável).

- [ ] **Step 1: Escrever os testes**

`diagnostico.Tests.ps1` (importa `common.ps1` e `diagnostico.ps1`; limpa `Get-AppPastas $true` no `BeforeEach`):
- `Get-ClasseEDisco @{ramGb=4;nucleos=4;gpuDedicada=$false;discoSistemaMediaType='HDD'} $regras` → `basico`/`hdd`.
- `@{ramGb=8;nucleos=4;gpuDedicada=$false;...='SSD'}` → `medio`/`ssd`.
- `@{ramGb=16;nucleos=8;gpuDedicada=$true;...='HDD'}` → `gamer`/`hdd` (gamer com HDD: duas dimensões).
- `@{ramGb=16;nucleos=2;gpuDedicada=$true;...='SSD'}` → `basico` (basico prevalece).
- `@{ramGb=32;nucleos=8;gpuDedicada=$true;discoSistemaMediaType='Unspecified';discoSistemaBusType='NVMe'}` → `ssd`.
- `@{...;discoSistemaMediaType=$null}` → `hdd`.
- `Invoke-Acao 'a1' 'coletar' @{simular=<basico/hdd>} $true` grava `perfil.json` com `classe = basico`; depois `Set-Perfil @{classe='gamer';disco='ssd';manual=$true} $true` e `coletar` de novo com simulação `basico/hdd` → `Get-Perfil` continua `gamer`/`ssd` (manual preservado).
- `coletar` real (sem `simular`, ainda `$Teste = $true` para gravar em TEMP) devolve `cpu.nucleos -gt 0`, `ram.totalBytes -gt 0`, `discos.Count -ge 1`, e exatamente um disco com `sistema = $true`.

- [ ] **Step 2: Rodar e ver falhar** — `Invoke-Pester -Path scripts/tests/diagnostico.Tests.ps1` → FAIL.

- [ ] **Step 3: Implementar `diagnostico.ps1`**

Coleta como o `hardware.ps1` do RetroLimpia (CIM `Win32_Processor/ComputerSystem/OperatingSystem/BaseBoard/BIOS/PhysicalMemory/VideoController`, `Get-PhysicalDisk` + `Get-StorageReliabilityCounter` com fallback `Win32_DiskDrive`, `MSAcpi_ThermalZoneTemperature`, bateria), mais: disco do sistema = `Get-Partition -DriveLetter $env:SystemDrive[0] | Get-Disk | Get-PhysicalDisk`; `inicioRapido` = `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power\HiberbootEnabled -eq 1`; `servicos` via `Get-Service SysMain, WSearch`. GPU `dedicada` = fabricante nvidia/amd e nome não contendo `Radeon(TM) Graphics|Vega|Iris|UHD|HD Graphics`.

- [ ] **Step 4: Rodar e ver passar** — PASS. Lint sem saída.

- [ ] **Step 5: Commit**

```bash
git add data scripts
git commit -m "feat(scripts): diagnóstico com perfil em duas dimensões"
```

---

### Task 8: `scripts/limpeza.ps1`

**Files:**
- Create: `scripts/limpeza.ps1`, `scripts/tests/limpeza.Tests.ps1`

**Interfaces:**
- Consumes: Task 2, `Get-Perfil`.
- Produces `Invoke-Acao $Id $Acao $Params $Teste`:
  - `analisar` → `dados = { categorias: [ { id, cor: verde|amarelo, tamanhoBytes, disponivel: bool, motivoIndisponivel: '', confirmacaoDupla: bool, avancado: bool } ] }`, na ordem de `CATEGORIAS_LIMPEZA` (Task 4). Regras: `shaders` só `disponivel` se `perfil.classe = gamer` ou `Params.avancado = $true`; `pontos_antigos` só com `avancado`; `windows_old` só se `C:\Windows.old` existir há ≥ 10 dias (`CreationTime`); `dism_componentes` tamanho = `-1` (desconhecido; o DISM não mede barato) e cor amarelo; `windows_old` e `pontos_antigos` com `confirmacaoDupla = $true`.
  - `limpar` com `Params.categorias` → `dados = { liberadoBytes, pulados: int, detalhes: [ { id, antes, depois, pulados } ] }`. Apaga conteúdo, não a pasta; arquivo em uso é pulado e contado (Review Focus 4). `wu_cache` para `wuauserv`/`bits` e religa. `entrega` usa `Delete-DeliveryOptimizationCache -Force` se existir. `dism_componentes` executa `Dism.exe /Online /Cleanup-Image /StartComponentCleanup` (sem `/ResetBase`; com `/ResetBase` só se `Params.avancado -and Params.resetBase`). `windows_old` grava `StateFlags0099 = 2` em `HKLM:\...\VolumeCaches\Previous Installations`, roda `cleanmgr.exe /sagerun:99`, espera terminar, remove o valor. `pontos_antigos` lista com `vssadmin list shadows`, apaga todos menos o mais recente com `vssadmin delete shadows /Shadow={id} /Quiet`.
  - Em `$Teste`: as rotas de cada categoria vêm de `"$env:TEMP\OtimizadorTeste\limpeza\<id>"` (função `Get-RotasCategoria $Id $Teste`), `lixeira`, `dism_componentes`, `windows_old`, `pontos_antigos` e parada de serviços são **simulados** (não executam nada e devolvem `antes = depois = 0`).

- [ ] **Step 1: Escrever os testes**

`limpeza.Tests.ps1` (cria pastas de teste com arquivos de tamanho conhecido no `BeforeEach`):
- `analisar` devolve 14 categorias na ordem de `CATEGORIAS_LIMPEZA`; `temp_usuario.tamanhoBytes = 300` quando a pasta de teste tem 3 arquivos de 100 bytes.
- Com `perfil` gravado `classe=medio` → `shaders.disponivel = $false` e `motivoIndisponivel` não vazio; com `classe=gamer` → `$true`; com `medio` e `Params.avancado = $true` → `$true`.
- `pontos_antigos.disponivel = $false` sem `avancado`; `$true` com.
- `windows_old`, `pontos_antigos` têm `confirmacaoDupla = $true`; `temp_usuario` tem `$false`.
- `limpar @{categorias=@('temp_usuario')}` → pasta `temp_usuario` fica vazia, pasta `temp_windows` intacta, `liberadoBytes = 300`, `pulados = 0`.
- Arquivo aberto com `[IO.File]::Open($f,'Open','ReadWrite','None')` durante `limpar` → esse arquivo permanece, `pulados = 1`, `ok = $true`, os outros foram apagados.
- `limpar @{categorias=@('inexistente')}` → `ok = $false`, `erro -match 'categoria'`.
- `limpar` nunca apaga a pasta raiz da categoria (ela continua existindo depois).

- [ ] **Step 2: Rodar e ver falhar** — FAIL.

- [ ] **Step 3: Implementar `limpeza.ps1`**

Rotas reais por categoria = as do `limpieza.ps1` do RetroLimpia (linhas 9–52: temp, `SoftwareDistribution\Download`, DeliveryOptimization, WER, `thumbcache_*.db`, caches de Chrome/Edge/Brave/Firefox por perfil, minidumps, shaders D3DSCache/NVIDIA/AMD/Intel, launchers Steam/Battle.net/Discord) com nomes em português. `Send-Progress` por categoria; `Send-Log 'aviso'` por arquivo pulado (máximo 20 linhas, depois só o total). `Write-AppLog` com o total liberado.

- [ ] **Step 4: Rodar e ver passar** — PASS. Lint sem saída.

- [ ] **Step 5: Adicionar `limpeza` e `diagnostico` à allowlist do `host.ps1` (já estão) e rodar a suíte inteira**

Run: `Invoke-Pester -Path scripts/tests -CI`
Expected: 0 falhas.

- [ ] **Step 6: Commit**

```bash
git add scripts
git commit -m "feat(scripts): limpeza com categorias por perfil e arquivos em uso pulados"
```

---

### Task 9: Interface (Início, Diagnóstico, Limpeza, demo)

**Files:**
- Create: `ui/index.html`, `ui/styles.css`, `ui/js/esc.js`, `ui/js/i18n.js`, `ui/js/api.js`, `ui/js/estado.js`, `ui/js/vistas/inicio.js`, `ui/js/vistas/diagnostico.js`, `ui/js/vistas/limpeza.js`, `ui/js/demo.js`, `ui/js/arranque.js`, `ui/i18n/pt-BR.json`
- Modify: `src-tauri/tauri.conf.json` (`app.security.csp`, janela 1240×800 mín. 760×500, `decorations: false`, `title: Otimizador`)

**Interfaces:**
- Consumes: comandos da Task 6 (`executar`, `cancelar`, `ajustes_ler`, `ajustes_gravar`, `dados`, `info`), evento `progresso`.
- Produces:
  - `esc(v) → string` (mesma tabela do RetroLimpia `00-estado.js:37`).
  - `t(chave, vars?) → string`; chaves faltantes devolvem `[chave]` (fácil de notar).
  - `api.executar(modulo, acao, params, onProgresso?) → Promise<dados>`; `api.cancelar()`; `api.info()`; `api.ajustes.ler()/gravar(parcial)`; `api.dados(nome)`. Em `S.info.demo`, `api.executar` delega a `demo.executar` (dados falsos com progresso simulado para `diagnostico/coletar`, `limpeza/analisar`, `limpeza/limpar`).
  - Vistas registradas em `VISTAS = { inicio, diagnostico, limpeza }`, cada uma com `render(main)`; `arranque.js` aplica `document.documentElement.classList.toggle('leve', S.info.modo_leve)` e a escala `--zoom` pela largura da janela (0,7–1,0).
  - Layout conforme o esboço da spec §11: barra de título custom (min/max/fechar via `getCurrentWindow()`), nav lateral, `<main>`, toasts, modal de confirmação com texto "vai fazer X em Y; para desfazer, Z" **antes** de toda ação de escrita; para categorias `confirmacaoDupla`, segunda caixa com a frase exata `Isto não vai para a quarentena e não pode ser desfeito.` e um checkbox obrigatório.

- [ ] **Step 1: Escrever a verificação automática possível**

`tools/ci-local.ps1` ganha o passo: `Select-String -Path ui/js -Pattern 'innerHTML\s*[+]?=\s*[^;]*\$\{(?![^}]*esc\()' -Recurse` → se encontrar, falha com a lista (interpolação em `innerHTML` sem `esc(`). E: `Select-String -Path ui/index.html -Pattern '>[^<{]*[A-Za-zÀ-ú]{3,}[^<]*<' ` deve devolver só linhas marcadas com `data-i18n` (textos visíveis vêm do JSON).

- [ ] **Step 2: Implementar a interface**

`pt-BR.json` inclui, no mínimo: `app.nome`, nomes das 3 vistas, `inicio.perfil.{basico,medio,gamer}`, `inicio.disco.{hdd,ssd}`, `inicio.frase` = `Tudo que o programa remove de você pode ser desfeito; caches e temporários são apagados de vez.`, nomes e descrições das 14 categorias (uma frase cada, dizendo o que é e o efeito), `limpeza.confirmacaoDupla`, `comum.{cancelar,confirmar,voltar,desfazer}`. Vista Diagnóstico mostra o perfil com botão "não é isso, trocar" que grava `perfil.json` com `manual: true` (via `executar('diagnostico','coletar',{forcarPerfil:{classe,disco}})` — **adicionar** esse parâmetro opcional à validação da Task 4 e ao script da Task 7, aceito sempre, valores restritos às listas). Vista Limpeza: checkboxes por categoria (verdes marcadas por padrão), tamanho formatado, botão "Limpar selecionadas", barra de progresso alimentada pelo evento, resultado "X liberados, Y arquivos em uso pulados".

- [ ] **Step 3: Verificar em demo e real**

Run: `npm run dev -- -- --demo` → navegar pelas 3 vistas, limpar em demo, confirmar que o modal aparece e que `windows_old` exige a segunda confirmação.
Run: `npm run dev` (elevado) → Diagnóstico mostra a máquina real (Positivo C6400, HDD → perfil básico/hdd, classe `leve` no `<html>`); Limpeza `analisar` lista tamanhos reais; `limpar` só de `temp_usuario` libera e registra em `%ProgramData%\Otimizador\logs`.
Run: `powershell -File tools/ci-local.ps1 -SoTestes` → passa, incluindo os dois greps.

- [ ] **Step 4: Commit**

```bash
git add ui src-tauri tools
git commit -m "feat(ui): início, diagnóstico e limpeza com modo demo e confirmações"
```

---

### Task 10: Instalador e elevação

**Files:**
- Modify: `src-tauri/tauri.conf.json`, `src-tauri/build.rs`, `src-tauri/Cargo.toml`
- Create: `src-tauri/manifest.xml`, `src-tauri/icons/*` (via `npm run tauri icon <png>`; usar um PNG 1024×1024 provisório gerado em SVG → PNG)

**Interfaces:**
- Produces: `npm run build` gera `src-tauri/target/release/bundle/nsis/Otimizador_<versão>_x64-setup.exe`, per-machine, que embute o bootstrapper do WebView2 e cujo executável instalado pede UAC ao abrir.

- [ ] **Step 1: Configurar**

`tauri.conf.json`: `bundle.active = true`, `bundle.targets = ["nsis"]`, `bundle.windows.webviewInstallMode = { "type": "embedBootstrapper" }`, `bundle.windows.nsis = { "installMode": "perMachine", "languages": ["PortugueseBR"], "displayLanguageSelector": false }`, `bundle.resources` (Task 6), `bundle.publisher = "Otimizador (nome provisório)"`.
`build.rs`:
```rust
fn main() {
    let attrs = tauri_build::WindowsAttributes::new().app_manifest(include_str!("manifest.xml"));
    tauri_build::try_build(tauri_build::Attributes::new().windows_attributes(attrs)).expect("build");
}
```
`manifest.xml`: manifesto padrão do Tauri com `<requestedExecutionLevel level="requireAdministrator" uiAccess="false"/>` e `compatibility` para Windows 10/11.

- [ ] **Step 2: Build e verificar**

Run: `npm run build`
Expected: `.exe` do instalador existe; tamanho ≤ 16,5 MB (`(Get-Item ...).Length / 1MB`).
Run: instalar numa VM ou na própria máquina; abrir pelo atalho → UAC aparece; dentro do app, `info().es_admin == true` (mostrar na vista Diagnóstico como "Executando como administrador: sim").
Run: `tools/ci-local.ps1` completo → passa, incluindo o limite de tamanho.

- [ ] **Step 3: Commit**

```bash
git add src-tauri
git commit -m "feat(build): instalador NSIS per-machine com WebView2 embutido e requireAdministrator"
```

---

### Task 11: Medição e CI

**Files:**
- Create: `tools/medir.ps1`, `.github/workflows/build.yml`

**Interfaces:**
- Produces: `tools/medir.ps1 [-Exe <caminho>]` imprime JSON `{ versao, pesoInstaladoMB, instaladorMB, arranqueSeg, processos, ramAbertaMB, ramHostMB, cpuOciosoPct }` somando **todos** os processos do app: `Otimizador.exe`, `msedgewebview2.exe` cujo `ParentProcessId` pertença à árvore do app, e `powershell.exe` filho do app. Sai com código 1 se `ramAbertaMB > 120` ou `cpuOciosoPct >= 0.5` (as duas metas que bloqueiam release na spec §12).
- `build.yml`: em `push` para `main`, tags `v*` e `workflow_dispatch`; `windows-latest`; passos: checkout, `actions/setup-node@v4` (Node 22), `dtolnay/rust-toolchain@stable`, `Swatinem/rust-cache@v2`, `Install-Module Pester, PSScriptAnalyzer`, `npm ci`, `powershell -File tools/ci-local.ps1` (que já inclui lint, Pester, clippy, cargo test, build e limite de tamanho), `Get-FileHash` → `SHA256.txt`, `actions/upload-artifact@v4` com o `.exe` e `SHA256.txt`. Publicação de Release fica para o Plano 6 (depende da conta GitHub e da chave do atualizador).

- [ ] **Step 1: Escrever `tools/medir.ps1`** a partir de `tools/medir-rendimiento.ps1` do RetroLimpia (mesma estratégia: abre, espera janela, 5 s, mede 10 s, fecha), com a soma de processos descrita acima.

- [ ] **Step 2: Rodar contra o instalado**

Run: `powershell -File tools/medir.ps1`
Expected: JSON impresso; `ramAbertaMB ≤ 120`, `cpuOciosoPct < 0.5`, `arranqueSeg` reportado. Se a RAM passar, registrar o valor no README como pendência e abrir tarefa no Plano 5 (destruir WebView2 na bandeja já está previsto lá).

- [ ] **Step 3: Escrever `.github/workflows/build.yml`** e validar a sintaxe localmente: `npx --yes @action-validator/cli .github/workflows/build.yml` (ou revisar manualmente se o pacote não estiver disponível).

- [ ] **Step 4: Commit**

```bash
git add tools .github
git commit -m "chore: medição de desempenho e CI no GitHub Actions"
```

- [ ] **Step 5: Publicar o repositório** — depende das perguntas abertas 2 e 3 (licença/visibilidade e conta GitHub). Quando respondidas: criar o repositório, `git remote add origin ...`, `git push -u origin main`, conferir que o workflow passa no Actions.

---

## Auto-revisão (feita ao escrever)

- **Cobertura da spec neste plano:** §6 arquitetura (Tasks 3–6), §7 perfil (Task 7), §8.1 Diagnóstico (Task 7, 9), §8.2 Limpeza (Task 8, 9), §9 regras 3, 5, 7 (Tasks 2, 5, 8), §10 instalador/WebView2/sem icacls (Task 10), §12 orçamento (Tasks 1, 11), §13 testes (todas). §9 regras 1, 2, 4, 6 (ponto de restauração, quarentena, protegidos de processos, rede) e §8.3–8.8 ficam nos Planos 2–5, como anunciado no cabeçalho. O ajuste `ponto_restauracao` já nasce em `Ajustes` (Task 6) para o Plano 2 usar.
- **Consistência de nomes:** `Invoke-Acao $Id $Acao $Params $Teste` (Tasks 3, 7, 8); `validar(modulo, acao, params, teste)` (Tasks 4, 5, 9); `Perfil{classe,disco,manual}` em PS e Rust (Tasks 2, 6, 7); `CATEGORIAS_LIMPEZA` com 14 ids idênticos em `acoes.rs`, `limpeza.ps1` e `pt-BR.json`; evento `progresso` (Tasks 6, 9).
- **Review Focus:** 1 → Task 6; 2 → Task 4; 3 → Task 3; 4 → Task 8; 5 → Task 2. Todos com teste nomeado.
- **Proporção:** o plano descreve interfaces e testes, não corpos; os únicos blocos de código são o `build.rs` (configuração exata que o implementador não deduziria) e o `perfis.json`.
