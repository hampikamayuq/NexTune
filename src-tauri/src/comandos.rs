//! Comandos Tauri chamados pela UI (`window.__TAURI__.core.invoke`).
//!
//! Contrato JSON (camelCase): `Ajustes` (ver `ajustes.rs`), `Perfil` e `Info`
//! (`versao, demo, esAdmin, perfil, modoLeve, equipo`). O progresso chega no evento
//! `progresso` com `{id, modulo, tipo:"progresso"|"log", ...}`.
//!
//! O host é compartilhado como `Arc<HostPowerShell>` dentro de um `Mutex`: cada comando clona o
//! `Arc`, solta o lock e só então espera a ação, então ações paralelas não se serializam.

use crate::ajustes::{self, Ajustes};
use crate::caminhos::Pastas;
use crate::host::{Evento, HostPowerShell};
use crate::perfil::{self, Perfil};
use crate::protocolo::Mensagem;
use serde::Serialize;
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use tauri::{Emitter, State, Window};
use tokio::sync::Mutex;

const DADOS_PERMITIDOS: &[&str] = &["perfis", "bloatware", "protegidos"];

pub struct Estado {
    pub pastas: Pastas,
    pub host: Mutex<Arc<HostPowerShell>>,
    pub demo: bool,
    pub versao: String,
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
    if r.is_ok() && modulo == "diagnostico" && acao == "coletar" {
        // O diagnóstico grava um perfil.json novo; reavalia a prioridade do host.
        trocar_host_se_mudou(&estado).await;
    }
    r
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
    }
}

#[cfg(test)]
mod testes {
    use super::*;

    fn dir_tmp() -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("otim-dados-{}", std::process::id()));
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
        assert_eq!(ler_dados(&dir_tmp(), "perfis").unwrap(), json!({"a": 1}));
    }

    #[test]
    fn traversal_e_desconhecidos_falham() {
        let d = dir_tmp();
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
        let classicos = b["classicos"].as_array().expect("bloatware.classicos é lista");
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
        let programas = p["programas"].as_array().expect("protegidos.programas é lista");
        let processos = p["processos"].as_array().expect("protegidos.processos é lista");
        assert!(!programas.is_empty() && !processos.is_empty());
        for e in programas {
            compila(&e["padrao"]);
            motivo_ok(e);
        }
        for proc in processos {
            let nome = proc.as_str().expect("processo é texto");
            assert!(nome.to_lowercase().ends_with(".exe"), "processo sem .exe: {nome}");
        }
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
}
