# NexTune — Plano 7: Explicar falhas de atualização e reparar produtos MSI órfãos

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Quando uma atualização falha, o NexTune diz o motivo em português; quando o motivo é um produto do Windows Installer sem a cópia local do `.msi` e sem origem acessível (caso real: Visual C++ 2019 instalado do drive `W:`), ele mostra o produto quebrado e remove só o registro dele, com backup e restauração.

**Architecture:** Um módulo novo `reparo` (PowerShell + Rust) com duas ações, `diagnosticar` (só leitura) e `reparar` (escrita, com backup `.reg` na quarentena). Funções puras (código de erro do winget para frase, GUID para forma compactada, "é órfão?") ficam testáveis em Pester. O módulo `atualizacoes` passa a traduzir os códigos do winget e a apontar para a tela Reparo.

**Tech Stack:** PowerShell 5.1 + Pester 6, Rust (validação em `acoes.rs`), JS vanilla (`ui/js/vistas/reparo.js`), pt-BR.

**Spec:** `docs/superpowers/specs/2026-11-20-otimizador-design.md` (seções 8.3 programas, 8.7 atualizações, 9 segurança). Referência de lógica: [Unregister-MissingMSIs.ps1](https://gist.github.com/BrentHumphreys/111ac670e577a94bf1531cc4d9a9d8a0) (MIT, fork de heaths), reescrito sem o módulo `MSI` da internet.

## Global Constraints

- pt-BR em todo texto visível; `.ps1` em UTF-8 com BOM e CRLF; PSScriptAnalyzer sem avisos; sem rede a partir do app.
- Toda escrita: ponto de restauração antes (`garantirPonto`), backup `.reg` na quarentena, log em `%ProgramData%\NexTune\Logs`, confirmação explícita, restauração por um clique (`quarentena/restaurar`).
- `reparar` só remove **registro** do Windows Installer; nunca apaga arquivos de programas nem de `C:\Windows\Installer`.
- Escopo do reparo: produtos de máquina (`S-1-5-18`) cuja cópia local (`LocalPackage`) não existe **e** cujas origens registradas não têm o `.msi`. Nunca o NexTune, WebView2 e Edge (`data/reparo.json`).

## Review Focus

1. Produto com cópia local ausente mas origem acessível (pendrive plugado): não é órfão. Teste `origem acessivel salva o produto`.
2. `LocalPackage` vazio ou sem valor: órfão só se as origens também falham; não pode lançar exceção.
3. GUID inválido vindo da UI ou do registro: recusado antes de montar qualquer caminho de chave (teste `guid invalido e recusado`).
4. Backup falha no meio: nada é removido daquele produto (teste `falha no backup nao remove`).
5. Winget com código desconhecido: mensagem genérica com o código em hexadecimal, nunca texto vazio.

---

### Tarefa 1: funções puras (`scripts/reparo.ps1`)

**Files:** Create `scripts/reparo.ps1`, `scripts/tests/reparo.Tests.ps1`

**Interfaces — Produces:**
- `Get-MensagemWinget([int64]$Codigo) -> string`: frase em pt-BR para os códigos `0x8A15010C`, `0x8A150110`, `0x8A150101`, `0x8A150103`, `0x8A150102`, `0x8A150105`, `0x8A150107`, `0x8A15010D`, `0x8A15010E`, `0x8A15010F`, `0x8A150109`, `0x8A15010A`, `0x8A150108`; desconhecido -> `winget terminou com código 0x........`.
- `ConvertTo-GuidCompactado([string]$Guid) -> string`: forma do Windows Installer (primeiros 3 grupos invertidos, resto com nibbles trocados); recusa o que não for `{8-4-4-4-12}` hexadecimal.
- `Test-ProdutoOrfao($Produto) -> bool`: `$Produto = @{ localPackage; packageName; origens = @() }`; verdadeiro só se `localPackage` não existe e nenhuma `origem\packageName` existe.

- [ ] **Passo 1:** testes `Get-MensagemWinget` (código conhecido, desconhecido, negativo como int32), `ConvertTo-GuidCompactado` (`{E5281CF4-57AC-41C9-8034-00F8428B8951}` -> `4CFC1E5E...` calculado à mão no teste; `'nao-guid'` lança), `Test-ProdutoOrfao` (4 casos: existe, ausente+origem acessível, ausente+sem origem, `localPackage` vazio).
- [ ] **Passo 2:** rodar e ver falhar.
- [ ] **Passo 3:** implementar as três funções (tabela em `$Script:MensagensWinget`).
- [ ] **Passo 4:** rodar e ver passar; PSSA 0.
- [ ] **Passo 5:** commit `feat(reparo): funções puras (mensagens do winget, GUID compactado, produto órfão)`.

### Tarefa 2: `diagnosticar` (só leitura) + validação Rust

**Files:** Modify `scripts/reparo.ps1`, `scripts/host.ps1` (allowlist), `src-tauri/src/acoes.rs` (módulo `reparo`, ação `diagnosticar` sem parâmetros além de `simular`), testes Pester e Rust; Create `data/reparo.json` (`naoReparar`: lista de `{padrao, motivo}`).

**Interfaces — Produces:** `reparo/diagnosticar -> { produtos: [{ codigo, nome, versao, editor, localPackage, origens: [], orfao: bool, reparavel: bool, motivo }] }`, só os órfãos mais, no máximo, 200; leitura de `HKLM:\SOFTWARE\Classes\Installer\Products` (nome em `ProductName`, `PackageName` em `SourceList`, origens em `SourceList\Net`) e `...\UserData\S-1-5-18\Products\<P>\InstallProperties` (`LocalPackage`, `DisplayVersion`, `Publisher`). Em `-Teste`, `simular.produtos` substitui a leitura.

- [ ] **Passo 1:** testes: lista simulada com 1 órfão reparável, 1 órfão não reparável (WebView2), 1 saudável -> só os 2 órfãos voltam, com `reparavel` certo; `acoes.rs`: `reparo/diagnosticar` aceita `{}` e `{simular}`, recusa chave estranha.
- [ ] **Passo 2:** ver falhar; **Passo 3:** implementar leitura real + simulada + `Invoke-Acao`; registrar `reparo` em `MODULOS` e na allowlist do `host.ps1`.
- [ ] **Passo 4:** ver passar (Pester local; Rust no Actions). **Passo 5:** commit.

### Tarefa 3: `reparar` (escrita com backup)

**Files:** Modify `scripts/reparo.ps1`, `src-tauri/src/acoes.rs` (`ESCRITA += ("reparo","reparar")`, parâmetros `{ ids: [guid], confirmado }`, máx. 20), testes.

**Interfaces — Consumes:** `New-EntradaQuarentena`, `Add-ItemQuarentena -Tipo chave`, `Complete-EntradaQuarentena` (quarentena.ps1). **Produces:** `reparo/reparar -> { reparados: [codigo], falhas: [{id, erro}], entrada: <id da quarentena> }`.

Chaves de cada produto (`<P>` compactado, `<G>` com chaves): `HKLM\SOFTWARE\Classes\Installer\Products\<P>`, `...\Features\<P>`, `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\<P>`, `...\Uninstall\<G>` e a do `WOW6432Node`. Cada uma é exportada para `.reg` pela quarentena e só então removida. **Ruling:** `UpgradeCodes` e `Components` não são tocados nesta versão (exigiriam backup de valores que a quarentena não restaura); se o teste real mostrar que falta, vira tarefa nova.

- [ ] **Passo 1:** testes em modo teste (chaves sob `HKCU:\Software\NexTuneTeste\Reparo\...`): reparar remove as chaves e deixa o backup restaurável por `quarentena/restaurar`; `guid invalido e recusado`; `falha no backup nao remove`; sem `confirmado` recusa; produto que passou a não ser órfão entre listar e reparar é recusado ("já não está quebrado").
- [ ] **Passo 2:** ver falhar; **Passo 3:** implementar (relê o diagnóstico na hora, não confia na UI); **Passo 4:** ver passar; **Passo 5:** commit.

### Tarefa 4: atualizações explicam o erro

**Files:** Modify `scripts/atualizacoes.ps1` (usa `Get-MensagemWinget`), `scripts/tests/atualizacoes.Tests.ps1`, `ui/i18n/pt-BR.js`, `ui/js/vistas/atualizacoes.js`.

- [ ] **Passo 1:** teste: `atualizarProgramas` com `simular` de código `0x8A150110` devolve `falhas[0].erro` com a frase de dependência e `falhas[0].codigo = '0x8A150110'`; código `0x8A15010C` sugere fechar o programa; resto genérico.
- [ ] **Passo 2:** ver falhar; **Passo 3:** trocar o `throw` por mensagem traduzida + campo `codigo`; a UI mostra um botão "Ver reparo" quando o código é `0x8A150110`.
- [ ] **Passo 4:** passar; **Passo 5:** commit.

### Tarefa 5: tela Reparo, demo, README

**Files:** Create `ui/js/vistas/reparo.js`; Modify `ui/index.html`, `ui/js/*` (menu, demo, api), `ui/i18n/pt-BR.js`, `README.md`.

- [ ] **Passo 1:** tela com "Procurar problemas" (diagnosticar), lista com nome/versão/motivo, caixa por item, botão "Reparar selecionados" com texto: o que será removido (só o registro), que o programa em si não é apagado, e que dá para desfazer em Quarentena; usa `garantirPonto()` e `mostrarErroEscrita`.
- [ ] **Passo 2:** modo demo com dois produtos; verificar no navegador (Playwright) a tela e o erro de i18n com `check-ui.js`.
- [ ] **Passo 3:** README ("Reparo do instalador") e commit.

### Fechamento e aceitação

- [ ] `tools/ci-local.ps1 -SoTestes` local; push; run verde no Actions (Rust).
- [ ] Revisão independente (segurança do registro).
- [ ] **Aceitação no PC do usuário:** instalar a versão nova, Reparo lista as duas peças do Visual C++ 2019 x64 (14.28.29213) sem a cópia local, reparar, depois `winget install Microsoft.VCRedist.2015+.x64` e `winget upgrade TheDocumentFoundation.LibreOffice` funcionam; restaurar pela quarentena devolve as chaves.
