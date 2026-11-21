# NexTune — Plano 8: Privacidade ampliada, saúde do Windows e ferramentas que faltam

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

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

---

### Tarefa 1: privacidade por registro (dados do Sophia)

**Files:** Modify `data/ajustes.json`, `scripts/tests/ajusteswin.Tests.ps1`.

Ajustes novos no grupo de privacidade (formato do catálogo atual: `chaves [{chave, nome, tipo, aplicar}]`):
- `feedback_frequencia`: `HKCU\Software\Microsoft\Siuf\Rules` `NumberOfSIUFInPeriod` DWord 0.
- `idioma_sites`: `HKCU\Control Panel\International\User Profile` `HttpAcceptLanguageOptOut` DWord 1.
- `novidades_windows`: `HKCU\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement` `ScoobeSystemSettingEnabled` DWord 0.
- `sugestoes_pesquisa_web`: `HKCU\Software\Policies\Microsoft\Windows\Explorer` `DisableSearchBoxSuggestions` DWord 1, `politica: true`.

- [ ] **Passo 1:** teste: os 4 ids aparecem em `listar`; aplicar e restaurar cada um em modo teste devolve o valor anterior exato (inclusive "não existia").
- [ ] **Passo 2:** ver falhar; **Passo 3:** acrescentar ao catálogo; **Passo 4:** ver passar; **Passo 5:** commit.

### Tarefa 2: serviços e tarefas de telemetria (ajusteswin)

**Files:** Modify `scripts/ajusteswin.ps1`, `data/ajustes.json`, testes.

**Interfaces:** o catálogo aceita, além de `chaves`, `servicos: [{nome, inicio: 'Disabled'}]` e `tarefas: [{caminho, nome}]`. O backup guarda `StartType` e se estava rodando (serviço) e `Enabled` (tarefa); restaurar devolve exatamente isso. Em modo teste, `simular.servicos` e `simular.tarefas` substituem o sistema e as escritas viram marcadores.

Ajustes novos:
- `servico_telemetria`: serviço `DiagTrack` desligado.
- `relatorio_erros`: serviço `WerSvc` desligado e tarefa `\Microsoft\Windows\Windows Error Reporting\QueueReporting` desativada.
- `tarefas_telemetria`: as tarefas da lista do Sophia (`MareBackup`, `Microsoft Compatibility Appraiser`, `Microsoft Compatibility Appraiser Exp`, `StartupAppTask`, `Proxy`, `Consolidator`, `UsbCeip`, `Microsoft-Windows-DiskDiagnosticDataCollector`, `MapsToastTask`, `MapsUpdateTask`), resolvidas por nome sob `\Microsoft\Windows\`.

- [ ] **Passo 1:** testes: `restaurar devolve o tipo de inicio anterior` (serviço que já era `Manual` volta `Manual`); tarefa inexistente vira `naoAplica` e o resto segue; `listar` mostra o estado atual de cada serviço/tarefa.
- [ ] **Passo 2:** ver falhar; **Passo 3:** implementar; **Passo 4:** ver passar; **Passo 5:** commit.

### Tarefa 3: por que o PC reiniciou (porta de `reinicios.ps1`)

**Files:** Modify `scripts/diagnostico.ps1` (ação `reinicios`), `src-tauri/src/acoes.rs`, `ui/js/vistas/diagnostico.js`, `ui/i18n/pt-BR.js`, testes.

**Produces:** `diagnostico/reinicios -> { eventos: [{ data, tipo: 'desligamento'|'reinicio'|'queda'|'telaAzul', quem, motivo, codigo? }] }`, últimos 30 dias, no máximo 50. Tabela de telas azuis traduzida (os 14 códigos do RetroLimpia). Só leitura.

- [ ] **Passo 1:** testes com `simular.eventos` (41, 1074 com usuário e motivo, 6008, 1001 com código `0x00000116`): cada um vira o tipo certo e a frase certa; código desconhecido vira "Tela azul (código X)".
- [ ] **Passo 2:** ver falhar; **Passo 3:** portar; **Passo 4:** ver passar; **Passo 5:** commit.

### Tarefa 4: saúde do Windows (DISM + SFC)

**Files:** Create `scripts/saude.ps1`, `scripts/tests/saude.Tests.ps1`; Modify `acoes.rs`, `host.ps1`, UI (seção no Disco ou tela própria "Saúde").

**Produces:** `saude/verificar -> { estado: 'ok'|'reparavel'|'irreparavel', detalhe }` (`DISM /Online /Cleanup-Image /CheckHealth`, rápido, só leitura); `saude/reparar {confirmado}` (`DISM /RestoreHealth` e depois `sfc /scannow`, com progresso, cancelável). Resultado pelos códigos de saída e pela última sessão do `CBS.log` (`[SR] Repairing` / `cannot repair`), nunca pelo texto da tela (Review Focus 3).

- [ ] **Passo 1:** testes com saídas gravadas (códigos e trechos de `CBS.log` em inglês e português): `ok`, `reparado`, `nao reparado`; cancelar no meio devolve "cancelado".
- [ ] **Passo 2:** ver falhar; **Passo 3:** implementar; **Passo 4:** ver passar; **Passo 5:** commit.

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
