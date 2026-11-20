'use strict';

let I18N = {};

// t('chave', {var: valor}) -> texto; chave faltante devolve [chave] para ser fácil de notar.
function t(chave, vars) {
  const s = I18N[chave];
  if (s === undefined) return '[' + chave + ']';
  if (!vars) return s;
  return s.replace(/\{(\w+)\}/g, (m, n) => (vars[n] !== undefined ? String(vars[n]) : m));
}

async function carregarI18n() {
  const r = await fetch('i18n/pt-BR.json');
  if (!r.ok) throw new Error('i18n ' + r.status);
  I18N = await r.json();
}

// Preenche os textos estáticos do HTML.
function aplicarI18n(raiz) {
  const base = raiz || document;
  base.querySelectorAll('[data-i18n]').forEach((el) => { el.textContent = t(el.dataset.i18n); });
  base.querySelectorAll('[data-i18n-title]').forEach((el) => { el.title = t(el.dataset.i18nTitle); });
  base.querySelectorAll('[data-i18n-aria]').forEach((el) => { el.setAttribute('aria-label', t(el.dataset.i18nAria)); });
}
