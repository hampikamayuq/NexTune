'use strict';

let textos = {};

// t('chave', {var: valor}) -> texto; chave faltante devolve [chave] para ser fácil de notar.
function t(chave, vars) {
  const s = textos[chave];
  if (s === undefined) return '[' + chave + ']';
  if (!vars) return s;
  return s.replace(/\{(\w+)\}/g, (m, n) => (vars[n] !== undefined ? String(vars[n]) : m));
}

// Os textos vêm de i18n/pt-BR.js (script clássico), pois o CSP do app bloqueia fetch (connect-src 'none').
function carregarI18n() {
  const dic = window.I18N && window.I18N['pt-BR'];
  if (!dic) throw new Error('Textos em português (i18n/pt-BR.js) não foram carregados: pacote da interface incompleto.');
  textos = dic;
}

// Preenche os textos estáticos do HTML.
function aplicarI18n(raiz) {
  const base = raiz || document;
  base.querySelectorAll('[data-i18n]').forEach((el) => { el.textContent = t(el.dataset.i18n); });
  base.querySelectorAll('[data-i18n-title]').forEach((el) => { el.title = t(el.dataset.i18nTitle); });
  base.querySelectorAll('[data-i18n-aria]').forEach((el) => { el.setAttribute('aria-label', t(el.dataset.i18nAria)); });
}
