use serde_json::{Map, Value};

#[derive(thiserror::Error, Debug)]
pub enum ErroValidacao {
    #[error("ação não permitida: {0}")]
    NaoPermitida(String),
    #[error("parâmetro inválido: {0}")]
    Parametro(String),
}

pub const CATEGORIAS_LIMPEZA: &[&str] = &[
    "temp_usuario",
    "temp_windows",
    "wu_cache",
    "entrega",
    "informes",
    "miniaturas",
    "launchers",
    "navegadores",
    "minidumps",
    "lixeira",
    "shaders",
    "dism_componentes",
    "windows_old",
    "pontos_antigos",
];

const MODULOS: &[&str] = &["host", "diagnostico", "limpeza"];

pub fn modulos_permitidos() -> &'static [&'static str] {
    MODULOS
}

fn erro(msg: impl Into<String>) -> ErroValidacao {
    ErroValidacao::Parametro(msg.into())
}

fn como_objeto(params: &Value) -> Result<Map<String, Value>, ErroValidacao> {
    match params {
        Value::Null => Ok(Map::new()),
        Value::Object(m) => Ok(m.clone()),
        _ => Err(erro("params deve ser um objeto")),
    }
}

fn so_chaves(m: &Map<String, Value>, permitidas: &[&str]) -> Result<(), ErroValidacao> {
    match m.keys().find(|k| !permitidas.contains(&k.as_str())) {
        Some(k) => Err(erro(format!("chave desconhecida: {k}"))),
        None => Ok(()),
    }
}

fn copiar_bool(
    de: &Map<String, Value>,
    para: &mut Map<String, Value>,
    chave: &str,
) -> Result<(), ErroValidacao> {
    if let Some(v) = de.get(chave) {
        if !v.is_boolean() {
            return Err(erro(format!("{chave} deve ser booleano")));
        }
        para.insert(chave.to_string(), v.clone());
    }
    Ok(())
}

fn forcar_perfil(v: &Value) -> Result<Value, ErroValidacao> {
    let m = v
        .as_object()
        .ok_or_else(|| erro("forcarPerfil deve ser objeto"))?;
    so_chaves(m, &["classe", "disco"])?;
    let classe = m.get("classe").and_then(Value::as_str);
    let disco = m.get("disco").and_then(Value::as_str);
    match (classe, disco) {
        (Some(c @ ("basico" | "medio" | "gamer")), Some(d @ ("hdd" | "ssd"))) => {
            Ok(serde_json::json!({"classe": c, "disco": d}))
        }
        _ => Err(erro("forcarPerfil: classe/disco inválidos")),
    }
}

/// Valida a ação contra a allowlist e devolve os params saneados.
pub fn validar(
    modulo: &str,
    acao: &str,
    params: &Value,
    teste: bool,
) -> Result<Value, ErroValidacao> {
    match (modulo, acao) {
        ("host", "ping") => {
            so_chaves(&como_objeto(params)?, &[])?;
            Ok(Value::Object(Map::new()))
        }
        ("diagnostico", "coletar") => {
            let m = como_objeto(params)?;
            so_chaves(&m, &["simular", "forcarPerfil"])?;
            let mut saida = Map::new();
            if let Some(s) = m.get("simular") {
                if !teste {
                    return Err(erro("simular só é aceito em modo teste"));
                }
                if !s.is_object() {
                    return Err(erro("simular deve ser objeto"));
                }
                saida.insert("simular".into(), s.clone());
            }
            if let Some(f) = m.get("forcarPerfil") {
                saida.insert("forcarPerfil".into(), forcar_perfil(f)?);
            }
            Ok(Value::Object(saida))
        }
        ("limpeza", "analisar") => {
            let m = como_objeto(params)?;
            so_chaves(&m, &["avancado"])?;
            let mut saida = Map::new();
            copiar_bool(&m, &mut saida, "avancado")?;
            Ok(Value::Object(saida))
        }
        ("limpeza", "limpar") => {
            let m = como_objeto(params)?;
            so_chaves(&m, &["categorias", "confirmado", "avancado", "resetBase"])?;
            let cats = m
                .get("categorias")
                .and_then(Value::as_array)
                .ok_or_else(|| erro("categorias é obrigatório (lista)"))?;
            if cats.is_empty() {
                return Err(erro("categorias não pode ser vazio"));
            }
            let mut vistas: Vec<&str> = Vec::new();
            for c in cats {
                let nome = c
                    .as_str()
                    .ok_or_else(|| erro("categorias deve conter textos"))?;
                if !CATEGORIAS_LIMPEZA.contains(&nome) {
                    return Err(erro(format!("categoria desconhecida: {nome}")));
                }
                if vistas.contains(&nome) {
                    return Err(erro(format!("categoria repetida: {nome}")));
                }
                vistas.push(nome);
            }
            let mut saida = Map::new();
            saida.insert("categorias".into(), Value::Array(cats.clone()));
            for k in ["confirmado", "avancado", "resetBase"] {
                copiar_bool(&m, &mut saida, k)?;
            }
            let perigosa = vistas
                .iter()
                .any(|c| matches!(*c, "windows_old" | "pontos_antigos"));
            if perigosa && saida.get("confirmado") != Some(&Value::Bool(true)) {
                return Err(erro("confirmado:true é obrigatório para esta categoria"));
            }
            Ok(Value::Object(saida))
        }
        _ => Err(ErroValidacao::NaoPermitida(format!("{modulo}/{acao}"))),
    }
}

#[cfg(test)]
mod testes {
    use super::*;
    use serde_json::json;

    fn parametro<T: std::fmt::Debug>(r: Result<T, ErroValidacao>) {
        assert!(matches!(r, Err(ErroValidacao::Parametro(_))), "{r:?}");
    }

    #[test]
    fn limpar_valido() {
        let p = json!({"categorias":["temp_usuario","lixeira"]});
        assert_eq!(validar("limpeza", "limpar", &p, false).unwrap(), p);
    }

    #[test]
    fn limpar_categorias_invalidas() {
        parametro(validar(
            "limpeza",
            "limpar",
            &json!({"categorias":[]}),
            false,
        ));
        parametro(validar("limpeza", "limpar", &json!({}), false));
        parametro(validar(
            "limpeza",
            "limpar",
            &json!({"categorias":["temp_usuario","temp_usuario"]}),
            false,
        ));
        parametro(validar(
            "limpeza",
            "limpar",
            &json!({"categorias":["registro"]}),
            false,
        ));
        parametro(validar(
            "limpeza",
            "limpar",
            &json!({"categorias":[1]}),
            false,
        ));
    }

    #[test]
    fn limpar_exige_confirmacao_para_categorias_perigosas() {
        for c in ["windows_old", "pontos_antigos"] {
            parametro(validar(
                "limpeza",
                "limpar",
                &json!({"categorias":[c]}),
                false,
            ));
            parametro(validar(
                "limpeza",
                "limpar",
                &json!({"categorias":[c],"confirmado":false}),
                false,
            ));
            assert!(
                validar(
                    "limpeza",
                    "limpar",
                    &json!({"categorias":[c],"confirmado":true}),
                    false
                )
                .is_ok()
            );
        }
    }

    #[test]
    fn limpar_chave_extra_e_booleanos() {
        parametro(validar(
            "limpeza",
            "limpar",
            &json!({"categorias":["lixeira"],"extra":1}),
            false,
        ));
        parametro(validar(
            "limpeza",
            "limpar",
            &json!({"categorias":["lixeira"],"avancado":"s"}),
            false,
        ));
        let p = json!({"categorias":["lixeira"],"resetBase":true,"avancado":true});
        assert_eq!(validar("limpeza", "limpar", &p, false).unwrap(), p);
    }

    #[test]
    fn analisar() {
        let p = json!({"avancado":true});
        assert_eq!(validar("limpeza", "analisar", &p, false).unwrap(), p);
        assert_eq!(
            validar("limpeza", "analisar", &json!(null), false).unwrap(),
            json!({})
        );
        parametro(validar("limpeza", "analisar", &json!({"x":1}), false));
    }

    #[test]
    fn nao_permitida() {
        let r = validar("programas", "listar", &json!({}), false);
        assert!(matches!(r, Err(ErroValidacao::NaoPermitida(ref s)) if s == "programas/listar"));
        assert!(matches!(
            validar("limpeza", "apagar", &json!({}), false),
            Err(ErroValidacao::NaoPermitida(_))
        ));
    }

    #[test]
    fn ping() {
        assert_eq!(
            validar("host", "ping", &json!(null), false).unwrap(),
            json!({})
        );
        assert!(validar("host", "ping", &json!({}), false).is_ok());
        parametro(validar("host", "ping", &json!({"a":1}), false));
    }

    #[test]
    fn coletar_simular_so_em_teste() {
        parametro(validar(
            "diagnostico",
            "coletar",
            &json!({"simular":{}}),
            false,
        ));
        assert!(validar("diagnostico", "coletar", &json!({"simular":{}}), true).is_ok());
        parametro(validar(
            "diagnostico",
            "coletar",
            &json!({"simular":1}),
            true,
        ));
    }

    #[test]
    fn coletar_forcar_perfil() {
        let p = json!({"forcarPerfil":{"classe":"gamer","disco":"hdd"}});
        assert_eq!(validar("diagnostico", "coletar", &p, false).unwrap(), p);
        parametro(validar(
            "diagnostico",
            "coletar",
            &json!({"forcarPerfil":{"classe":"x","disco":"hdd"}}),
            false,
        ));
        parametro(validar(
            "diagnostico",
            "coletar",
            &json!({"forcarPerfil":{"classe":"gamer"}}),
            false,
        ));
        parametro(validar(
            "diagnostico",
            "coletar",
            &json!({"outra":1}),
            false,
        ));
        assert!(validar("diagnostico", "coletar", &json!({}), false).is_ok());
    }

    #[test]
    fn modulos() {
        assert_eq!(modulos_permitidos().len(), 3);
        assert_eq!(CATEGORIAS_LIMPEZA.len(), 14);
    }
}
