// Демо-данные для экранов «Удаление ПДн» и «Согласования»: два администратора проходят «четыре глаза».
//   node tools/scenarios/lead-seed-erasure.mjs
import { BASE, accessToken, ensureConsent } from './lib.mjs';

const tokens = {};
for (const who of ['admin', 'admin2']) {
	tokens[who] = await accessToken(who);
	await ensureConsent(who, { access_token: tokens[who] });
}

async function call(who, method, path, body) {
	const res = await fetch(`${BASE}${path}`, {
		method,
		headers: { Authorization: `Bearer ${tokens[who]}`, 'Content-Type': 'application/json', 'Idempotency-Key': crypto.randomUUID() },
		body: body === undefined ? undefined : JSON.stringify(body)
	});
	const text = await res.text();
	const json = text ? JSON.parse(text) : null;
	return { status: res.status, json };
}

async function contact(last, first) {
	const found = await call('admin', 'GET', `/api/contacts?q=${encodeURIComponent(last)}&limit=5`);
	const hit = found.json?.items?.find((c) => c.last_name === last);
	if (hit) return hit;
	const made = await call('admin', 'POST', '/api/contacts', { last_name: last, first_name: first, position: 'Демо-контакт для удаления', email: `${last.toLowerCase()}@example.test` });
	if (made.status >= 300) throw new Error(`create contact ${last}: ${made.status} ${JSON.stringify(made.json)}`);
	return made.json;
}

async function requestErasure(who, contactId, body, kind = 'contacts') {
	const first = await call(who, 'POST', `/api/admin/${kind}/${contactId}/erasure-request`, body);
	if (first.status < 300) return first.json;
	const approvalId = first.json?.extra?.approval_id ?? first.json?.approval_id;
	if (!approvalId) throw new Error(`erasure ${contactId}: ${first.status} ${JSON.stringify(first.json)}`);
	const approve = await call(who === 'admin' ? 'admin2' : 'admin', 'POST', `/api/admin/approvals/${approvalId}/approve`);
	if (approve.status >= 300) throw new Error(`approve ${approvalId}: ${approve.status} ${JSON.stringify(approve.json)}`);
	const second = await call(who, 'POST', `/api/admin/${kind}/${contactId}/erasure-request`, { ...body, approval_id: approvalId });
	if (second.status >= 300) throw new Error(`erasure (approved) ${contactId}: ${second.status} ${JSON.stringify(second.json)}`);
	return second.json;
}

const existing = await call('admin', 'GET', '/api/admin/erasure-requests?limit=100');
const have = new Set((existing.json?.items ?? []).map((r) => r.subject_id));

const a = await contact('Удаляемов', 'Пётр');
if (!have.has(a.id)) console.log('request A →', (await requestErasure('admin', a.id, { mode: 'anonymize', reason: 'Отзыв согласия на обработку', legal_basis: 'ст. 9 152-ФЗ — отзыв согласия на обработку ПДн' })).status);

const b = await contact('Отказников', 'Олег');
if (!have.has(b.id)) {
	const made = await requestErasure('admin', b.id, { mode: 'anonymize', reason: 'Запрос по электронной почте', legal_basis: 'ст. 21 152-ФЗ — требование субъекта об уничтожении ПДн' });
	const rej = await call('admin', 'POST', `/api/admin/erasure-requests/${made.id}/reject`, { reason: 'Действующий договор с организацией, срок хранения не истёк' });
	console.log('request B rejected →', rej.status);
}

// сотрудник с активной учётной записью: запрос сразу заблокирован (блокеры «Учётная запись активна» и т.п.)
const users = await call('admin', 'GET', '/api/admin/users?q=Петров&limit=5');
const head = users.json?.items?.find((u) => u.email?.startsWith('petrov'));
if (head && !have.has(head.id)) {
	const made = await requestErasure('admin', head.id, { mode: 'anonymize', reason: 'Демонстрация блокеров', legal_basis: 'увольнение сотрудника, истечение срока хранения' }, 'users');
	console.log('request C →', made.status, (made.blockers ?? []).map((b) => b.code).join(','));
}

const list = await call('admin', 'GET', '/api/admin/erasure-requests?limit=100');
console.log((list.json?.items ?? []).map((r) => `${r.id.slice(0, 8)} ${r.subject_type} ${r.status} blockers=${r.blockers?.length ?? 0}`).join('\n'));
