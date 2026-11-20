# NexTune — Plano 2: Programas, Quarentena e Ponto de Restauração

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Entregar o módulo Programas (listar, desinstalar em silêncio, restos para a quarentena), a Quarentena (listar, restaurar, purgar) e as regras transversais da spec §9.1–9.2 e §9.4–9.5 que ainda faltavam: ponto de restauração antes da primeira ação de escrita da sessão, Proteção do Sistema desligada tratada sem recusar, bloqueio de escrita quando o usuário elevado não é o usuário da sessão, listas compartilhadas de protegidos e bloatware.

**Architecture:** Mesma ponte do Plano 1 (UI → comandos Tauri → `host.ps1` → `scripts/<modulo>.ps1`). Três módulos PowerShell novos (`quarentena.ps1`, `sistema.ps1`, `programas.ps1`), duas listas de dados (`bloatware.json`, `protegidos.json`), a allowlist e a validação de parâmetros estendidas em `acoes.rs`, e duas vistas novas na interface (Programas, Quarentena) mais um fluxo compartilhado `garantirPonto()` que a Limpeza também passa a usar.

**Tech Stack:** o mesmo do Plano 1. Nada novo além de `reg.exe` (export/import de chaves), `Checkpoint-Computer`, `Enable-ComputerRestore`, `vssadmin`, `Get-AppxPackage`, `Remove-AppxPackage`, `Remove-AppxProvisionedPackage`.

**Spec:** `docs/superpowers/specs/2026-11-20-otimizador-design.md` §8.3, §9.1, §9.2, §9.4, §9.5, §17.

**Plano anterior:** `2026-11-20-fundacao-diagnostico-limpeza.md` (concluído). **Planos seguintes:** 3 Inicialização + Ajustes do Windows; 4 Disco + Atualizações; 5 Modo Jogo + bandeja + lembretes + atualizador; 6 site, README e primeira release.

## Global Constraints

Valem todas as do Plano 1 (PowerShell 5.1, BOM nos `.ps1`, sem `Invoke-Expression`, argumentos em lista, `Test-ProtectedPath` no Rust **e** no PowerShell, textos só em `ui/i18n/pt-BR.js`, `esc()`/nós DOM, commits pequenos em português). Mais estas:

- **Ambiente de construção:** o contêiner de desenvolvimento é Linux. `cargo test` e `cargo clippy` rodam aqui (bibliotecas GTK instaladas); Pester e PSScriptAnalyzer **não** rodam aqui e são verificados no GitHub Actions (`windows-latest`) e pelo usuário com `tools/ci-local.ps1`. Por isso cada script novo passa por revisão de um segundo agente lendo o código, e os testes Pester são escritos para falhar alto (sem `-ErrorAction SilentlyContinue` escondendo falhas).
- **Semântica das cores em Programas é a mesma da Limpeza:** `verde` = remover é seguro (bloatware conhecido), `amarelo` = decide você (utilitário OEM, trial, duplicado), `vermelho` = não remova (runtime, Edge, WebView2, driver, parte do Windows). Programa fora das listas fica sem cor (`null`) e a interface mostra "sem classificação". Item `vermelho` vem com `protegido:true` e o botão Desinstalar não aparece.
- **Quarentena nunca apaga antes do prazo sem clique.** `purgarVencidos` só remove entradas cuja data + `diasQuarentena` já passou; `purgar {ids}` exige `confirmado:true`.
- **Ponto de restauração nunca é motivo de recusa.** Falhou? Avisa e segue. Proteção desligada? Pergunta uma vez (ligar com 3 % ou seguir sem) e grava a escolha em `ajustes.pontoRestauracao` (`ligar` | `pular`).
- **`SystemRestorePointCreationFrequency` volta ao valor original** (ou é removida, se não existia) num `finally`, mesmo com cancelamento.
- **Ids de programa nunca viram caminho.** O PowerShell resolve o id contra a lista que ele mesmo gera (`Get-ProgramaPorId`); o Rust só confere tamanho e caracteres.
- **Anti-objetivos continuam valendo:** Edge, WebView2, runtimes .NET/VC++, DirectX, GameInput, drivers e tudo que `Test-ProtectedPath` cobre são `protegido:true` e nenhuma ação de escrita os aceita, nem no modo avançado.

## Review Focus

Entradas que a spec implica e que um teste fixa (cada uma com teste nomeado na tarefa dona):

1. **Restaurar da quarentena quando a origem voltou a existir:** não sobrescreve; o item fica na quarentena e o resultado lista o conflito. → Tarefa 2.
2. **Chave de registro com nome contendo espaço, acento e parênteses** exportada e reimportada intacta (o `.reg` é UTF-16 LE com BOM, como `reg.exe` gera). → Tarefa 2.
3. **`SystemRestorePointCreationFrequency` restaurada após falha de `Checkpoint-Computer`** (e removida se não existia antes). → Tarefa 3.
4. **UninstallString com aspas, espaços e argumentos próprios** (`"C:\Program Files\X\unins000.exe" /PARAM`) separada em executável + argumentos, e o argumento silencioso acrescentado sem duplicar. → Tarefa 4.
5. **Programa protegido nunca desinstala**, mesmo com `confirmado:true` e `avancado:true`, mesmo se o id vier correto. → Tarefas 4 e 5.
6. **Usuário elevado diferente do usuário do console:** toda ação de escrita é recusada pelo Rust com `sessao_diferente`, antes de chegar ao PowerShell; leitura segue liberada. → Tarefa 5.
7. **Caminho de resto dentro de pasta protegida** (`C:\Program Files\Common Files\X`) recusado pelo Rust **e** pelo PowerShell. → Tarefas 4 e 5.

---

## Estrutura de arquivos (novos e alterados)

```
data/
  bloatware.json              lista por PackageFamilyName/ProductId (Store) e por nome/editor (clássico): cor, motivo, siteReinstalar, productId
  protegidos.json             programas e processos protegidos (compartilhado por Programas, Inicialização e Modo Jogo): padrões de nome/editor/PackageFamilyName
scripts/
  quarentena.ps1              funções Move-ParaQuarentena, Export-ChaveRegistro, Remove-ChaveComBackup; ações listar, restaurar, purgar, purgarVencidos
  sistema.ps1                 ações protecaoEstado, criarPonto, ligarProtecao, sessao
  programas.ps1               ações listar, desinstalar, restos, limparRestos
  host.ps1                    allowlist += quarentena, sistema, programas
  tests/quarentena.Tests.ps1
  tests/sistema.Tests.ps1
  tests/programas.Tests.ps1
  tests/fixtures/desinstalador.cmd   desinstalador falso: grava marcador com os argumentos recebidos e sai com o código pedido
src-tauri/src/
  acoes.rs                    MODULOS += programas, quarentena, sistema; validação das ações novas; e_escrita(modulo, acao)
  comandos.rs                 DADOS_PERMITIDOS += bloatware, protegidos; Estado += ponto_sessao, sessao; comando ponto_sessao; bloqueio de escrita por sessão
  lib.rs                      registra ponto_sessao
ui/
  index.html                  nav += programas, quarentena (com contador), faixa de sessão bloqueada
  js/estado.js                S += programas, quarentena, sessao; aplicarOcupado respeita S.escritaBloqueada
  js/api.js                   api.pontoSessao(); demo das ações novas
  js/ponto.js                 garantirPonto(): fluxo compartilhado do ponto de restauração
  js/vistas/programas.js
  js/vistas/quarentena.js
  js/vistas/limpeza.js        chama garantirPonto() antes de limpar
  js/arranque.js              carrega sessao e quarentena; purga vencidos
  js/demo.js                  dados de programas, quarentena, sistema
  i18n/pt-BR.js               chaves programas.*, quarentena.*, ponto.*, sessao.*
README.md                     pendências atualizadas
```

---

## Contratos (JSON, camelCase na UI; o PowerShell devolve exatamente estes nomes)

### quarentena
- `listar {}` → `{ entradas: [{ id, data (ISO), modulo, descricao, itens: n, tamanhoBytes, venceEm (ISO) }] , diasPadrao }`. Ordenadas da mais nova para a mais antiga.
- `restaurar { ids: [id] }` → `{ restauradas: [id], conflitos: [{ id, item, motivo }], falhas: [{ id, erro }] }`. Uma entrada só sai da quarentena quando **todos** os itens voltaram; com conflito ela fica.
- `purgar { ids: [id], confirmado: true }` → `{ removidas: [id], falhas: [{ id, erro }] }`.
- `purgarVencidos { dias: 1..90 }` → `{ removidas: [id] }`.
- Layout em disco: `<Quarentena>\<id>\manifesto.json` + `<Quarentena>\<id>\itens\<n>\...`. `id` = `yyyyMMdd-HHmmss-xxxx` (4 hex). Manifesto: `{ id, data, modulo, descricao, itens: [{ n, tipo: 'arquivo'|'pasta'|'chave', origem, nome }] }`. Chave de registro: `itens\<n>\chave.reg` (export de `reg.exe`), `origem` = caminho completo (`HKCU\Software\...`). Em modo teste a base é `%TEMP%\NexTuneTeste` e as chaves ficam sob `HKCU\Software\NexTuneTeste`.
- Funções exportadas (dot-source por `programas.ps1`): `New-EntradaQuarentena -Modulo -Descricao -Teste` → objeto com `id`; `Add-ItemQuarentena -Entrada -Caminho` (arquivo/pasta: `Move-Item` após `Test-ProtectedPath` falso e `Test-Reparse` falso; chave: `Export-ChaveRegistro` + remoção); `Complete-EntradaQuarentena -Entrada` (grava o manifesto; entrada sem itens é apagada e devolve `$null`).

### sistema
- `protecaoEstado {}` → `{ ativa, ultimoPonto (ISO|null), frequenciaMin (int|null), unidade }`.
- `criarPonto { descricao? }` → `{ criado, mensagem }`. Nunca lança: falha vira `criado:false` com mensagem. Zera `SystemRestorePointCreationFrequency` antes e restaura no `finally`.
- `ligarProtecao {}` → `{ ligada, mensagem }` (`Enable-ComputerRestore -Drive <SystemDrive>` + `vssadmin resize shadowstorage /for=C: /on=C: /maxsize=3%` com lista de argumentos).
- `sessao {}` → `{ usuarioProcesso, usuarioConsole (string|null), mesmo (bool), desconhecido (bool) }`. `mesmo` compara sem diferenciar caixa; console sem usuário (RDP, serviço) → `desconhecido:true, mesmo:true`.
- Em modo teste: registro em `HKCU\Software\NexTuneTeste\SystemRestore`, nenhum `Checkpoint-Computer`/`vssadmin`/`Enable-ComputerRestore` real (grava marcador em `%TEMP%\NexTuneTeste\sistema\`), e `simular { falharCriar?, usuarioConsole?, usuarioProcesso? }` aceito só em teste (o estado da proteção em teste vem da chave `HKCU\Software\NexTuneTeste\SystemRestore` semeada pelo teste).

### programas
- `listar {}` → `{ programas: [{ id, nome, versao, editor, tipo: 'classico'|'store', tamanhoBytes (-1 desconhecido), instaladoEm (ISO|null), local, cor (verde|amarelo|vermelho|null), motivoCor, protegido, motivoProtegido, instalador: 'msi'|'inno'|'nsis'|'installshield'|'quiet'|'loja'|'desconhecido', servicos: [nome], ramBytes, packageFamilyName, productId, siteReinstalar }] }`.
  - Id clássico: `cl:<hive>:<nomeDaChave>` com hive em `hklm64|hklm32|hkcu`. Id Store: `st:<PackageFullName>`.
  - Fontes: `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall`, `HKLM\SOFTWARE\WOW6432Node\...\Uninstall`, `HKCU\...\Uninstall` (ignora `SystemComponent=1`, sem `DisplayName`, atualizações `KB`); `Get-AppxPackage -AllUsers` sem `IsFramework`, sem `SignatureKind -eq 'System'` e sem `NonRemovable`.
  - Progresso em três etapas (clássicos, Store, tamanhos/serviços/RAM). Tamanho: `EstimatedSize` (KB) quando houver, senão `Get-PathSize` do `InstallLocation` com teto de 10 s por programa (`-1` se estourar).
- `desinstalar { id, confirmado: true, avancado?, desprovisionar? }` → `{ modo: 'silencioso'|'assistente'|'loja', codigo (int|null), restos: <mesmo formato de restos.candidatos> }`. Recusa `protegido`. Ordem: `QuietUninstallString` → MSI (`msiexec /x {guid} /qn /norestart`) → Inno (`/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`) → NSIS (`/S`) → InstallShield (`/s /v"/qn"`) → último recurso o assistente (sem `-Wait` infinito: limite de 10 min, código `null` se estourar). Store: `Remove-AppxPackage -AllUsers`; `desprovisionar` só com `avancado:true` (`Remove-AppxProvisionedPackage -Online`). Em modo teste só executa desinstaladores dentro de `%TEMP%\NexTuneTeste`.
- `restos { id, nome, editor?, local? }` → `{ candidatos: [{ tipo: 'pasta'|'arquivo'|'atalho'|'chave', caminho, tamanhoBytes, motivo, confianca: 'media' }] }`. Candidatos: `local` se ainda existir e sem `.exe/.dll/.sys`; `%LOCALAPPDATA%`, `%APPDATA%`, `%ProgramData%` com `\<editor>\<nome>` ou `\<nome>` (mesmas regras: fora de `Test-ProtectedPath`, sem executáveis, sem alteração há 30 dias — exceto `local`, que acabou de ser desinstalado); atalhos `.lnk` do Menu Iniciar (usuário e todos) e da Área de Trabalho cujo alvo não existe; chaves `HKCU\Software\<editor>\<nome>` e `HKLM\SOFTWARE\<editor>\<nome>` quando o programa não está mais na lista. Nunca sugere nada sob caminho protegido.
- `limparRestos { itens: [{ tipo, caminho }], confirmado: true }` → `{ quarentenaId (string|null), movidos: n, falhas: [{ caminho, erro }] }`. Cada item passa por `Test-ProtectedPath` de novo; tudo numa única entrada de quarentena (`modulo:'programas'`).

### Rust
- `acoes::e_escrita(modulo, acao) -> bool`: `limpeza/limpar`, `programas/desinstalar`, `programas/limparRestos`, `quarentena/restaurar`, `quarentena/purgar`, `quarentena/purgarVencidos`, `sistema/criarPonto`, `sistema/ligarProtecao`.
- `comandos::executar`: se `e_escrita` e a sessão ainda não foi verificada neste processo, roda `sistema/sessao` antes e guarda; `mesmo:false` → `Err("sessao_diferente")`. `sistema/criarPonto` com `criado:true` marca `ponto_sessao`.
- Comando novo `ponto_sessao() -> bool`. `Info` ganha `sessaoOk: Option<bool>` (None até verificar).
- `DADOS_PERMITIDOS` = `perfis, bloatware, protegidos`.

### UI
- `garantirPonto()` (`ui/js/ponto.js`): se `ajustes.pontoRestauracao === 'pular'` ou `api.pontoSessao()` → volta `true`. Senão lê `protecaoEstado`; desligada e `perguntar` → modal com dois botões (**Ligar a Proteção do Sistema (recomendado)** / Continuar sem ponto) que grava `ligar` ou `pular`; `ligar` → `ligarProtecao`. Depois `criarPonto`; `criado:false` → toast de aviso e segue. Devolve `true` sempre que o usuário não cancelou o modal.
- Programas: lista com busca, filtros (todos / recomendados / Store / clássicos), ordenação (nome, tamanho, data), ponto de cor, selos (Store, protegido, serviços, RAM). Botão Desinstalar → `garantirPonto()` → modal "Vai desinstalar X (Y). Para desfazer: Z" (Z = link da Store `ms-windows-store://pdp/?ProductId=` quando `productId`, senão `siteReinstalar`, senão "reinstale pelo site do fabricante"); no modo avançado, apps da Store mostram a caixa "Impedir que volte em contas novas" com aviso. Depois: cartão de resultado e lista de restos com caixas (todas marcadas, confiança média sempre pergunta) → "Mover para a quarentena".
- Quarentena: lista (data, módulo, descrição, itens, tamanho, vence em), seleção múltipla, **Restaurar** e **Apagar agora** (confirmação dupla com checkbox), aviso "N vencidas". Contador no menu (`Quarentena (n)`).
- Sessão bloqueada: `S.sessaoOk === false` → faixa fixa explicando e todos os botões de escrita (`.acao.escrita`) com `data-bloq`.
- Limpeza: `limpar()` chama `garantirPonto()` depois das confirmações e antes de `executar`.
- Demo: programas de exemplo (Positivo/Multilaser bloatware em verde, utilitário OEM em amarelo, Edge/WebView2 em vermelho, dois sem cor), três entradas de quarentena (uma vencida), proteção desligada na primeira pergunta.

---

### Task 1: Listas de dados e `dados` no Rust

**Files:** `data/bloatware.json`, `data/protegidos.json`, `src-tauri/src/comandos.rs`.

- [x] **Step 1:** Escrever `data/protegidos.json`: `{ "programas": [{ "padrao": <regex sem diferenciar caixa sobre nome|editor|packageFamilyName>, "motivo": <texto curto pt-BR> }], "processos": [<nomes .exe>] }`. Cobrir: Microsoft Edge, EdgeWebView/WebView2, Microsoft Visual C++ 20xx Redistributable, .NET (Runtime, Desktop Runtime, Framework, Windows Desktop), Windows SDK, DirectX, GameInput, Xbox Identity/Game Bar dependências, drivers NVIDIA/AMD/Intel/Realtek, Windows Security/Defender, Microsoft Store, Microsoft.WindowsStore, Microsoft.VCLibs, Microsoft.NET.Native, Microsoft.UI.Xaml, Microsoft.WindowsAppRuntime, Microsoft.DesktopAppInstaller (winget), OneDrive (amarelo, não protegido — vai em bloatware), Windows Terminal. Processos: `explorer.exe, csrss.exe, winlogon.exe, lsass.exe, services.exe, svchost.exe, dwm.exe, msedgewebview2.exe, NexTune.exe, powershell.exe, conhost.exe, RuntimeBroker.exe, SearchHost.exe, StartMenuExperienceHost.exe, ShellExperienceHost.exe, sihost.exe, fontdrvhost.exe, audiodg.exe, ctfmon.exe`.
- [x] **Step 2:** Escrever `data/bloatware.json`: `{ "store": [{ "packageFamilyName", "productId", "cor", "motivo", "siteReinstalar"? }], "classicos": [{ "padrao": <regex sobre nome>, "editor"?: <regex>, "cor", "motivo", "siteReinstalar"? }] }`. Verde (bloatware conhecido): Microsoft.BingNews, BingWeather, GetHelp, Getstarted/Tips, Microsoft3DViewer, MicrosoftOfficeHub, MicrosoftSolitaireCollection, MixedReality.Portal, People, SkypeApp, Todos, WindowsFeedbackHub, ZuneMusic/ZuneVideo, YourPhone (amarelo), Clipchamp, Microsoft.549981C3F5F10 (Cortana), Disney, Spotify/TikTok/Instagram/Facebook pré-instalados, Candy Crush/King, McAfee/Norton trials, WildTangent, ExpressVPN trial, Booking.com. Fabricantes brasileiros: Positivo (`Positivo .*`, `PositivoApp`, utilitários), Multilaser (`Multilaser .*`), Samsung (`Samsung Update`, `Samsung Settings` amarelo), Lenovo (`Lenovo Vantage` amarelo, `Lenovo Now`/`Lenovo Welcome` verde), Dell/HP/Acer/Asus utilitários (amarelo), `Avast`/`AVG`/`McAfee`/`Norton` (amarelo com motivo "antivírus: só remova se tiver outro"), `OneDrive` amarelo, `Microsoft Teams` (pessoal) amarelo, `Xbox` apps amarelo. Todo item com `motivo` em pt-BR direto, sem jargão. Créditos ao RetroLimpia no topo do arquivo não cabem em JSON: colocar o crédito em `README.md` (Task 7).
- [x] **Step 3:** `comandos.rs`: `DADOS_PERMITIDOS = &["perfis", "bloatware", "protegidos"]`; teste `traversal_e_desconhecidos_falham` continua; novo teste `bloatware_e_protegidos_ok` lendo `data/` real via `pastas_dev()` e conferindo que os dois arquivos são objetos com as chaves `store`/`classicos` e `programas`/`processos`, que toda `cor` está em `verde|amarelo|vermelho` e que todo `padrao` compila como regex (`regex::RegexBuilder::new(p).case_insensitive(true)`).
- [x] **Step 4:** `cargo test --manifest-path src-tauri/Cargo.toml comandos` → PASS. `cargo clippy -- -D warnings` limpo.
- [x] **Step 5:** Commit `feat(dados): listas de bloatware e protegidos com fabricantes brasileiros`.

### Task 2: `scripts/quarentena.ps1`

**Files:** `scripts/quarentena.ps1`, `scripts/tests/quarentena.Tests.ps1`.

- [x] **Step 1: Escrever os testes** (Pester 5, modo teste, mesmo estilo de `limpeza.Tests.ps1`: `Invoke-Q` que captura `@@RESULT`). Casos: mover arquivo e pasta cria `manifesto.json` com 2 itens e a origem desaparece; `listar` devolve a entrada com `itens:2`, `tamanhoBytes` > 0 e `venceEm` = data + dias; `restaurar` devolve tudo à origem e remove a entrada; **Review Focus 1:** criar arquivo na origem antes de restaurar → `conflitos` com 1 item, entrada continua na pasta, outros itens da mesma entrada **também** continuam (atomicidade por entrada); `Add-ItemQuarentena` com caminho protegido (`$env:windir\System32\x`) lança e nada é movido; junction como item é recusada (`New-Juncao` do helper da limpeza — copiar para `_helpers.ps1`); **Review Focus 2:** chave `HKCU\Software\NexTuneTeste\Teste Ação (1)` com valor `Nome Çã` exportada, removida, restaurada com o valor igual; `purgar` sem `confirmado` recusa; `purgar` com `confirmado:true` apaga; `purgarVencidos {dias:7}` remove só entrada com data forjada há 8 dias no manifesto e mantém a de hoje; `Complete-EntradaQuarentena` sem itens apaga a pasta e devolve `$null`; manifesto corrompido aparece em `listar` com `descricao:'(manifesto ilegível)'` e `itens:0` e pode ser purgado.
- [x] **Step 2:** Implementar `quarentena.ps1` conforme o contrato. `Export-ChaveRegistro` usa `& reg.exe export $chave $arquivo /y` (lista de argumentos, nunca string única) e confere `$LASTEXITCODE`; `Restore-ChaveRegistro` usa `reg.exe import`. Em modo teste, chaves fora de `HKCU\Software\NexTuneTeste` são recusadas. Tamanho da entrada via `Get-PathSize`. Datas em ISO 8601 (`ToString('o')`). Toda escrita registra em `Write-AppLog`.
- [x] **Step 3:** Acrescentar `quarentena` à `$Allowlist` em `host.ps1`.
- [x] **Step 4:** Revisão por agente (lint mental PSScriptAnalyzer: `ShouldProcess` suprimido como nos outros scripts, sem `Write-Host`, nomes aprovados `Verbo-Substantivo`).
- [x] **Step 5:** Commit `feat(scripts): quarentena com manifesto, restauração atômica por entrada e purga por prazo`.

### Task 3: `scripts/sistema.ps1`

**Files:** `scripts/sistema.ps1`, `scripts/tests/sistema.Tests.ps1`, `scripts/host.ps1`.

- [x] **Step 1: Escrever os testes.** `protecaoEstado` em teste lê `HKCU\Software\NexTuneTeste\SystemRestore\RPSessionInterval` (1 = ativa) e `SystemRestorePointCreationFrequency`; `criarPonto` em teste grava marcador `%TEMP%\NexTuneTeste\sistema\ponto-<n>.txt` e devolve `criado:true`; **Review Focus 3:** com `simular.falharCriar=true`, `criado:false`, mensagem não vazia, e `SystemRestorePointCreationFrequency` volta ao valor anterior (testar com valor 1440 pré-existente **e** com a chave ausente, que deve continuar ausente); `ligarProtecao` em teste grava `RPSessionInterval=1` e marcador `protecao-ligada.txt`; `sessao` com `simular.usuarioConsole` igual (caixa diferente) → `mesmo:true`; diferente → `mesmo:false`; `$null` → `desconhecido:true, mesmo:true`; `simular` fora do modo teste é ignorado (o Rust já recusa, mas o script também); ação desconhecida → `ok:false`.
- [x] **Step 2:** Implementar. Fora do teste: `Get-ComputerRestorePoint` (último `CreationTime` convertido de WMI), `Checkpoint-Computer -Description "NexTune $(Get-Date -Format 'dd/MM HH:mm')" -RestorePointType MODIFY_SETTINGS`, `Enable-ComputerRestore -Drive "$env:SystemDrive\"`, `& vssadmin.exe resize shadowstorage "/for=$env:SystemDrive" "/on=$env:SystemDrive" '/maxsize=3%'`. Usuário do console: `(Get-CimInstance Win32_ComputerSystem).UserName`; do processo: `[Security.Principal.WindowsIdentity]::GetCurrent().Name`.
- [x] **Step 3:** `host.ps1` allowlist += `sistema`.
- [x] **Step 4:** Revisão por agente.
- [x] **Step 5:** Commit `feat(scripts): ponto de restauração, Proteção do Sistema e verificação de sessão`.

### Task 4: `scripts/programas.ps1`

**Files:** `scripts/programas.ps1`, `scripts/tests/programas.Tests.ps1`, `scripts/tests/fixtures/desinstalador.cmd`, `scripts/host.ps1`.

- [x] **Step 1: Escrever os testes.** Modo teste lê o Uninstall falso em `HKCU\Software\NexTuneTeste\Uninstall\<hive>\<chave>` e **não** chama `Get-AppxPackage` (lista Store vem de `simular.store` ou vazia). Semear 6 programas: `Positivo Utilities` (verde por bloatware.json), `Lenovo Vantage` (amarelo), `Microsoft Edge WebView2 Runtime` (vermelho/protegido), `Programa Qualquer` (sem cor), `Security Update for KB5000` (ignorado), `Oculto` com `SystemComponent=1` (ignorado). `listar` devolve 4, cores e `protegido` certos, ids `cl:hkcu:<chave>`. **Review Focus 4:** função pura `Split-UninstallString` com `"C:\Program Files\X\unins000.exe" /PARAM` → exe + `/PARAM`; `C:\X\u.exe` sem aspas; `MsiExec.exe /I{GUID}` → `msi` com guid; `Get-TipoInstalador` reconhece `unins000.exe`→inno, `uninst.exe`/`Uninstall.exe` com `/S` conhecido ou marca NSIS no arquivo→nsis, `setup.exe -runfromtemp`/`InstallShield`→installshield, `QuietUninstallString` presente→quiet, Store→loja. `Get-ArgumentosSilenciosos` não duplica `/VERYSILENT` quando já presente. **Review Focus 5:** `desinstalar` de id protegido → `ok:false` com `protegido` na mensagem mesmo com `confirmado` e `avancado`. `desinstalar` sem `confirmado` recusa. `desinstalar` do programa falso cujo UninstallString aponta para `fixtures/desinstalador.cmd` copiado para `%TEMP%\NexTuneTeste\prog\` → marcador contém os argumentos silenciosos, `modo:'silencioso'`, `codigo:0`, chave do Uninstall removida pelo próprio `.cmd` (o fixture apaga a chave que recebe como argumento) e `restos` traz a pasta `local` (sem `.exe`) como candidato. UninstallString apontando para fora de `%TEMP%\NexTuneTeste` em modo teste → recusado. **Review Focus 7:** `restos` nunca devolve caminho protegido; `limparRestos` com `C:\Windows\Temp\x` → `falhas` com motivo "protegido" e nada movido. `limparRestos` de 1 pasta + 1 atalho quebrado → `quarentenaId` não nulo, `movidos:2`, entrada na quarentena com `modulo:'programas'`. Pasta com `.dll` dentro não é candidata. Chave `HKCU\Software\NexTuneTeste\Editor\Programa` órfã vira candidato `chave` e `limparRestos` a leva para a quarentena como `.reg`.
- [x] **Step 2:** Implementar `programas.ps1` (dot-source `common.ps1` e `quarentena.ps1`). Carregar `data/bloatware.json` e `data/protegidos.json` da pasta `data` ao lado de `scripts` (em teste, o mesmo repositório). Classificação: primeiro `protegidos.json` (→ `vermelho`, `protegido:true`) e `Test-ProtectedPath` do `InstallLocation`; depois `bloatware.json`. Serviços: `Get-CimInstance Win32_Service` uma vez, casando `PathName` com `InstallLocation`. RAM: `Get-Process` uma vez, somando `WorkingSet64` dos processos cujo `Path` começa com `InstallLocation` (teto: 0 quando sem `Path`). Progresso: 0–40 clássicos, 40–70 Store, 70–100 enriquecimento. Desinstalar: `Start-Process -FilePath $exe -ArgumentList $args -Wait -PassThru` com `WaitForExit(600000)`; estourou → `Kill()` da árvore e `codigo:null`. Nunca interpola a UninstallString numa string de comando.
- [x] **Step 3:** `fixtures/desinstalador.cmd`: grava `%~dp0marcador.txt` com `%*`, apaga a chave recebida em `%1` via `reg delete ... /f` **somente** se ela começar com `HKCU\Software\NexTuneTeste`, sai com `%2` (código) ou 0.
- [x] **Step 4:** `host.ps1` allowlist += `programas`.
- [x] **Step 5:** Revisão por agente.
- [x] **Step 6:** Commit `feat(scripts): programas com classificação por listas, desinstalação silenciosa e restos para a quarentena`.

### Task 5: Rust — allowlist, sessão e ponto de sessão

**Files:** `src-tauri/src/acoes.rs`, `src-tauri/src/comandos.rs`, `src-tauri/src/lib.rs`.

- [x] **Step 1: Escrever os testes** em `acoes.rs`: `quarentena/listar {}`; `restaurar {ids:[...]}` exige lista não vazia de strings no formato `^\d{8}-\d{6}-[0-9a-f]{4}$`, sem repetição, até 200; `purgar` idem + `confirmado:true`; `purgarVencidos {dias}` inteiro 1..=90; `sistema/protecaoEstado {}`, `criarPonto {descricao?}` (string ≤ 80, sem controle), `ligarProtecao {}`, `sessao {}`; `simular` só em teste; `programas/listar {}`; `desinstalar {id, confirmado:true, avancado?, desprovisionar?}` com id `^(cl:(hklm64|hklm32|hkcu):.{1,255}|st:.{1,255})$` sem `\r\n\0`, `desprovisionar:true` exige `avancado:true`; `restos {id, nome, editor?, local?}` strings ≤ 260; `limparRestos {itens:[{tipo, caminho}], confirmado:true}` com `tipo` em `pasta|arquivo|atalho|chave`, 1..=500 itens, caminho de arquivo/pasta/atalho absoluto (`^[A-Za-z]:\\`) e **não** `caminho_protegido` (**Review Focus 7**), chave começando por `HKCU\` ou `HKLM\` e nunca sob `HKLM\SOFTWARE\Microsoft\Windows` nem `HKLM\SYSTEM`; `e_escrita` para a tabela do contrato; `modulos_permitidos().len() == 6`.
- [x] **Step 2:** Implementar em `acoes.rs`.
- [x] **Step 3:** `comandos.rs`: `Estado` += `ponto_sessao: AtomicBool`, `sessao: Mutex<Option<bool>>`. Em `executar`: se `acoes::e_escrita` → `verificar_sessao(&estado, &host).await?` (roda `sistema/sessao` uma vez por processo; `mesmo:false` → `Err("sessao_diferente")`; erro ao rodar → não bloqueia, mas também não guarda). Após `sistema/criarPonto` com `dados.criado == true` → `ponto_sessao.store(true)`. Após `sistema/sessao` executado pela UI, guardar também. Comando `ponto_sessao() -> bool`. `Info.sessao_ok: Option<bool>`. Em demo, `info.sessaoOk = Some(true)`. Testes unitários: função pura `sessao_permite(resultado: &Value) -> Option<bool>` (lê `dados.mesmo`), e `e_escrita` integrado (`"limpeza","limpar"` true; `"limpeza","analisar"` false).
- [x] **Step 4:** `lib.rs` registra `comandos::ponto_sessao`. `cargo test` e `cargo clippy -- -D warnings` → PASS.
- [x] **Step 5:** Commit `feat(rust): allowlist de programas, quarentena e sistema; bloqueio por sessão e ponto da sessão`.

### Task 6: Interface — Programas, Quarentena, ponto de restauração e sessão

**Files:** `ui/index.html`, `ui/styles.css`, `ui/js/estado.js`, `ui/js/api.js`, `ui/js/ponto.js`, `ui/js/vistas/programas.js`, `ui/js/vistas/quarentena.js`, `ui/js/vistas/limpeza.js`, `ui/js/arranque.js`, `ui/js/demo.js`, `ui/i18n/pt-BR.js`.

- [x] **Step 1: Verificação automática possível:** as duas checagens de `ci-local.ps1` (innerHTML sem `esc()`, texto sem `data-i18n`) reproduzidas com `grep`/`node` aqui no Linux; e um script `node` descartável que carrega `pt-BR.js` e confere que toda chave `t('...')` literal usada em `ui/js/**/*.js` existe (chaves montadas dinamicamente como `'cat.' + id` ficam fora).
- [x] **Step 2:** Implementar conforme a seção **UI** dos contratos. Botões de escrita levam a classe `acao escrita`; `aplicarOcupado()` desabilita `.escrita` quando `S.sessaoOk === false`. `arranque()`: depois de `carregarBase()`, roda `sistema/sessao` (guarda `S.sessaoOk`), `quarentena/listar` (contador) e `quarentena/purgarVencidos {dias: S.ajustes.diasQuarentena}` quando houver vencidas; erros viram toast, nunca travam o arranque. Programas carrega na primeira visita e tem botão "Atualizar lista". Textos: tom direto, consequência e como desfazer em toda confirmação.
- [x] **Step 3:** Demo: percorrer no navegador (`ui/index.html?vista=programas` e `?vista=quarentena`) com Playwright headless; capturar duas telas em `/tmp` para a revisão; conferir no console que não há erro.
- [x] **Step 4:** Revisão por agente (acessibilidade básica: `aria-live` no contador, foco no modal, `label for`).
- [x] **Step 5:** Commit `feat(ui): programas, quarentena, ponto de restauração compartilhado e bloqueio por sessão`.

### Task 7: Fechamento

- [x] **Step 1:** `README.md`: seção "Pendências" atualizada; crédito ao RetroLimpia (MIT) pelas listas e pela lógica de desinstalação; nota de que Pester/PSScriptAnalyzer rodam no Actions e em `tools/ci-local.ps1`.
- [x] **Step 2:** Marcar as caixas deste plano. Rodar `cargo clippy -D warnings`, `cargo test`, e as checagens de UI do Step 1 da Task 6.
- [x] **Step 3:** Revisão final por agente do diff completo do plano (foco: Review Focus 1–7, anti-objetivos, textos em pt-BR fora do i18n).
- [x] **Step 4:** Commit `docs: fechar o Plano 2 e atualizar pendências` e `git push -u origin ccr-9c9329b8-ajpqfw`.

---

## Auto-revisão (feita ao escrever)

- **Cobertura da spec:** §8.3 inteiro (Tasks 1, 4, 6), §9.1 ponto + Proteção desligada + conta padrão (Tasks 3, 5, 6), §9.2 quarentena e `.reg` (Task 2), §9.4 lista compartilhada (Task 1), §9.5 log de toda escrita (`Write-AppLog` em Tasks 2–4), §17 linhas "Caminho de volta da desinstalação" e "Conta padrão" (Tasks 4, 6). Fica para os Planos 3–5: `inicio.json`, Ajustes do Windows com backup de registro (reaproveita `Export-ChaveRegistro`), bandeja.
- **Consistência de nomes:** ids `cl:`/`st:` em PS, Rust e demo; `confirmado:true` como booleano estrito em todos os lados (`Test-ParamVerdadeiro`); `e_escrita` espelha a lista de ações de escrita da UI (`.escrita`).
- **Review Focus:** 1, 2 → Task 2; 3 → Task 3; 4, 5, 7 → Task 4; 5, 6, 7 → Task 5. Todos com teste nomeado.
- **Risco assumido:** os scripts PowerShell não rodam no contêiner Linux; a verificação Pester acontece no Actions. Por isso cada script tem revisão independente antes do commit e o plano pede testes que falham alto.
