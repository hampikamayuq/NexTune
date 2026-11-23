# NexTune — Plano 8: Privacidade ampliada, saúde do Windows e ferramentas que faltam

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Cobrir o que as melhores ferramentas da área têm e o NexTune ainda não: privacidade além do registro (serviços e tarefas de telemetria), reparo do Windows (DISM + SFC), "por que meu PC reiniciou", restos de programas já desinstalados, dispositivos com problema e backup de drivers, analisador de espaço e ferramentas de rede, sempre reaproveitando código MIT quando existe.

**Architecture:** Três módulos novos (`saude`, `drivers`, `rede`, mais `espaco` só de leitura) e ações novas em módulos existentes (`ajusteswin`, `diagnostico`, `programas`). Mesmo contrato de sempre: PowerShell com modo teste e `simular`, validação no Rust (`acoes.rs`), escrita com ponto de restauração, backup e confirmação.

**Tech Stack:** PowerShell 5.1 + Pester 6, Rust, JS vanilla, pt-BR.

**Spec:** `docs/superpowers/specs/2026-11-20-otimizador-design.md` (seções 7 perfis, 8 módulos, 9 segurança).

## Código reaproveitado (licenças conferidas nos repositórios clonados em 2026-11-21)

| Fonte | Licença | O que aproveitamos |
|---|---|---|
| [RetroLimpia](https://github.com/Retropunk94/RetroLimpia) (`scripts/reinicios.ps1`, `residuos.ps1`, `drivers.ps1`) | MIT (Retropunk94, 2026) | Leitura dos eventos 41/1074/6008/1001 e tabela de telas azuis; busca conservadora de restos por nome; lista de dispositivos com erro, backup com `pnputil /export-driver` e reparo escalonado. Traduzir para pt-BR e trocar o protocolo deles (`Read-Params`/`Send-Progress` com dois idiomas) pelo nosso. |
| [Sophia Script for Windows](https://github.com/farag2/Sophia-Script-for-Windows) (`Sophia.psm1`, região Privacy & Telemetry, `DNSoverHTTPS`) | MIT (farag2, 2023) | Chaves de `FeedbackFrequency`, `LanguageListAccess`, `WhatsNewInWindows`, `BingSearch`; serviços `DiagTrack` e `WerSvc`; lista de tarefas de telemetria; configuração de DNS seguro. Os valores entram como dados no nosso catálogo, com o backup e a restauração que o Sophia não guarda. |

Todo arquivo que reaproveitar código ganha no cabeçalho a linha `Baseado em <projeto> (MIT, <autor>)`, e o README ganha os créditos.

**Já existe no NexTune e não entra:** os ajustes de privacidade do RetroLimpia (`privacidad.ps1`) já estão todos em `data/ajustes.json`; temperatura, confiabilidade do disco e bateria já estão no Diagnóstico; ponto de restauração já está em `sistema`.

**Fica de fora de propósito:** `procesos.ps1` do RetroLimpia (encerra processos à força, contra a regra do NexTune de nunca matar programas); otimizador de registro, "liberar RAM" e atualização automática de drivers (prometem mais do que entregam e já quebraram PCs); `SigninInfo` do Sophia (grava em `HKLM\...\UserARSO\<SID>`, fica para quando houver necessidade).

## Global Constraints

- pt-BR em todo texto visível; `.ps1` em UTF-8 com BOM e CRLF; PSScriptAnalyzer sem avisos; sem rede a partir da interface (exceção explícita: DISM `/RestoreHealth` baixa do Windows Update, e a tela avisa).
- Escrita: ponto de restauração antes (`garantirPonto`), backup do estado anterior, log em `%ProgramData%\NexTune\Logs`, confirmação, desfazer.
- Binários do sistema por caminho absoluto (`$env:windir\System32\...`, que o host já recebe da API).
- Nunca `Stop-Process`/kill; nunca apagar fora da quarentena; nunca mexer em ACLs.

## Review Focus

1. Serviço que já estava desligado antes do ajuste: restaurar devolve "desligado", não "automático" (teste `restaurar devolve o tipo de inicio anterior`).
2. Tarefa agendada que não existe nesta edição do Windows: vira "não se aplica", não falha o ajuste inteiro.
3. SFC/DISM em idioma diferente de pt-BR e en-US: o resultado vem dos códigos de saída e do `CBS.log`/`dism.log`, nunca do texto da tela.
4. Pasta de restos com nome parecido mas de programa ainda instalado ("Adobe" × "Adobe Acrobat"): não é marcada como segura.
5. Analisador de espaço em pasta com junction ou sem permissão: não segue o link, não trava (teto de tempo) e mostra "sem acesso" em vez de tamanho zero.

## Contratos das Tarefas 5 a 8 (fixados em 2026-11-23, antes de implementar)

Valem para PowerShell, Rust (`acoes.rs`), interface e `demo.js`. Nomes em camelCase; `-1` em bytes = desconhecido; datas ISO 8601. `simular` (objeto) só é aceito em modo teste, como nos módulos anteriores. `confirmado` é sempre o booleano `true`. Os módulos novos entram na allowlist de `host.ps1` e em `MODULOS`.

### espaco (só leitura)
- `espaco/analisar { raiz, tetoSegundos? }` → `{ raiz, totalBytes, incompleto, pastas: [{ caminho, nome, bytes, semAcesso, parcial }], arquivos: [{ caminho, nome, bytes }] }`.
  - `raiz`: caminho absoluto de pasta (`^[A-Za-z]:\\`), até 260 caracteres, existente e sem link na cadeia (`Test-CadeiaSemLink`); a raiz de unidade (`C:\`) é aceita. `tetoSegundos` inteiro 5..300 (padrão 60), teto da análise inteira.
  - `pastas`: as 20 maiores do primeiro nível, da maior para a menor; `bytes:-1` quando não deu para medir. `semAcesso:true` quando a própria pasta não pode ser listada; `parcial:true` quando alguma subpasta não pôde ser lida ou o teto estourou no meio dela. Links e junções nunca são seguidos nem somados (Review Focus 5); um link no primeiro nível aparece com `bytes:0` e não entra na soma.
  - `arquivos`: os 20 maiores arquivos de toda a árvore percorrida, do maior para o menor.
  - `incompleto:true` quando o teto estourou; as pastas não alcançadas vêm com `bytes:-1, parcial:true`.
  - "Um nível abaixo ao clicar" = nova chamada com `raiz` = a pasta clicada.
- Rust: comando novo `abrir_pasta(caminho)` em `bandeja.rs`: só caminho absoluto `^[A-Za-z]:\\`, sem aspas nem caracteres de controle, que existe, é pasta e não tem link/junção em nenhum ancestral; abre com `<Windows>\explorer.exe "<caminho>"` como `abrir_url`. No demo devolve `Ok`. Para um arquivo a interface abre a pasta que o contém.

### programas/restosAntigos (só leitura; limpar usa `limparRestos`)
- `programas/restosAntigos {}` → `{ itens: [{ tipo: 'pasta'|'atalho', caminho, nome, bytes, seguro, motivo }] }`.
  - Pastas do primeiro nível de `%ProgramFiles%`, `%ProgramFiles(x86)%`, `%ProgramData%`, `%APPDATA%`, `%LOCALAPPDATA%` (e o segundo nível quando o primeiro é a pasta de um editor de programa instalado) que não pertencem a nenhum programa instalado; atalhos `.lnk` quebrados do Menu Iniciar (usuário e todos).
  - Nunca aparece: caminho protegido (`Test-ProtectedPath`), link/junção (na pasta, na cadeia ou na árvore), pasta com executável (`.exe/.dll/.sys`) alterado há menos de 30 dias, nome de `protegidos.json`, pastas do Windows/Microsoft conhecidas (lista no script).
  - `seguro:true` só quando o nome limpo (sem versão, arquitetura, parênteses, sufixos como `x64`, `Inc`) não casa com nenhum programa instalado (nome ou editor, nos dois sentidos de "contém") nem com `protegidos.json` (Review Focus 4: "Adobe" × "Adobe Acrobat" → `seguro:false`). `motivo` explica em pt-BR.
  - `bytes` pelo `Get-TamanhoComTeto` (teto 10 s por pasta). Em modo teste as raízes ficam em `%TEMP%\NexTuneTeste\restosAntigos\{ProgramFiles,ProgramFilesX86,ProgramData,AppData,LocalAppData,Menu}` e os instalados vêm do Uninstall falso já usado pelos testes de `programas`.
- Interface: seção "Restos de programas antigos" em Programas; os itens marcados vão por `programas/limparRestos { itens:[{tipo, caminho}], confirmado:true, nome:'Restos antigos' }`; só os `seguro:true` vêm marcados.

### drivers
- `drivers/listar {}` → `{ dispositivos: [{ id, nome, classe, codigo, explicacao, critico }] }`: dispositivos com `ConfigManagerErrorCode` diferente de 0 e de 22; `id` = `PNPDeviceID`; `explicacao` em pt-BR por código (tabela no script; código desconhecido tem texto genérico com o número); `critico` = classe que nunca é reinstalada (`DiskDrive`, `HDC`, `SCSIAdapter`, `Display`, `System`, `Processor`, `Computer`, `Volume`, `VolumeSnapshot`, `Keyboard`, `Mouse`, `HIDClass`, `USB`, e `Net` quando é o único adaptador ativo).
- `drivers/backup { confirmado }` → `{ pasta, quantidade, codigo }`: `<System32>\pnputil.exe /export-driver * <ProgramData\NexTune\Drivers\AAAAMMDD-HHMMSS>`; `quantidade` = pastas com `.inf` exportadas.
- `drivers/reparar { id, confirmado }` → `{ resolvido, passos: [{ passo: 'reiniciar'|'reinstalar'|'procurar', ok, codigoDepois }], precisaReiniciar }`. O `id` é resolvido contra a lista de `listar` (nunca usado sem estar nela). Ordem: desligar e ligar (`Disable-PnpDevice`/`Enable-PnpDevice`); reinstalar (`pnputil /remove-device` + `/scan-devices`) só quando `critico:false`; procurar hardware (`pnputil /scan-devices`). Para no primeiro passo após o qual `ConfigManagerErrorCode` vira 0.
- Escrita: `backup` e `reparar` (sessão verificada; a interface roda `garantirPonto()` antes de `reparar`).

### rede
- `rede/estado {}` → `{ adaptadores: [{ indice, nome, descricao, dns: [ip], automatico }], provedor: 'cloudflare'|'google'|'quad9'|'automatico'|'outro', dohDisponivel, temBackup }`. Adaptadores físicos ativos; `dohDisponivel` = Windows 11 (build ≥ 22000).
- `rede/limparDns {}` → `{ ok }` (`<System32>\ipconfig.exe /flushdns`).
- `rede/redefinir { confirmado }` → `{ precisaReiniciar: true, detalhe }` (`netsh winsock reset` e `netsh int ip reset`, por caminho absoluto).
- `rede/dnsSeguro { provedor, confirmado }` → `{ adaptadores: [{ indice, nome, ok, erro }], provedor }`. `provedor` ∈ `cloudflare|google|quad9|automatico`. Antes da primeira troca grava `%ProgramData%\NexTune\Backups\dns.json` com os servidores de cada adaptador (e se vinham do DHCP); trocas seguintes não sobrescrevem esse backup. `automatico` restaura exatamente o backup (servidores fixos ou DHCP) e remove os modelos DoH que o NexTune adicionou; sem backup, volta ao DHCP. Servidores IPv4/IPv6 de cada provedor e os modelos DoH vêm do Sophia Script (MIT, farag2). Windows 10 recusa os três provedores com mensagem clara ("DNS seguro precisa do Windows 11"); `automatico` funciona nos dois.
- Escrita: `limparDns`, `redefinir`, `dnsSeguro` (sessão verificada). A interface roda `garantirPonto()` antes de `redefinir` e `dnsSeguro`, não antes de `limparDns`.

### Interface
Três telas novas no menu, depois de Reparo: **Espaço**, **Dispositivos** (drivers) e **Rede**; restos antigos dentro de Programas. Toda escrita com `.acao .escrita`, confirmação dizendo o que vai acontecer e como desfazer, erros por `mostrarErroEscrita`, textos em `pt-BR.js`, demo completo.

---

### Tarefa 1: privacidade por registro (dados do Sophia)

**Files:** Modify `data/ajustes.json`, `scripts/tests/ajusteswin.Tests.ps1`.

Ajustes novos no grupo de privacidade (formato do catálogo atual: `chaves [{chave, nome, tipo, aplicar}]`):
- `feedback_frequencia`: `HKCU\Software\Microsoft\Siuf\Rules` `NumberOfSIUFInPeriod` DWord 0.
- `idioma_sites`: `HKCU\Control Panel\International\User Profile` `HttpAcceptLanguageOptOut` DWord 1.
- `novidades_windows`: `HKCU\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement` `ScoobeSystemSettingEnabled` DWord 0.
- `sugestoes_pesquisa_web`: `HKCU\Software\Policies\Microsoft\Windows\Explorer` `DisableSearchBoxSuggestions` DWord 1, `politica: true`.

- [x] **Passo 1:** teste: os 4 ids aparecem em `listar`; aplicar e restaurar cada um em modo teste devolve o valor anterior exato (inclusive "não existia").
- [x] **Passo 2:** ver falhar; **Passo 3:** acrescentar ao catálogo; **Passo 4:** ver passar; **Passo 5:** commit.

### Tarefa 2: serviços e tarefas de telemetria (ajusteswin)

**Files:** Modify `scripts/ajusteswin.ps1`, `data/ajustes.json`, testes.

**Interfaces:** o catálogo aceita, além de `chaves`, `servicos: [{nome, inicio: 'Disabled'}]` e `tarefas: [{caminho, nome}]`. O backup guarda `StartType` e se estava rodando (serviço) e `Enabled` (tarefa); restaurar devolve exatamente isso. Em modo teste, `simular.servicos` e `simular.tarefas` substituem o sistema e as escritas viram marcadores.

Ajustes novos:
- `servico_telemetria`: serviço `DiagTrack` desligado.
- `relatorio_erros`: serviço `WerSvc` desligado e tarefa `\Microsoft\Windows\Windows Error Reporting\QueueReporting` desativada.
- `tarefas_telemetria`: as tarefas da lista do Sophia (`MareBackup`, `Microsoft Compatibility Appraiser`, `Microsoft Compatibility Appraiser Exp`, `StartupAppTask`, `Proxy`, `Consolidator`, `UsbCeip`, `Microsoft-Windows-DiskDiagnosticDataCollector`, `MapsToastTask`, `MapsUpdateTask`), resolvidas por nome sob `\Microsoft\Windows\`.

- [x] **Passo 1:** testes: `restaurar devolve o tipo de inicio anterior` (serviço que já era `Manual` volta `Manual`); tarefa inexistente vira `naoAplica` e o resto segue; `listar` mostra o estado atual de cada serviço/tarefa.
- [x] **Passo 2:** ver falhar; **Passo 3:** implementar; **Passo 4:** ver passar; **Passo 5:** commit.

### Tarefa 3: por que o PC reiniciou (porta de `reinicios.ps1`)

**Files:** Modify `scripts/diagnostico.ps1` (ação `reinicios`), `src-tauri/src/acoes.rs`, `ui/js/vistas/diagnostico.js`, `ui/i18n/pt-BR.js`, testes.

**Produces:** `diagnostico/reinicios -> { eventos: [{ data, tipo: 'desligamento'|'reinicio'|'queda'|'telaAzul', quem, motivo, codigo? }] }`, últimos 30 dias, no máximo 50. Tabela de telas azuis traduzida (os 14 códigos do RetroLimpia). Só leitura.

- [x] **Passo 1:** testes com `simular.eventos` (41, 1074 com usuário e motivo, 6008, 1001 com código `0x00000116`): cada um vira o tipo certo e a frase certa; código desconhecido vira "Tela azul (código X)".
- [x] **Passo 2:** ver falhar; **Passo 3:** portar; **Passo 4:** ver passar; **Passo 5:** commit.

### Tarefa 4: saúde do Windows (DISM + SFC)

**Files:** Create `scripts/saude.ps1`, `scripts/tests/saude.Tests.ps1`; Modify `acoes.rs`, `host.ps1`, UI (seção no Disco ou tela própria "Saúde").

**Produces:** `saude/verificar -> { estado: 'ok'|'reparavel'|'irreparavel', detalhe }` (`DISM /Online /Cleanup-Image /CheckHealth`, rápido, só leitura); `saude/reparar {confirmado}` (`DISM /RestoreHealth` e depois `sfc /scannow`, com progresso, cancelável). Resultado pelos códigos de saída e pela última sessão do `CBS.log` (`[SR] Repairing` / `cannot repair`), nunca pelo texto da tela (Review Focus 3).

- [x] **Passo 1:** testes com saídas gravadas (códigos e trechos de `CBS.log` em inglês e português): `ok`, `reparado`, `nao reparado`; cancelar no meio devolve "cancelado".
- [x] **Passo 2:** ver falhar; **Passo 3:** implementar; **Passo 4:** ver passar; **Passo 5:** commit.

### Tarefa 5: analisador de espaço

**Files:** Create `scripts/espaco.ps1`, testes; Modify `acoes.rs`, `host.ps1`, `src-tauri/src/bandeja.rs` (comando `abrir_pasta`: só pasta existente, absoluta, sem link, aberta pelo `explorer.exe`), UI (tela "Espaço").

**Produces:** `espaco/analisar {raiz}` → `{ pastas: [{caminho, bytes, semAcesso}], arquivos: [{caminho, bytes}] }`: as 20 maiores pastas do primeiro nível (e um nível abaixo ao clicar) e os 20 maiores arquivos, usando o `Get-TamanhoComTeto` que já existe (sem seguir links, com teto de tempo). Só leitura; apagar continua sendo pela Limpeza ou pela quarentena.

- [ ] **Passo 1:** testes com pasta falsa (junction para fora, pasta sem permissão, arquivos grandes): ordem certa, junction não somada, `semAcesso` marcado (Review Focus 5).
- [ ] **Passo 2:** ver falhar; **Passo 3:** implementar; **Passo 4:** ver passar; **Passo 5:** commit.

### Tarefa 6: restos de programas já desinstalados (porta de `residuos.ps1`)

**Files:** Modify `scripts/programas.ps1` (ação `restosAntigos`), testes, `acoes.rs`, UI (Programas).

**Produces:** `programas/restosAntigos -> { itens: [{tipo, caminho, nome, bytes, seguro}] }` em `%ProgramFiles%`, `%ProgramFiles(x86)%`, `%ProgramData%`, `%APPDATA%`, `%LOCALAPPDATA%` e atalhos do menu Iniciar. Regra do RetroLimpia: "seguro" só quando o nome limpo (sem versão, arquitetura e parênteses) não casa com nenhum programa instalado nem com `protegidos.json`. A limpeza reaproveita `limparRestos` (vai para a quarentena).

- [ ] **Passo 1:** testes: pasta de programa removido é achada; pasta de programa ainda instalado com nome parecido não é "segura" (Review Focus 4); pasta protegida nunca aparece.
- [ ] **Passo 2:** ver falhar; **Passo 3:** portar; **Passo 4:** ver passar; **Passo 5:** commit.

### Tarefa 7: dispositivos com problema e backup de drivers (porta de `drivers.ps1`)

**Files:** Create `scripts/drivers.ps1`, testes; Modify `acoes.rs`, `host.ps1`, UI.

**Produces:** `drivers/listar` (dispositivos com `ConfigManagerErrorCode` diferente de 0 e 22, com o código explicado em pt-BR); `drivers/backup {confirmado}` (`pnputil /export-driver * <ProgramData\NexTune\Drivers\AAAAMMDD-HHMMSS>`); `drivers/reparar {id, confirmado}` escalonado como no RetroLimpia (desligar e ligar; reinstalar o driver só para classes não críticas; procurar hardware de novo), parando no primeiro passo que resolve.

- [ ] **Passo 1:** testes com `simular.dispositivos`: lista e textos; `reparar` para no passo que resolve; classe crítica (disco, display do sistema) nunca é reinstalada.
- [ ] **Passo 2:** ver falhar; **Passo 3:** portar; **Passo 4:** ver passar; **Passo 5:** commit.

### Tarefa 8: rede

**Files:** Create `scripts/rede.ps1`, testes; Modify `acoes.rs`, `host.ps1`, UI.

**Produces:** `rede/limparDns` (`ipconfig /flushdns`); `rede/redefinir {confirmado}` (`netsh winsock reset` e `netsh int ip reset`, avisa que precisa reiniciar); `rede/dnsSeguro {provedor: 'cloudflare'|'google'|'quad9'|'automatico', confirmado}` (servidores e DoH por adaptador, com backup dos servidores anteriores e restauração; só no Windows 11, como no Sophia).

- [ ] **Passo 1:** testes com `simular.adaptadores`: backup e restauração exatos dos servidores; Windows 10 recusa DoH com mensagem clara.
- [ ] **Passo 2:** ver falhar; **Passo 3:** implementar; **Passo 4:** ver passar; **Passo 5:** commit.

### Fechamento

- [ ] `tools/ci-local.ps1 -SoTestes` local; push; Actions verde (Rust).
- [ ] Revisão independente (segurança: serviços, drivers, rede).
- [ ] README (ferramentas novas e créditos do Sophia Script), memória do projeto.

**Ordem sugerida:** 1 e 2 (privacidade, mais baratos e com código pronto), 3 (só leitura), 4, 5, 6, 7, 8. Cada tarefa pode virar uma versão (0.1.x) sozinha.
