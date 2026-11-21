//! Lembretes de manutenção: só leitura, no máximo uma notificação por intervalo.
//!
//! Contrato:
//! - `iniciar(app)`: espera 2 min e depois revisa a cada 60 min. Com `lembretes` ligado e fora do
//!   modo demonstração, quando `devido(ultimo, lembretesDias, agora)`, roda só ações de leitura
//!   (`limpeza/analisar`, `atualizacoes/listar`, `disco/estado`, `diagnostico/coletar`), avalia
//!   com `avaliar` e mostra **uma** notificação com os textos unidos por " · ". Nunca executa
//!   outra ação. Grava `<appdata>/lembretes.json` (`{"ultimoLembrete": <segundos desde 1970>}`)
//!   a cada revisão feita, mesmo sem alertas. Sem a janela `main` aberta, encerra o host
//!   PowerShell logo depois da revisão.
//! - `avaliar` é puro: campo ausente ou com tipo errado conta como ausente (sem alerta).
//!   Ordem dos alertas: limpeza, atualizacoes, disco (verificação), disco (saúde).

use crate::ajustes;
use crate::caminhos::Pastas;
use crate::comandos::{self, Estado};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Manager};
use tauri_plugin_notification::NotificationExt;

const ESPERA_INICIAL: Duration = Duration::from_secs(2 * 60);
const INTERVALO: Duration = Duration::from_secs(60 * 60);
const SEGUNDOS_DIA: u64 = 86_400;
const BYTES_MB: u64 = 1_048_576;
const LIXO_MB_PADRAO: u64 = 500;
const DIAS_DISCO_PADRAO: u64 = 90;

/// Já passou o intervalo desde o último lembrete? Sem registro, sim. Registro no futuro (o relógio
/// voltou) também conta como devido, para não calar os lembretes até o relógio alcançar.
pub fn devido(ultimo: Option<SystemTime>, dias: u32, agora: SystemTime) -> bool {
    ultimo.is_none_or(|u| {
        agora
            .duration_since(u)
            .ok()
            .is_none_or(|d| d.as_secs() >= u64::from(dias) * SEGUNDOS_DIA)
    })
}

#[derive(Debug, PartialEq)]
pub struct Alerta {
    /// Tela da UI que trata o alerta.
    pub tela: &'static str,
    pub texto: String,
}

fn lista<'a>(v: &'a Value, chave: &str) -> &'a [Value] {
    v.get(chave)
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default()
}

/// Tamanho no estilo pt-BR: "600 MB", "1,4 GB".
fn tamanho_ptbr(bytes: u64) -> String {
    let mb = bytes as f64 / BYTES_MB as f64;
    if mb >= 1024.0 {
        format!("{:.1} GB", mb / 1024.0).replace('.', ",")
    } else {
        format!("{} MB", mb.round() as u64)
    }
}

fn saude_ok(s: &str) -> bool {
    let s = s.trim().to_lowercase();
    // Vazio = não deu para ler: não é aviso de saúde.
    s.is_empty() || ["healthy", "ok", "saudável"].contains(&s.as_str())
}

/// Alertas a partir das saídas de leitura dos módulos (puro).
pub fn avaliar(
    limpeza: &Value,
    atualiz: &Value,
    disco: &Value,
    diag: &Value,
    lixo_mb: u64,
    dias_disco: u64,
) -> Vec<Alerta> {
    let mut alertas = Vec::new();

    let lixo: u64 = lista(limpeza, "categorias")
        .iter()
        .filter(|c| {
            c.get("cor").and_then(Value::as_str) == Some("verde")
                && c.get("disponivel").and_then(Value::as_bool) == Some(true)
        })
        .filter_map(|c| c.get("tamanhoBytes").and_then(Value::as_u64))
        .sum();
    if lixo > lixo_mb.saturating_mul(BYTES_MB) {
        alertas.push(Alerta {
            tela: "limpeza",
            texto: format!("{} de arquivos temporários para limpar", tamanho_ptbr(lixo)),
        });
    }

    let n = lista(atualiz, "windows")
        .iter()
        .filter(|w| w.get("excluido").is_none_or(Value::is_null))
        .count()
        + lista(atualiz, "programas").len();
    if n > 0 {
        let texto = if n == 1 {
            "1 atualização pendente".to_string()
        } else {
            format!("{n} atualizações pendentes")
        };
        alertas.push(Alerta {
            tela: "atualizacoes",
            texto,
        });
    }

    let sistema = lista(disco, "unidades")
        .iter()
        .find(|u| u.get("sistema").and_then(Value::as_bool) == Some(true));
    if let Some(u) = sistema {
        if u.get("ultimaVerificacao").is_some_and(Value::is_null) {
            alertas.push(Alerta {
                tela: "disco",
                texto: "disco nunca verificado por aqui".into(),
            });
        } else if let Some(d) = u.get("diasSemVerificar").and_then(Value::as_u64)
            && d >= dias_disco
        {
            alertas.push(Alerta {
                tela: "disco",
                texto: format!("disco sem verificação há {d} dias"),
            });
        }
    }

    let aviso = lista(diag, "discos").iter().any(|d| {
        d.get("saude")
            .and_then(Value::as_str)
            .is_some_and(|s| !saude_ok(s))
    });
    if aviso {
        alertas.push(Alerta {
            tela: "disco",
            texto: "disco com aviso de saúde".into(),
        });
    }

    alertas
}

#[derive(Serialize, Deserialize, Default, Debug, PartialEq)]
#[serde(rename_all = "camelCase", default)]
struct Registro {
    /// Segundos desde 1970 (UTC) da última revisão feita.
    ultimo_lembrete: Option<u64>,
}

fn arquivo(pastas: &Pastas) -> std::path::PathBuf {
    pastas.appdata.join("lembretes.json")
}

/// Arquivo ausente ou corrompido = nunca lembrou.
fn ler_registro(pastas: &Pastas) -> Registro {
    std::fs::read(arquivo(pastas))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

/// Mesmo esquema de `ajustes::gravar`: grava num `.tmp` e renomeia.
fn gravar_registro(pastas: &Pastas, r: &Registro) -> std::io::Result<()> {
    std::fs::create_dir_all(&pastas.appdata)?;
    let texto = serde_json::to_string_pretty(r).map_err(std::io::Error::other)?;
    let destino = arquivo(pastas);
    let tmp = destino.with_extension("json.tmp");
    std::fs::write(&tmp, texto)?;
    std::fs::rename(&tmp, &destino).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp);
    })
}

/// Ação de leitura; erro vira `{}` (o alerta correspondente simplesmente não sai).
async fn ler(estado: &Estado, modulo: &str, acao: &str) -> Value {
    comandos::executar_interno(estado, modulo, acao, json!({}))
        .await
        .unwrap_or_else(|e| {
            eprintln!("lembretes: {modulo}/{acao}: {e}");
            json!({})
        })
}

async fn revisar(app: &AppHandle) {
    let estado = app.state::<Estado>();
    if estado.demo {
        return;
    }
    let a = ajustes::ler(&estado.pastas);
    if !a.lembretes {
        return;
    }
    let agora = SystemTime::now();
    let ultimo = ler_registro(&estado.pastas)
        .ultimo_lembrete
        .map(|s| UNIX_EPOCH + Duration::from_secs(s));
    if !devido(ultimo, a.lembretes_dias, agora) {
        return;
    }

    let limpeza = ler(&estado, "limpeza", "analisar").await;
    let atualiz = ler(&estado, "atualizacoes", "listar").await;
    let disco = ler(&estado, "disco", "estado").await;
    let diag = ler(&estado, "diagnostico", "coletar").await;
    let perfis = comandos::ler_dados(&estado.pastas.data, "perfis").unwrap_or_else(|e| {
        eprintln!("lembretes: {e}");
        json!({})
    });
    let limite = |chave: &str, padrao: u64| {
        perfis
            .get("limites")
            .and_then(|l| l.get(chave))
            .and_then(Value::as_u64)
            .unwrap_or(padrao)
    };
    let alertas = avaliar(
        &limpeza,
        &atualiz,
        &disco,
        &diag,
        limite("lixoNotificarMB", LIXO_MB_PADRAO),
        limite("diasSemVerificarDisco", DIAS_DISCO_PADRAO),
    );

    if !alertas.is_empty() {
        let texto = alertas
            .iter()
            .map(|a| a.texto.as_str())
            .collect::<Vec<_>>()
            .join(" · ");
        if let Err(e) = app
            .notification()
            .builder()
            .title("NexTune")
            .body(texto)
            .show()
        {
            eprintln!("lembretes: notificação falhou: {e}");
        }
    }

    let registro = Registro {
        ultimo_lembrete: agora.duration_since(UNIX_EPOCH).ok().map(|d| d.as_secs()),
    };
    if let Err(e) = gravar_registro(&estado.pastas, &registro) {
        eprintln!("lembretes: não foi possível gravar lembretes.json: {e}");
    }

    // Só na bandeja: o host PowerShell não fica de pé à toa depois da revisão.
    if app.get_webview_window("main").is_none() {
        let host = estado.host.lock().await.clone();
        host.encerrar().await;
    }
}

pub fn iniciar(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(ESPERA_INICIAL).await;
        loop {
            revisar(&app).await;
            tokio::time::sleep(INTERVALO).await;
        }
    });
}

#[cfg(test)]
mod testes {
    use super::*;
    use crate::caminhos::pastas_dev;

    const DIA: Duration = Duration::from_secs(SEGUNDOS_DIA);

    fn vazio() -> Value {
        json!({})
    }

    fn so_limpeza(v: Value) -> Vec<Alerta> {
        avaliar(&v, &vazio(), &vazio(), &vazio(), 500, 90)
    }

    fn so_atualiz(v: Value) -> Vec<Alerta> {
        avaliar(&vazio(), &v, &vazio(), &vazio(), 500, 90)
    }

    fn so_disco(v: Value) -> Vec<Alerta> {
        avaliar(&vazio(), &vazio(), &v, &vazio(), 500, 90)
    }

    fn so_diag(v: Value) -> Vec<Alerta> {
        avaliar(&vazio(), &vazio(), &vazio(), &v, 500, 90)
    }

    fn telas(a: &[Alerta]) -> Vec<&str> {
        a.iter().map(|x| x.tela).collect()
    }

    #[test]
    fn devido_por_intervalo() {
        let agora = UNIX_EPOCH + Duration::from_secs(1_800_000_000);
        assert!(devido(None, 3, agora));
        assert!(!devido(Some(agora - 2 * DIA), 3, agora));
        assert!(devido(Some(agora - 3 * DIA), 3, agora));
        assert!(devido(Some(agora + DIA), 3, agora));
    }

    #[test]
    fn limpeza_so_conta_verde_disponivel() {
        let a = so_limpeza(json!({"categorias": [
            {"cor": "verde", "disponivel": true, "tamanhoBytes": 600 * BYTES_MB},
            {"cor": "amarelo", "disponivel": true, "tamanhoBytes": 2048 * BYTES_MB},
            {"cor": "verde", "disponivel": false, "tamanhoBytes": 900 * BYTES_MB}
        ]}));
        assert_eq!(
            a,
            vec![Alerta {
                tela: "limpeza",
                texto: "600 MB de arquivos temporários para limpar".into()
            }]
        );
        let pouco = so_limpeza(json!({"categorias": [
            {"cor": "verde", "disponivel": true, "tamanhoBytes": 400 * BYTES_MB}
        ]}));
        assert!(pouco.is_empty());
    }

    #[test]
    fn tamanho_em_gb_com_virgula() {
        assert_eq!(tamanho_ptbr(1434 * BYTES_MB), "1,4 GB");
        assert_eq!(tamanho_ptbr(600 * BYTES_MB), "600 MB");
    }

    #[test]
    fn atualizacoes_ignoram_excluidas() {
        let a = so_atualiz(json!({"windows": [{"excluido": null}]}));
        assert_eq!(telas(&a), ["atualizacoes"]);
        assert_eq!(a[0].texto, "1 atualização pendente");
        let duas = so_atualiz(json!({"windows": [{"excluido": null}], "programas": [{}]}));
        assert_eq!(duas[0].texto, "2 atualizações pendentes");
        assert!(
            so_atualiz(json!({"windows": [{"excluido": "upgrade"}], "programas": []})).is_empty()
        );
    }

    #[test]
    fn disco_sem_verificacao() {
        let nunca = so_disco(json!({"unidades": [
            {"sistema": false, "ultimaVerificacao": null},
            {"sistema": true, "ultimaVerificacao": null}
        ]}));
        assert_eq!(telas(&nunca), ["disco"]);
        assert_eq!(nunca[0].texto, "disco nunca verificado por aqui");
        let unidade = |dias: u64| {
            json!({"unidades": [
                {"sistema": true, "ultimaVerificacao": "2026-08-23", "diasSemVerificar": dias}
            ]})
        };
        let velho = so_disco(unidade(90));
        assert_eq!(telas(&velho), ["disco"]);
        assert_eq!(velho[0].texto, "disco sem verificação há 90 dias");
        assert!(so_disco(unidade(89)).is_empty());
        assert!(
            so_disco(json!({"unidades": [{"sistema": false, "ultimaVerificacao": null}]}))
                .is_empty()
        );
    }

    #[test]
    fn saude_do_disco() {
        let a = so_diag(json!({"discos": [{"saude": "Healthy"}, {"saude": "Warning"}]}));
        assert_eq!(
            a,
            vec![Alerta {
                tela: "disco",
                texto: "disco com aviso de saúde".into()
            }]
        );
        for ok in ["Healthy", "Saudável", "OK", " ok ", ""] {
            assert!(so_diag(json!({"discos": [{"saude": ok}]})).is_empty(), "{ok:?}");
        }
    }

    #[test]
    fn ordem_e_entradas_vazias_ou_estranhas() {
        assert_eq!(avaliar(&vazio(), &vazio(), &vazio(), &vazio(), 500, 90), vec![]);
        let estranho =
            json!({"categorias": 3, "windows": "x", "unidades": [1], "discos": [{"saude": 5}]});
        assert!(avaliar(&estranho, &estranho, &estranho, &estranho, 500, 90).is_empty());
        let todos = avaliar(
            &json!({"categorias": [
                {"cor": "verde", "disponivel": true, "tamanhoBytes": 600 * BYTES_MB}
            ]}),
            &json!({"programas": [{}]}),
            &json!({"unidades": [{"sistema": true, "ultimaVerificacao": null}]}),
            &json!({"discos": [{"saude": "Unhealthy"}]}),
            500,
            90,
        );
        assert_eq!(telas(&todos), ["limpeza", "atualizacoes", "disco", "disco"]);
    }

    #[test]
    fn registro_ida_e_volta() {
        let dir = std::env::temp_dir().join(format!("otim-lembretes-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let p = Pastas {
            appdata: dir.join("app"),
            ..pastas_dev()
        };
        assert_eq!(ler_registro(&p), Registro::default());
        let r = Registro {
            ultimo_lembrete: Some(1_800_000_000),
        };
        gravar_registro(&p, &r).unwrap();
        assert_eq!(ler_registro(&p), r);
        let texto = std::fs::read_to_string(p.appdata.join("lembretes.json")).unwrap();
        assert!(texto.contains("\"ultimoLembrete\": 1800000000"));
        assert!(!p.appdata.join("lembretes.json.tmp").exists());
        std::fs::write(p.appdata.join("lembretes.json"), "{corrompido").unwrap();
        assert_eq!(ler_registro(&p), Registro::default());
    }
}
