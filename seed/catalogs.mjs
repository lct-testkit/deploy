// Демо-данные справочников (агент B): направления, причины отказа, праздники 2026, пользовательские поля. Идемпотентно: существующие коды пропускаются.
//   node tools/scenarios/b-seed-catalogs.mjs
import { BASE, ACCOUNTS, ensureConsent } from './lib.mjs';

const config = await (await fetch(`${BASE}/config.json`)).json();
const kc = config.keycloak;
const login = async (who) => {
	const a = ACCOUNTS[who];
	const res = await fetch(`${BASE}${kc.path}/realms/${kc.realm}/protocol/openid-connect/token`, {
		method: 'POST',
		headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
		body: new URLSearchParams({ grant_type: 'password', client_id: kc.clientId, client_secret: kc.clientSecret ?? '', scope: 'openid', username: a.username, password: a.password })
	});
	return (await res.json()).access_token;
};
const token = await login('admin');
await fetch(`${BASE}/api/me`, { headers: { Authorization: `Bearer ${token}` } }); // JIT первым запросом
await ensureConsent('admin', { access_token: token });
const call = async (method, path, body) => {
	const res = await fetch(BASE + path, {
		method,
		headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'Idempotency-Key': crypto.randomUUID() },
		body: body ? JSON.stringify(body) : undefined
	});
	const text = await res.text();
	return { status: res.status, json: text ? JSON.parse(text) : null };
};
const list = async (path) => (await call('GET', path)).json.items;
let created = 0;
const make = async (path, body, label) => {
	const r = await call('POST', path, body);
	if (r.status === 201) created++;
	else console.log(`  ! ${label}: ${r.status} ${JSON.stringify(r.json).slice(0, 160)}`);
	return r.json;
};

// --- направления
const dirs = await list('/api/directions?limit=100');
const dirId = new Map(dirs.map((d) => [d.code, d.id]));
const tree = [
	['programming', 'Программирование', null],
	['python', 'Python', 'programming'],
	['java', 'Java', 'programming'],
	['web', 'Веб-разработка', 'programming'],
	['data', 'Анализ данных', null],
	['ml', 'Машинное обучение', 'data'],
	['security', 'Информационная безопасность', null],
	['infra', 'Инфраструктура', null],
	['devops', 'DevOps', 'infra']
];
for (const [code, name, parent] of tree) {
	if (dirId.has(code)) continue;
	const d = await make('/api/directions', { code, name, parent_id: parent ? dirId.get(parent) : null }, `направление ${code}`);
	if (d?.id) dirId.set(code, d.id);
}

// --- причины отказа
const reasons = new Set((await list('/api/loss-reasons')).map((r) => r.code));
const lost = [
	['too_expensive', 'Слишком дорого', 'price'],
	['no_budget', 'Нет бюджета', 'no_budget'],
	['competitor', 'Выбрали конкурента', 'competitor'],
	['no_need', 'Нет потребности', 'no_need'],
	['bad_timing', 'Не подошли сроки', 'timing'],
	['no_answer', 'Нет ответа от вуза', 'no_contact'],
	['other', 'Другая причина', 'other']
];
let order = 10;
for (const [code, name, category] of lost) {
	if (!reasons.has(code)) await make('/api/loss-reasons', { code, name, category, sort_order: order }, `причина ${code}`);
	order += 10;
}

// --- производственный календарь 2026 (по данным производственного календаря РФ)
const have = new Set((await list('/api/holidays?date_from=2026-01-01&date_to=2026-12-31')).map((h) => h.date));
const holidays = [
	['2026-01-01', 'Новогодние каникулы'],
	['2026-01-02', 'Новогодние каникулы'],
	['2026-01-05', 'Новогодние каникулы'],
	['2026-01-06', 'Новогодние каникулы'],
	['2026-01-07', 'Рождество Христово'],
	['2026-01-08', 'Новогодние каникулы'],
	['2026-01-09', 'Перенос выходного с 3 января'],
	['2026-02-23', 'День защитника Отечества'],
	['2026-03-09', 'Перенос с 8 марта (Международный женский день)'],
	['2026-05-01', 'Праздник Весны и Труда'],
	['2026-05-11', 'Перенос с 9 мая (День Победы)'],
	['2026-06-12', 'День России'],
	['2026-11-04', 'День народного единства'],
	['2026-12-31', 'Предновогодний выходной']
];
for (const [date, name] of holidays) if (!have.has(date)) await make('/api/holidays', { date, name, is_working_day: false }, `праздник ${date}`);

// --- пользовательские поля сделки: их использует конструктор условий воронок
const defs = new Set((await list('/api/custom-field-defs?entity_type=deal')).map((d) => d.code));
const fields = [
	['contract_number', 'Номер договора', 'string', null],
	['license_signed', 'Лицензия подписана', 'bool', null],
	['license_valid_until', 'Срок действия лицензии', 'date', null],
	['payment_confirmed', 'Оплата подтверждена', 'bool', null],
	['park_reason', 'Причина заморозки', 'string', null],
	['resume_at', 'Вернуться к сделке', 'date', null],
	['vendor', 'Вендор', 'select', { choices: ['Яндекс', 'VK', 'Сбер', 'Ростелеком', 'Другой'] }]
];
let sort = 10;
for (const [code, label, field_type, options] of fields) {
	if (!defs.has(code)) await make('/api/custom-field-defs', { entity_type: 'deal', code, label, field_type, options, is_required: false, sort_order: sort }, `поле ${code}`);
	sort += 10;
}

console.log(`Создано записей: ${created}`);
