// Testes ponta a ponta do app web (Flutter) contra uma API com dados de demonstração.
// Uso: BASE_URL=http://localhost:8080 node smoke.mjs
import assert from 'node:assert/strict';
import { chromium } from 'playwright';

const BASE = process.env.BASE_URL ?? 'http://localhost:8080';
const API = `${BASE}/api/v1`;
const results = [];

async function api(path, { token, method = 'GET', body } = {}) {
  const res = await fetch(`${API}${path}`, {
    method,
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  return { status: res.status, json: text ? JSON.parse(text) : null };
}

async function login(email, password = 'pontomax123') {
  const r = await api('/auth/login', { method: 'POST', body: { email, password } });
  assert.equal(r.status, 200, `login ${email}`);
  return r.json.access_token;
}

async function newPage(browser, opts = {}) {
  const ctx = await browser.newContext({
    viewport: { width: 1280, height: 800 },
    locale: 'pt-BR',
    timezoneId: 'America/Sao_Paulo',
    ...opts,
  });
  const page = await ctx.newPage();
  page.on('pageerror', (e) => console.error('pageerror:', e.message));
  return page;
}

/// Abre o app e ativa a árvore de acessibilidade do Flutter (rótulos no DOM).
async function open(page, hash = '') {
  await page.goto(`${BASE}/app/${hash}`, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1500);
  await page.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
  await page.waitForTimeout(500);
}

async function uiLogin(page, email) {
  await open(page);
  await page.getByRole('textbox', { name: 'E-mail' }).click();
  await page.keyboard.type(email);
  await page.getByRole('textbox', { name: 'Senha' }).click();
  await page.keyboard.type('pontomax123');
  await page.getByRole('button', { name: 'Entrar' }).first().click();
  await page.waitForTimeout(3000);
}

async function step(name, fn) {
  const t = Date.now();
  try {
    await fn();
    results.push({ name, ok: true, ms: Date.now() - t });
    console.log(`✔ ${name}`);
  } catch (e) {
    results.push({ name, ok: false, error: e.message });
    console.error(`✘ ${name}: ${e.message}`);
  }
}

const browser = await chromium.launch();

await step('site institucional responde', async () => {
  const res = await fetch(`${BASE}/`);
  assert.equal(res.status, 200);
  assert.match(await res.text(), /PontoMax/);
});

await step('gestor entra e vê o painel', async () => {
  const page = await newPage(browser);
  await uiLogin(page, 'admin@pontomax.app');
  assert.match(page.url(), /#\/painel/);
  await page.close();
});

await step('colaboradora bate o ponto com GPS dentro do perímetro', async () => {
  const token = await login('fernanda@pontomax.app');
  const before = (await api('/punches/today', { token })).json.punches.length;
  const page = await newPage(browser, {
    geolocation: { latitude: -23.5643, longitude: -46.6529, accuracy: 15 },
    permissions: ['geolocation'],
  });
  await uiLogin(page, 'fernanda@pontomax.app');
  assert.match(page.url(), /#\/ponto/);
  await page.getByRole('button', { name: /^Registrar ponto: / }).click();
  await page.getByRole('button', { name: 'Confirmar registro' }).click();
  await page.waitForTimeout(2500);
  const after = (await api('/punches/today', { token })).json.punches;
  assert.equal(after.length, before + 1, 'marcação registrada');
  const last = after[after.length - 1];
  assert.equal(last.inside_geofence, true);
  assert.equal(last.source, 'browser');
  assert.ok(last.nsr > 0 && last.hash.length === 64, 'NSR e hash');
  await page.close();
});

await step('quiosque: ativação e marcação com PIN', async () => {
  const admin = await login('admin@pontomax.app');
  const dev = await api('/devices', { token: admin, method: 'POST', body: { name: `E2E ${Date.now()}` } });
  assert.equal(dev.status, 201);
  const page = await newPage(browser);
  await open(page, '#/kiosk/ativar');
  await page.getByRole('textbox', { name: 'Código de ativação' }).click();
  await page.keyboard.type(dev.json.activation_code);
  await page.getByRole('button', { name: 'Ativar' }).click();
  await page.waitForTimeout(3000);
  const ana = await login('ana@pontomax.app');
  const before = (await api('/punches/today', { token: ana })).json.punches.length;
  for (const k of ['0', '0', '3', 'OK', '1', '2', '3', '4', 'OK']) {
    await page.getByRole('button', { name: k, exact: true }).click();
    await page.waitForTimeout(150);
  }
  await page.waitForTimeout(2500);
  const after = (await api('/punches/today', { token: ana })).json.punches;
  assert.equal(after.length, before + 1, 'marcação pelo quiosque');
  assert.equal(after[after.length - 1].source, 'device');
  await page.close();
});

await browser.close();
const failed = results.filter((r) => !r.ok);
console.log(`\n${results.length - failed.length}/${results.length} cenários aprovados`);
process.exit(failed.length ? 1 : 0);
