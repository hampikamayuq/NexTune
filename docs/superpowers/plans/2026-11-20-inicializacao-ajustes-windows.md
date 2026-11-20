# NexTune — Plano 3: Inicialização e Ajustes do Windows

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Entregar o módulo Inicialização (o que abre com o Windows, pelo mesmo mecanismo `StartupApproved` do Gerenciador de Tarefas, com recomendação por lista de dados e tarefas agendadas de fabricante no modo avançado) e o módulo Ajustes do Windows (anúncios, privacidade, Copilot/Widgets, Explorador, efeitos visuais), com o valor original de cada chave salvo em `Backups\ajustes-registro.json` antes da escrita e restauração exata.

**Architecture:** Mesma ponte dos Planos 1 e 2 (UI → comandos Tauri → `host.ps1` → `scripts/<modulo>.ps1`). Dois módulos PowerShell novos (`inicializacao.ps1`, `ajusteswin.ps1`), duas listas de dados (`inicio.json`, `ajustes.json`), a allowlist e a validação estendidas em `acoes.rs`, `DADOS_PERMITIDOS` estendido em `comandos.rs`, duas vistas novas na interface e um cartão novo na tela Início. Helpers que já existem em `programas.ps1`/`quarentena.ps1` (`Read-ArquivoJson`, `Get-AlvoAtalho`, `New-RegexLista`, `ConvertTo-CaminhoRegistro`) sobem para `common.ps1` porque os módulos novos também os usam.

**Tech Stack:** o mesmo dos Planos 1 e 2. Nada novo além de `Get-ScheduledTask`/`Enable-ScheduledTask`/`Disable-ScheduledTask` (módulo `ScheduledTasks`, nativo do Windows) e leitura de `VersionInfo` de executáveis.

**Spec:** `docs/superpowers/specs/2026-11-20-otimizador-design.md` §3 (anti-objetivos), §7 (regras para pouca RAM), §8.4, §8.5, §9.4, §9.5.

**Plano anterior:** `2026-11-20-programas-quarentena.md` (concluído). **Planos seguintes:** 4 Disco + Atualizações; 5 Modo Jogo + bandeja + lembretes + atualizador; 6 site, README e primeira release.

## Global Constraints

Valem todas as dos Planos 1 e 2 (PowerShell 5.1, BOM nos `.ps1`, sem `Invoke-Expression`, argumentos em lista, `Test-ProtectedPath` no Rust **e** no PowerShell, textos só em `ui/i18n/pt-BR.js`, `esc()`/nós DOM, commits pequenos em português). Mais estas:

- **Ambiente de construção:** esta máquina é Windows, mas sem Rust e só com Pester 3.4. `cargo test`/`cargo clippy`, Pester 5 e PSScriptAnalyzer rodam no GitHub Actions. Localmente: cada `.ps1` novo é carregado com `powershell -NoProfile -ExecutionPolicy Bypass -Command ". .\scripts\common.ps1; . .\scripts\<modulo>.ps1"` (erro de sintaxe falha alto) e as funções puras são exercitadas à mão; a interface é verificada em modo demo no navegador e com as checagens de `tools/ci-local.ps1` reproduzidas em `grep`. O Rust é revisado por leitura e confirmado no Actions após o push.
- **Regra de ouro dos Ajustes (spec §8.5):** só chaves que a própria tela de Configurações grava. Chave sob `HKLM\SOFTWARE\Policies\` ou `HKCU\Software\Policies\` só com `politica:true` **e** `avancado:true` em `data/ajustes.json`; a interface mostra o selo "trava a opção em Configurações".
- **Backup antes da escrita, sempre.** `aplicar` grava o valor original de cada `chave\nome` em `Backups\ajustes-registro.json` **antes** do primeiro `Set-ItemProperty` daquele ajuste e nunca sobrescreve um backup que já existe (reaplicar não apaga o original). `restaurar` devolve exatamente o valor anterior (mesmo tipo) ou remove o nome quando ele não existia (e a chave, se ela também não existia e ficou vazia), e só então apaga o backup.
- **Anti-objetivos continuam valendo:** nenhum ajuste toca Defender, Windows Update, pagefile, Edge/WebView2, nem "limpa o registro". Nenhum item de inicialização cujo executável esteja em `protegidos.json` (`processos`) ou case com `protegidos.json` (`programas`) pode ser desligado, nem no modo avançado. Tarefas agendadas sob `\Microsoft\` nunca aparecem.
- **Ids nunca viram caminho.** `inicializacao/alternar` e `ajusteswin/aplicar|restaurar` resolvem o id contra a lista que o próprio script gera (`Get-ItemInicioPorId`, `Get-AjustePorId`); o Rust só confere forma e tamanho.
- **Nenhum ajuste exige logoff para ser revertido.** Alguns só aparecem depois de reiniciar o Explorador ou sair e entrar no Windows: `data/ajustes.json` marca `reiniciarExplorer:true` e o resultado devolve `precisaReiniciar:true`; o programa **não** mata o `explorer.exe`, só avisa.

## Review Focus

Entradas que a spec implica e que um teste fixa (cada uma com teste nomeado na tarefa dona):

1. **Item de inicialização sem entrada em `StartupApproved`** (programa recém-instalado): é `ativo:true`, e desligar cria a entrada com `03` + FILETIME; religar grava `02` + zeros, nunca apaga a entrada. → Tarefa 3.
2. **Item protegido** (`SecurityHealth`, driver de áudio, `explorer.exe`) nunca é desligado, mesmo com `confirmado:true` e `avancado:true`; e tarefa agendada só é alternada com `avancado:true`. → Tarefas 2 e 3.
3. **Reaplicar um ajuste já aplicado não sobrescreve o backup**: o original gravado na primeira vez é o que `restaurar` devolve. → Tarefa 4.
4. **Valor que não existia antes** (chave inteira ausente): após `aplicar` + `restaurar`, nem o nome nem a chave existem; valor `String` original volta como `String`, `DWord` como `DWord`. → Tarefa 4.
5. **Ajuste `politica:true` fora do modo avançado**: `listar` não o devolve e `aplicar` o recusa; `soWin11:true` em build < 22000 vem `disponivel:false` com motivo. → Tarefas 1 e 4.
6. **Backup corrompido ou ausente ao restaurar**: `restaurar` devolve a falha daquele id com mensagem e nada é escrito no registro; os outros ids da mesma chamada seguem. → Tarefa 4.
7. **Nome de valor do Run com acento, espaço e parênteses** (`Meu App (x64) ção`) aparece em `listar`, e `alternar` grava a entrada `StartupApproved` com o mesmo nome exato. → Tarefa 3.

---

## Estrutura de arquivos (novos e alterados)

```
data/
  inicio.json                 recomendações de inicialização: itens (Run/pasta) e tarefas agendadas por regex; cor + motivo
  ajustes.json                catálogo dos Ajustes do Windows: id, grupo, chaves/valores, politica, avancado, recomendadoPara, soWin11, reiniciarExplorer
scripts/
  common.ps1                  += Get-PastaDeDados, Read-ArquivoJson, New-RegexLista, Get-AlvoAtalho (de programas.ps1), ConvertTo-CaminhoRegistro + tabela de raízes (de quarentena.ps1)
  programas.ps1, quarentena.ps1   usam os de common.ps1 (removem as cópias locais)
  inicializacao.ps1           ações listar, alternar
  ajusteswin.ps1              ações listar, aplicar, restaurar
  host.ps1                    allowlist += inicializacao, ajusteswin
  tests/inicializacao.Tests.ps1
  tests/ajusteswin.Tests.ps1
src-tauri/src/
  acoes.rs                    MODULOS += inicializacao, ajusteswin; ESCRITA += alternar, aplicar, restaurar; validação das ações novas
  comandos.rs                 DADOS_PERMITIDOS += inicio, ajustes; teste de forma dos dois arquivos e dos textos i18n
ui/
  index.html                  nav += inicializacao, ajustes (entre Programas e Quarentena); scripts das vistas novas
  js/estado.js                S += inicio, ajustesWin
  js/arranque.js              carregarBase() também lê inicializacao/listar (para o cartão do Início)
  js/vistas/inicio.js         cartão "N programas abrindo com o Windows [Ver]"
  js/vistas/inicializacao.js
  js/vistas/ajustes.js
  js/demo.js                  dados de inicialização e ajustes
  i18n/pt-BR.js               chaves nav.inicializacao, nav.ajustes, inicializacao.*, ajustes.*, ajuste.<id>.nome/.desc, inicio.inicializacao*
  styles.css                  .toggle (botão Ligado/Desligado), .grupo-ajustes
README.md                     "O que já existe" e pendências
```

---

## Contratos (JSON, camelCase; o PowerShell devolve exatamente estes nomes)

### inicializacao
- `listar { avancado? }` → `{ itens: [{ id, nome, comando, exe (string|null), editor (string|null), origem: 'run'|'pasta'|'tarefa', escopo: 'usuario'|'todos', ativo, cor: 'verde'|'amarelo'|'vermelho'|null, motivoCor (string|null), protegido, motivoProtegido (string|null), tamanhoBytes (-1 desconhecido), ramBytes, rodando, avancado }] }`. Ordenados: ativos primeiro, depois por nome.
  - Ids: `run:hkcu:<nomeDoValor>`, `run:hklm:<nomeDoValor>`, `run:hklm32:<nomeDoValor>`, `pasta:usuario:<arquivo.lnk>`, `pasta:todos:<arquivo.lnk>`, `tarefa:<TaskPath><TaskName>` (ex.: `tarefa:\Positivo\Updater`). Nomes vão inteiros, sem escape (o Rust aceita qualquer texto sem controle até 255).
  - Fontes e `StartupApproved` correspondente (sempre `...\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\`): `HKCU\...\Run` ↔ `HKCU\...\StartupApproved\Run`; `HKLM\...\Run` ↔ `HKLM\...\StartupApproved\Run`; `HKLM\SOFTWARE\WOW6432Node\...\Run` ↔ `HKLM\...\StartupApproved\Run32`; pasta `shell:startup` ↔ `HKCU\...\StartupApproved\StartupFolder`; pasta `shell:common startup` ↔ `HKLM\...\StartupApproved\StartupFolder`. Valor binário: byte 0 em `0x02`/`0x06` = ativo, `0x03`/`0x07` = desligado; **ausente = ativo**.
  - `exe`: primeiro token do comando (aspas respeitadas, `%var%` expandido) para `run`; `Get-AlvoAtalho` para `pasta`; `Actions[0].Execute` para `tarefa`. `editor` = `VersionInfo.CompanyName` do exe (null se não der). `tamanhoBytes` = tamanho do exe. `rodando`/`ramBytes` = `Get-Process` cujo `Path` é o exe (soma `WorkingSet64`).
  - Classificação: `protegidos.json` primeiro (`processos` casa com o nome do exe; `programas` casa com nome|editor|comando) → `cor:'vermelho'`, `protegido:true`; depois `inicio.json`: `itens[]` para run/pasta, `tarefas[]` para tarefas (regex sobre nome|comando|editor). Fora das listas → `cor:null`.
  - Tarefas só com `avancado:true`: `Get-ScheduledTask` cujo `TaskPath` não começa por `\Microsoft\`, com gatilho `MSFT_TaskLogonTrigger` ou `MSFT_TaskBootTrigger`; `ativo` = `State -ne 'Disabled'`; `avancado:true` no item.
  - Modo teste: Run em `HKCU\Software\NexTuneTeste\Inicio\Run\<hkcu|hklm|hklm32>`, `StartupApproved` em `HKCU\Software\NexTuneTeste\Inicio\StartupApproved\<hkcu|hklm>\<Run|Run32|StartupFolder>` (hive + subchave replicam o real), pastas de inicialização em `%TEMP%\NexTuneTeste\inicio\usuario` e `...\todos`, tarefas só de `simular.tarefas: [{ caminho, nome, exe, ativo }]` (nunca `Get-ScheduledTask`), `alternar` de tarefa em teste grava marcador `%TEMP%\NexTuneTeste\inicio\tarefa-<nome>.txt` com `ativar`.
- `alternar { id, ativar (bool), confirmado: true, avancado? }` → `{ id, ativo }`. Recusa `protegido`, id fora da lista, e `tarefa:` sem `avancado:true`. Run/pasta: grava 12 bytes em `StartupApproved` (`02 00 00 00` + 8 zeros para ligar; `03 00 00 00` + FILETIME UTC atual little-endian para desligar). Tarefa: `Enable-ScheduledTask`/`Disable-ScheduledTask -TaskPath -TaskName`. Toda escrita vai para `Write-AppLog`.

### ajusteswin
- `listar { avancado? }` → `{ ajustes: [{ id, grupo: 'anuncios'|'privacidade'|'copilot'|'explorador'|'desempenho', politica, avancado, recomendado, disponivel, motivoIndisponivel, aplicado, temBackup, reiniciarExplorer }] }`. Sem `avancado:true`, itens `avancado:true` não aparecem. `aplicado` = todo `chave\nome` do item já tem o valor `aplicar`. `recomendado` = `recomendadoPara:'todos'`, ou `'fraco'` e perfil (`Get-Perfil`) com `classe=basico` ou `disco=hdd` (perfil ausente conta como fraco). `soWin11:true` com build < 22000 → `disponivel:false`, `motivoIndisponivel:'Só existe no Windows 11.'`.
- `aplicar { ids, confirmado: true, avancado? }` → `{ aplicados: [id], falhas: [{ id, erro }], precisaReiniciar }`. Por id: recusa desconhecido, indisponível, ou `avancado:true` sem `avancado:true` nos params; grava backup (se ainda não há) e só então escreve cada `chave\nome` com o tipo da lista (`DWord`|`String`), criando a chave se faltar.
- `restaurar { ids, confirmado: true }` → `{ restaurados: [id], falhas: [{ id, erro }], precisaReiniciar }`. Por id sem backup → falha "sem backup para este ajuste". Backup ilegível → falha, nada escrito.
- Backup em `(Get-AppPastas).Backups\ajustes-registro.json`: `{ "<id>": { "data": ISO, "valores": [{ "chave", "nome", "chaveExistia", "existia", "tipo": 'DWord'|'String'|'QWord'|'Binary'|'MultiString'|'ExpandString'|null, "valor" }] } }` (Binary como lista de inteiros). Escrita atômica: `.tmp` + `Move-Item -Force`.
- Modo teste: toda chave passa por `Get-ChaveEfetiva $chave $Teste`: `HKCU\X` → `HKCU\Software\NexTuneTeste\Ajustes\HKCU\X`, `HKLM\X` → `HKCU\Software\NexTuneTeste\Ajustes\HKLM\X`; backups em `%TEMP%\NexTuneTeste\Backups`. `simular { build? }` (inteiro) substitui o build do Windows em teste.
- `data/ajustes.json`: `{ "ajustes": [{ "id": ^[a-z0-9_]{1,40}$, "grupo", "politica": bool, "avancado": bool, "recomendadoPara": "todos"|"fraco"|"nenhum", "soWin11": bool, "reiniciarExplorer": bool, "chaves": [{ "chave": "HKCU\\..."|"HKLM\\...", "nome", "tipo": "DWord"|"String", "aplicar": <int|string> }] }] }`. Textos em `pt-BR.js`: `ajuste.<id>.nome` e `ajuste.<id>.desc` (a desc diz o que muda e o que se perde). Conteúdo inicial (chaves que a tela de Configurações grava, salvo onde indicado; `...` = `HKCU\Software\Microsoft\Windows\CurrentVersion`):
  - `anuncios`: `sugestoes_inicio` (`...\ContentDeliveryManager`: `SubscribedContent-338388Enabled`=0, `SystemPaneSuggestionsEnabled`=0), `dicas_windows` (`SubscribedContent-338389Enabled`=0, `SoftLandingEnabled`=0), `sugestoes_configuracoes` (`SubscribedContent-338393Enabled`=0, `SubscribedContent-353694Enabled`=0, `SubscribedContent-353696Enabled`=0), `apps_sugeridos` (`SilentInstalledAppsEnabled`=0, `PreInstalledAppsEnabled`=0, `OemPreInstalledAppsEnabled`=0, `SubscribedContent-310093Enabled`=0), `avisos_onedrive_explorador` (`...\Explorer\Advanced` `ShowSyncProviderNotifications`=0). Todos `recomendadoPara:'todos'`.
  - `privacidade`: `id_publicidade` (`...\AdvertisingInfo` `Enabled`=0), `experiencias_personalizadas` (`...\Privacy` `TailoredExperiencesWithDiagnosticDataEnabled`=0), `telemetria_minima` (`HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection` `AllowTelemetry`=1: é a chave que a tela de Configurações grava, não a de Política), `digitacao_personalizada` (`HKCU\Software\Microsoft\InputPersonalization` `RestrictImplicitInkCollection`=1, `RestrictImplicitTextCollection`=1; `HKCU\Software\Microsoft\Personalization\Settings` `AcceptedPrivacyPolicy`=0), `historico_atividades` (**política**, avançado: `HKLM\SOFTWARE\Policies\Microsoft\Windows\System` `PublishUserActivities`=0, `UploadUserActivities`=0). Os quatro primeiros `recomendadoPara:'todos'`; o último `'nenhum'`.
  - `copilot`: `widgets_barra` (`...\Explorer\Advanced` `TaskbarDa`=0, soWin11), `copilot_barra` (`ShowCopilotButton`=0, soWin11), `chat_teams_barra` (`TaskbarMn`=0, soWin11), `destaques_pesquisa` (`...\SearchSettings` `IsDynamicSearchBoxEnabled`=0), `noticias_barra_win10` (`...\Feeds` `ShellFeedsTaskbarViewMode`=2), `copilot_desligar` (**política**, avançado: `HKCU\Software\Policies\Microsoft\Windows\WindowsCopilot` `TurnOffWindowsCopilot`=1, soWin11). `widgets_barra`, `copilot_barra`, `chat_teams_barra`, `destaques_pesquisa` `recomendadoPara:'fraco'`; os demais `'nenhum'`.
  - `explorador`: `extensoes_visiveis` (`...\Explorer\Advanced` `HideFileExt`=0, reiniciarExplorer), `abrir_este_computador` (`LaunchTo`=1, reiniciarExplorer), `recentes_inicio_rapido` (`...\Explorer` `ShowRecent`=0, `ShowFrequent`=0, reiniciarExplorer). Todos `recomendadoPara:'nenhum'`.
  - `desempenho`: `efeitos_visuais` (`HKCU\Control Panel\Desktop\WindowMetrics` `MinAnimate`='0' String; `HKCU\Control Panel\Desktop` `DragFullWindows`='0' String, `MenuShowDelay`='0' String; `...\Explorer\Advanced` `TaskbarAnimations`=0, `ListviewAlphaSelect`=0, `ListviewShadow`=0; `HKCU\Software\Microsoft\Windows\DWM` `EnableAeroPeek`=0, `AlwaysHibernateThumbnails`=0; reiniciarExplorer), `transparencia` (`...\Themes\Personalize` `EnableTransparency`=0). Ambos `recomendadoPara:'fraco'`.

### Rust
- `acoes::MODULOS` += `inicializacao`, `ajusteswin` (8 no total). `ESCRITA` += `inicializacao/alternar`, `ajusteswin/aplicar`, `ajusteswin/restaurar`.
- `inicializacao/listar {avancado?, simular?}`; `inicializacao/alternar {id, ativar, confirmado:true, avancado?, simular?}`: `ativar` booleano obrigatório; id `^(run:(hkcu|hklm|hklm32):.{1,255}|pasta:(usuario|todos):.{1,255}|tarefa:\\.{1,255})$` sem controle; `tarefa:` exige `avancado:true` (o Rust também recusa, como o script).
- `ajusteswin/listar {avancado?, simular?}`; `ajusteswin/aplicar {ids, confirmado:true, avancado?}`; `ajusteswin/restaurar {ids, confirmado:true}`: `ids` lista 1..=50 de `^[a-z0-9_]{1,40}$` sem repetição.
- `comandos::DADOS_PERMITIDOS` = `perfis, bloatware, protegidos, inicio, ajustes`.

### UI
- **Inicialização** (`VISTAS.inicializacao`): carrega na primeira visita (e no arranque, para o Início), botão "Atualizar". Cabeçalho: "N abrem com o Windows · M recomendados para desligar". Linha por item (`.prog` reaproveitado): ponto de cor, nome, editor, comando em `.pequeno.suave`, selos (`rodando` com RAM, `protegido`, `tarefa agendada`, `todos os usuários`), e à direita um botão `.btn.toggle.acao.escrita` com texto "Ligado"/"Desligado" (`aria-pressed`). Protegido → sem botão, selo com `title` = motivoProtegido. Clique → modal "Vai impedir X de abrir com o Windows. O programa continua instalado; para desfazer, ligue de novo aqui ou no Gerenciador de Tarefas." (ligar: "Vai fazer X abrir com o Windows de novo.") → `garantirPonto()` → `alternar`. Filtro: todos / recomendados / desligados. Tarefas só aparecem com `S.ajustes.modoAvancado` (o script já filtra; a vista passa `avancado:true`).
- **Ajustes** (`VISTAS.ajustes`): cinco grupos em cartões (`.grupo-ajustes`), cada ajuste uma linha: nome, desc, selos (`recomendado`, `trava a opção em Configurações` para `politica`, `pede reiniciar o Explorador`), estado ("aplicado"/"original") e botão "Aplicar" ou "Restaurar" (`.acao.escrita`). Indisponível → linha `.indisp` com motivo. Topo: botão "Aplicar recomendados" (todos `recomendado && disponivel && !aplicado`), modal lista os nomes e diz "Para desfazer: o botão Restaurar devolve exatamente o valor anterior de cada ajuste." Depois de aplicar/restaurar com `precisaReiniciar:true`: toast "Alguns ajustes só aparecem depois de sair e entrar de novo no Windows." Modo avançado desligado esconde `politica`/`avancado` (o script já filtra).
- **Início**: abaixo do cartão da limpeza, se houver itens `verde && ativo` em `S.inicio.itens`: cartão "N programas abrindo com o Windows" + botão "Ver" → `irPara('inicializacao')`.
- **Demo**: 7 itens de inicialização (Positivo Updater verde ativo, Multilaser verde ativo, Spotify amarelo ativo, Discord amarelo desligado, OneDrive amarelo ativo, SecurityHealth vermelho protegido, Realtek áudio vermelho protegido) + 1 tarefa (`\Positivo\PositivoUpdate` verde, só avançado); ajustes com `sugestoes_inicio` já aplicado, `historico_atividades`/`copilot_desligar` só no avançado, demo simula Win11 (tudo disponível). `alternar`/`aplicar`/`restaurar` mudam o estado em memória.

---

### Task 1: Helpers compartilhados e listas de dados

**Files:** `scripts/common.ps1`, `scripts/programas.ps1`, `scripts/quarentena.ps1`, `data/inicio.json`, `data/ajustes.json`, `src-tauri/src/comandos.rs`, `ui/i18n/pt-BR.js`.

**Interfaces:**
- Produces, em `common.ps1`, com as assinaturas de hoje: `Get-PastaDeDados()` → caminho da pasta `data` ao lado de `scripts`; `Read-ArquivoJson -Caminho`; `New-RegexLista -Padrao`; `Get-AlvoAtalho -Caminho`; `Test-ChaveRegistro -Chave`; `ConvertTo-CaminhoRegistro -Chave` (`HKCU\X` → `Registry::HKEY_CURRENT_USER\X`) e `$Script:RaizRegistro`.

- [x] **Step 1:** Mover `Read-ArquivoJson`, `New-RegexLista`, `Get-AlvoAtalho` (com `$Script:WsShell`) de `programas.ps1` e `$Script:RaizRegistro`, `Test-ChaveRegistro`, `ConvertTo-CaminhoRegistro` de `quarentena.ps1` para `common.ps1`; substituir `$Script:PastaDeDados` por `function Get-PastaDeDados { return (Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($PSScriptRoot))) 'data') }` em `common.ps1` e trocar os dois usos em `programas.ps1` por `(Get-PastaDeDados)`. Carregar: `powershell -NoProfile -ExecutionPolicy Bypass -Command "cd <repo>; . .\scripts\common.ps1; . .\scripts\quarentena.ps1; . .\scripts\programas.ps1; Get-PastaDeDados; (Read-ArquivoJson (Join-Path (Get-PastaDeDados) 'perfis.json')).classes.padrao; ConvertTo-CaminhoRegistro 'HKCU\Software\X'"`.
  Expected: o caminho `...\Nextune\data`, `medio` e `Registry::HKEY_CURRENT_USER\Software\X`, sem erro.
- [x] **Step 2:** Escrever `data/inicio.json`: `{ "itens": [{ "padrao", "cor", "motivo" }], "tarefas": [{ "padrao", "cor", "motivo" }] }`. Verde (pode desligar; motivo em pt-BR direto): updaters e "Welcome/Now" de Positivo, Multilaser, Samsung, Lenovo, Dell, HP, Acer, Asus; Spotify, Steam, Epic, Battle.net, Discord, Adobe/Acrobat updaters, iTunes/Apple Push, Java Update, CCleaner, Skype, Teams pessoal, Zoom, Cortana. Amarelo: OneDrive, Google Drive/Backup, Dropbox, antivírus de terceiros (Avast/AVG/McAfee/Norton/Kaspersky: "só desligue se tiver outro"), Logitech/Razer/Corsair/SteelSeries, NVIDIA App/GeForce Experience, AMD Software, Intel Graphics Command Center, utilitários de bateria de fabricante. Vermelho: `SecurityHealth`, Realtek (`RtkAudUService|RAVCpl64|RtkNGUI`), `Synaptics|SynTPEnh`, `ETDCtrl` (ELAN), `igfx`, Bluetooth de fabricante, `WavesSvc|Dolby|Nahimic` (áudio), `ctfmon`. Tarefas: verde `Positivo|Multilaser|Lenovo Now|Dell SupportAssist Update|HP Analytics|Acer Jumpstart|ASUS Update`; amarelo `Google|Adobe|Mozilla|Opera|Brave` updaters.
- [x] **Step 3:** Escrever `data/ajustes.json` conforme o contrato (lista completa acima) e as chaves `ajuste.<id>.nome` / `ajuste.<id>.desc` em `pt-BR.js` para os 20 ids (nome curto; desc em uma frase: o que muda e o que se perde, ex.: `extensoes_visiveis.desc`: "Mostra .pdf, .exe, .docx no fim dos nomes de arquivo; ajuda a reconhecer arquivos disfarçados. Faz efeito depois de sair e entrar no Windows.").
- [x] **Step 4:** `comandos.rs`: `DADOS_PERMITIDOS = &["perfis", "bloatware", "protegidos", "inicio", "ajustes"]`; teste novo `inicio_e_ajustes_ok` lendo `data/` real: `inicio.json` tem `itens` (não vazia) e `tarefas` (lista), todo `padrao` compila sem diferenciar caixa, toda `cor` em `verde|amarelo|vermelho`, `motivo` não vazio; `ajustes.json`: `ajustes` não vazia, `id` casa `^[a-z0-9_]{1,40}$` e é único, `grupo` em `anuncios|privacidade|copilot|explorador|desempenho`, `recomendadoPara` em `todos|fraco|nenhum`, `politica:true` ⇒ `avancado:true`, chave começa por `HKCU\` ou `HKLM\`, chave sob `\Policies\` (exceto `CurrentVersion\Policies\DataCollection`) ⇔ `politica:true` (**Review Focus 5**), `tipo` em `DWord|String` e `aplicar` do tipo certo, nenhuma chave contém `Windows Defender`, `WindowsUpdate` ou `Edge`; e, lendo `ui/i18n/pt-BR.js` (do primeiro `{` ao último `}` como JSON) via `fn textos_pt_br() -> Map<String, Value>` no módulo de testes, `ajuste.<id>.nome` e `ajuste.<id>.desc` existem para todo id.
- [x] **Step 5:** Commit `feat(dados): listas de inicialização e catálogo de ajustes do Windows; helpers de dados e registro em common.ps1`.

### Task 2: Rust — allowlist e validação

**Files:** `src-tauri/src/acoes.rs`.

**Interfaces:**
- Produces: `validar("inicializacao", "listar"|"alternar", ...)`, `validar("ajusteswin", "listar"|"aplicar"|"restaurar", ...)`, `e_escrita` para as três ações de escrita; `modulos_permitidos().len() == 8`.

- [x] **Step 1: Escrever os testes** (estilo de `programas_*`): `inicializacao_listar` (`{}`, `{avancado:true}` ok; `{avancado:"s"}`, `{x:1}` falham; `simular` só em teste); `inicializacao_alternar_valido` (`run:hkcu:Spotify`, `run:hklm32:Nome Com Espaço (x64) ção`, `pasta:usuario:App.lnk`, `tarefa:\Positivo\Updater` com `avancado:true`, cada um com `ativar:true|false, confirmado:true` → saída igual à entrada); `inicializacao_alternar_recusa` (sem `confirmado`; `confirmado:"true"`; sem `ativar`; `ativar:1`; ids `run:hklm:` vazio, `run:hkey:X`, `pasta:outro:X`, `tarefa:Sem\Barra`, `tarefa:\X` sem `avancado` — **Review Focus 2**, `run:hkcu:a\nb`, 256 chars após o prefixo); `ajusteswin_listar`; `ajusteswin_aplicar_e_restaurar` (`{ids:["id_publicidade","efeitos_visuais"],confirmado:true}` ok; `restaurar` não aceita `avancado`; `ids` vazio, repetido, `Maiusculo`, `com-hifen`, 41 chars, 51 ids falham); `tabela_e_escrita` += as três de escrita e `inicializacao/listar`, `ajusteswin/listar` como leitura; `modulos` → 8.
- [x] **Step 2:** Implementar em `acoes.rs`: `re_id_inicio()`, `re_id_ajuste()`, `fn lista_de_ids(m, re: &Regex, max: usize, rotulo: &str) -> Result<Value, ErroValidacao>` (extraída de `ids_quarentena`, que passa a chamá-la), ramos novos em `validar`.
- [x] **Step 3:** Revisão por leitura (clippy mental). Não há `cargo` local; o Actions confirma após o push da Task 6.
- [x] **Step 4:** Commit `feat(rust): allowlist e validação de inicialização e ajustes do Windows`.

### Task 3: `scripts/inicializacao.ps1`

**Files:** `scripts/inicializacao.ps1`, `scripts/tests/inicializacao.Tests.ps1`, `scripts/host.ps1`.

**Interfaces:**
- Consumes: `Get-PastaDeDados`, `Read-ArquivoJson`, `New-RegexLista`, `Get-AlvoAtalho`, `Write-AppLog`, `Test-ParamVerdadeiro`, `Get-Simulacao` (common.ps1).
- Produces: ações `listar`, `alternar`; funções puras `Get-EstadoAprovado($Bytes)` → `$true|$false`, `New-ValorAprovado([bool]$Ativar, [DateTime]$Agora)` → 12 bytes, `Split-ComandoInicio([string])` → `@{ exe; args }`, `Get-ItemInicioPorId`.

- [x] **Step 1: Escrever os testes** (Pester 5, modo teste, `Invoke-Ini` que captura `@@RESULT` como em `sistema.Tests.ps1`). Semear em `HKCU\Software\NexTuneTeste\Inicio\Run\hkcu`: `Spotify` = `"C:\Users\x\AppData\Roaming\Spotify\Spotify.exe" --autostart`, `Meu App (x64) ção` = `C:\Apps\meu.exe /min` (**Review Focus 7**), `SecurityHealth` = `%windir%\system32\SecurityHealthSystray.exe`; em `...\Run\hklm`: `Positivo Updater` = `"C:\Program Files\Positivo\Updater.exe"`; em `...\Run\hklm32`: `Discord` = `C:\x\Update.exe --processStart Discord.exe` com `StartupApproved\hklm\Run32\Discord` = `03 00 00 00` + 8 bytes. Pasta `%TEMP%\NexTuneTeste\inicio\usuario\Bloco.lnk` criada no teste via WScript.Shell apontando para `$env:windir\System32\notepad.exe`. Casos: `listar` devolve 6 itens; `Discord` `ativo:false`; os outros `ativo:true` (**Review Focus 1**: sem entrada = ativo); `Spotify` e `Positivo Updater` `cor:'verde'`, `SecurityHealth` `cor:'vermelho'` e `protegido:true`, `Meu App (x64) ção` `cor:$null` e `nome` exatamente igual; `Bloco.lnk` tem `origem:'pasta'`, `exe` terminando em `notepad.exe`, `editor` não vazio, `tamanhoBytes` > 0; `Split-ComandoInicio` com aspas, sem aspas, com `%windir%` expandido; `Get-EstadoAprovado` para `02`, `06`, `03`, `07`, `$null`, lista de 1 byte; `New-ValorAprovado $false $agora` tem 12 bytes, byte 0 = 3 e bytes 4..11 = `[BitConverter]::GetBytes($agora.ToFileTimeUtc())`; `New-ValorAprovado $true` = `02` + 11 zeros; `alternar Spotify ativar:false` → `ativo:false`, entrada `StartupApproved\hkcu\Run\Spotify` existe com byte 0 = 3 (**Review Focus 1**) e `listar` passa a mostrar `ativo:false`; `alternar Spotify ativar:true` → byte 0 = 2 e a entrada **continua existindo**; `alternar 'run:hkcu:Meu App (x64) ção'` grava a entrada com esse nome exato (**Review Focus 7**); `alternar SecurityHealth` com `confirmado:true, avancado:true` → `ok:false` com `protegido` no erro (**Review Focus 2**); `alternar` sem `confirmado` recusa; id desconhecido recusa; `listar` sem `avancado` não traz tarefas e com `avancado:true` + `simular.tarefas=@(@{caminho='\Positivo\';nome='PositivoUpdate';exe='C:\P\u.exe';ativo=$true})` traz `tarefa:\Positivo\PositivoUpdate` com `cor:'verde'` e `avancado:true`; `alternar` dessa tarefa sem `avancado` recusa e com `avancado:true` grava `tarefa-PositivoUpdate.txt` contendo `False` (**Review Focus 2**); tarefa simulada sob `\Microsoft\` não aparece; ação desconhecida → `ok:false`.
- [x] **Step 2:** Implementar `inicializacao.ps1` conforme o contrato. `Get-Process` e `Get-ScheduledTask` uma vez por `listar`. Progresso em três etapas (Run, pastas, tarefas/enriquecimento). Escrita: `Set-ItemProperty -Type Binary`.
- [x] **Step 3:** `host.ps1` allowlist += `inicializacao`. Carregar: `powershell -NoProfile -ExecutionPolicy Bypass -Command "cd <repo>; . .\scripts\common.ps1; . .\scripts\inicializacao.ps1; (New-ValorAprovado $true (Get-Date)) -join ','; (Split-ComandoInicio '\"C:\a b\x.exe\" /q').exe"`.
  Expected: `2,0,0,0,0,0,0,0,0,0,0,0` e `C:\a b\x.exe`.
- [x] **Step 4:** Revisão por leitura (PSScriptAnalyzer mental: `ShouldProcess` suprimido onde há escrita, sem `Write-Host`, verbos aprovados).
- [x] **Step 5:** Commit `feat(scripts): inicialização pelo StartupApproved com recomendações por lista e tarefas de fabricante no avançado`.

### Task 4: `scripts/ajusteswin.ps1`

**Files:** `scripts/ajusteswin.ps1`, `scripts/tests/ajusteswin.Tests.ps1`, `scripts/host.ps1`.

**Interfaces:**
- Consumes: `Get-PastaDeDados`, `Read-ArquivoJson`, `ConvertTo-CaminhoRegistro`, `Get-Perfil`, `Get-AppPastas`, `Write-AppLog`, `Test-ParamVerdadeiro`, `Get-Simulacao`.
- Produces: ações `listar`, `aplicar`, `restaurar`; funções puras `Get-ChaveEfetiva([string]$Chave, [bool]$Teste)`, `Test-AjusteDisponivel($Ajuste, [int]$Build)` → `@{ disponivel; motivo }`, `Test-RecomendadoAjuste($Ajuste, $Perfil)`.

- [x] **Step 1: Escrever os testes.** Antes de cada teste: apagar `HKCU:\Software\NexTuneTeste\Ajustes` e `%TEMP%\NexTuneTeste\Backups`. Casos: `listar` devolve todos os ids de `data/ajustes.json` que não são `avancado:true` (comparar com o JSON lido no teste), nenhum `aplicado`, nenhum `temBackup`; com `avancado:true` devolve todos; **Review Focus 5**: `historico_atividades` ausente sem avançado e `aplicar` dele sem `avancado` → `falhas` com o id; `simular.build=19045` → `widgets_barra` `disponivel:false` com motivo contendo "Windows 11", e `simular.build=22631` → `disponivel:true`; `recomendado` de `efeitos_visuais` é `true` com perfil `basico/hdd` (`Set-Perfil` em teste) e `false` com `gamer/ssd`, e `id_publicidade` é `true` nos dois; `aplicar ['id_publicidade']` com a chave efetiva ausente → `aplicados` contém o id, `Enabled`=0 gravado como `DWord`, backup com `chaveExistia:false, existia:false`; **Review Focus 4**: `restaurar` em seguida → nem o nome nem a chave existem, backup removido, `temBackup:false`; semear `Enabled`=1 (DWord) antes → `aplicar` → `restaurar` → `Enabled` volta a 1 com `Kind` `DWord`; semear `MinAnimate`='1' (String) → `aplicar ['efeitos_visuais']` → `restaurar` → `'1'` e `Kind` `String`; **Review Focus 3**: semear `Enabled`=1, `aplicar`, mudar à mão para 5, `aplicar` de novo → backup continua `valor:1`, `restaurar` devolve 1; `aplicar` de dois ids em que o segundo é desconhecido → o primeiro em `aplicados`, o segundo em `falhas`; `aplicar ['extensoes_visiveis']` → `precisaReiniciar:true`, `['id_publicidade']` → `false`; **Review Focus 6**: `restaurar ['id_publicidade']` sem backup → `falhas` com "sem backup"; gravar lixo em `ajustes-registro.json` → `restaurar` → `falhas`, valor semeado intacto e `listar` ainda funciona (`temBackup:false` para todos); `aplicar` sem `confirmado` recusa; `Get-ChaveEfetiva 'HKLM\SOFTWARE\X' $true` = `HKCU\Software\NexTuneTeste\Ajustes\HKLM\SOFTWARE\X` e com `$false` devolve a chave intacta; ação desconhecida → `ok:false`.
- [x] **Step 2:** Implementar `ajusteswin.ps1`. Leitura com tipo: `$k = Get-Item -LiteralPath (ConvertTo-CaminhoRegistro $chave)`; `$k.GetValue($nome, $null, 'DoNotExpandEnvironmentNames')` e `$k.GetValueKind($nome)`. Build: `[Environment]::OSVersion.Version.Build` ou `simular.build` em teste. Backup atômico: `[IO.File]::WriteAllText($tmp, $json, UTF8 sem BOM)` + `Move-Item -Force`. Toda escrita em `Write-AppLog`.
- [x] **Step 3:** `host.ps1` allowlist += `ajusteswin`. Carregar: `powershell -NoProfile -ExecutionPolicy Bypass -Command "cd <repo>; . .\scripts\common.ps1; . .\scripts\ajusteswin.ps1; Get-ChaveEfetiva 'HKLM\SOFTWARE\X' $true; (Test-AjusteDisponivel @{ soWin11 = $true } 19045).disponivel"`.
  Expected: `HKCU\Software\NexTuneTeste\Ajustes\HKLM\SOFTWARE\X` e `False`.
- [x] **Step 4:** Revisão por leitura.
- [x] **Step 5:** Commit `feat(scripts): ajustes do Windows com backup do valor original e restauração exata`.

### Task 5: Interface — Inicialização, Ajustes e cartão no Início

**Files:** `ui/index.html`, `ui/styles.css`, `ui/js/estado.js`, `ui/js/arranque.js`, `ui/js/vistas/inicio.js`, `ui/js/vistas/inicializacao.js`, `ui/js/vistas/ajustes.js`, `ui/js/vistas/opcoes.js` (só o texto de ajuda), `ui/js/demo.js`, `ui/i18n/pt-BR.js`.

**Interfaces:**
- Consumes: contratos `inicializacao` e `ajusteswin`; `garantirPonto()`, `perguntar()`, `aplicarOcupado()`, `mostrarErroEscrita()`, `fmtBytes()`.
- Produces: `carregarInicializacao()` (usado por `arranque.js` e pela vista), `S.inicio = { itens, carregando, erro, filtro, avancadoListado }`, `S.ajustesWin = { lista, carregando, erro, avancadoListado }`.

- [x] **Step 1: Checagens automáticas:** reproduzir as duas de `ci-local.ps1` (`grep -rnP "innerHTML\s*\+?=\s*[^;]*\$\{(?![^}]*esc\()" ui/js` vazio; texto visível sem `data-i18n` em `index.html`) e, com `node -e`, carregar `pt-BR.js` num `window` falso e conferir que toda chave literal `t('...')` em `ui/js/**/*.js` existe (chaves montadas como `'ajuste.' + id` ficam fora). Expected: nenhuma linha.
- [x] **Step 2:** Implementar conforme a seção **UI** dos contratos. `arranque.js`: em `carregarBase()`, depois de `analisarLimpeza()`, `try { await carregarInicializacao(); } catch (e) { mostrarErro(e); }`. Inicialização e Ajustes recarregam ao mudar `modoAvancado` (como Limpeza faz com `avancadoAnalisado`). `opcoes.modoAvancadoAjuda` passa a citar também as tarefas agendadas e os ajustes de Política.
- [x] **Step 3:** Demo no navegador: `ui/index.html?vista=inicializacao` e `?vista=ajustes`; conferir que nenhum `[chave]` aparece e que alternar um item e aplicar/restaurar um ajuste funcionam na demo.
- [x] **Step 4:** Revisão por leitura (acessibilidade: `aria-pressed` no toggle, `aria-live` na contagem, `label for`).
- [x] **Step 5:** Commit `feat(ui): inicialização com liga/desliga reversível, ajustes do Windows com restauração e cartão no Início`.

### Task 6: Fechamento

- [x] **Step 1:** `README.md`: "O que já existe" += Inicialização e Ajustes do Windows (uma linha cada); pendências += "a lista de ajustes partiu de chaves que a tela de Configurações grava; o pacote gpedit/autounattend do usuário não estava nesta máquina e entra depois"; link do Plano 3 na linha de planos.
- [x] **Step 2:** Marcar as caixas deste plano. Rodar de novo as checagens da Task 5 Step 1 e o carregamento dos `.ps1` tocados (common, quarentena, programas, inicializacao, ajusteswin).
- [x] **Step 3:** Commit `docs: README com inicialização e ajustes do Windows; caixas do Plano 3 marcadas` e `git push -u origin <branch>`. Acompanhar o Actions em https://github.com/hampikamayuq/NexTune/actions (`gh` não está instalado); se falhar, corrigir no mesmo branch.

---

## Auto-revisão (feita ao escrever)

- **Cobertura da spec:** §8.4 inteiro (Tasks 1, 3, 5: `StartupApproved`, `inicio.json`, impacto medido = RAM/tamanho do exe, tarefas de fabricante só no avançado); §8.5 inteiro (Tasks 1, 4, 5: cinco grupos, backup antes da escrita, restauração exata, regra de ouro com selo de Política); §7 pouca RAM (`efeitos_visuais`, `widgets_barra`, `chat_teams_barra` recomendados para perfil fraco); §9.4 lista compartilhada (`protegidos.json` em Inicialização); §9.5 `Write-AppLog` em toda escrita. **Fora deste plano (decisão):** o pacote gpedit/autounattend do usuário (§8.5) não foi encontrado nesta máquina; o catálogo nasce das chaves de Configurações conhecidas e o README registra a pendência. Reiniciar o Explorador fica como aviso, não como ação.
- **Consistência de nomes:** módulo `ajusteswin` (PowerShell, Rust, `api.executar`) ≠ `S.ajustes`/`ajustes.rs` (opções do usuário); vista e i18n usam `ajustes.*` e `ajuste.<id>.*`; ids `run:|pasta:|tarefa:` iguais em PS, Rust e demo; `confirmado:true` estrito nos três lados.
- **Review Focus:** 1, 7 → Task 3; 2 → Tasks 2, 3; 3, 4, 6 → Task 4; 5 → Tasks 1 e 4. Todos com teste nomeado.
- **Risco assumido:** sem Rust nem Pester 5 locais, a prova dos testes acontece no Actions após o push da Task 6; por isso cada script é carregado localmente (sintaxe) e as funções puras são exercitadas à mão antes do commit.
