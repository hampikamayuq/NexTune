//! Perfil da máquina (`<programdata>/estado/perfil.json`, escrito pelo lado PowerShell).
//!
//! JSON em camelCase para a UI: `classe, disco, manual`.

use crate::ajustes::Ajustes;
use crate::caminhos::Pastas;
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Perfil {
    /// basico | medio | gamer
    pub classe: String,
    /// hdd | ssd
    pub disco: String,
    pub manual: bool,
}

impl Default for Perfil {
    fn default() -> Self {
        Self {
            classe: "basico".into(),
            disco: "hdd".into(),
            manual: false,
        }
    }
}

/// Ausente, corrompido ou incompleto → perfil conservador (básico/hdd).
pub fn ler(pastas: &Pastas) -> Perfil {
    let Ok(bytes) = std::fs::read(pastas.programdata.join("estado").join("perfil.json")) else {
        return Perfil::default();
    };
    let bytes = bytes.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(&bytes);
    match serde_json::from_slice::<Perfil>(bytes) {
        Ok(p)
            if ["basico", "medio", "gamer"].contains(&p.classe.as_str())
                && ["hdd", "ssd"].contains(&p.disco.as_str()) =>
        {
            p
        }
        _ => Perfil::default(),
    }
}

pub fn modo_leve(p: &Perfil, a: &Ajustes) -> bool {
    a.modo_leve == "on" || (a.modo_leve != "off" && (p.classe == "basico" || p.disco == "hdd"))
}

#[cfg(test)]
mod testes {
    use super::*;
    use crate::caminhos::pastas_dev;

    fn pastas_tmp(nome: &str) -> Pastas {
        let dir = std::env::temp_dir().join(format!("otim-perfil-{nome}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        Pastas {
            programdata: dir,
            ..pastas_dev()
        }
    }

    fn escrever(p: &Pastas, texto: &str) {
        let d = p.programdata.join("estado");
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join("perfil.json"), texto).unwrap();
    }

    fn perfil(classe: &str, disco: &str) -> Perfil {
        Perfil {
            classe: classe.into(),
            disco: disco.into(),
            manual: false,
        }
    }

    fn aj(modo: &str) -> Ajustes {
        Ajustes {
            modo_leve: modo.into(),
            ..Ajustes::default()
        }
    }

    #[test]
    fn ausente_vira_basico_hdd() {
        assert_eq!(ler(&pastas_tmp("ausente")), perfil("basico", "hdd"));
    }

    #[test]
    fn corrompido_vira_fallback() {
        let p = pastas_tmp("corrompido");
        escrever(&p, r#"{"classe":"gamer","disco":"ssd""#);
        assert_eq!(ler(&p), perfil("basico", "hdd"));
    }

    #[test]
    fn incompleto_ou_fora_do_conjunto_vira_fallback() {
        let p = pastas_tmp("incompleto");
        escrever(&p, r#"{"classe":"gamer"}"#);
        assert_eq!(ler(&p), perfil("basico", "hdd"));
        escrever(&p, r#"{"classe":"ultra","disco":"ssd","manual":false}"#);
        assert_eq!(ler(&p), perfil("basico", "hdd"));
    }

    #[test]
    fn valido_e_lido() {
        let p = pastas_tmp("valido");
        escrever(&p, r#"{"classe":"gamer","disco":"ssd","manual":true}"#);
        let r = ler(&p);
        assert_eq!(
            (r.classe.as_str(), r.disco.as_str(), r.manual),
            ("gamer", "ssd", true)
        );
    }

    #[test]
    fn casos_modo_leve() {
        assert!(!modo_leve(&perfil("medio", "ssd"), &aj("auto")));
        assert!(modo_leve(&perfil("medio", "hdd"), &aj("auto")));
        assert!(modo_leve(&perfil("gamer", "ssd"), &aj("on")));
        assert!(!modo_leve(&perfil("basico", "hdd"), &aj("off")));
    }
}
