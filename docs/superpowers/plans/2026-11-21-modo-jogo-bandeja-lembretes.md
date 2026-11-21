# NexTune — Plano 5: Modo Jogo, bandeja, lembretes e atualizador

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Entregar o Modo Jogo (presets `suave`, `equilibrado`, `a_fundo`; estado salvo em disco **antes** de qualquer mudança; nunca ativa por cima de um estado existente; protegidos nunca fechados; pedido de fechar, não `kill`; restaura tudo e reabre o que fechou), o Modo Jogo **automático** (lista "meus jogos" + vigia em Rust a cada 15 s, restaura 30 s depois de o jogo fechar), a bandeja com a janela **destruída** ao fechar (meta de RAM §12), o autostart por tarefa ONLOGON, os lembretes só de leitura com uma notificação, o comando `abrir_url` (pendência do Plano 2) e o atualizador do próprio NexTune com assinatura minisign (código pronto; artefatos assinados só no Plano 6).

**Architecture:** Mesma ponte (UI → comandos Tauri → `host.ps1` → `scripts/<modulo>.ps1`). Um módulo PowerShell novo (`modojogo.ps1`) e uma lista de dados (`modojogo.json`). O Rust ganha quatro arquivos: `bandeja.rs` (ícone, menu, janela recriada pela configuração, fechar = destruir, autostart por `schtasks`, `abrir_url`), `vigia.rs` (loop do Modo Jogo automático sobre `tasklist /FO CSV /NH`), `lembretes.rs` (revisão de leitura a cada N dias → uma notificação) e `atualizador.rs` (`tauri-plugin-updater`). `Ajustes` ganha os campos do Modo Jogo, da bandeja e dos lembretes. Na UI: vista Modo Jogo, Opções estendidas, "Abrir" nos links de Programas.

**Tech Stack:** o mesmo dos Planos 1 a 4, mais: `tauri` com features `tray-icon` e `image-png`; crates `tauri-plugin-notification` e `tauri-plugin-updater`; `schtasks.exe`, `tasklist.exe`, `powercfg.exe`, `rundll32 url.dll,FileProtocolHandler`; `Process.CloseMainWindow()`, `Stop-Service`/`Start-Service`, `PriorityClass`.

**Spec:** `docs/superpowers/specs/2026-11-20-otimizador-design.md` §3 (anti-objetivos), §6.2 (bandeja, autostart, lembretes, vigia), §7 (perfil fraco: `a_fundo` só no avançado), §8.7 (atualizador do NexTune), §8.8, §9.4 (protegidos compartilhados), §9.5, §9.6 (rede só HTTPS para github), §9.7, §10 (chave minisign), §12 (RAM na bandeja), §17 ("O que são os lembretes").

**Plano anterior:** `2026-11-20-disco-atualizacoes.md` (concluído). **Plano seguinte:** 6 site, README e primeira release (liga `createUpdaterArtifacts`, publica `latest.json`, SignPath).

## Global Constraints

Valem todas as dos Planos 1 a 4 (PowerShell 5.1, BOM+CRLF nos `.ps1`, sem `Invoke-Expression`, argumentos em lista, textos só em `ui/i18n/pt-BR.js`, `esc()`/nós DOM, commits pequenos em português). **Ferramentas locais (corrigido no Plano 4):** Pester 6.2 e PSScriptAnalyzer 1.25 existem nesta máquina: cada tarefa roda `Invoke-Pester -Path scripts/tests` (sem `-CI`) e `Invoke-ScriptAnalyzer -Path scripts -Recurse -Severity Warning,Error` (0 avisos) antes do commit. **Rust não compila aqui** (sem toolchain): o código Rust é escrito com APIs conhecidas do Tauri 2, revisado por leitura e provado no Actions após o merge; cada tarefa Rust lista as APIs exatas que usa. Mais estas:

- **Estado antes da mudança (spec §8.8):** `modojogo/ativar` grava `Estado\modojogo.json` com o estado anterior de **tudo** que vai mexer antes do primeiro `powercfg`, `Stop-Service`, `CloseMainWindow` ou escrita no registro; cada passo seguinte atualiza o arquivo (atômico, `Write-JsonAtomico`). Se o arquivo já existe com `ativo:true`, `ativar` recusa ("já ativo"); `desativar` é quem apaga.
- **Protegidos nunca fecham:** processos de `protegidos.json` (`processos`) e de `data/modojogo.json` (`protegidos`: OBS, Discord, Steam, Epic, Battle.net, GOG Galaxy, EA, Ubisoft, Riot, NVIDIA, AMD, Realtek/Nahimic/Dolby, Afterburner/RTSS, Overwolf, TeamSpeak, Parsec, Xbox Game Bar) vão para `naoFechados` mesmo se vierem em `fechar`, mesmo com `avancado:true`.
- **Pedido de fechar, nunca `kill`:** `CloseMainWindow()`, espera até 10 s por processo; quem não fechou (diálogo "salvar?") fica aberto e em `naoFechados` com motivo.
- **Serviços:** só pausa o que estava `Running` e só religa esses; Windows Update/BITS/Otimização de Entrega **não** são pausados se `TiWorker.exe` ou `TrustedInstaller.exe` estiver rodando (`windowsInstalando:true`). Nunca `Set-Service -StartupType`: só `Stop-Service`/`Start-Service`.
- **`a_fundo` em perfil fraco** (`classe=basico` ou `disco=hdd`, perfil ausente conta como fraco) só com `avancado:true` (script confere; a UI esconde).
- **Vigia e lembretes nunca executam nada além de `modojogo/ativar|desativar` (vigia) e ações de leitura (lembretes).** Lembretes: `limpeza/analisar`, `atualizacoes/listar`, `disco/estado`, `diagnostico/coletar`; uma notificação por revisão; host encerrado logo depois quando a janela está fechada.
- **Fechar a janela com a bandeja ativa destrói a janela** (`WebviewWindow::destroy`, não `hide`), e a janela volta por `WebviewWindowBuilder::from_config` com a configuração de `tauri.conf.json`. Bandeja ativa = `ajustes.bandeja || ajustes.lembretes || ajustes.modoJogoAuto`.
- **Autostart (spec §6.2):** `schtasks /Create /TN NexTune /SC ONLOGON /RL HIGHEST /TR "\"<exe>\" --bandeja" /F`; recusa quando o executável não está sob `%ProgramFiles%` (instalação de desenvolvimento) — nunca aponta para pasta gravável pelo usuário. `--bandeja` abre sem janela.
- **`abrir_url`:** só `https://<host>/...` (sem espaço/controle, até 2048 chars) ou `ms-windows-store://pdp/?ProductId=<12 alfanuméricos maiúsculos>`; abre via `rundll32.exe url.dll,FileProtocolHandler <url>` com argumento de lista.
- **Atualizador:** `tauri-plugin-updater` com `endpoints: ["https://github.com/hampikamayuq/NexTune/releases/latest/download/latest.json"]` e a **chave pública** gerada nesta máquina (`tauri signer generate`); a chave privada fica **fora do repositório** em `%USERPROFILE%\.nextune\nextune.key` e o README diz que ela vai para o secret `TAURI_SIGNING_PRIVATE_KEY` do Actions e para uma cópia criptografada (pergunta aberta 6). `bundle.createUpdaterArtifacts` fica `false` até o Plano 6 (sem o secret o build do Actions falharia). Sem `latest.json` publicado, "Procurar atualização" responde "você já tem a versão mais nova" (404 tratado).
- **Ids e nomes nunca viram comando:** nomes de exe `^[^\\/:*?"<>|\x00-\x1f]{1,120}\.exe$` (sem diferenciar caixa) no Rust; o script resolve o exe contra a própria lista de processos; `fechar` e `jogos` até 50 itens.

## Review Focus

1. **Nunca ativa por cima:** com `modojogo.json` `ativo:true`, `ativar` devolve `ok:false` "já ativo" e nada muda; o estado é gravado **antes** de qualquer efeito (simulação que falha no primeiro passo deixa o arquivo escrito e `desativar` restaura). → Tarefa 1.
2. **Protegido em `fechar`** (`obs64.exe`, `Discord.exe`, `steam.exe`, `RtkAudUService64.exe`, `explorer.exe`): nunca fechado, aparece em `naoFechados` com motivo; os demais da lista fecham. → Tarefa 1.
3. **Windows instalando** (`TiWorker.exe` rodando): `equilibrado` não pausa `wuauserv`/`BITS`/`DoSvc`, `windowsInstalando:true`, o resto do preset é aplicado. → Tarefa 1.
4. **Serviço já parado não é religado; `a_fundo` em perfil fraco sem `avancado` recusado; `desativar` idempotente (sem estado → `ok:true, ativo:false`) e com estado corrompido → `ok:false` sem tocar no sistema.** → Tarefa 1.
5. **Processo que não fecha em tempo** (simulado `naoFecha:true`): fica em `naoFechados` "não fechou a tempo", nunca é morto, e `desativar` não tenta reabri-lo. → Tarefa 1.
6. **Vigia:** CSV do `tasklist` com nomes entre aspas e vírgula no título; detecção sem diferenciar caixa; só desativa depois de dois ticks (≥ 30 s) sem o jogo; nunca ativa se já ativo (estado do script). `abrir_url` recusa `http://`, `javascript:`, `file:`, `https://` sem host, store com ProductId curto; `autostart` recusa exe fora de Program Files. → Tarefa 3.
7. **Lembretes:** `devido` com `ultimo=None` é `true`; thresholds exatos (lixo > `lixoNotificarMB`, qualquer atualização não excluída, disco do sistema `diasSemVerificar ≥ 90` ou `null`, disco com `saude ≠ Healthy|OK`); zero alertas ⇒ nenhuma notificação, mas `ultimoLembrete` é gravado. → Tarefa 4.

---

## Estrutura de arquivos

```
data/modojogo.json            protegidos [{padrao, motivo}], planoDesempenho (GUID Alto desempenho), servicos por preset
scripts/modojogo.ps1          ações estado, processos, ativar, desativar
scripts/tests/modojogo.Tests.ps1
scripts/host.ps1              allowlist += modojogo
src-tauri/Cargo.toml          tauri features tray-icon, image-png; + tauri-plugin-notification, tauri-plugin-updater
src-tauri/tauri.conf.json     plugins.updater {endpoints, pubkey}; bundle.createUpdaterArtifacts false
src-tauri/capabilities/default.json  += core:window:allow-show, core:window:allow-set-focus
src-tauri/src/acoes.rs        MODULOS += modojogo; ESCRITA += modojogo/ativar, modojogo/desativar; validação
src-tauri/src/ajustes.rs      += jogos, modoJogoAuto, modoJogoPreset, lembretes, lembretesDias, bandeja; bandeja_ativa()
src-tauri/src/comandos.rs     DADOS_PERMITIDOS += modojogo; verificar_sessao pub(crate); comandos novos registrados em lib.rs
src-tauri/src/bandeja.rs      criar_bandeja, abrir_janela, fechar_para_bandeja, autostart, autostart_estado, abrir_url (+ url_permitida pura)
src-tauri/src/vigia.rs        exes_de_tasklist (pura), Decisao (pura), loop a cada 15 s
src-tauri/src/lembretes.rs    devido (pura), avaliar (pura), loop a cada 60 min, notificação
src-tauri/src/atualizador.rs  atualizacao_verificar, atualizacao_instalar
src-tauri/src/lib.rs          plugins, bandeja, --bandeja, ExitRequested, CloseRequested, spawn vigia/lembretes, handlers novos
ui/index.html                 nav += modojogo (entre Atualizações e Quarentena); script da vista
ui/js/api.js                  abrirUrl, autostart, autostartEstado, atualizacao.verificar/instalar (demo: no-op)
ui/js/estado.js               S.modoJogo
ui/js/arranque.js             ouve evento 'modojogo' (vigia) e re-renderiza
ui/js/vistas/modojogo.js
ui/js/vistas/opcoes.js        lembretes, dias, bandeja, autostart, atualização do NexTune
ui/js/vistas/programas.js     botão "Abrir" (abrirUrl) ao lado do endereço
ui/js/demo.js                 modojogo
ui/i18n/pt-BR.js              nav.modojogo, modojogo.*, opcoes.lembretes*, opcoes.bandeja*, opcoes.autostart*, opcoes.atualizacao*, programas.abrirLink
ui/styles.css                 .preset, .proc-jogo
README.md                     "O que já existe", pendências (RAM medida só após build), chave do atualizador
```

---

## Contratos

### `data/modojogo.json`
`{ "planoDesempenho": "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c", "protegidos": [{ "padrao", "motivo" }], "servicos": { "equilibrado": ["wuauserv", "BITS", "DoSvc"], "a_fundo": ["WSearch", "SysMain"] } }`. `padrao` é regex sem diferenciar caixa sobre o nome do exe: `^obs(32|64)?\.exe$`, `^Discord(PTB|Canary)?\.exe$`, `^steam(webhelper)?\.exe$`, `^EpicGamesLauncher\.exe$`, `^Battle\.net\.exe$`, `^GalaxyClient\.exe$`, `^(EADesktop|Origin)\.exe$`, `^(upc|UbisoftConnect)\.exe$`, `^RiotClient`, `^nv(container|display)`, `^(RadeonSoftware|AMDRSServ)`, `^(RtkAudUService64|RAVCpl64|nahimic|Dolby)`, `^(MSIAfterburner|RTSS)\.exe$`, `^Overwolf`, `^(ts3client|TeamSpeak)`, `^parsec`, `^GameBar`. Motivos em pt-BR direto ("Gravação/transmissão: fechar perde a live." etc.).

### modojogo (PowerShell)
- `estado {}` → `{ ativo:false }` ou `{ ativo:true, preset, desde (ISO), automatico, jogo (string|null), fechados:[{exe, caminho}], naoFechados:[{exe, motivo}], servicosPausados:[string], planoAnterior (GUID|null), notificacoesAnterior (int|null), windowsInstalando }`. Lê `Estado\modojogo.json`; ilegível → `ok:false` "estado do Modo Jogo ilegível".
- `processos {}` → `{ processos: [{ exe, nome (título da janela ou exe), caminho (string|null), ramBytes, protegido, motivoProtegido }] }`: um item por exe entre os processos com `MainWindowHandle -ne 0`, ordenados por `ramBytes` desc; `protegido` = `protegidos.json.processos` (nome exato) ou `modojogo.json.protegidos` (regex). Teste: vem de `simular.processos`.
- `ativar { preset: 'suave'|'equilibrado'|'a_fundo', fechar:[exe], jogo?: exe, automatico?: bool, confirmado:true, avancado? }` → `{ ativo:true, preset, fechados, naoFechados, servicosPausados, windowsInstalando, precisaAvancado:false }`. Ordem: (1) recusa se já ativo, se `a_fundo` com perfil fraco sem `avancado` ("preset a fundo só no modo avançado neste PC"); (2) resolve `fechar` contra `processos` (desconhecido → `naoFechados` "não está aberto"; protegido → `naoFechados` com o motivo); (3) **grava o estado** com `planoAnterior` (`powercfg /getactivescheme` → GUID por regex), `notificacoesAnterior` (valor atual de `HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings` `NOC_GLOBAL_SETTING_TOASTS_ENABLED`, `null` se ausente), serviços do preset com `Status` atual, `fechados` planejados com `caminho`; (4) fecha (`CloseMainWindow`, espera 10 s; não fechou → `naoFechados` "não fechou a tempo (há algo para salvar?)" e sai de `fechados`); (5) `powercfg /setactive <planoDesempenho>`; (6) `equilibrado`+: `Set-ItemProperty ... TOASTS_ENABLED 0 DWord`; `Stop-Service` nos `Running` do preset, exceto WU/BITS/DoSvc com `TiWorker.exe|TrustedInstaller.exe` rodando (`windowsInstalando:true`); (7) `a_fundo`: `Stop-Service` em WSearch/SysMain (se Running) e `PriorityClass='High'` no processo `jogo` se rodando (guarda `prioridadeAnterior`). Cada passo regrava o estado; `Write-AppLog` em cada mudança.
- `desativar { confirmado:true }` → `{ ativo:false, reabertos:[exe], religados:[servico], falhas:[{item, erro}] }`. Sem estado → `ok:true` com listas vazias (idempotente). Estado ilegível → `ok:false`, nada tocado. Ordem inversa: prioridade `Normal`; `Start-Service` só em `servicosPausados`; notificações: `notificacoesAnterior` null → remove o valor, senão devolve; `powercfg /setactive planoAnterior` se houver; reabre `fechados` com `caminho` (`Start-Process -FilePath`, falha → `falhas`); apaga o estado por último (só se nenhuma falha "grave"? não: apaga sempre e lista `falhas`; o usuário vê o que não voltou).
- Teste: `simular { processos:[{exe, nome, caminho, ramBytes, janela, naoFecha?}], planoAtivo (GUID), servicos:{ nome: 'Running'|'Stopped' }, windowsInstalando?, perfil? }`; nunca chama `Get-Process`/`powercfg`/`*-Service`/`Start-Process`; marcadores em `%TEMP%\NexTuneTeste\modojogo\`: `powercfg-<guid>.txt`, `servico-<nome>-stop.txt`/`-start.txt`, `fechar-<exe>.txt`, `reabrir-<exe>.txt`, `prioridade-<exe>-<High|Normal>.txt`; notificações em `HKCU\Software\NexTuneTeste\ModoJogo\Notifications`; estado em `%TEMP%\NexTuneTeste\Estado\modojogo.json`; perfil via `Set-Perfil ... $true`.

### Rust — Ajustes (`ajustes.rs`)
`+= jogos: Vec<String>` (padrão vazio; validar: ≤ 50, cada um casa `re_exe`), `modo_jogo_auto: bool` (false), `modo_jogo_preset: String` (`suave`; valores `suave|equilibrado|a_fundo`), `lembretes: bool` (false), `lembretes_dias: u32` (3; 1..=30), `bandeja: bool` (false). `pub fn bandeja_ativa(&self) -> bool { self.bandeja || self.lembretes || self.modo_jogo_auto }`. camelCase na UI: `jogos, modoJogoAuto, modoJogoPreset, lembretes, lembretesDias, bandeja`.

### Rust — acoes.rs
`MODULOS` += `modojogo` (11). `ESCRITA` += `modojogo/ativar`, `modojogo/desativar`. `fn re_exe()` = `(?i)^[^\\/:*?"<>|\x00-\x1f]{1,120}\.exe$`. `modojogo/estado|processos {simular?}`; `modojogo/ativar {preset, fechar, jogo?, automatico?, confirmado:true, avancado?, simular?}`: `preset` em `suave|equilibrado|a_fundo` (obrigatório), `fechar` lista 0..=50 de exes sem repetição (obrigatória, pode ser vazia), `jogo` opcional exe, `automatico` bool opcional; `modojogo/desativar {confirmado:true, simular?}`. `MAX_FECHAR: usize = 50`.

### Rust — bandeja.rs
- `pub fn criar_bandeja(app: &AppHandle) -> tauri::Result<()>`: `TrayIconBuilder::with_id("principal")`, ícone `app.default_window_icon()`, menu `Menu::with_items(app, &[&MenuItem::with_id(app, "abrir", "Abrir o NexTune", true, None)?, &PredefinedMenuItem::separator(app)?, &MenuItem::with_id(app, "sair", "Sair", true, None)?])`, `on_menu_event` (`abrir` → `abrir_janela`; `sair` → `app.exit(0)`), `on_tray_icon_event` clique esquerdo `Up` → `abrir_janela`. `pub fn remover_bandeja(app)` (`app.remove_tray_by_id("principal")`).
- `pub fn abrir_janela(app: &AppHandle)`: `app.get_webview_window("main")` → `show()` + `set_focus()`; senão `WebviewWindowBuilder::from_config(app, &app.config().app.windows[0])?.build()?`.
- `pub fn tratar_fechar(window: &Window, api: &CloseRequestApi, ajustes: &Ajustes)`: se `ajustes.bandeja_ativa()` → `api.prevent_close()` e `tauri::async_runtime::spawn` com `window.destroy()`; senão nada (o Tauri fecha e, sem outras janelas, sai).
- Em `lib.rs`: `.on_window_event(|w, e| if let WindowEvent::CloseRequested { api, .. } = e { tratar_fechar(...) })`; `RunEvent::ExitRequested { api, code: None, .. }` → `api.prevent_exit()` quando `bandeja_ativa()`; no `setup`, se `bandeja_ativa()` → `criar_bandeja`; se arg `--bandeja` → destruir a janela "main" logo após o setup (abre só na bandeja). `ajustes_gravar`: quando `bandeja_ativa` passa de false→true cria a bandeja; true→false remove.
- `pub fn url_permitida(url: &str) -> bool` (pura; regra dos Global Constraints). `#[tauri::command] abrir_url(url: String, estado) -> Result<(), String>`: demo → `Ok`; recusa → `Err("url não permitida")`; `Command::new("rundll32.exe").args(["url.dll,FileProtocolHandler", &url]).creation_flags(CREATE_NO_WINDOW).spawn()`.
- `pub fn exe_em_program_files(exe: &Path) -> bool` (pura: prefixo `%ProgramFiles%` ou `%ProgramFiles(x86)%`, sem diferenciar caixa). `#[tauri::command] autostart(ligar: bool) -> Result<bool, String>`: `current_exe()`, recusa fora de Program Files ("instalação de desenvolvimento: autostart só com o programa instalado"), `schtasks /Create ... /F` ou `/Delete /TN NexTune /F` (CREATE_NO_WINDOW, `status.success()`), devolve `autostart_estado()`. `#[tauri::command] autostart_estado() -> bool`: `schtasks /Query /TN NexTune` com sucesso.

### Rust — vigia.rs
- `pub fn exes_de_tasklist(csv: &str) -> HashSet<String>`: primeiro campo CSV de cada linha, sem aspas, minúsculas (`"Image Name","PID",...` sem `/NH` não aparece; `/NH` omite cabeçalho; linha vazia e `INFO: No tasks...` ignoradas por não terminarem em `.exe`).
- `#[derive(PartialEq, Debug)] pub enum Decisao { Nada, Ativar(String), Desativar }` e `pub fn decidir(jogos: &[String], rodando: &HashSet<String>, ativo_por_vigia: Option<&str>, ausente_ha: Option<Duration>) -> Decisao` (pura): algum jogo rodando (comparação minúscula) e não ativo → `Ativar(exe)`; ativo e jogo ausente há ≥ 30 s → `Desativar`; senão `Nada`.
- `pub fn iniciar(app: AppHandle)`: `tauri::async_runtime::spawn` com loop `tokio::time::sleep(15 s)`: lê `Ajustes`; se `!modo_jogo_auto || jogos.is_empty()` continua; `tasklist /FO CSV /NH` (CREATE_NO_WINDOW); `decidir`; `Ativar` → `comandos::executar_interno(&estado, "modojogo", "ativar", json!({preset, fechar:[], jogo, automatico:true, confirmado:true, avancado: modo_avancado}))` (função nova em `comandos.rs` que faz `verificar_sessao` + `host.executar`, usada também pelos lembretes); `Desativar` → `desativar`. Guarda `ativo_por_vigia` e `ausente_desde` no loop. Emite `app.emit("modojogo", json!({ativo, jogo}))` após cada mudança. Erros viram `Write-AppLog`? Não há acesso ao log do PowerShell: `eprintln!` + evento `modojogo` com `erro`.

### Rust — lembretes.rs
- `pub fn devido(ultimo: Option<SystemTime>, dias: u32, agora: SystemTime) -> bool` (pura; `None` → true).
- `pub struct Alerta { pub tela: &'static str, pub texto: String }`; `pub fn avaliar(limpeza: &Value, atualiz: &Value, disco: &Value, diag: &Value, lixo_mb: u64, dias_disco: u64) -> Vec<Alerta>` (pura): lixo = soma de `categorias[cor=verde && disponivel].tamanhoBytes` > `lixo_mb`·1 MiB → ("limpeza", "X de arquivos temporários"); `windows[excluido==null].len() + programas.len()` > 0 → ("atualizacoes", "N atualizações pendentes"); unidade `sistema` com `ultimaVerificacao==null` ou `diasSemVerificar >= dias_disco` → ("disco", ...); algum `diag.discos[].saude` fora de `Healthy|OK|Saudável` → ("disco", "disco com aviso de saúde").
- `Registro { ultimo_lembrete: Option<String> }` em `%APPDATA%\NexTune\lembretes.json`. `pub fn iniciar(app: AppHandle)`: loop a cada 60 min (primeira passada 2 min após abrir): se `ajustes.lembretes` e `devido` → roda as quatro leituras via `executar_interno`, `avaliar` com `perfis.json.limites`; se houver alertas → **uma** notificação (`app.notification().builder().title("NexTune").body(<textos unidos por " · ">).show()`); grava `ultimo_lembrete` sempre; se não há janela "main" → `host.encerrar()`.

### Rust — atualizador.rs
- `#[tauri::command] async fn atualizacao_verificar(app) -> Result<Option<Atualizacao>, String>` com `Atualizacao { versao: String, notas: Option<String> }`: `app.updater()?.check().await` → `Some(u)` → `Some(Atualizacao{ versao: u.version, notas: u.body })`; `None` → `Ok(None)`; erro de rede/404 → `Ok(None)` + `eprintln!` (sem `latest.json` ainda não é erro para o usuário). `#[tauri::command] async fn atualizacao_instalar(app) -> Result<(), String>`: `check()` → `download_and_install(|_, _| {}, || {})` → `app.restart()`. Demo → `Ok(None)`/`Err("demo")`.
- `tauri.conf.json`: `"plugins": { "updater": { "endpoints": ["https://github.com/hampikamayuq/NexTune/releases/latest/download/latest.json"], "pubkey": "<conteúdo de nextune.key.pub>" } }`, `"bundle": { "createUpdaterArtifacts": false }`.

### UI
- **Modo Jogo** (`VISTAS.modojogo`): carrega `estado` + `processos` na visita. Ativo: cartão `.recomendado` "Modo Jogo ativo (preset X) desde HH:mm · jogo Y" + botão "Desativar e restaurar tudo" (`.escrita`) + listas (fechados, serviços pausados, não fechados com motivo). Inativo: (a) presets em `fieldset` com radios e descrição por preset (`modojogo.preset.<p>.desc`); `a_fundo` oculto se perfil fraco e `!modoAvancado`; (b) "Fechar ao ativar": lista `.proc-jogo` com checkbox por processo (protegidos sem caixa, selo e motivo), RAM; (c) "Meus jogos" (automático): input texto + "Adicionar" (valida `.exe` no JS com a mesma regex), lista com "Remover", toggle "Ligar automaticamente quando um jogo abrir" → ao ligar: modal "Isso liga a bandeja e o início com o Windows (sem eles o automático não funciona). Para desfazer: desligue aqui." → `ajustes.gravar({modoJogoAuto:true, modoJogoPreset})` + `api.autostart(true)` (erro de autostart vira aviso, não desfaz); (d) botão "Ativar Modo Jogo" (`.escrita`, modal com o que vai fazer e "Para desfazer: Desativar devolve tudo e reabre o que fechou") → `ativar` **sem** `garantirPonto()` (nada permanente). Evento `modojogo` do vigia → recarrega.
- **Opções** += seção "Bandeja e lembretes": checkbox lembretes + número de dias (1–30) + ajuda ("só olha; nunca executa; uma notificação"); checkbox "manter na bandeja ao fechar"; linha "Abrir com o Windows: ligado/desligado" + botão Ligar/Desligar (`api.autostart`); seção "Atualização do NexTune": versão atual + botão "Procurar atualização" → `api.atualizacao.verificar()` → toast "você já tem a versão mais nova" ou cartão "Versão X disponível" + botão "Baixar e instalar" (modal "o programa fecha e reabre").
- **Programas**: ao lado do endereço de reinstalação, botão "Abrir" (`api.abrirUrl`); em demo só toast.
- **Demo**: processos (Chrome 540 MB, Spotify 210 MB, Discord protegido, OBS protegido, LibreOffice), estado inativo; `ativar` muda estado em memória; `autostart` devolve o booleano pedido; `atualizacao.verificar` → `null`.

---

### Task 1: `data/modojogo.json` e `scripts/modojogo.ps1`

**Files:** `data/modojogo.json`, `scripts/modojogo.ps1`, `scripts/tests/modojogo.Tests.ps1`, `scripts/host.ps1`, `src-tauri/src/comandos.rs` (só `DADOS_PERMITIDOS` += `modojogo` e o teste de forma do arquivo).

**Interfaces:**
- Consumes (common.ps1): `Get-PastaDeDados`, `Read-ArquivoJson`, `New-RegexLista`, `Get-AppPastas`, `Write-JsonAtomico`, `Get-Perfil`, `Write-AppLog`, `Test-ParamVerdadeiro`, `Get-Simulacao`, `ConvertTo-CaminhoRegistro`, `Send-*`.
- Produces: ações `estado`, `processos`, `ativar`, `desativar`; puras `Test-PerfilFraco($Perfil)`, `Test-PresetPermitido([string]$Preset, $Perfil, [bool]$Avancado)`, `Get-GuidPlano([string]$SaidaPowercfg)` → GUID ou `$null`, `Get-ProcessoProtegido([string]$Exe, $Tabelas)` → motivo ou `$null`, `Get-ServicosDoPreset([string]$Preset, $Dados)`.

- [x] **Step 1: Escrever `data/modojogo.json`** conforme o contrato e, em `comandos.rs`, `DADOS_PERMITIDOS` += `"modojogo"` e teste `modojogo_ok` (lendo `data/` real): `planoDesempenho` casa GUID, `protegidos` não vazia com `padrao` compilando sem diferenciar caixa e `motivo` não vazio, `servicos.equilibrado` e `servicos.a_fundo` listas não vazias de `^[A-Za-z]+$`.
- [x] **Step 2: Escrever os testes Pester** (`Invoke-Jogo` captura `@@RESULT`; `BeforeEach` apaga `%TEMP%\NexTuneTeste\modojogo`, o estado e `HKCU:\Software\NexTuneTeste\ModoJogo`; perfil `medio/ssd` por padrão). Simulado padrão: processos `chrome.exe` (janela, 540 MB), `Spotify.exe` (janela), `Discord.exe` (janela, protegido), `obs64.exe` (janela, protegido), `soffice.bin`? não: `soffice.exe` com `naoFecha:$true`, `svchost.exe` (sem janela), `jogo.exe` (janela); `planoAtivo = '381b4222-f694-41f0-9685-ff5bb260df2e'` (Equilibrado); serviços `wuauserv Running, BITS Running, DoSvc Stopped, WSearch Running, SysMain Running`. Casos: puras — `Get-GuidPlano 'GUID do Esquema de Energia: 381b4222-... (Equilibrado)'` devolve o GUID, texto sem GUID → `$null`; `Test-PresetPermitido 'a_fundo' <basico/hdd> $false` falso, `$true` verdadeiro, `'suave'` sempre, perfil `$null` conta como fraco; `Get-ProcessoProtegido 'OBS64.EXE'` motivo não vazio (caixa), `'explorer.exe'` (protegidos.json) não vazio, `'chrome.exe'` `$null`. Ações — `estado` sem arquivo → `ativo:false`; `processos` → só com janela (5), `Discord.exe`/`obs64.exe` `protegido:true`, ordenados por RAM; **RF1** `ativar suave fechar @('chrome.exe')` → `ok:true`, `fechados` = chrome com caminho, marcador `fechar-chrome.exe.txt`, `powercfg-8c5e7fda-....txt`, estado com `planoAnterior` = GUID simulado, **nenhum** `servico-*`; segundo `ativar` → `ok:false` "já ativo", nenhum marcador novo; **RF2** `ativar suave fechar @('Discord.exe','obs64.exe','chrome.exe','explorer.exe','naoexiste.exe')` → `fechados` só chrome, `naoFechados` com 4 itens e motivos; **RF5** `fechar @('soffice.exe')` → `naoFechados` "não fechou a tempo", sem marcador `fechar-soffice.exe.txt`?? (o pedido de fechar é feito: marcador existe; o que não existe é kill) → asserção: `naoFechados[0].exe = 'soffice.exe'`, estado `fechados` vazio, e `desativar` não gera `reabrir-soffice.exe.txt`; **RF3** `ativar equilibrado` com `windowsInstalando:$true` → `windowsInstalando:true`, sem `servico-wuauserv-stop.txt`/`servico-BITS-stop.txt`, mas notificações gravadas (valor 0 em `...NexTuneTeste\ModoJogo\Notifications\Settings`) e `powercfg` marcado; sem `windowsInstalando` → `servico-wuauserv-stop.txt` e `servico-BITS-stop.txt` existem, `servico-DoSvc-stop.txt` **não** (estava Stopped), `servicosPausados = @('wuauserv','BITS')`; **RF4** `ativar a_fundo` com perfil `basico/hdd` sem `avancado` → `ok:false` contém "avançado", sem estado e sem marcadores; com `avancado:true` → ok, `servico-WSearch-stop.txt`, `servico-SysMain-stop.txt`, `prioridade-jogo.exe-High.txt` quando `jogo='jogo.exe'`; `desativar` depois → `religados` = exatamente os pausados, `servico-DoSvc-start.txt` não existe, `prioridade-jogo.exe-Normal.txt`, `powercfg-381b4222-....txt`, notificações restauradas (valor removido, pois `notificacoesAnterior` era null), `reabrir-chrome.exe.txt`, estado apagado, `estado` → `ativo:false`; `desativar` sem estado → `ok:true`, listas vazias; estado com lixo → `ok:false`, nenhum marcador; `ativar` sem `confirmado` → `ok:false`; ação desconhecida → `ok:false`.
- [x] **Step 3: Rodar os testes e ver falhar** (`Invoke-Pester -Path scripts/tests/modojogo.Tests.ps1`). Expected: falhas por função/arquivo ausente.
- [x] **Step 4: Implementar `modojogo.ps1`** conforme o contrato (BOM+CRLF; suprimir `PSUseSingularNouns` nas funções plurais; `Stop-Service`/`Start-Service` só fora do teste). `host.ps1` allowlist += `modojogo`.
- [x] **Step 5: Rodar `Invoke-Pester -Path scripts/tests` e `Invoke-ScriptAnalyzer -Path scripts -Recurse -Severity Warning,Error`.** Expected: todos passando, 0 avisos.
- [x] **Step 6: Commit** `feat(scripts): modo jogo com estado salvo antes da mudança, protegidos, pedido de fechar e restauração completa`.

### Task 2: Rust — Ajustes e validação

**Files:** `src-tauri/src/ajustes.rs`, `src-tauri/src/acoes.rs`.

**Interfaces:**
- Produces: campos novos de `Ajustes` + `bandeja_ativa()`; `validar("modojogo", ...)`; `re_exe()` público no crate (`pub(crate) fn re_exe`) para `vigia.rs`; `modulos_permitidos().len() == 11`.

- [x] **Step 1: Testes** em `ajustes.rs`: `padrao_tem_modo_jogo` (campos padrão: `jogos` vazio, `modo_jogo_preset == "suave"`, `lembretes_dias == 3`, `!bandeja_ativa()`); `bandeja_ativa_por_qualquer_um` (cada um dos três flags); `validacao` += `modo_jogo_preset = "turbo"` erro, `lembretes_dias = 0` e `31` erro, `jogos` com `"a b.exe"` ok, `"jogo"` (sem .exe) erro, `"a\\b.exe"` erro, 51 jogos erro; `json_parcial_faz_merge` continua passando (campos novos com `default`). Em `acoes.rs`: `modojogo_estado_e_processos` (`{}` ok, `simular` só em teste); `modojogo_ativar_valido` (`{preset:"suave", fechar:[], confirmado:true}`, com `fechar:["Chrome.exe","Spotify.exe"]`, `jogo:"Jogo Legal.exe"`, `automatico:true`, `avancado:true`); `modojogo_ativar_recusa` (sem preset; `preset:"turbo"`; sem `fechar`; `fechar:"x"`; `fechar:["x"]` sem .exe; `fechar:["a/b.exe"]`; repetido; 51; `jogo:"x"`; `automatico:"sim"`; sem `confirmado`); `modojogo_desativar` (`{confirmado:true}` ok; `{}` falha; chave extra falha); `tabela_e_escrita` += as duas de escrita e `estado`/`processos` como leitura; `modulos` → 11.
- [x] **Step 2: Implementar** (`Ajustes` com `#[serde(default)]` já no struct; `validar` novo; `re_exe`, `MAX_FECHAR`, ramos de `validar`).
- [x] **Step 3: Revisão por leitura** (clippy mental; `regex` com `(?i)` em vez de `to_lowercase`).
- [x] **Step 4: Commit** `feat(rust): ajustes do modo jogo, bandeja e lembretes; validação do módulo modojogo`.

### Task 3: Rust — bandeja, janela, autostart, `abrir_url`, vigia

**Files:** `src-tauri/Cargo.toml`, `src-tauri/capabilities/default.json`, `src-tauri/src/bandeja.rs`, `src-tauri/src/vigia.rs`, `src-tauri/src/comandos.rs`, `src-tauri/src/lib.rs`.

**Interfaces:**
- Consumes: `Ajustes::bandeja_ativa`, `acoes::re_exe`, `HostPowerShell::executar`, `verificar_sessao`.
- Produces: `comandos::executar_interno(estado: &Estado, modulo, acao, params) -> Result<Value, String>` (sem janela; `verificar_sessao` quando escrita); comandos Tauri `abrir_url`, `autostart`, `autostart_estado`; `bandeja::{criar_bandeja, remover_bandeja, abrir_janela, tratar_fechar, url_permitida, exe_em_program_files}`; `vigia::{exes_de_tasklist, decidir, Decisao, iniciar}`.

- [x] **Step 1: Testes** (puros, `#[cfg(test)]`): `url_permitida`: aceita `https://support.lenovo.com/br/pt/x`, `ms-windows-store://pdp/?ProductId=9WZDNCRFHVFW`; recusa `http://a.com`, `https://`, `https:///x`, `javascript:alert(1)`, `file:///C:/x`, `https://a.com/x y`, `https://a.com/\n`, `ms-windows-store://pdp/?ProductId=abc`, 2049 chars (**RF6**). `exe_em_program_files`: `C:\Program Files\NexTune\nextune.exe` true (caixa indiferente), `C:\Program Files (x86)\X\x.exe` true, `C:\Users\x\AppData\Local\Programs\NexTune\nextune.exe` false, `D:\dev\target\release\nextune.exe` false. `exes_de_tasklist`: CSV `"NexTune.exe","1234","Console","1","85.000 K"\r\n"Jogo Legal.exe","99","Console","1","1,2 MB"\r\n"obs64.exe","7","Console","1","x, y"\r\nINFO: No tasks are running.\r\n` → `{nextune.exe, jogo legal.exe, obs64.exe}`. `decidir`: jogos `["Jogo Legal.exe"]`, rodando `{jogo legal.exe}`, nenhum ativo → `Ativar("Jogo Legal.exe")`; ativo `Some("Jogo Legal.exe")`, rodando sem o jogo, `ausente_ha = Some(15s)` → `Nada`; `Some(30s)` → `Desativar`; ativo e jogo rodando → `Nada`; jogos vazio → `Nada`.
- [x] **Step 2: Implementar.** `Cargo.toml`: `tauri = { version = "2", features = ["tray-icon", "image-png"] }`. APIs usadas (Tauri 2): `tauri::tray::{TrayIconBuilder, TrayIconEvent, MouseButton, MouseButtonState}`, `tauri::menu::{Menu, MenuItem, PredefinedMenuItem}`, `tauri::{AppHandle, Manager, Emitter, WebviewWindowBuilder, WindowEvent, RunEvent}`, `app.default_window_icon()`, `app.remove_tray_by_id`, `WebviewWindowBuilder::from_config(&app, &app.config().app.windows[0])`, `window.destroy()`, `api.prevent_close()`, `api.prevent_exit()`. `lib.rs`: `on_window_event`, `setup` (bandeja se ativa; `--bandeja` → destruir janela; `vigia::iniciar(app.handle().clone())`), `run` com `ExitRequested`. `comandos.rs`: `executar_interno`; `ajustes_gravar` cria/remove a bandeja na transição (recebe `AppHandle`). `capabilities/default.json` += `core:window:allow-show`, `core:window:allow-set-focus`.
- [x] **Step 3: Revisão por leitura** com a lista de APIs acima conferida contra a documentação do Tauri 2 (docs.rs tauri 2.x): nomes de módulos, assinaturas de `from_config`, `TrayIconBuilder::on_menu_event(|app, event| ...)`, `event.id().as_ref()`.
- [x] **Step 4: Commit** `feat(rust): bandeja com janela destruída ao fechar, autostart por tarefa, abrir_url e vigia do modo jogo automático`.

### Task 4: Rust — lembretes e atualizador

**Files:** `src-tauri/Cargo.toml`, `src-tauri/tauri.conf.json`, `src-tauri/src/lembretes.rs`, `src-tauri/src/atualizador.rs`, `src-tauri/src/lib.rs`, `README.md` (seção da chave).

**Interfaces:**
- Consumes: `executar_interno`, `Ajustes`, `comandos::ler_dados(perfis)`.
- Produces: `lembretes::{devido, avaliar, Alerta, iniciar}`; comandos `atualizacao_verificar`, `atualizacao_instalar`.

- [x] **Step 1: Gerar a chave** (passo do executor principal, fora do subagente): `npx @tauri-apps/cli signer generate -w %USERPROFILE%\.nextune\nextune.key --password ""` (ou com senha e `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`); copiar `nextune.key.pub` para `plugins.updater.pubkey`. Nunca commitar `nextune.key`.
- [x] **Step 2: Testes** (puros): `devido(None, 3, agora)` true; `devido(Some(agora-2d), 3, agora)` false; `Some(agora-3d)` true; `avaliar` com JSONs mínimos (**RF7**): lixo 600 MB verde disponível + 2 GB amarelo → 1 alerta `limpeza` (só verde conta); 400 MB → nenhum; `windows:[{excluido:null}]` → alerta `atualizacoes`; `windows:[{excluido:"upgrade"}], programas:[]` → nenhum; disco sistema `ultimaVerificacao:null` → alerta; `diasSemVerificar: 90` → alerta; `89` → nenhum; `diag.discos:[{saude:"Warning"}]` → alerta; `"Healthy"`/`"Saudável"`/`"OK"` → nenhum; tudo vazio → `vec![]`.
- [x] **Step 3: Implementar.** `Cargo.toml` += `tauri-plugin-notification = "2"`, `tauri-plugin-updater = "2"`. `lib.rs`: `.plugin(tauri_plugin_notification::init())`, `.plugin(tauri_plugin_updater::Builder::new().build())`, `lembretes::iniciar`, handlers `atualizacao_verificar`, `atualizacao_instalar`. APIs: `tauri_plugin_notification::NotificationExt` (`app.notification().builder().title().body().show()`), `tauri_plugin_updater::UpdaterExt` (`app.updater()?.check().await?`, `update.version`, `update.body`, `update.download_and_install(|_chunk, _total| {}, || {}).await`), `app.restart()`. `tauri.conf.json` conforme o contrato. README: seção "Chave do atualizador" (onde está a privada, para onde vai, por que `createUpdaterArtifacts` está `false`).
- [x] **Step 4: Revisão por leitura; commit** `feat(rust): lembretes só de leitura com uma notificação e atualizador com assinatura minisign (artefatos no Plano 6)`.

### Task 5: Interface — Modo Jogo, Opções, "Abrir" em Programas

**Files:** `ui/index.html`, `ui/js/api.js`, `ui/js/estado.js`, `ui/js/arranque.js`, `ui/js/vistas/modojogo.js`, `ui/js/vistas/opcoes.js`, `ui/js/vistas/programas.js`, `ui/js/demo.js`, `ui/i18n/pt-BR.js`, `ui/styles.css`.

**Interfaces:**
- Consumes: contratos `modojogo`, comandos `abrir_url`, `autostart`, `autostart_estado`, `atualizacao_*`, `ajustes_gravar` com os campos novos; `perguntar`, `garantirPonto` (não usado aqui), `aplicarOcupado`, `fmtBytes`.
- Produces: `api.abrirUrl(url)`, `api.autostart(ligar)`, `api.autostartEstado()`, `api.atualizacao.verificar()/instalar()`; `S.modoJogo = { estado, processos, sel: Set, preset, carregando, erro }`; `carregarModoJogo()`.

- [x] **Step 1: Checagens automáticas** (as três do Plano 4: `innerHTML` sem `esc()`, texto sem `data-i18n`, chaves `t('...')` literais + compostas `modojogo.preset.<p>.nome/desc`). Expected: nenhuma linha.
- [x] **Step 2: Implementar** conforme a seção **UI**. Regex do exe no JS igual à do Rust. `arranque.js`: `TAURI.event.listen('modojogo', ...)` → `carregarModoJogo()` + toast.
- [x] **Step 3: Demo no navegador** (servidor estático em `ui/`, Playwright): `?vista=modojogo` ativar com um processo marcado → cartão ativo → desativar; Opções com os campos novos; Programas com "Abrir". Expected: 0 erros de console, nenhum `[chave]`.
- [x] **Step 4: Commit** `feat(ui): modo jogo com presets, fechar ao ativar e automático; opções de bandeja, lembretes, autostart e atualização; abrir links em Programas`.

### Task 6: Fechamento

- [x] **Step 1:** `README.md`: "O que já existe" += Modo Jogo, bandeja/lembretes/autostart, atualizador (código); pendências: RAM na bandeja só medida após build do Actions (`tools/medir.ps1`), `createUpdaterArtifacts` e secret no Plano 6, clique na notificação abre o programa (não a tela) — limitação do plugin no Windows; link do Plano 5.
- [x] **Step 2:** Marcar as caixas; rodar Pester, PSSA e as checagens da UI de novo.
- [x] **Step 3:** Commit `docs: README com modo jogo, bandeja, lembretes e atualizador; caixas do Plano 5 marcadas` e `git push -u origin plano-5-modo-jogo-bandeja`.

---

## Auto-revisão (feita ao escrever)

- **Cobertura da spec:** §8.8 inteiro (Task 1: estado antes, nunca por cima, protegidos, pedido de fechar, restauração e reabertura, três presets, `a_fundo` no avançado em perfil fraco; Task 3: lista "meus jogos", vigia a cada 15 s, 30 s para restaurar). §6.2 bandeja opcional, autostart ONLOGON RL HIGHEST sem script intermediário, lembretes com a definição de §17 (Task 3 e 4). §12 janela destruída na bandeja (Task 3); a medição fica para depois do build. §8.7 atualizador com minisign (Task 4; artefatos no Plano 6). §9.6 rede só do Rust para github (updater) e `abrir_url` só HTTPS/Store. Pendências herdadas: `abrir_url` (Plano 2), RAM (Plano 1).
- **Decisões registradas:** clique na notificação não abre a tela específica (o plugin não expõe o clique no Windows); o Início já mostra os mesmos cartões. `ativar` do Modo Jogo não cria ponto de restauração: nada é permanente e `desativar` desfaz. `createUpdaterArtifacts:false` até existir o secret. Vigia com `tasklist` (spec) em vez de WMI: processo externo a cada 15 s, só quando o automático está ligado.
- **Consistência de nomes:** módulo `modojogo` em PS, Rust, allowlist, UI, demo; preset `a_fundo` (underscore) em todos os lados; `jogos` sempre nomes de exe, nunca caminhos.
- **Review Focus:** 1–5 → Task 1; 6 → Task 3; 7 → Task 4.
- **Risco assumido:** Rust sem compilação local em um plano com Tauri tray, janela recriada, dois plugins novos e processos externos; mitigação: APIs listadas por tarefa, revisão por leitura, e o Actions como juiz após o merge. A chave minisign gerada aqui pode ser regenerada antes da primeira release.

## Correções e decisões durante a execução (2026-11-21)

- A chave minisign NÃO foi gerada: `pubkey` fica com o marcador `SUBSTITUIR_PELA_CHAVE_PUBLICA_MINISIGN` (decisão de segurança do usuário, que gera o par; ver "Chave do atualizador" no README).
- `ExitRequested` olha a existência do ícone da bandeja em vez de `bandeja_ativa()`, por causa do argumento `--bandeja`.
- `abrir_janela` cria a janela numa tarefa assíncrona.
- `abrir_url` espera o `rundll32` numa thread.
- Executáveis do sistema (`tasklist`, `schtasks`, `rundll32`, `explorer`) são chamados por caminho absoluto de System32.
- O vigia não repete uma ativação ou desativação que falhou.
- `ativar` devolve também `avisos` e segue mesmo com falha de plano de energia, notificações ou prioridade.
- `planoAnterior` ausente no estado: o plano de energia atual é mantido na restauração.
- Prioridade só nos PIDs do jogo (`jogoPids`).
- A reabertura dos programas fechados é feita via `explorer.exe` (token do usuário, sem elevação).
- O `jogo` nunca é fechado.
- Colisão global `linhaPrograma` corrigida (bug do Plano 4).
- **Revisão final:**
  1. Vigia lê `modojogo/estado` a cada ciclo e após erro em `ativar`: adota Modo Jogo ativo com `automatico:true` (`adotar_estado`), não mexe no ligado à mão (sem toast) e desativa uma vez quando o automático é desligado com o Modo Jogo ligado por ele.
  2. `abrir_url` abre por `%SystemRoot%\explorer.exe "<url>"` em vez de `rundll32` (o navegador sai sem elevação); substitui o texto de §6.2 e do contrato de `bandeja.rs`.
  3. A tarefa ONLOGON é criada por XML (`schtasks /Create /XML`, UTF-16 em `%APPDATA%\NexTune\autostart.xml`, apagado depois): roda na bateria, não para ao passar para a bateria, sem limite de tempo, `HighestAvailable`.
  4. Instância única (`tauri-plugin-single-instance`, primeiro plugin): abrir de novo mostra a janela da instância existente (exceto com `--bandeja`).
  5. Desligar o automático na tela do Modo Jogo desliga também o início com o Windows, a menos que lembretes ou bandeja estejam ligados; texto do modal atualizado.
  6. `Test-NomeExe` (PowerShell) usa a mesma regra do `re_exe` do Rust e do `RE_EXE` da UI.
  7. Atualizador: só `Error::ReleaseNotFound` (sem `latest.json`) vira "sem atualização"; rede fora do ar e outros erros chegam à UI (`opcoes.atualizacaoErro`).
