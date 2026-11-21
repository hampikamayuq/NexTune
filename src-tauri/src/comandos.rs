//! Comandos Tauri chamados pela UI (`window.__TAURI__.core.invoke`).
//!
//! Contrato JSON (camelCase): `Ajustes` (ver `ajustes.rs`), `Perfil` e `Info`
//! (`versao, demo, esAdmin, perfil, modoLeve, equipo, sessaoOk`). O progresso chega no evento
//! `progresso` com `{id, modulo, tipo:"progresso"|"log", ...}`.
//!
//! Comandos: `executar(modulo, acao, params)`, `cancelar()`, `ajustes_ler()`, `ajustes_gravar(a)`,
//! `dados(nome)`, `info()` e `ponto_sessao() -> bool` (se `sistema/criarPonto` já devolveu
//! `criado:true` neste processo).
//!
//! Sessão (spec §9.1, Review Focus 6): antes da primeira ação de escrita (`acoes::e_escrita`) o
//! Rust roda `sistema/sessao` uma vez por processo e guarda `mesmo`; `false` recusa toda escrita
//! com `Err("sessao_diferente")` antes de chegar ao PowerShell. Leitura segue liberada. Falha ao
//! verificar nunca bloqueia (e não é guardada). `Info.sessaoOk` é `null` até a verificação.
//!
//! O host é compartilhado como `Arc<HostPowerShell>` dentro de um `Mutex`: cada comando clona o
//! `Arc`, solta o lock e só então espera a ação, então ações paralelas não se serializam.

use crate::acoes;
use crate::ajustes::{self, Ajustes};
use crate::caminhos::Pastas;
use crate::host::{Evento, HostPowerShell};
use crate::perfil::{self, Perfil};
use crate::protocolo::Mensagem;
use serde::Serialize;
use serde_json::{Value, json};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as MutexSync};
use tauri::{Emitter, State, Window};
use tokio::sync::Mutex;

const DADOS_PERMITIDOS: &[&str] = &["perfis", "bloatware", "protegidos", "inicio", "ajustes"];

pub struct Estado {
    pub pastas: Pastas,
    pub host: Mutex<Arc<HostPowerShell>>,
    pub demo: bool,
    pub versao: String,
    /// `sistema/criarPonto` já devolveu `criado:true` neste processo.
    pub ponto_sessao: AtomicBool,
    /// Resultado de `sistema/sessao` (`mesmo`): `None` = ainda não verificado.
    pub sessao: MutexSync<Option<bool>>,
}

impl Estado {
    pub fn novo(pastas: Pastas, demo: bool, versao: String) -> Self {
        let leve = perfil::modo_leve(&perfil::ler(&pastas), &ajustes::ler(&pastas));
        let host = Arc::new(criar_host(&pastas, leve));
        Self {
            pastas,
            host: Mutex::new(host),
            demo,
            versao,
            ponto_sessao: AtomicBool::new(false),
            sessao: MutexSync::new(None),
        }
    }

    fn sessao_lida(&self) -> Option<bool> {
        *self.sessao.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn guardar_sessao(&self, v: Option<bool>) {
        if v.is_some() {
            *self.sessao.lock().unwrap_or_else(|e| e.into_inner()) = v;
        }
    }
}

fn criar_host(pastas: &Pastas, leve: bool) -> HostPowerShell {
    HostPowerShell::novo(pastas.scripts.join("host.ps1"), leve, 120, vec![])
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Info {
    pub versao: String,
    pub demo: bool,
    pub es_admin: bool,
    pub perfil: Perfil,
    pub modo_leve: bool,
    pub equipo: String,
    /// `true`/`false` depois de `sistema/sessao`; `null` enquanto não verificado.
    pub sessao_ok: Option<bool>,
}

/// Lê `<data_dir>/<nome>.json`; só nomes da allowlist (sem `..`, `/` ou `\`).
pub fn ler_dados(data_dir: &Path, nome: &str) -> Result<Value, String> {
    if nome.contains("..") || nome.contains('/') || nome.contains('\\') {
        return Err("nome de dados inválido".into());
    }
    if !DADOS_PERMITIDOS.contains(&nome) {
        return Err(format!("dados desconhecidos: {nome}"));
    }
    let bytes = std::fs::read(data_dir.join(format!("{nome}.json")))
        .map_err(|e| format!("não foi possível ler {nome}: {e}"))?;
    let bytes = bytes.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(&bytes);
    serde_json::from_slice(bytes).map_err(|e| format!("{nome}.json inválido: {e}"))
}

#[cfg(windows)]
fn es_admin() -> bool {
    // SAFETY: chamada sem argumentos e sem efeitos colaterais.
    unsafe { windows_sys::Win32::UI::Shell::IsUserAnAdmin() != 0 }
}

#[cfg(not(windows))]
fn es_admin() -> bool {
    false
}

fn evento_json(modulo: &str, ev: Evento) -> Option<Value> {
    match ev.mensagem {
        Mensagem::Progresso { pct, msg, .. } => Some(json!({
            "id": ev.id, "modulo": modulo, "tipo": "progresso", "pct": pct, "msg": msg
        })),
        Mensagem::Log {
            tipo, msg, ruta, ..
        } => Some(json!({
            "id": ev.id, "modulo": modulo, "tipo": "log", "tipoLog": tipo, "msg": msg, "ruta": ruta
        })),
        Mensagem::Resultado { .. } => None,
    }
}

/// Lê `mesmo` dos dados devolvidos por `sistema/sessao`. `None` quando ausente ou não booleano
/// (resultado inesperado nunca bloqueia nem é guardado).
pub fn sessao_permite(dados: &Value) -> Option<bool> {
    dados.get("mesmo").and_then(Value::as_bool)
}

/// Bloqueio por sessão (Review Focus 6): na primeira ação de escrita do processo roda
/// `sistema/sessao` e guarda o resultado; `mesmo:false` recusa com `sessao_diferente`. Erro ao
/// rodar a verificação não bloqueia (nem guarda), para uma falha de ferramenta não travar o uso.
async fn verificar_sessao(estado: &Estado, host: &HostPowerShell) -> Result<(), String> {
    let atual = match estado.sessao_lida() {
        Some(v) => Some(v),
        None => {
            let r = host
                .executar("sistema", "sessao", json!({}), false, |_| {})
                .await;
            let v = r.ok().as_ref().and_then(sessao_permite);
            estado.guardar_sessao(v);
            v
        }
    };
    decidir_sessao(atual)
}

/// Decisão pura: só `Some(false)` (usuário elevado diferente do usuário do console) bloqueia;
/// sessão ainda não verificada nunca bloqueia.
pub fn decidir_sessao(atual: Option<bool>) -> Result<(), String> {
    match atual {
        Some(false) => Err("sessao_diferente".into()),
        _ => Ok(()),
    }
}

/// Decisão pura: o host precisa ser recriado quando o modo leve calculado difere da prioridade atual.
pub fn precisa_trocar(atual: bool, perfil: &Perfil, ajustes: &Ajustes) -> bool {
    perfil::modo_leve(perfil, ajustes) != atual
}

/// Relê perfil e ajustes e, se o modo leve mudou, substitui o host (devolve `true` ao trocar).
///
/// Atenção: trocar o host chama `encerrar()` no antigo e cancela qualquer ação em andamento.
/// A UI (Task 9) não deve oferecer o alternador de modo leve enquanto houver ação rodando.
pub async fn trocar_host_se_mudou(estado: &Estado) -> bool {
    let perfil = perfil::ler(&estado.pastas);
    let ajustes = ajustes::ler(&estado.pastas);
    let mut guarda = estado.host.lock().await;
    if !precisa_trocar(guarda.prioridade_baixa(), &perfil, &ajustes) {
        return false;
    }
    let leve = perfil::modo_leve(&perfil, &ajustes);
    let antigo = std::mem::replace(&mut *guarda, Arc::new(criar_host(&estado.pastas, leve)));
    drop(guarda);
    antigo.encerrar().await;
    true
}

#[tauri::command]
pub async fn executar(
    modulo: String,
    acao: String,
    params: Value,
    window: Window,
    estado: State<'_, Estado>,
) -> Result<Value, String> {
    if estado.demo {
        return Err("demo".into());
    }
    let host = estado.host.lock().await.clone();
    if acoes::e_escrita(&modulo, &acao) {
        verificar_sessao(&estado, &host).await?;
    }
    let mod_cb = modulo.clone();
    // Não bloqueia: só emite o evento e volta.
    let progresso = move |ev: Evento| {
        if let Some(v) = evento_json(&mod_cb, ev) {
            let _ = window.emit("progresso", v);
        }
    };
    let r = host
        .executar(&modulo, &acao, params, false, progresso)
        .await
        .map_err(|e| e.to_string());
    if let Ok(d) = &r {
        match (modulo.as_str(), acao.as_str()) {
            ("diagnostico", "coletar") => {
                // O diagnóstico grava um perfil.json novo; reavalia a prioridade do host.
                trocar_host_se_mudou(&estado).await;
            }
            // A UI também verifica a sessão no arranque: aproveita o resultado.
            ("sistema", "sessao") => estado.guardar_sessao(sessao_permite(d)),
            ("sistema", "criarPonto") if d["criado"] == json!(true) => {
                estado.ponto_sessao.store(true, Ordering::SeqCst);
            }
            _ => {}
        }
    }
    r
}

/// `true` se um ponto de restauração já foi criado neste processo (`sistema/criarPonto` com
/// `criado:true`); a UI usa para não criar outro antes de cada ação de escrita.
#[tauri::command]
pub fn ponto_sessao(estado: State<'_, Estado>) -> bool {
    estado.ponto_sessao.load(Ordering::SeqCst)
}

/// Cancela a ação em curso e espera (até 10 s) os `finally` dela restaurarem serviços e registro.
#[tauri::command]
pub async fn cancelar(estado: State<'_, Estado>) -> Result<(), String> {
    let host = estado.host.lock().await.clone();
    host.cancelar_tudo().await;
    Ok(())
}

#[tauri::command]
pub fn ajustes_ler(estado: State<'_, Estado>) -> Ajustes {
    ajustes::ler(&estado.pastas)
}

#[tauri::command]
pub async fn ajustes_gravar(a: Ajustes, estado: State<'_, Estado>) -> Result<Ajustes, String> {
    a.validar()?;
    let perfil = perfil::ler(&estado.pastas);
    let antes = perfil::modo_leve(&perfil, &ajustes::ler(&estado.pastas));
    ajustes::gravar(&estado.pastas, &a).map_err(|e| format!("não foi possível gravar: {e}"))?;
    let depois = perfil::modo_leve(&perfil, &a);
    if antes != depois {
        let novo = Arc::new(criar_host(&estado.pastas, depois));
        let antigo = std::mem::replace(&mut *estado.host.lock().await, novo);
        antigo.encerrar().await;
    }
    Ok(a)
}

#[tauri::command]
pub fn dados(nome: String, estado: State<'_, Estado>) -> Result<Value, String> {
    ler_dados(&estado.pastas.data, &nome)
}

#[tauri::command]
pub fn info(estado: State<'_, Estado>) -> Info {
    let perfil = perfil::ler(&estado.pastas);
    let modo_leve = perfil::modo_leve(&perfil, &ajustes::ler(&estado.pastas));
    Info {
        versao: estado.versao.clone(),
        demo: estado.demo,
        es_admin: estado.demo || es_admin(),
        perfil,
        modo_leve,
        equipo: std::env::var("COMPUTERNAME").unwrap_or_default(),
        sessao_ok: if estado.demo {
            Some(true)
        } else {
            estado.sessao_lida()
        },
    }
}

#[cfg(test)]
mod testes {
    use super::*;

    /// Uma pasta por teste (`nome`) e por processo: os testes correm em paralelo.
    fn dir_tmp(nome: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("otim-dados-{}-{nome}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join("perfis.json"), r#"{"a":1}"#).unwrap();
        std::fs::write(d.join("ajustes.json"), "{}").unwrap();
        std::fs::write(d.join("outro.json"), "{}").unwrap();
        d
    }

    #[test]
    fn tabela_precisa_trocar() {
        let p = |c: &str, d: &str| Perfil {
            classe: c.into(),
            disco: d.into(),
            manual: false,
        };
        let a = |m: &str| Ajustes {
            modo_leve: m.into(),
            ..Ajustes::default()
        };
        assert!(!precisa_trocar(true, &p("basico", "hdd"), &a("auto")));
        assert!(precisa_trocar(false, &p("basico", "hdd"), &a("auto")));
        assert!(precisa_trocar(true, &p("gamer", "ssd"), &a("auto")));
        assert!(!precisa_trocar(false, &p("gamer", "ssd"), &a("auto")));
        assert!(precisa_trocar(false, &p("gamer", "ssd"), &a("on")));
        assert!(precisa_trocar(true, &p("basico", "hdd"), &a("off")));
    }

    #[test]
    fn perfis_ok() {
        assert_eq!(
            ler_dados(&dir_tmp("perfis_ok"), "perfis").unwrap(),
            json!({"a": 1})
        );
    }

    #[test]
    fn traversal_e_desconhecidos_falham() {
        let d = dir_tmp("traversal");
        assert!(ler_dados(&d, "../ajustes").is_err());
        assert!(ler_dados(&d, "a/b").is_err());
        assert!(ler_dados(&d, "a\\b").is_err());
        assert!(ler_dados(&d, "nao_existe").is_err());
        assert!(ler_dados(&d, "outro").is_err());
    }

    /// Lê `data/` real do repositório e confere a forma das listas de bloatware e protegidos:
    /// chaves de topo, cores válidas, padrões que compilam como regex sem diferenciar caixa
    /// (o PowerShell usa os mesmos padrões) e `packageFamilyName` no formato da Store.
    #[test]
    fn bloatware_e_protegidos_ok() {
        let data = crate::caminhos::pastas_dev().data;
        let re_pfn = regex::Regex::new(r"^[A-Za-z0-9.\-]+_[a-z0-9]{13}$").unwrap();
        let compila = |p: &Value| {
            let p = p.as_str().expect("padrao é texto");
            regex::RegexBuilder::new(p)
                .case_insensitive(true)
                .build()
                .unwrap_or_else(|e| panic!("padrão inválido {p:?}: {e}"));
        };
        let cor_ok = |c: &Value| {
            assert!(
                matches!(c.as_str(), Some("verde" | "amarelo" | "vermelho")),
                "cor inválida: {c}"
            );
        };
        let motivo_ok = |e: &Value| {
            assert!(
                e["motivo"].as_str().is_some_and(|m| !m.trim().is_empty()),
                "motivo ausente em {e}"
            );
        };

        let b = ler_dados(&data, "bloatware").unwrap();
        let store = b["store"].as_array().expect("bloatware.store é lista");
        let classicos = b["classicos"]
            .as_array()
            .expect("bloatware.classicos é lista");
        assert!(!store.is_empty() && !classicos.is_empty());
        let mut vistos = std::collections::HashSet::new();
        for e in store {
            let pfn = e["packageFamilyName"]
                .as_str()
                .expect("packageFamilyName é texto");
            assert!(re_pfn.is_match(pfn), "packageFamilyName inválido: {pfn}");
            assert!(
                vistos.insert(pfn.to_lowercase()),
                "packageFamilyName repetido: {pfn}"
            );
            cor_ok(&e["cor"]);
            motivo_ok(e);
        }
        for e in classicos {
            compila(&e["padrao"]);
            if let Some(ed) = e.get("editor") {
                compila(ed);
            }
            cor_ok(&e["cor"]);
            motivo_ok(e);
        }

        let p = ler_dados(&data, "protegidos").unwrap();
        let programas = p["programas"]
            .as_array()
            .expect("protegidos.programas é lista");
        let processos = p["processos"]
            .as_array()
            .expect("protegidos.processos é lista");
        assert!(!programas.is_empty() && !processos.is_empty());
        for e in programas {
            compila(&e["padrao"]);
            motivo_ok(e);
        }
        for proc in processos {
            let nome = proc.as_str().expect("processo é texto");
            assert!(
                nome.to_lowercase().ends_with(".exe"),
                "processo sem .exe: {nome}"
            );
        }
    }

    #[test]
    fn decidir_sessao_bloqueia_so_quando_diferente() {
        assert_eq!(decidir_sessao(Some(false)), Err("sessao_diferente".to_string()));
        assert_eq!(decidir_sessao(Some(true)), Ok(()));
        assert_eq!(decidir_sessao(None), Ok(()));
    }

    #[test]
    fn sessao_permite_le_mesmo() {
        assert_eq!(
            sessao_permite(
                &json!({"usuarioProcesso": "PC\\ana", "mesmo": true, "desconhecido": false})
            ),
            Some(true)
        );
        assert_eq!(
            sessao_permite(
                &json!({"usuarioProcesso": "PC\\adm", "usuarioConsole": "PC\\ana", "mesmo": false})
            ),
            Some(false)
        );
        // Console desconhecido (RDP, serviço) vem com mesmo:true e não bloqueia.
        assert_eq!(
            sessao_permite(&json!({"usuarioConsole": null, "mesmo": true, "desconhecido": true})),
            Some(true)
        );
        assert_eq!(sessao_permite(&json!({"usuarioProcesso": "x"})), None);
        assert_eq!(sessao_permite(&json!({"mesmo": "true"})), None);
        assert_eq!(sessao_permite(&json!({"mesmo": 1})), None);
        assert_eq!(sessao_permite(&json!({"mesmo": null})), None);
        assert_eq!(sessao_permite(&json!(null)), None);
        assert_eq!(sessao_permite(&json!([true])), None);
    }

    #[test]
    fn e_escrita_integrado() {
        assert!(acoes::e_escrita("limpeza", "limpar"));
        assert!(acoes::e_escrita("quarentena", "purgar"));
        assert!(!acoes::e_escrita("limpeza", "analisar"));
        assert!(!acoes::e_escrita("sistema", "sessao"));
    }

    #[test]
    fn estado_guarda_sessao_e_ponto() {
        let e = Estado::novo(crate::caminhos::pastas_dev(), true, "0.0.0-teste".into());
        assert_eq!(e.sessao_lida(), None);
        assert!(!e.ponto_sessao.load(Ordering::SeqCst));
        e.guardar_sessao(None);
        assert_eq!(e.sessao_lida(), None, "None não sobrescreve");
        e.guardar_sessao(Some(false));
        assert_eq!(e.sessao_lida(), Some(false));
        e.guardar_sessao(None);
        assert_eq!(
            e.sessao_lida(),
            Some(false),
            "None não apaga o que foi verificado"
        );
        e.guardar_sessao(Some(true));
        assert_eq!(e.sessao_lida(), Some(true));
        e.ponto_sessao.store(true, Ordering::SeqCst);
        assert!(e.ponto_sessao.load(Ordering::SeqCst));
    }

    #[test]
    fn info_serializa_sessao_ok_sempre() {
        let base = Info {
            versao: "0".into(),
            demo: false,
            es_admin: false,
            perfil: Perfil {
                classe: "basico".into(),
                disco: "hdd".into(),
                manual: false,
            },
            modo_leve: false,
            equipo: String::new(),
            sessao_ok: None,
        };
        let v = serde_json::to_value(&base).unwrap();
        assert!(v.as_object().unwrap().contains_key("sessaoOk"));
        assert_eq!(v["sessaoOk"], Value::Null);
        let v = serde_json::to_value(Info {
            sessao_ok: Some(false),
            ..base
        })
        .unwrap();
        assert_eq!(v["sessaoOk"], json!(false));
    }

    #[test]
    fn evento_progresso_e_log() {
        let p = Evento {
            id: "1".into(),
            mensagem: Mensagem::Progresso {
                id: "1".into(),
                pct: 40,
                msg: "x".into(),
            },
        };
        let v = evento_json("limpeza", p).unwrap();
        assert_eq!(v["tipo"], "progresso");
        assert_eq!(v["pct"], 40);
        let l = Evento {
            id: "1".into(),
            mensagem: Mensagem::Log {
                id: "1".into(),
                tipo: "ok".into(),
                msg: "m".into(),
                ruta: "r".into(),
            },
        };
        assert_eq!(evento_json("limpeza", l).unwrap()["tipoLog"], "ok");
    }

    /// Textos da interface (`ui/i18n/pt-BR.js`): o corpo entre o primeiro `{` e o último `}` é JSON.
    fn textos_pt_br() -> serde_json::Map<String, Value> {
        let raiz = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..");
        let js = std::fs::read_to_string(raiz.join("ui/i18n/pt-BR.js")).expect("pt-BR.js");
        // A primeira linha é `window.I18N = window.I18N || {};`: o dicionário vem depois do marcador.
        let marcador = "['pt-BR'] = ";
        let ini = js.find(marcador).expect("marcador do dicionário") + marcador.len();
        let fim = js.rfind('}').expect("fecha }");
        serde_json::from_str::<Value>(&js[ini..=fim])
            .expect("corpo de pt-BR.js é JSON")
            .as_object()
            .expect("objeto")
            .clone()
    }

    /// Lê `data/inicio.json` e `data/ajustes.json` reais e confere a forma dos dois (Plano 3, Task 1),
    /// incluindo Review Focus 5: chave de Política ⇔ `politica:true`, e `politica` ⇒ `avancado`.
    #[test]
    fn inicio_e_ajustes_ok() {
        let data = crate::caminhos::pastas_dev().data;
        let compila = |p: &Value| {
            let p = p.as_str().expect("padrao é texto");
            regex::RegexBuilder::new(p)
                .case_insensitive(true)
                .build()
                .unwrap_or_else(|e| panic!("padrão inválido {p:?}: {e}"));
        };
        let regra_ok = |e: &Value| {
            compila(&e["padrao"]);
            assert!(
                matches!(e["cor"].as_str(), Some("verde" | "amarelo" | "vermelho")),
                "cor inválida: {e}"
            );
            assert!(
                e["motivo"].as_str().is_some_and(|m| !m.trim().is_empty()),
                "motivo ausente em {e}"
            );
        };

        let i = ler_dados(&data, "inicio").unwrap();
        let itens = i["itens"].as_array().expect("inicio.itens é lista");
        let tarefas = i["tarefas"].as_array().expect("inicio.tarefas é lista");
        assert!(!itens.is_empty());
        itens.iter().chain(tarefas.iter()).for_each(regra_ok);

        let a = ler_dados(&data, "ajustes").unwrap();
        let ajustes = a["ajustes"].as_array().expect("ajustes é lista");
        assert!(!ajustes.is_empty());
        let re_id = regex::Regex::new(r"^[a-z0-9_]{1,40}$").unwrap();
        let textos = textos_pt_br();
        let mut ids = std::collections::HashSet::new();
        for e in ajustes {
            let id = e["id"].as_str().expect("id é texto");
            assert!(re_id.is_match(id), "id inválido: {id}");
            assert!(ids.insert(id.to_string()), "id repetido: {id}");
            assert!(
                matches!(
                    e["grupo"].as_str(),
                    Some("anuncios" | "privacidade" | "copilot" | "explorador" | "desempenho")
                ),
                "grupo inválido em {id}"
            );
            assert!(
                matches!(e["recomendadoPara"].as_str(), Some("todos" | "fraco" | "nenhum")),
                "recomendadoPara inválido em {id}"
            );
            let politica = e["politica"].as_bool().expect("politica é booleano");
            let avancado = e["avancado"].as_bool().expect("avancado é booleano");
            assert!(e["soWin11"].is_boolean() && e["reiniciarExplorer"].is_boolean(), "{id}");
            assert!(!politica || avancado, "{id}: politica exige avancado");
            for k in ["nome", "desc"] {
                let chave = format!("ajuste.{id}.{k}");
                assert!(
                    textos.get(&chave).and_then(Value::as_str).is_some_and(|t| !t.is_empty()),
                    "falta {chave} em pt-BR.js"
                );
            }
            let chaves = e["chaves"].as_array().expect("chaves é lista");
            assert!(!chaves.is_empty(), "{id} sem chaves");
            for c in chaves {
                let chave = c["chave"].as_str().expect("chave é texto");
                let baixa = chave.to_lowercase();
                assert!(
                    baixa.starts_with(r"hkcu\") || baixa.starts_with(r"hklm\"),
                    "{id}: chave fora de HKCU/HKLM: {chave}"
                );
                // A tela de Configurações grava AllowTelemetry em CurrentVersion\Policies\DataCollection:
                // não é chave de Política de Grupo.
                let de_politica = baixa.contains(r"\policies\")
                    && !baixa.contains(r"currentversion\policies\datacollection");
                assert_eq!(de_politica, politica, "{id}: politica não bate com a chave {chave}");
                for proibido in ["windows defender", "windowsupdate", "edge"] {
                    assert!(!baixa.contains(proibido), "{id}: anti-objetivo em {chave}");
                }
                assert!(
                    c["nome"].as_str().is_some_and(|n| !n.is_empty()),
                    "{id}: nome vazio"
                );
                match c["tipo"].as_str() {
                    Some("DWord") => assert!(c["aplicar"].is_i64(), "{id}: DWord pede inteiro"),
                    Some("String") => assert!(c["aplicar"].is_string(), "{id}: String pede texto"),
                    outro => panic!("{id}: tipo inválido {outro:?}"),
                }
            }
        }
    }
}
