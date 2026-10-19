// Помощники сценариев спринта F3: сделка в воронке по умолчанию (14 шагов), доведённая до нужного шага, и загрузка PDF в сделку цепочкой API
// (upload-intent -> PUT в хранилище -> commit -> POST /api/attachments). Файловые условия `step_attachments.*` закрываются приложенным PDF.
import http from 'node:http';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { BASE, accessToken } from './lib.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const pdf = readFileSync(join(here, 'fixtures', 'contract.pdf'));

/** Клиент API под ролью: `j(path, init)` -> { status, body }. */
export async function apiAs(role) {
	const H = { Authorization: `Bearer ${await accessToken(role)}`, 'Content-Type': 'application/json' };
	return async (path, init) => {
		const r = await fetch(`${BASE}${path}`, { ...init, headers: { ...H, ...(init?.headers ?? {}) } });
		const t = await r.text();
		let body;
		try {
			body = JSON.parse(t);
		} catch {
			body = t;
		}
		return { status: r.status, body };
	};
}

// предварительно подписанный URL хранилища подписывает content-type, поэтому он обязателен; fetch Node добавляет лишние заголовки
function putRaw(url, body) {
	return new Promise((resolve, reject) => {
		const u = new URL(url);
		const req = http.request({ method: 'PUT', hostname: u.hostname, port: u.port, path: u.pathname + u.search, headers: { 'Content-Length': body.length, 'Content-Type': 'application/pdf' } }, (res) => {
			let t = '';
			res.on('data', (c) => (t += c));
			res.on('end', () => (res.statusCode < 300 ? resolve() : reject(new Error(`PUT в хранилище: ${res.statusCode} ${t.slice(0, 200)}`))));
		});
		req.on('error', reject);
		req.end(body);
	});
}

/** Загрузить PDF и привязать к сделке; возвращает id вложения. */
export async function attachPdf(j, dealId, category, name = `${category}.pdf`) {
	const intent = await j('/api/files/upload-intent', { method: 'POST', headers: { 'Idempotency-Key': crypto.randomUUID() }, body: JSON.stringify({ filename: name, size_bytes: pdf.length, mime_type: 'application/pdf', category }) });
	if (intent.status >= 300) throw new Error('upload-intent: ' + JSON.stringify(intent.body).slice(0, 200));
	await putRaw(intent.body.upload_url, pdf);
	const commit = await j(`/api/files/${intent.body.file_id}/commit`, { method: 'POST', body: JSON.stringify({ sha256: null }) });
	if (commit.status >= 300) throw new Error('commit: ' + JSON.stringify(commit.body).slice(0, 200));
	for (let i = 0; i < 6; i += 1) {
		const a = await j('/api/attachments', { method: 'POST', headers: { 'Idempotency-Key': crypto.randomUUID() }, body: JSON.stringify({ file_id: intent.body.file_id, entity_type: 'deal', entity_id: dealId, category, description: name }) });
		if (a.status < 300) return a.body.id;
		if (!/не прошёл проверку/.test(JSON.stringify(a.body))) throw new Error('attachments: ' + JSON.stringify(a.body).slice(0, 200));
		await new Promise((r) => setTimeout(r, 2000));
	}
	throw new Error('файл не прошёл проверку');
}

/** Новая сделка в воронке по умолчанию (B2B, 14 шагов), доведённая до шага, в названии которого есть `fragment`. */
export async function walkDeal(role, fragment, title) {
	const j = await apiAs(role);
	const wfs = (await j('/api/workflows?state=published&limit=20')).body.items;
	const wf = wfs.find((w) => w.deal_type === 'b2b' && w.is_default);
	const g = (await j(`/api/workflows/${wf.id}`)).body;
	const statuses = (g.graph ?? g).statuses.filter((s) => !s.is_archived).sort((a, b) => a.sort_order - b.sort_order);
	const org = (await j('/api/organizations?limit=1')).body.items[0];
	const contact = (await j(`/api/contacts?organization_id=${org.id}&limit=1`)).body.items[0];
	let deal = (await j('/api/deals', { method: 'POST', headers: { 'Idempotency-Key': crypto.randomUUID() }, body: JSON.stringify({ title, deal_type: 'b2b', organization_id: org.id, contact_id: contact?.id, workflow_id: wf.id, amount: '100000', currency: 'RUB', priority: 'normal', expected_close_date: '2027-03-01' }) })).body;
	for (let i = 0; i < 15; i += 1) {
		const cur = statuses.find((s) => s.id === deal.status_id);
		if (cur.name.toLowerCase().includes(fragment.toLowerCase())) break;
		const av = (await j(`/api/deals/${deal.id}/available-transitions`)).body.items;
		const order = (id) => statuses.find((s) => s.id === id)?.sort_order;
		const next = av
			.filter((t) => order(t.to_status_id) > cur.sort_order && statuses.find((s) => s.id === t.to_status_id)?.type === 'intermediate')
			.sort((a, b) => order(a.to_status_id) - order(b.to_status_id))[0];
		if (!next) throw new Error(`нет перехода вперёд из «${cur.name}»`);
		const ids = [];
		for (const leaf of next.conditions ?? []) {
			const m = !leaf.satisfied && /^step_attachments\.(.+)$/.exec(leaf.field);
			if (m && !ids.length) ids.push(await attachPdf(j, deal.id, m[1]));
		}
		const res = await j(`/api/deals/${deal.id}/transition`, { method: 'POST', headers: { 'If-Match': `"${deal.version}"` }, body: JSON.stringify({ to_status_id: next.to_status_id, comment: 'проверка', fields: {}, attachments: ids }) });
		if (res.status !== 200) throw new Error(`переход «${next.name}»: ${res.status} ${JSON.stringify(res.body).slice(0, 300)}`);
		deal = res.body.deal;
	}
	return { deal, j, statuses };
}

/** Мягко удалить сделки по точному названию (нужна роль admin). */
export async function deleteDealsByTitle(title) {
	const j = await apiAs('admin');
	let n = 0;
	for (;;) {
		const page = (await j(`/api/deals?q=${encodeURIComponent(title)}&limit=100`)).body;
		const mine = (page.items ?? []).filter((d) => d.title === title);
		if (!mine.length) return n;
		for (const d of mine) {
			const r = await j(`/api/deals/${d.id}`, { method: 'DELETE', headers: { 'If-Match': `"${d.version}"` }, body: JSON.stringify({ reason: 'тестовая сделка сценария' }) });
			if (r.status >= 300) return n;
			n += 1;
		}
	}
}

/**
 * Сделка B2B по маршруту: числа — номера шагов из задания (1…14), 'park' — заморозка, 'lost' — отказ.
 *   dealAlong('kam', 'Название', [2, 3, 4, 6, 7, 8, 6])  // пропуск шага 5 и возврат с 8 на 6
 * Файловые условия переходов закрываются приложенным PDF, поля заморозки и отказа заполняются.
 */
export async function dealAlong(role, title, route) {
	const j = await apiAs(role);
	const wfs = (await j('/api/workflows?state=published&limit=20')).body.items;
	const wf = wfs.find((w) => w.deal_type === 'b2b' && w.is_default);
	const g = (await j(`/api/workflows/${wf.id}`)).body;
	const all = g.statuses.filter((s) => !s.is_archived);
	const stepList = all.filter((s) => s.type === 'initial' || s.type === 'intermediate').sort((a, b) => a.sort_order - b.sort_order);
	const org = (await j('/api/organizations?limit=1')).body.items[0];
	const contact = (await j(`/api/contacts?organization_id=${org.id}&limit=1`)).body.items[0];
	let deal = (await j('/api/deals', { method: 'POST', headers: { 'Idempotency-Key': crypto.randomUUID() }, body: JSON.stringify({ title, deal_type: 'b2b', organization_id: org.id, contact_id: contact?.id, workflow_id: wf.id, amount: '100000', currency: 'RUB', priority: 'normal', expected_close_date: '2027-03-01' }) })).body;
	const reasons = (await j('/api/loss-reasons?is_active=true')).body.items;
	for (const stop of route) {
		const target = stop === 'park' ? all.find((s) => s.type === 'parked') : stop === 'lost' ? all.find((s) => s.type === 'lost') : stepList[stop - 1];
		const av = (await j(`/api/deals/${deal.id}/available-transitions`)).body.items;
		const t = av.find((x) => x.to_status_id === target.id);
		if (!t) throw new Error(`нет перехода в «${target.name}» из «${all.find((s) => s.id === deal.status_id)?.name}»`);
		const ids = [];
		for (const leaf of t.conditions ?? []) {
			const m = !leaf.satisfied && /^step_attachments\.(.+)$/.exec(leaf.field);
			if (m && !ids.length) ids.push(await attachPdf(j, deal.id, m[1]));
		}
		const fields = {};
		if (target.type === 'lost') fields.loss_reason_id = reasons[0]?.id;
		if (target.type === 'parked') fields['custom_fields.park_reason'] = 'Решение учёного совета отложено';
		const res = await j(`/api/deals/${deal.id}/transition`, { method: 'POST', headers: { 'If-Match': `"${deal.version}"` }, body: JSON.stringify({ to_status_id: target.id, comment: t.requires_comment ? 'Переход по демо-сценарию.' : null, fields, attachments: ids }) });
		if (res.status !== 200) throw new Error(`переход в «${target.name}»: ${res.status} ${JSON.stringify(res.body).slice(0, 300)}`);
		deal = res.body.deal;
	}
	return { deal, j };
}
