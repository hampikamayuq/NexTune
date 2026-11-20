//! Gerente do processo PowerShell persistente (`scripts/host.ps1`).
//!
//! Um único processo atende todos os comandos; uma tarefa lê o stdout e roteia cada mensagem
//! pelo `id` para quem está esperando. Os ids são monotônicos e nunca reaproveitados durante a
//! vida do gerente (o host guarda os ids já finalizados e suprimiria um resultado repetido).

use crate::acoes::{self, ErroValidacao};
use crate::protocolo::{Mensagem, comando_json, parse_linha};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex, MutexGuard as StdGuard, Weak};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::{Mutex, oneshot};

#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const ESPERA_CANCELAR: Duration = Duration::from_secs(5);
/// Depois de um cancelamento confirmado, quanto esperar o host ficar ocioso (os `finally` das
/// ações religam serviços e restauram o registro) antes de matar o processo.
const ESPERA_OCIOSO: Duration = Duration::from_secs(10);
/// O host espera até 10 s pelos `finally` antes de sair; damos uma folga antes de matar.
const ESPERA_SAIR: Duration = Duration::from_secs(12);

/// `powershell.exe` por caminho absoluto em System32 (nunca pela busca do PATH).
#[cfg(windows)]
fn caminho_powershell() -> PathBuf {
    use windows_sys::Win32::System::SystemInformation::GetSystemDirectoryW;
    let mut buf = [0u16; 260];
    // SAFETY: `buf` é válido e o tamanho passado é o do buffer.
    let n = unsafe { GetSystemDirectoryW(buf.as_mut_ptr(), buf.len() as u32) } as usize;
    let sistema = if n > 0 && n < buf.len() {
        PathBuf::from(String::from_utf16_lossy(&buf[..n]))
    } else {
        let raiz = std::env::var("SystemRoot").unwrap_or_else(|_| r"C:\Windows".into());
        PathBuf::from(raiz).join("System32")
    };
    sistema
        .join("WindowsPowerShell")
        .join("v1.0")
        .join("powershell.exe")
}

#[cfg(not(windows))]
fn caminho_powershell() -> PathBuf {
    PathBuf::from("powershell.exe")
}

/// Mensagem de progresso/log de uma ação em curso.
#[derive(Debug, Clone, PartialEq)]
pub struct Evento {
    pub id: String,
    pub mensagem: Mensagem,
}

#[derive(thiserror::Error, Debug)]
pub enum ErroHost {
    #[error("{0}")]
    Validacao(#[from] ErroValidacao),
    #[error("host não respondeu")]
    Timeout,
    #[error("{0}")]
    Acao(String),
    #[error("cancelado")]
    Cancelado,
    #[error("falha ao iniciar powershell: {0}")]
    Spawn(String),
}

type Resposta = Result<Value, ErroHost>;
type Callback = Arc<StdMutex<Box<dyn Fn(Evento) + Send>>>;

struct Pendente {
    tx: oneshot::Sender<Resposta>,
    progresso: Callback,
}

#[derive(Default)]
struct Proc {
    child: Option<Child>,
    stdin: Option<ChildStdin>,
    pid: Option<u32>,
    geracao: u64,
}

struct Interno {
    script: PathBuf,
    prioridade_baixa: bool,
    ocioso_segundos: u32,
    allowlist_extra: Vec<String>,
    contador: AtomicU64,
    proc: Mutex<Proc>,
    pendentes: StdMutex<HashMap<String, Pendente>>,
}

pub struct HostPowerShell {
    interno: Arc<Interno>,
}

#[cfg(windows)]
fn baixar_prioridade(child: &Child) {
    use windows_sys::Win32::System::Threading::{BELOW_NORMAL_PRIORITY_CLASS, SetPriorityClass};
    if let Some(h) = child.raw_handle() {
        // SAFETY: `h` é o handle válido do processo filho, mantido vivo por `child`.
        unsafe {
            SetPriorityClass(h, BELOW_NORMAL_PRIORITY_CLASS);
        }
    }
}

#[cfg(not(windows))]
fn baixar_prioridade(_child: &Child) {}

impl Interno {
    fn pendentes(&self) -> StdGuard<'_, HashMap<String, Pendente>> {
        self.pendentes.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn proximo_id(&self) -> String {
        format!("{:x}", self.contador.fetch_add(1, Ordering::SeqCst) + 1)
    }

    /// Resolve todos os pendentes com `Timeout` (o processo morreu ou foi encerrado).
    fn falhar_todos(&self) {
        let todos = std::mem::take(&mut *self.pendentes());
        for (_, p) in todos {
            let _ = p.tx.send(Err(ErroHost::Timeout));
        }
    }

    fn rotear(&self, m: Mensagem) {
        match &m {
            Mensagem::Progresso { id, .. } | Mensagem::Log { id, .. } => {
                let id = id.clone();
                // Clona o callback e solta o lock do mapa antes de chamar (o callback pode bloquear).
                let cb = self.pendentes().get(&id).map(|p| p.progresso.clone());
                if let Some(cb) = cb {
                    let f = cb.lock().unwrap_or_else(|e| e.into_inner());
                    f(Evento { id, mensagem: m });
                }
            }
            Mensagem::Resultado {
                id,
                ok,
                dados,
                erro,
            } => {
                let Some(p) = self.pendentes().remove(id) else {
                    #[cfg(debug_assertions)]
                    eprintln!("host: resultado de id desconhecido: {id}");
                    return;
                };
                let r = if *ok {
                    Ok(dados.clone())
                } else if erro == "cancelado" {
                    Err(ErroHost::Cancelado)
                } else {
                    Err(ErroHost::Acao(erro.clone()))
                };
                let _ = p.tx.send(r);
            }
        }
    }

    fn iniciar(self: &Arc<Self>, proc: &mut Proc) -> Result<(), ErroHost> {
        let mut cmd = Command::new(caminho_powershell());
        cmd.args([
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-WindowStyle",
            "Hidden",
            "-File",
        ])
        .arg(&self.script)
        .arg("-OciosoSegundos")
        .arg(self.ocioso_segundos.to_string());
        if !self.allowlist_extra.is_empty() {
            cmd.arg("-AllowlistExtra").args(&self.allowlist_extra);
        }
        cmd.stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        #[cfg(windows)]
        cmd.creation_flags(CREATE_NO_WINDOW);
        let mut child = cmd.spawn().map_err(|e| ErroHost::Spawn(e.to_string()))?;
        let (Some(stdin), Some(stdout)) = (child.stdin.take(), child.stdout.take()) else {
            return Err(ErroHost::Spawn("stdio indisponível".into()));
        };
        if self.prioridade_baixa {
            baixar_prioridade(&child);
        }
        proc.geracao += 1;
        proc.pid = child.id();
        proc.stdin = Some(stdin);
        proc.child = Some(child);
        tokio::spawn(ler(Arc::downgrade(self), stdout, proc.geracao));
        Ok(())
    }

    /// Mata o processo (se houver) e falha todos os pendentes.
    async fn matar(&self, proc: &mut Proc) {
        if let Some(mut c) = proc.child.take() {
            let _ = c.kill().await;
        }
        proc.pid = None;
        proc.stdin = None;
        self.falhar_todos();
    }

    async fn escrever(&self, proc: &mut Proc, linha: &str) -> Result<(), ErroHost> {
        let Some(stdin) = proc.stdin.as_mut() else {
            return Err(ErroHost::Timeout);
        };
        let r = async {
            stdin.write_all(linha.as_bytes()).await?;
            stdin.write_all(b"\n").await?;
            stdin.flush().await
        }
        .await;
        if r.is_err() {
            self.matar(proc).await;
            return Err(ErroHost::Timeout);
        }
        Ok(())
    }

    /// Registra o pendente e envia o comando. `iniciar_se_preciso = false` não relança o host.
    async fn enviar(
        self: &Arc<Self>,
        (modulo, acao, params, teste): (&str, &str, &Value, bool),
        progresso: Box<dyn Fn(Evento) + Send>,
        iniciar_se_preciso: bool,
    ) -> Result<(String, oneshot::Receiver<Resposta>), ErroHost> {
        let id = self.proximo_id();
        let (tx, rx) = oneshot::channel();
        let mut proc = self.proc.lock().await;
        if proc.pid.is_none() {
            if !iniciar_se_preciso {
                return Err(ErroHost::Timeout);
            }
            self.iniciar(&mut proc)?;
        }
        self.pendentes().insert(
            id.clone(),
            Pendente {
                tx,
                progresso: Arc::new(StdMutex::new(progresso)),
            },
        );
        let linha = comando_json(&id, modulo, acao, params, teste);
        if let Err(e) = self.escrever(&mut proc, &linha).await {
            self.pendentes().remove(&id);
            return Err(e);
        }
        Ok((id, rx))
    }

    /// O stdout terminou: se este ainda é o processo atual, marca como morto e falha os pendentes.
    async fn processo_encerrou(&self, geracao: u64) {
        let mut proc = self.proc.lock().await;
        if proc.geracao != geracao || proc.pid.is_none() {
            return;
        }
        proc.pid = None;
        proc.stdin = None;
        if let Some(mut c) = proc.child.take()
            && tokio::time::timeout(Duration::from_secs(2), c.wait())
                .await
                .is_err()
        {
            let _ = c.kill().await;
        }
        self.falhar_todos();
    }
}

async fn ler(fraco: Weak<Interno>, stdout: ChildStdout, geracao: u64) {
    let mut linhas = BufReader::new(stdout).lines();
    while let Ok(Some(linha)) = linhas.next_line().await {
        let Some(i) = fraco.upgrade() else { return };
        if let Some(m) = parse_linha(&linha) {
            i.rotear(m);
        }
    }
    if let Some(i) = fraco.upgrade() {
        i.processo_encerrou(geracao).await;
    }
}

impl HostPowerShell {
    /// Não inicia o processo. `allowlist_extra` são módulos extras do host (apenas testes;
    /// produção passa `vec![]`) e dispensam a validação de `acoes`.
    pub fn novo(
        script: PathBuf,
        prioridade_baixa: bool,
        ocioso_segundos: u32,
        allowlist_extra: Vec<String>,
    ) -> Self {
        // Nomes que colidem com módulos reais ou com "host" são descartados: um extra nunca
        // pode desligar a validação de um módulo de produção.
        let allowlist_extra = allowlist_extra
            .into_iter()
            .filter(|m| m != "host" && !acoes::modulos_permitidos().contains(&m.as_str()))
            .collect();
        Self {
            interno: Arc::new(Interno {
                script,
                prioridade_baixa,
                ocioso_segundos,
                allowlist_extra,
                contador: AtomicU64::new(0),
                proc: Mutex::new(Proc::default()),
                pendentes: StdMutex::new(HashMap::new()),
            }),
        }
    }

    /// Prioridade baixa configurada para o processo.
    pub fn prioridade_baixa(&self) -> bool {
        self.interno.prioridade_baixa
    }

    /// PID do processo vivo, se houver.
    pub async fn pid(&self) -> Option<u32> {
        self.interno.proc.lock().await.pid
    }

    pub async fn executar(
        &self,
        modulo: &str,
        acao: &str,
        params: Value,
        teste: bool,
        progresso: impl Fn(Evento) + Send + 'static,
    ) -> Result<Value, ErroHost> {
        let params = if self.interno.allowlist_extra.iter().any(|m| m == modulo) {
            match params {
                Value::Null => json!({}),
                p @ Value::Object(_) => p,
                _ => {
                    return Err(ErroValidacao::Parametro("params deve ser um objeto".into()).into());
                }
            }
        } else {
            acoes::validar(modulo, acao, &params, teste)?
        };
        let (_, rx) = self
            .interno
            .enviar((modulo, acao, &params, teste), Box::new(progresso), true)
            .await?;
        rx.await.unwrap_or(Err(ErroHost::Timeout))
    }

    /// Pede o cancelamento de `id`; sem confirmação em 5 s, mata o processo.
    pub async fn cancelar(&self, id: &str) -> Result<(), ErroHost> {
        let i = &self.interno;
        if !i.pendentes().contains_key(id) {
            return Ok(());
        }
        let params = json!({ "alvo": id });
        let Ok((cid, mut rx)) = i
            .enviar(
                ("host", "cancelar", &params, false),
                Box::new(|_| {}),
                false,
            )
            .await
        else {
            return Ok(());
        };
        let esperar = async {
            loop {
                tokio::select! {
                    _ = &mut rx => break,
                    _ = tokio::time::sleep(Duration::from_millis(25)) => {
                        if !i.pendentes().contains_key(id) {
                            break;
                        }
                    }
                }
            }
        };
        if tokio::time::timeout(ESPERA_CANCELAR, esperar)
            .await
            .is_err()
        {
            let mut proc = i.proc.lock().await;
            i.matar(&mut proc).await;
        }
        i.pendentes().remove(&cid);
        Ok(())
    }

    /// Cancela todos os pendentes e espera (até `ESPERA_OCIOSO`) o host ficar ocioso, para os
    /// `finally` das ações rodarem (religar serviços, restaurar o registro). Só mata o processo
    /// se ele não ficar ocioso a tempo; ocioso, o host continua vivo para a próxima ação.
    pub async fn cancelar_tudo(&self) {
        self.cancelar_tudo_com(ESPERA_OCIOSO).await;
    }

    async fn cancelar_tudo_com(&self, limite: Duration) {
        let ids: Vec<String> = self.interno.pendentes().keys().cloned().collect();
        for id in ids {
            let _ = self.cancelar(&id).await;
        }
        if !self.esperar_ocioso(limite).await {
            let mut proc = self.interno.proc.lock().await;
            self.interno.matar(&mut proc).await;
        }
    }

    /// Faz `host/ping` até `dados.ocioso == true` ou estourar `limite`. Sem processo vivo, já está
    /// ocioso. Não relança o host.
    async fn esperar_ocioso(&self, limite: Duration) -> bool {
        let i = &self.interno;
        let fim = tokio::time::Instant::now() + limite;
        loop {
            let Ok((cid, rx)) = i
                .enviar(("host", "ping", &json!({}), false), Box::new(|_| {}), false)
                .await
            else {
                return true;
            };
            match tokio::time::timeout_at(fim, rx).await {
                Ok(Ok(Ok(dados))) if dados["ocioso"] == json!(true) => return true,
                Ok(Ok(Ok(_))) => {}
                // O processo morreu enquanto esperávamos: nada mais para esperar.
                Ok(_) => return true,
                Err(_) => {
                    i.pendentes().remove(&cid);
                    return false;
                }
            }
            if tokio::time::Instant::now() >= fim {
                return false;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }

    /// Pede ao host que saia (`host/sair`); se não sair em `ESPERA_SAIR` (12 s), mata.
    pub async fn encerrar(&self) {
        let i = &self.interno;
        let mut proc = i.proc.lock().await;
        if proc.pid.is_some() {
            let linha = comando_json(&i.proximo_id(), "host", "sair", &json!({}), false);
            let _ = i.escrever(&mut proc, &linha).await;
            if let Some(mut c) = proc.child.take()
                && tokio::time::timeout(ESPERA_SAIR, c.wait()).await.is_err()
            {
                let _ = c.kill().await;
            }
        }
        proc.pid = None;
        proc.stdin = None;
        i.falhar_todos();
    }
}

#[cfg(test)]
mod testes {
    use super::*;
    use crate::acoes::ErroValidacao;
    use crate::protocolo::Mensagem;
    use serde_json::json;
    use std::path::PathBuf;
    use std::sync::Arc;
    use std::time::{Duration, Instant};
    use tokio::sync::{Mutex, MutexGuard, mpsc};

    static TRAVA: Mutex<()> = Mutex::const_new(());

    /// Copia o modulo de teste `eco` para scripts/ e remove ao sair do escopo.
    struct Eco {
        arquivo: PathBuf,
        _trava: MutexGuard<'static, ()>,
    }

    impl Drop for Eco {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.arquivo);
        }
    }

    fn raiz() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..")
    }

    async fn eco() -> Eco {
        let trava = TRAVA.lock().await;
        let arquivo = raiz().join("scripts").join("eco.ps1");
        std::fs::copy(raiz().join("scripts/tests/fixtures/eco.ps1"), &arquivo).unwrap();
        Eco {
            arquivo,
            _trava: trava,
        }
    }

    fn novo_host(ocioso: u32) -> Arc<HostPowerShell> {
        Arc::new(HostPowerShell::novo(
            raiz().join("scripts").join("host.ps1"),
            false,
            ocioso,
            vec!["eco".into()],
        ))
    }

    async fn ping(h: &HostPowerShell) -> Result<serde_json::Value, ErroHost> {
        tokio::time::timeout(
            Duration::from_secs(30),
            h.executar("host", "ping", json!({}), false, |_| {}),
        )
        .await
        .expect("ping demorou demais")
    }

    type Tarefa = tokio::task::JoinHandle<Result<serde_json::Value, ErroHost>>;

    /// Dispara `demorar` e devolve (id, tarefa) depois do primeiro progresso.
    async fn iniciar_demorar(h: &Arc<HostPowerShell>) -> (String, Tarefa) {
        iniciar_acao(h, "demorar", json!({"segundos": 30})).await
    }

    /// Dispara uma ação do `eco` que emite progresso ao começar e devolve (id, tarefa).
    async fn iniciar_acao(
        h: &Arc<HostPowerShell>,
        acao: &'static str,
        params: serde_json::Value,
    ) -> (String, Tarefa) {
        let (tx, mut rx) = mpsc::unbounded_channel::<Evento>();
        let h2 = h.clone();
        let tarefa = tokio::spawn(async move {
            h2.executar("eco", acao, params, true, move |e| {
                let _ = tx.send(e);
            })
            .await
        });
        let ev = tokio::time::timeout(Duration::from_secs(30), rx.recv())
            .await
            .expect("sem progresso")
            .expect("canal fechado");
        assert!(matches!(ev.mensagem, Mensagem::Progresso { .. }));
        (ev.id, tarefa)
    }

    #[tokio::test]
    async fn ping_devolve_pid() {
        let h = novo_host(120);
        let dados = ping(&h).await.unwrap();
        assert!(dados["pid"].is_number(), "{dados}");
        assert!(h.pid().await.is_some());
        h.encerrar().await;
        assert!(h.pid().await.is_none());
    }

    #[tokio::test]
    async fn modulo_nao_permitido_nao_inicia_processo() {
        let h = novo_host(120);
        let r = h
            .executar("programas", "listar", json!({}), false, |_| {})
            .await;
        assert!(matches!(
            r,
            Err(ErroHost::Validacao(ErroValidacao::NaoPermitida(_)))
        ));
        assert!(h.pid().await.is_none());
    }

    #[tokio::test]
    async fn extra_exige_objeto_e_nao_desliga_modulo_real() {
        let h = novo_host(120);
        let r = h.executar("eco", "eco", json!("x"), true, |_| {}).await;
        assert!(matches!(
            r,
            Err(ErroHost::Validacao(ErroValidacao::Parametro(_)))
        ));
        let h2 = HostPowerShell::novo(
            raiz().join("scripts").join("host.ps1"),
            false,
            120,
            vec!["limpeza".into(), "host".into()],
        );
        let r = h2
            .executar("limpeza", "limpar", json!("x"), false, |_| {})
            .await;
        assert!(matches!(r, Err(ErroHost::Validacao(_))), "{r:?}");
        assert!(h.pid().await.is_none() && h2.pid().await.is_none());
    }

    #[tokio::test]
    async fn eco_devolve_params_e_ids_nao_se_repetem() {
        let _eco = eco().await;
        let h = novo_host(120);
        let a = h
            .executar("eco", "eco", json!({"x": 1}), true, |_| {})
            .await
            .unwrap();
        assert_eq!(a["x"], 1);
        let r = h.executar("eco", "falhar", json!({}), true, |_| {}).await;
        assert!(matches!(r, Err(ErroHost::Acao(ref m)) if m.contains("falha de proposito")));
        h.encerrar().await;
        // Apos relancar, os ids continuam crescendo.
        let (id1, t) = iniciar_demorar(&h).await;
        h.cancelar(&id1).await.unwrap();
        let _ = t.await;
        let (id2, t) = iniciar_demorar(&h).await;
        assert_ne!(id1, id2);
        h.cancelar(&id2).await.unwrap();
        let _ = t.await;
        h.encerrar().await;
    }

    #[tokio::test]
    async fn cancelar_acao_em_curso() {
        let _eco = eco().await;
        let h = novo_host(120);
        ping(&h).await.unwrap();
        let (id, tarefa) = iniciar_demorar(&h).await;
        tokio::time::sleep(Duration::from_millis(200)).await;
        let t0 = Instant::now();
        h.cancelar(&id).await.unwrap();
        let r = tokio::time::timeout(Duration::from_secs(5), tarefa)
            .await
            .expect("nao resolveu")
            .unwrap();
        assert!(matches!(r, Err(ErroHost::Cancelado)), "{r:?}");
        assert!(t0.elapsed() < Duration::from_secs(5));
        h.encerrar().await;
    }

    #[tokio::test]
    async fn processo_morto_por_fora_resolve_timeout_e_relanca() {
        let _eco = eco().await;
        let h = novo_host(120);
        let pid = ping(&h).await.unwrap()["pid"].as_u64().unwrap();
        let (_id, tarefa) = iniciar_demorar(&h).await;
        let st = std::process::Command::new("taskkill")
            .args(["/PID", &pid.to_string(), "/F", "/T"])
            .output()
            .unwrap();
        assert!(st.status.success(), "{st:?}");
        let r = tokio::time::timeout(Duration::from_secs(10), tarefa)
            .await
            .expect("pendente nao resolveu")
            .unwrap();
        assert!(matches!(r, Err(ErroHost::Timeout)), "{r:?}");
        let novo = ping(&h).await.unwrap();
        assert_ne!(novo["pid"].as_u64().unwrap(), pid);
        h.encerrar().await;
    }

    #[tokio::test]
    async fn host_ocioso_sai_e_relanca() {
        let h = novo_host(2);
        ping(&h).await.unwrap();
        tokio::time::sleep(Duration::from_secs(4)).await;
        let limite = Instant::now() + Duration::from_secs(6);
        while h.pid().await.is_some() && Instant::now() < limite {
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        assert!(h.pid().await.is_none());
        ping(&h).await.unwrap();
        h.encerrar().await;
    }

    #[tokio::test]
    async fn cancelar_tudo_encerra_pendentes_e_mantem_host_ocioso() {
        let _eco = eco().await;
        let h = novo_host(120);
        let (_id, tarefa) = iniciar_demorar(&h).await;
        let pid = h.pid().await;
        h.cancelar_tudo().await;
        let r = tokio::time::timeout(Duration::from_secs(10), tarefa)
            .await
            .expect("nao resolveu")
            .unwrap();
        assert!(matches!(r, Err(ErroHost::Cancelado)), "{r:?}");
        // Cancelamento confirmado e host ocioso: o processo não é morto.
        assert_eq!(h.pid().await, pid);
        assert_eq!(ping(&h).await.unwrap()["ocioso"], true);
        h.encerrar().await;
    }

    fn marcador(nome: &str) -> PathBuf {
        let d = std::env::temp_dir().join("NexTuneTesteRust");
        std::fs::create_dir_all(&d).unwrap();
        let f = d.join(format!("{nome}-{}.txt", std::process::id()));
        let _ = std::fs::remove_file(&f);
        f
    }

    #[tokio::test]
    async fn cancelar_tudo_espera_o_finally_da_acao() {
        let _eco = eco().await;
        let h = novo_host(120);
        let arq = marcador("finally");
        let (_id, tarefa) = iniciar_acao(
            &h,
            "comFinally",
            json!({"esperaFinal": 1500, "arquivo": arq.to_string_lossy()}),
        )
        .await;
        let pid = h.pid().await;
        let t0 = Instant::now();
        h.cancelar_tudo().await;
        assert!(arq.exists(), "cancelar_tudo voltou antes do finally");
        assert!(t0.elapsed() < ESPERA_OCIOSO, "{:?}", t0.elapsed());
        assert_eq!(h.pid().await, pid, "host foi morto apesar de ocioso");
        let r = tarefa.await.unwrap();
        assert!(matches!(r, Err(ErroHost::Cancelado)), "{r:?}");
        h.encerrar().await;
        let _ = std::fs::remove_file(&arq);
    }

    #[tokio::test]
    async fn cancelar_tudo_mata_se_o_host_nao_ficar_ocioso_a_tempo() {
        let _eco = eco().await;
        let h = novo_host(120);
        let arq = marcador("teimoso");
        let (_id, tarefa) = iniciar_acao(
            &h,
            "comFinally",
            json!({"esperaFinal": 20000, "arquivo": arq.to_string_lossy()}),
        )
        .await;
        let t0 = Instant::now();
        h.cancelar_tudo_com(Duration::from_secs(2)).await;
        assert!(t0.elapsed() < Duration::from_secs(8), "{:?}", t0.elapsed());
        assert!(h.pid().await.is_none());
        let r = tokio::time::timeout(Duration::from_secs(10), tarefa)
            .await
            .expect("nao resolveu")
            .unwrap();
        assert!(
            matches!(r, Err(ErroHost::Cancelado) | Err(ErroHost::Timeout)),
            "{r:?}"
        );
        assert!(!arq.exists());
    }

    #[test]
    fn powershell_por_caminho_absoluto() {
        let p = caminho_powershell();
        assert!(p.is_absolute(), "{p:?}");
        // %SystemRoot% pode vir como C:\WINDOWS\system32: compara sem caixa.
        let s = p.to_string_lossy().to_ascii_lowercase();
        assert!(
            s.ends_with(r"\system32\windowspowershell\v1.0\powershell.exe"),
            "{p:?}"
        );
        assert!(p.exists(), "{p:?}");
    }
}
