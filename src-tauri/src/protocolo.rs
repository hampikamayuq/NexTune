use serde_json::Value;

/// Mensagem emitida pelo host (stdout) no protocolo `@@TIPO {json}`.
#[derive(Debug, Clone, PartialEq)]
pub enum Mensagem {
    Progresso {
        id: String,
        pct: u8,
        msg: String,
    },
    Log {
        id: String,
        tipo: String,
        msg: String,
        ruta: String,
    },
    Resultado {
        id: String,
        ok: bool,
        dados: Value,
        erro: String,
    },
}

fn texto(v: &Value, chave: &str) -> String {
    v.get(chave)
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string()
}

/// Interpreta uma linha do host; `None` para linhas fora do protocolo.
pub fn parse_linha(linha: &str) -> Option<Mensagem> {
    let linha = linha.trim_start_matches('\u{feff}').trim_end_matches('\r');
    let (prefixo, json) = linha.split_once(' ').unwrap_or((linha, ""));
    let v: Value = serde_json::from_str(json).ok()?;
    if !v.is_object() {
        return None;
    }
    let id = texto(&v, "id");
    match prefixo {
        "@@PROGRESS" => {
            let pct = v
                .get("pct")
                .and_then(Value::as_f64)
                .unwrap_or(0.0)
                .clamp(0.0, 100.0) as u8;
            Some(Mensagem::Progresso {
                id,
                pct,
                msg: texto(&v, "msg"),
            })
        }
        "@@LOG" => Some(Mensagem::Log {
            id,
            tipo: texto(&v, "tipo"),
            msg: texto(&v, "msg"),
            ruta: texto(&v, "ruta"),
        }),
        "@@RESULT" => Some(Mensagem::Resultado {
            id,
            ok: v.get("ok").and_then(Value::as_bool).unwrap_or(false),
            dados: v.get("dados").cloned().unwrap_or(Value::Null),
            erro: texto(&v, "erro"),
        }),
        _ => None,
    }
}

/// Linha de comando para o stdin do host (JSON compacto, sem '\n' interno).
pub fn comando_json(id: &str, modulo: &str, acao: &str, params: &Value, teste: bool) -> String {
    serde_json::json!({
        "id": id,
        "modulo": modulo,
        "acao": acao,
        "params": params,
        "teste": teste,
    })
    .to_string()
}

#[cfg(test)]
mod testes {
    use super::*;
    use serde_json::json;

    #[test]
    fn resultado_ok() {
        let m =
            parse_linha("@@RESULT {\"id\":\"a1\",\"ok\":true,\"dados\":{\"x\":1},\"erro\":\"\"}");
        match m {
            Some(Mensagem::Resultado {
                id,
                ok,
                dados,
                erro,
            }) => {
                assert_eq!(id, "a1");
                assert!(ok);
                assert_eq!(dados["x"], 1);
                assert_eq!(erro, "");
            }
            outro => panic!("inesperado: {outro:?}"),
        }
    }

    #[test]
    fn progresso() {
        let m = parse_linha("@@PROGRESS {\"id\":\"a1\",\"pct\":40,\"msg\":\"Medindo\"}");
        assert_eq!(
            m,
            Some(Mensagem::Progresso {
                id: "a1".into(),
                pct: 40,
                msg: "Medindo".into()
            })
        );
    }

    #[test]
    fn progresso_pct_fora_da_faixa_e_limitado() {
        let m = parse_linha("@@PROGRESS {\"id\":\"a\",\"pct\":250,\"msg\":\"\"}");
        assert!(matches!(m, Some(Mensagem::Progresso { pct: 100, .. })));
        let m = parse_linha("@@PROGRESS {\"id\":\"a\",\"pct\":-5,\"msg\":\"\"}");
        assert!(matches!(m, Some(Mensagem::Progresso { pct: 0, .. })));
    }

    #[test]
    fn log_com_e_sem_ruta() {
        let m =
            parse_linha("@@LOG {\"id\":\"a1\",\"tipo\":\"ok\",\"msg\":\"m\",\"ruta\":\"C:\\\\x\"}");
        assert_eq!(
            m,
            Some(Mensagem::Log {
                id: "a1".into(),
                tipo: "ok".into(),
                msg: "m".into(),
                ruta: "C:\\x".into()
            })
        );
        let m = parse_linha("@@LOG {\"id\":\"a1\",\"tipo\":\"ok\",\"msg\":\"m\"}");
        assert!(matches!(m, Some(Mensagem::Log { ruta, .. }) if ruta.is_empty()));
    }

    #[test]
    fn resultado_dados_null_e_erro_ausente() {
        let m = parse_linha("@@RESULT {\"id\":\"a\",\"ok\":false,\"dados\":null}");
        match m {
            Some(Mensagem::Resultado {
                ok, dados, erro, ..
            }) => {
                assert!(!ok);
                assert!(dados.is_null());
                assert_eq!(erro, "");
            }
            outro => panic!("inesperado: {outro:?}"),
        }
    }

    #[test]
    fn linhas_fora_do_protocolo() {
        assert!(parse_linha("AVISO: algo").is_none());
        assert!(parse_linha("").is_none());
        assert!(parse_linha("@@RESULT {json quebrado").is_none());
    }

    #[test]
    fn bom_e_cr_sao_aceitos() {
        match parse_linha("\u{feff}@@RESULT {}") {
            Some(Mensagem::Resultado { id, .. }) => assert_eq!(id, ""),
            outro => panic!("inesperado: {outro:?}"),
        }
        assert!(parse_linha("@@PROGRESS {\"id\":\"a\",\"pct\":1,\"msg\":\"\"}\r").is_some());
    }

    #[test]
    fn comando_json_e_uma_linha() {
        let s = comando_json(
            "a1",
            "limpeza",
            "limpar",
            &json!({"categorias":["temp_usuario"],"nota":"a\nb"}),
            false,
        );
        assert!(!s.contains('\n'));
        let v: serde_json::Value = serde_json::from_str(&s).unwrap();
        assert_eq!(v["id"], "a1");
        assert_eq!(v["modulo"], "limpeza");
        assert_eq!(v["acao"], "limpar");
        assert_eq!(v["params"]["categorias"][0], "temp_usuario");
        assert_eq!(v["teste"], json!(false));
    }
}
