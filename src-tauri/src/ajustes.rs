//! Ajustes do usuário em `<appdata>/ajustes.json`.
//!
//! Contrato com a UI (JS): os campos viajam em camelCase —
//! `idioma, modoAvancado, pontoRestauracao, diasQuarentena, modoLeve, tourVisto, ultimaVersao`.

use crate::caminhos::Pastas;
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct Ajustes {
    pub idioma: String,
    pub modo_avancado: bool,
    /// "perguntar" | "ligar" | "pular"
    pub ponto_restauracao: String,
    pub dias_quarentena: u32,
    /// "auto" | "on" | "off"
    pub modo_leve: String,
    pub tour_visto: bool,
    pub ultima_versao: String,
}

impl Default for Ajustes {
    fn default() -> Self {
        Self {
            idioma: "pt-BR".into(),
            modo_avancado: false,
            ponto_restauracao: "perguntar".into(),
            dias_quarentena: 7,
            modo_leve: "auto".into(),
            tour_visto: false,
            ultima_versao: String::new(),
        }
    }
}

impl Ajustes {
    /// Confere os valores aceitos; devolve a mensagem de erro em português.
    pub fn validar(&self) -> Result<(), String> {
        if !["auto", "on", "off"].contains(&self.modo_leve.as_str()) {
            return Err("modoLeve inválido".into());
        }
        if !["perguntar", "ligar", "pular"].contains(&self.ponto_restauracao.as_str()) {
            return Err("pontoRestauracao inválido".into());
        }
        if !(1..=90).contains(&self.dias_quarentena) {
            return Err("diasQuarentena deve estar entre 1 e 90".into());
        }
        if self.idioma != "pt-BR" {
            return Err("idioma não suportado".into());
        }
        Ok(())
    }
}

fn arquivo(pastas: &Pastas) -> std::path::PathBuf {
    pastas.appdata.join("ajustes.json")
}

/// Lê os ajustes; qualquer erro de leitura/parse devolve os padrões.
pub fn ler(pastas: &Pastas) -> Ajustes {
    std::fs::read(arquivo(pastas))
        .ok()
        .and_then(|b| serde_json::from_slice(b.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(&b)).ok())
        .unwrap_or_default()
}

/// Grava em JSON indentado, UTF-8 sem BOM; cria a pasta se faltar.
pub fn gravar(pastas: &Pastas, a: &Ajustes) -> std::io::Result<()> {
    std::fs::create_dir_all(&pastas.appdata)?;
    let texto = serde_json::to_string_pretty(a).map_err(std::io::Error::other)?;
    let destino = arquivo(pastas);
    let tmp = destino.with_extension("json.tmp");
    std::fs::write(&tmp, texto)?;
    std::fs::rename(&tmp, &destino).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp);
    })
}

#[cfg(test)]
mod testes {
    use super::*;
    use crate::caminhos::pastas_dev;

    fn pastas_tmp(nome: &str) -> Pastas {
        let dir = std::env::temp_dir().join(format!("otim-ajustes-{nome}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        Pastas {
            appdata: dir.join("app"),
            ..pastas_dev()
        }
    }

    #[test]
    fn pasta_vazia_devolve_padrao() {
        let a = ler(&pastas_tmp("vazia"));
        assert_eq!(a, Ajustes::default());
        assert_eq!(a.dias_quarentena, 7);
        assert_eq!(a.ponto_restauracao, "perguntar");
    }

    #[test]
    fn gravar_e_ler_preserva() {
        let p = pastas_tmp("ida-volta");
        let a = Ajustes {
            modo_avancado: true,
            dias_quarentena: 30,
            modo_leve: "on".into(),
            ultima_versao: "0.1.0".into(),
            ..Ajustes::default()
        };
        gravar(&p, &a).unwrap();
        assert_eq!(ler(&p), a);
        let texto = std::fs::read_to_string(p.appdata.join("ajustes.json")).unwrap();
        assert!(texto.contains("\"diasQuarentena\": 30"));
    }

    #[test]
    fn gravar_substitui_arquivo_existente_sem_deixar_tmp() {
        let p = pastas_tmp("atomico");
        gravar(&p, &Ajustes::default()).unwrap();
        let b = Ajustes {
            tour_visto: true,
            ..Ajustes::default()
        };
        gravar(&p, &b).unwrap();
        assert_eq!(ler(&p), b);
        assert!(!p.appdata.join("ajustes.json.tmp").exists());
    }

    #[test]
    fn json_parcial_faz_merge() {
        let p = pastas_tmp("parcial");
        std::fs::create_dir_all(&p.appdata).unwrap();
        std::fs::write(
            p.appdata.join("ajustes.json"),
            r#"{"modoAvancado":true,"x":1}"#,
        )
        .unwrap();
        let a = ler(&p);
        assert!(a.modo_avancado);
        assert_eq!(
            Ajustes {
                modo_avancado: false,
                ..a
            },
            Ajustes::default()
        );
    }

    #[test]
    fn validacao() {
        assert!(Ajustes::default().validar().is_ok());
        let ruim = |f: fn(&mut Ajustes)| {
            let mut a = Ajustes::default();
            f(&mut a);
            a.validar().is_err()
        };
        assert!(ruim(|a| a.modo_leve = "x".into()));
        assert!(ruim(|a| a.ponto_restauracao = "x".into()));
        assert!(ruim(|a| a.dias_quarentena = 0));
        assert!(ruim(|a| a.dias_quarentena = 91));
        assert!(ruim(|a| a.idioma = "en".into()));
    }
}
