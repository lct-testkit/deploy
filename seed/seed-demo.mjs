// Демо-данные через API живого бэкенда (агент A). Идемпотентно: организации ищутся по ИНН, контакты — по фамилии
// в организации, сделки — по названию; повторный запуск ничего не дублирует, переходы делаются только для новых сделок.
//   node tools/seed-demo.mjs            (по умолчанию http://localhost:5273 → прокси на бэкенд)
//   APP_URL=http://localhost:8080 node tools/seed-demo.mjs
import { BASE, accessToken, ensureConsent } from './lib.mjs';

// ---------------------------------------------------------------- HTTP
const tokens = {};
async function login(who) {
	const token = await accessToken(who);
	await ensureConsent(who, { access_token: token });
	tokens[who] = token;
}

async function call(who, method, path, body, headers = {}) {
	const res = await fetch(`${BASE}${path}`, {
		method,
		headers: { Authorization: `Bearer ${tokens[who]}`, 'Content-Type': 'application/json', ...headers },
		body: body === undefined ? undefined : JSON.stringify(body)
	});
	const text = await res.text();
	let json = null;
	try {
		json = text ? JSON.parse(text) : null;
	} catch {
		// not JSON (an error page): json stays null
	}
	if (!res.ok) {
		const err = new Error(`${method} ${path} → ${res.status} ${json?.code ?? ''} ${json?.detail ?? text.slice(0, 200)}`);
		err.status = res.status;
		err.code = json?.code;
		err.body = json;
		throw err;
	}
	return json;
}
const get = (who, path) => call(who, 'GET', path);
const post = (who, path, body, headers) => call(who, 'POST', path, body, headers);
const ifMatch = (v) => ({ 'If-Match': `"${v}"` });
const idem = () => ({ 'Idempotency-Key': crypto.randomUUID() });

// ---------------------------------------------------------------- реквизиты
const INN10 = [2, 4, 10, 3, 5, 9, 4, 6, 8];
function inn10(prefix9) {
	const sum = [...prefix9].reduce((acc, d, i) => acc + Number(d) * INN10[i], 0);
	return prefix9 + String((sum % 11) % 10);
}
function ogrn13(prefix12) {
	return prefix12 + String((Number(prefix12) % 11) % 10);
}
const daysFromNow = (days) => new Date(Date.now() + days * 86_400_000).toISOString();
const dateFromNow = (days) => daysFromNow(days).slice(0, 10);

// ---------------------------------------------------------------- данные
const ORGS = [
	{ inn: inn10('165501234'), name: 'Казанский государственный технологический университет', short: 'КГТУ', type: 'university', region: 'Татарстан', city: 'Казань', students: 18500 },
	{ inn: inn10('631201234'), name: 'Самарский университет телекоммуникаций и информатики', short: 'СУТИ', type: 'university', region: 'Самарская', city: 'Самара', students: 9200 },
	{ inn: inn10('590401234'), name: 'Пермский политехнический университет', short: 'ППУ', type: 'university', region: 'Пермский', city: 'Пермь', students: 21000 },
	{ inn: inn10('540601234'), name: 'Новосибирский институт цифровых технологий', short: 'НИЦТ', type: 'university', region: 'Новосибирская', city: 'Новосибирск', students: 7400 },
	{ inn: inn10('667001234'), name: 'Уральский федеральный институт информатики', short: 'УФИИ', type: 'university', region: 'Свердловская', city: 'Екатеринбург', students: 26000 },
	{ inn: inn10('231001234'), name: 'Кубанский государственный аграрно-технический университет', short: 'КубГАТУ', type: 'university', region: 'Краснодарский', city: 'Краснодар', students: 15300 },
	{ inn: inn10('616501234'), name: 'Ростовский колледж связи и информатики', short: 'РКСИ', type: 'college', region: 'Ростовская', city: 'Ростов-на-Дону', students: 2100 },
	{ inn: inn10('027801234'), name: 'Уфимский авиационно-технический университет', short: 'УАТУ', type: 'university', region: 'Башкортостан', city: 'Уфа', students: 19800 },
	{ inn: inn10('745301234'), name: 'Челябинский институт прикладной математики', short: 'ЧИПМ', type: 'university', region: 'Челябинская', city: 'Челябинск', students: 5600 },
	{ inn: inn10('366601234'), name: 'Воронежский государственный колледж информационных технологий', short: 'ВГКИТ', type: 'college', region: 'Воронежская', city: 'Воронеж', students: 1800 },
	{ inn: inn10('780701234'), name: 'Санкт-Петербургский институт цифровой экономики', short: 'СПбИЦЭ', type: 'university', region: 'Санкт-Петербург', city: 'Санкт-Петербург', students: 8800 },
	{ inn: inn10('772201234'), name: 'Московский открытый университет прикладных наук', short: 'МОУПН', type: 'university', region: 'Москва', city: 'Москва', students: 31000 },
	{ inn: inn10('246301234'), name: 'Красноярский сибирский университет технологий', short: 'КСУТ', type: 'university', region: 'Красноярский', city: 'Красноярск', students: 12400 },
	{ inn: inn10('772901234'), name: 'ООО «Цифровые кадры»', short: 'Цифровые кадры', type: 'company', region: 'Москва', city: 'Москва', students: null }
];

const CONTACTS = [
	['КГТУ', 'Ахметов', 'Ринат', 'Ильдарович', 'Проректор по цифровизации', true],
	['КГТУ', 'Сафина', 'Гульнара', 'Рашитовна', 'Начальник учебного отдела', false],
	['СУТИ', 'Кузнецова', 'Ольга', 'Викторовна', 'Ректор', true],
	['ППУ', 'Малышев', 'Дмитрий', 'Сергеевич', 'Директор ИТ-института', true],
	['НИЦТ', 'Громова', 'Анна', 'Петровна', 'Проректор по учебной работе', true],
	['УФИИ', 'Соколов', 'Игорь', 'Анатольевич', 'Декан факультета информатики', true],
	['КубГАТУ', 'Мироненко', 'Сергей', 'Владимирович', 'Проректор', true],
	['РКСИ', 'Литвинова', 'Елена', 'Николаевна', 'Директор', true],
	['УАТУ', 'Хабибуллин', 'Айрат', 'Маратович', 'Начальник управления ДПО', true],
	['ЧИПМ', 'Орлова', 'Марина', 'Игоревна', 'Заведующая кафедрой', false],
	['ВГКИТ', 'Панин', 'Виктор', 'Степанович', 'Директор', true],
	['СПбИЦЭ', 'Белова', 'Ирина', 'Олеговна', 'Проректор по развитию', true],
	['МОУПН', 'Титов', 'Николай', 'Андреевич', 'Руководитель центра компетенций', true],
	['КСУТ', 'Зайцева', 'Дарья', 'Максимовна', 'Начальник отдела партнёрств', false],
	['Цифровые кадры', 'Фомин', 'Артём', 'Юрьевич', 'Генеральный директор', true]
];

// B2C-физлица (без организации)
const PERSONS = [
	['Смирнова', 'Екатерина', 'Алексеевна', 'smirnova.ek@example.ru', '+79161234501', 'kam'],
	['Волков', 'Павел', 'Дмитриевич', 'volkov.pd@example.ru', '+79161234502', 'kam'],
	['Егорова', 'Алина', 'Романовна', 'egorova.ar@example.ru', '+79161234503', 'kam'],
	['Назаров', 'Илья', 'Сергеевич', 'nazarov.is@example.ru', '+79161234504', 'kam'],
	['Кузьмина', 'Татьяна', 'Викторовна', 'kuzmina.tv@example.ru', '+79161234505', 'kam'],
	['Тарасов', 'Андрей', 'Михайлович', 'tarasov.am@example.ru', '+79161234506', 'kam'],
	['Орлов', 'Денис', 'Константинович', 'orlov.dk@example.ru', '+79161234507', 'head'],
	['Беляева', 'Мария', 'Сергеевна', 'belyaeva.ms@example.ru', '+79161234508', 'kam'],
	['Гусев', 'Кирилл', 'Олегович', 'gusev.ko@example.ru', '+79161234509', 'head']
];

// Сделки: [владелец, тип, организация/контакт, название, сумма, студентов, приоритет, целевой статус, дней до закрытия]
const DEALS = [
	['kam', 'b2b', 'КГТУ', 'Программа «Разработка на Python» для 3 курса', '1250000', 120, 'high', 'kp_approval', 45],
	['kam', 'b2b', 'СУТИ', 'Курс по сетевым технологиям для магистратуры', '840000', 60, 'normal', 'meeting_held', 60],
	['kam', 'b2b', 'ППУ', 'Пилот «Основы Data Science»', '390000', 40, 'normal', 'qualification', 90],
	['kam', 'b2b', 'НИЦТ', 'Цифровая кафедра: DevOps-трек', '2100000', 150, 'critical', 'legal_approval', 30],
	['kam', 'b2b', 'УФИИ', 'Летняя ИТ-школа для абитуриентов', '560000', 200, 'normal', 'requirements', 75],
	['kam', 'b2b', 'КубГАТУ', 'Курс «Кибербезопасность» для агроинженеров', '720000', 80, 'high', 'contract_signing', 20],
	['kam', 'b2b', 'РКСИ', 'Программа переподготовки преподавателей', '310000', 25, 'low', 'first_contact', 120],
	['kam', 'b2b', 'УАТУ', 'Трек «Промышленный интернет вещей»', '1650000', 90, 'high', 'lms_transfer', 15],
	['kam', 'b2b', 'ЧИПМ', 'Курс «Машинное обучение» — 2025/26', '480000', 35, 'normal', 'lost', 40],
	['kam', 'b2b', 'ВГКИТ', 'Стажировочная программа для выпускников', '150000', 30, 'low', 'parked', 180],
	['kam', 'b2b', 'СПбИЦЭ', 'Обучение сотрудников университета работе с LMS', '290000', 50, 'normal', 'identification', 100],
	['kam', 'b2b', 'МОУПН', 'Партнёрская программа «Цифровые кафедры 2026»', '3400000', 400, 'critical', 'training_launch', 10],
	['kam', 'b2b', 'КСУТ', 'Курс по мобильной разработке', '610000', 45, 'normal', 'kp_preparation', 55],
	['kam', 'b2b', 'Цифровые кадры', 'Корпоративное обучение аналитиков данных', '990000', 20, 'high', 'meeting_scheduled', 35],
	['kam', 'b2c', 'Смирнова', 'Frontend-разработчик с нуля — Смирнова Е. А.', '89000', 1, 'normal', 'consultation', 14],
	['kam', 'b2c', 'Волков', 'Data Science Pro — Волков П. Д.', '129000', 1, 'normal', 'won', 7],
	['kam', 'b2c', 'Егорова', 'Python для анализа данных — Егорова А. Р.', '59000', 1, 'low', 'contact_verification', 21],
	['head', 'b2b', 'МОУПН', 'Расширение программы на второй кампус', '1800000', 160, 'high', 'monitoring', 25],
	['head', 'b2b', 'УФИИ', 'Хакатон-интенсив для студентов', '240000', 300, 'normal', 'closing_prolongation', 12],
	['head', 'b2b', 'КГТУ', 'Пролонгация программы 2024 года', '1100000', 110, 'normal', 'won', 5],
	// вторая волна: ранние статусы с короткими SLA (Истекает / Нарушен) и больше B2C
	['kam', 'b2b', 'СУТИ', 'Модуль «Облачные технологии» для бакалавриата', '430000', 70, 'high', 'first_contact', 50],
	['kam', 'b2b', 'ППУ', 'Курс «Тестирование программного обеспечения»', '380000', 45, 'normal', 'qualification', 65],
	['kam', 'b2b', 'НИЦТ', 'Стажировки для студентов 4 курса', '270000', 60, 'normal', 'meeting_scheduled', 40],
	['kam', 'b2b', 'КубГАТУ', 'Летняя школа по робототехнике', '520000', 90, 'low', 'first_contact', 85],
	['kam', 'b2b', 'РКСИ', 'Сетевая академия: расширение программы', '340000', 30, 'normal', 'qualification', 70],
	['head', 'b2b', 'КГТУ', 'Кибербезопасность для преподавателей', '410000', 40, 'high', 'meeting_scheduled', 30],
	['head', 'b2b', 'УФИИ', 'Цифровая кафедра: анализ данных', '1350000', 120, 'critical', 'qualification', 55],
	['kam', 'b2c', 'Назаров', 'DevOps с нуля — Назаров И. С.', '99000', 1, 'normal', 'lms_enrollment', 10],
	['kam', 'b2c', 'Кузьмина', 'Аналитик данных — Кузьмина Т. В.', '109000', 1, 'low', 'lost', 12],
	['kam', 'b2c', 'Тарасов', 'Java-разработчик — Тарасов А. М.', '119000', 1, 'high', 'payment_contract', 9],
	['head', 'b2c', 'Орлов', 'UX/UI-дизайн — Орлов Д. К.', '79000', 1, 'normal', 'won', 3],
	['kam', 'b2c', 'Беляева', 'Python-старт — Беляева М. С.', '45000', 1, 'normal', 'contact_verification', 18],
	['head', 'b2c', 'Гусев', 'Тестировщик ПО — Гусев К. О.', '69000', 1, 'low', 'training_completed', 6],
	// третья волна: короткие SLA на ранних статусах — сделки быстро уходят в «Истекает» и «Нарушен»
	['kam', 'b2b', 'КГТУ', 'Пилот по кибербезопасности для магистров', '260000', 35, 'high', 'first_contact', 60],
	['kam', 'b2b', 'СУТИ', 'Курс «Сети 5G» для бакалавров', '310000', 40, 'normal', 'qualification', 70],
	['head', 'b2b', 'ППУ', 'Летняя практика для студентов ИТ-института', '180000', 60, 'normal', 'meeting_scheduled', 45],
	['kam', 'b2b', 'УАТУ', 'Программа «Умное производство»', '890000', 75, 'critical', 'qualification', 50],
	['kam', 'b2b', 'ЧИПМ', 'Введение в анализ данных для преподавателей', '145000', 25, 'low', 'first_contact', 90],
	['kam', 'b2c', 'Егорова', 'SQL и базы данных — Егорова А. Р.', '39000', 1, 'low', 'consultation', 10]
];

const TASK_TITLES = [
	'Согласовать список групп с учебным отделом',
	'Отправить коммерческое предложение проректору',
	'Подготовить договор для юристов вуза',
	'Назначить встречу на следующей неделе',
	'Уточнить бюджет на 2026/27 учебный год',
	'Собрать отзывы участников пилота',
	'Проверить поступление оплаты',
	'Подготовить презентацию программы',
	'Созвониться с руководителем кафедры',
	'Отправить материалы для LMS'
];
const GENERIC_TASKS = new Set(['Позвонить контактному лицу и уточнить состав групп', 'Подготовить презентацию программы']);

const COMMENTS = [
	'Провели созвон с проректором, ждём список групп до конца недели.',
	'Уточнили бюджет: университет готов рассматривать только рамочный договор на год.',
	'**Важно:** заказчик просит включить модуль по кибербезопасности в программу.',
	'Отправил обновлённое КП, следующий контакт — во вторник.',
	'Юристы вуза просят добавить пункт о персональных данных обучающихся.'
];

// ---------------------------------------------------------------- шаги
const summary = { orgs: 0, contacts: 0, deals: 0, transitions: 0, comments: 0, tasks: 0, participants: 0, sla: 0 };

const TEAM_NAME = 'Отдел вузов';

/** Команда «Отдел вузов»: руководитель — Петров, в ней же Иванов и Петров (скоуп HEAD = участники его команды). */
async function ensureTeam(me) {
	const teams = await get('admin', '/api/admin/teams?limit=100');
	let team = teams.items.find((t) => t.name === TEAM_NAME);
	if (!team) {
		team = await post('admin', '/api/admin/teams', { name: TEAM_NAME, head_id: me.head.id });
		console.log(`  + команда «${TEAM_NAME}»`);
	}
	const assign = async (user, body) => {
		const fresh = await get('admin', `/api/admin/users/${user.id}`);
		if (Object.entries(body).every(([key, value]) => fresh[key] === value)) return;
		await call('admin', 'PATCH', `/api/admin/users/${user.id}`, body, ifMatch(fresh.version));
		console.log(`  + ${fresh.full_name}: команда «${TEAM_NAME}»`);
	};
	await assign(me.head, { team_id: team.id });
	await assign(me.kam, { team_id: team.id, manager_id: me.head.id });
	return team;
}

async function ensureReferenceData() {
	const reasons = await get('admin', '/api/loss-reasons?is_active=true');
	if (!reasons.items.length) {
		const list = [
			['price', 'Не устроила цена', 'price'],
			['timing', 'Не подошли сроки', 'timing'],
			['competitor', 'Выбрали другого поставщика', 'competitor'],
			['no_budget', 'Нет бюджета в этом году', 'no_budget'],
			['no_need', 'Потребность отпала', 'no_need']
		];
		for (const [code, name, category] of list) await post('admin', '/api/loss-reasons', { code, name, category, is_active: true });
		console.log('  + причины отказа: 5');
	}
	const products = await get('admin', '/api/products?is_active=true&limit=50');
	if (!products.items.length) {
		const list = [
			['py-base', 'Разработка на Python: базовый курс', 72, 'online', '4500.00'],
			['ds-pro', 'Data Science Pro', 144, 'blended', '9800.00'],
			['devops', 'DevOps-инженер', 96, 'online', '7200.00'],
			['cyber', 'Кибербезопасность', 80, 'offline', '6100.00']
		];
		for (const [code, name, hours, format, price] of list) {
			await post('admin', '/api/products', { code, name, duration_hours: hours, format, base_price: price, currency: 'RUB', is_active: true });
		}
		console.log('  + продукты: 4');
	}
}

// Короткие календарные сроки на ранних статусах: свежие демо-сделки там быстро становятся «Истекает» / «Нарушен».
// Остальные промежуточные статусы — 72 рабочих часа, начальный — 24.
const SLA_SHORT_HOURS = { first_contact: 0.05, qualification: 0.15, meeting_scheduled: 1, contact_verification: 0.05, consultation: 1.5 };

function wantedSla(graph) {
	return graph.statuses
		.filter((s) => !s.is_archived && (s.type === 'initial' || s.type === 'intermediate'))
		.map((s) => {
			const short = SLA_SHORT_HOURS[s.code];
			return {
				status: s.id,
				max_duration_hours: short ?? (s.type === 'initial' ? 24 : 72),
				warn_threshold_pct: 75,
				escalate_to_role: 'HEAD',
				channels: ['in_app'],
				count_business_days: short === undefined,
				is_active: true
			};
		});
}

async function ensureSla(workflow) {
	const graph = await get('admin', `/api/workflows/${workflow.id}`);
	const wanted = wantedSla(graph);
	const same = wanted.every((w) => {
		const have = graph.sla_rules.find((r) => r.status_id === w.status);
		return have && Number(have.max_duration_hours) === w.max_duration_hours && have.count_business_days === w.count_business_days && have.is_active;
	});
	if (same) return graph;
	const statuses = graph.statuses.filter((s) => !s.is_archived);
	const body = {
		statuses: statuses.map((s) => ({
			id: s.id, code: s.code, name: s.name, type: s.type, color: s.color, sort_order: s.sort_order, required_fields: s.required_fields, is_archived: false
		})),
		transitions: graph.transitions.map((t) => ({
			id: t.id, from_status: t.from_status_id, to_status: t.to_status_id, name: t.name, allowed_roles: t.allowed_roles,
			conditions: t.conditions, actions: t.actions, requires_comment: t.requires_comment, sort_order: t.sort_order
		})),
		sla_rules: wanted
	};
	try {
		await call('admin', 'PUT', `/api/workflows/${workflow.id}/graph`, body, ifMatch(graph.workflow.version));
	} catch (e) {
		// backend: PUT /graph пересоздаёт все переходы и падает (500) на FK deal_status_history.transition_id, когда у сделок уже есть история
		console.log(`  ! SLA «${workflow.name}» не обновлены (${e.status}): правила можно менять только до появления сделок с историей`);
		return graph;
	}
	const fresh = await get('admin', `/api/workflows/${workflow.id}`);
	await post('admin', `/api/workflows/${workflow.id}/publish`, undefined, ifMatch(fresh.workflow.version));
	summary.sla += wanted.length;
	console.log(`  + SLA-правила «${workflow.name}»: ${wanted.length}`);
	return get('admin', `/api/workflows/${workflow.id}`);
}


// ---------------------------------------------------------------- реестр ЕГРЮЛ (автоподстановка по ИНН)
// Учебные организации в формате открытых данных ФНС (`СвЮЛ`): наши 14 организаций и ещё вузы «про запас», чтобы поиск по названию и ИНН
// было на чём показать. Есть ликвидированные и реорганизуемые — подсказки красятся по статусу.
const REGISTRY_EXTRA = [
	['Томский политехнический институт цифровых технологий', 'ТПИЦТ', '70', 'Томская', 'Томск', '85.22', 'Действующее'],
	['Иркутский государственный университет информационных систем', 'ИГУИС', '38', 'Иркутская', 'Иркутск', '85.22', 'Действующее'],
	['Нижегородский университет радиоэлектроники и связи', 'НУРС', '52', 'Нижегородская', 'Нижний Новгород', '85.22', 'Действующее'],
	['Саратовский государственный технический институт', 'СГТИ', '64', 'Саратовская', 'Саратов', '85.22', 'Действующее'],
	['Омский университет транспорта и телекоммуникаций', 'ОУТТ', '55', 'Омская', 'Омск', '85.22', 'Действующее'],
	['Тюменский колледж информационных технологий', 'ТКИТ', '72', 'Тюменская', 'Тюмень', '85.21', 'Действующее'],
	['Волгоградский политехнический университет', 'ВолгПУ', '34', 'Волгоградская', 'Волгоград', '85.22', 'Действующее'],
	['Дальневосточный университет цифровой экономики', 'ДВУЦЭ', '25', 'Приморский', 'Владивосток', '85.22', 'Действующее'],
	['Калининградский институт связи и информатики', 'КИСИ', '39', 'Калининградская', 'Калининград', '85.22', 'Действующее'],
	['Ярославский колледж информационной безопасности', 'ЯКИБ', '76', 'Ярославская', 'Ярославль', '85.21', 'Действующее'],
	['Ставропольский университет компьютерных наук', 'СтавУКН', '26', 'Ставропольский', 'Ставрополь', '85.22', 'В процессе реорганизации'],
	['Тульский институт прикладной информатики', 'ТИПИ', '71', 'Тульская', 'Тула', '85.22', 'В процессе ликвидации'],
	['Пензенский университет телекоммуникаций (ликвидирован)', 'ПУТ', '58', 'Пензенская', 'Пенза', '85.22', 'Ликвидировано'],
	['Липецкий колледж вычислительной техники (ликвидирован)', 'ЛКВТ', '48', 'Липецкая', 'Липецк', '85.21', 'Ликвидировано']
];

function registryEntries() {
	const own = ORGS.filter((o) => o.type !== 'company').map((o) => ({
		inn: o.inn, ogrn: ogrn13('1' + o.inn.slice(0, 2) + '77000' + o.inn.slice(4, 8)), kpp: o.inn.slice(0, 4) + '01001', name: o.name, short: o.short,
		code: o.inn.slice(0, 2), region: o.region, city: o.city, okved: o.type === 'college' ? '85.21' : '85.22', status: 'Действующее',
		address: `г. ${o.city}, ул. Университетская, д. ${Number(o.inn.slice(6, 8)) + 1}`
	}));
	const extra = REGISTRY_EXTRA.map(([name, short, code, region, city, okved, status], i) => {
		const inn = inn10(code + String(5000000 + i * 137));
		return { inn, ogrn: ogrn13('1' + code + '77000' + String(1000 + i)), kpp: inn.slice(0, 4) + '01001', name, short, code, region, city, okved, status, address: `г. ${city}, пр. Ленина, д. ${10 + i}` };
	});
	return [...own, ...extra];
}

const xmlAttr = (v) => String(v).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');

function registryXml(entries) {
	const body = entries.map((e) => `  <СвЮЛ ИНН="${e.inn}" ОГРН="${e.ogrn}" ДатаОГРН="2002-08-21" КПП="${e.kpp}">
    <СвНаимЮЛ НаимЮЛПолн="${xmlAttr(e.name)}" НаимЮЛСокр="${xmlAttr(e.short)}"/>
    <СвОПФ КодОПФ="75103" НаимОПФ="Федеральные государственные бюджетные образовательные учреждения высшего образования"/>
    <СвСтатус НаимСтатус="${e.status}"/>
    <СвАдресЮЛ><АдресРФ КодРегион="${e.code}" Регион="${xmlAttr(e.region)}" Город="${xmlAttr(e.city)}" Улица="${xmlAttr(e.address)}"/></СвАдресЮЛ>
    <СвОКВЭДОсн КодОКВЭД="${e.okved}"/>
    <СведФЛ Фамилия="Иванов" Имя="Сергей" Отчество="Петрович"/>
    <СвДолжн НаимДолжн="Ректор"/>
  </СвЮЛ>`).join('\n');
	return `<?xml version="1.0" encoding="UTF-8"?>\n<Файл>\n${body}\n</Файл>\n`;
}

async function ensureRegistry() {
	const versions = await get('admin', '/api/admin/registry/versions?limit=20');
	if (!process.env.REGISTRY_REIMPORT && versions.items.some((v) => v.status === 'completed' || v.status === 'pending' || v.status === 'running')) return;
	const bytes = Buffer.from(registryXml(registryEntries()), 'utf8');
	const intent = await post('admin', '/api/files/upload-intent', { filename: 'egrul-demo.xml', size_bytes: bytes.length, mime_type: 'application/xml', purpose: 'registry' }, idem());
	// ссылка подписана вместе с Content-Type — он должен совпасть с mime_type из upload-intent
	const put = await fetch(intent.upload_url, { method: 'PUT', headers: { 'Content-Type': 'application/xml', ...(intent.upload_headers ?? {}) }, body: bytes });
	if (!put.ok) throw new Error(`PUT реестра → ${put.status}`);
	await post('admin', `/api/files/${intent.file_id}/commit`, {});
	const version = await post('admin', '/api/admin/registry/import', { file_id: intent.file_id, source: 'fns_egrul' });
	console.log(`  + выгрузка реестра ЕГРЮЛ загружена (${registryEntries().length} записей), ждём разбор…`);
	for (let i = 0; i < 40; i += 1) {
		await new Promise((r) => setTimeout(r, 5000));
		const now = (await get('admin', '/api/admin/registry/versions?limit=20')).items.find((v) => v.id === version.id);
		if (now?.status === 'completed') return console.log(`  реестр готов: ${now.entries_count} записей`);
		if (now?.status === 'failed') return console.log(`  ! реестр не разобран: ${now.error}`);
	}
	console.log('  ! реестр ещё разбирается — подсказки появятся через минуту');
}

async function ensureOrganizations(regionsByName, ownerOf) {
	const byShort = {};
	for (const org of ORGS) {
		const who = ownerOf(org);
		const found = await get(who, `/api/organizations?inn=${org.inn}&limit=1`);
		let row = found.items[0];
		if (!row) {
			const region = [...regionsByName.entries()].find(([name]) => name.toLowerCase().includes(org.region.toLowerCase()))?.[1] ?? null;
			row = await post(who, '/api/organizations', {
				name: org.name,
				short_name: org.short,
				org_type: org.type,
				inn: org.inn,
				kpp: org.inn.slice(0, 4) + '01001',
				ogrn: ogrn13('1' + org.inn.slice(0, 2) + '77000' + org.inn.slice(4, 8)),
				legal_address: `г. ${org.city}, ул. Университетская, д. ${Number(org.inn.slice(6, 8)) + 1}`,
				region_id: region,
				website: `https://${org.short.toLowerCase().replace(/[^a-zа-я0-9]/g, '')}.example.ru`,
				main_phone: `+7${org.inn.slice(0, 3)}${org.inn.slice(3, 10)}`,
				main_email: `info@${org.short.toLowerCase().replace(/[^a-zа-я0-9]/g, '')}.example.ru`,
				students_count: org.students,
				source: 'demo'
			}, idem());
			summary.orgs += 1;
		}
		byShort[org.short] = row;
	}
	return byShort;
}

async function ensureContacts(orgsByShort, ownerByShort) {
	const byKey = {};
	for (const [short, last, first, middle, position, dm] of CONTACTS) {
		const org = orgsByShort[short];
		if (!org) continue;
		const who = ownerByShort[short] ?? 'kam';
		const found = await get(who, `/api/contacts?organization_id=${org.id}&q=${encodeURIComponent(last)}&limit=5`);
		let row = found.items.find((c) => c.last_name === last);
		if (!row) {
			const slug = `${first[0]}.${last}`.toLowerCase().replace(/[^a-zа-я.]/g, '');
			row = await post(who, '/api/contacts', {
				organization_id: org.id, first_name: first, last_name: last, middle_name: middle, position,
				email: `${translit(slug)}@${translit(short.toLowerCase().replace(/[^a-zа-я0-9]/g, ''))}.example.ru`,
				phone: `+7999${String(Math.abs(hash(last)) % 10_000_000).padStart(7, '0')}`,
				is_decision_maker: dm, source: 'demo',
				channels: dm ? [{ type: 'telegram', value: `@${translit(slug.replace('.', '_'))}`, is_primary: false }] : []
			}, idem());
			summary.contacts += 1;
		}
		byKey[`${short}:${last}`] = row;
	}
	for (const [last, first, middle, email, phone, who] of PERSONS) {
		const found = await get(who, `/api/contacts?q=${encodeURIComponent(last)}&limit=5`);
		let row = found.items.find((c) => c.last_name === last && !c.organization_id);
		if (!row) {
			row = await post(who, '/api/contacts', { first_name: first, last_name: last, middle_name: middle, email, phone, is_decision_maker: true, source: 'demo' }, idem());
			summary.contacts += 1;
		}
		byKey[last] = row;
	}
	return byKey;
}

function hash(s) {
	let h = 7;
	for (const ch of s) h = (h * 31 + ch.charCodeAt(0)) | 0;
	return h;
}
const TR = { а: 'a', б: 'b', в: 'v', г: 'g', д: 'd', е: 'e', ё: 'e', ж: 'zh', з: 'z', и: 'i', й: 'y', к: 'k', л: 'l', м: 'm', н: 'n', о: 'o', п: 'p', р: 'r', с: 's', т: 't', у: 'u', ф: 'f', х: 'h', ц: 'c', ч: 'ch', ш: 'sh', щ: 'sch', ъ: '', ы: 'y', ь: '', э: 'e', ю: 'yu', я: 'ya' };
const translit = (s) => [...s].map((c) => TR[c] ?? c).join('');

/** Путь переходов от текущего статуса к целевому по графу (BFS по рёбрам). */
function pathTo(graph, fromId, toCode) {
	const byId = new Map(graph.statuses.map((s) => [s.id, s]));
	const target = graph.statuses.find((s) => s.code === toCode);
	if (!target) return null;
	const prev = new Map([[fromId, null]]);
	const queue = [fromId];
	while (queue.length) {
		const cur = queue.shift();
		if (cur === target.id) break;
		for (const t of graph.transitions.filter((t) => t.from_status_id === cur)) {
			if (!prev.has(t.to_status_id)) {
				prev.set(t.to_status_id, { transition: t, from: cur });
				queue.push(t.to_status_id);
			}
		}
	}
	if (!prev.has(target.id)) return null;
	const steps = [];
	for (let id = target.id; prev.get(id); id = prev.get(id).from) steps.unshift({ transition: prev.get(id).transition, status: byId.get(id) });
	return steps;
}

async function walk(who, deal, graph, targetCode, lossReasonId) {
	const steps = pathTo(graph, deal.status_id, targetCode);
	if (!steps) {
		console.log(`    ! нет пути в «${targetCode}» для ${deal.number}`);
		return deal;
	}
	let current = deal;
	for (const { transition, status } of steps) {
		const body = { to_status_id: status.id, fields: {} };
		if (transition.requires_comment) body.comment = status.type === 'lost' ? 'Вуз выбрал другого поставщика после сравнения КП.' : status.type === 'parked' ? 'Ждём решения учёного совета, вернёмся к сделке позже.' : `Переход: ${transition.name}.`;
		if (status.type === 'lost') body.fields.loss_reason_id = lossReasonId;
		if (status.type === 'parked') body.fields['custom_fields.park_reason'] = 'Решение учёного совета отложено';
		if (status.code === 'consultation') body.fields['custom_fields.contact_verified'] = true;
		if (status.code === 'lms_enrollment') body.fields['custom_fields.payment_confirmed'] = true;
		try {
			const res = await post(who, `/api/deals/${current.id}/transition`, body, ifMatch(current.version));
			current = res.deal;
			summary.transitions += 1;
		} catch (e) {
			console.log(`    ! ${deal.number}: переход «${transition.name}» не выполнен (${e.message.slice(0, 140)})`);
			return current;
		}
	}
	return current;
}

/** Демо-задачи из первого прогона одинаковые: даём им разные названия, часть отмечаем выполненными (идемпотентно — трогаем только типовые названия). */
async function varyTasks() {
	let renamed = 0;
	for (const who of ['kam', 'head']) {
		let cursor = '';
		for (let page = 0; page < 5; page += 1) {
			const res = await get(who, `/api/tasks?limit=100${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ''}`);
			for (const task of res.items) {
				if (!GENERIC_TASKS.has(task.title)) continue;
				const h = Math.abs(hash(task.id));
				await call(who, 'PATCH', `/api/tasks/${task.id}`, { title: TASK_TITLES[h % TASK_TITLES.length], priority: ['normal', 'high', 'low'][h % 3] });
				if (h % 5 === 0 && task.status === 'open') await post(who, `/api/tasks/${task.id}/complete`);
				renamed += 1;
			}
			if (!res.next_cursor) break;
			cursor = res.next_cursor;
		}
	}
	if (renamed) console.log(`  задач переименовано: ${renamed}`);
}

async function main() {
	console.log(`Сид демо-данных → ${BASE}`);
	// первым запросом каждого пользователя обязан быть GET /api/me: он создаёт локальную запись (JIT) и не требует согласия на ПДн
	for (const who of ['admin', 'head', 'kam', 'auditor']) await login(who);
	const me = { kam: await get('kam', '/api/me'), head: await get('head', '/api/me') };

	console.log('Команда…');
	await ensureTeam(me);

	console.log('Справочники…');
	await ensureReferenceData();
	const regions = await get('kam', '/api/regions');
	const regionsByName = new Map(regions.items.map((r) => [r.name, r.id]));
	const lossReasons = (await get('kam', '/api/loss-reasons?is_active=true')).items;
	const products = (await get('kam', '/api/products?is_active=true&limit=50')).items;

	console.log('Реестр ЕГРЮЛ…');
	await ensureRegistry();

	console.log('Воронки и SLA…');
	const workflows = (await get('admin', '/api/workflows?state=published&limit=50')).items;
	const graphs = {};
	for (const wf of workflows.filter((w) => w.is_default)) graphs[wf.deal_type] = await ensureSla(wf);
	if (!graphs.b2b || !graphs.b2c) throw new Error('Нет опубликованных воронок по умолчанию: сначала python -m app.modules.workflow.seed');

	console.log('Организации…');
	const ownerOf = (org) => (org.short === 'МОУПН' || org.short === 'УФИИ' ? 'head' : 'kam');
	const ownerByShort = Object.fromEntries(ORGS.map((org) => [org.short, ownerOf(org)]));
	const orgsByShort = await ensureOrganizations(regionsByName, ownerOf);
	console.log(`  организаций: ${Object.keys(orgsByShort).length} (новых ${summary.orgs})`);

	console.log('Контакты…');
	const contacts = await ensureContacts(orgsByShort, ownerByShort);
	console.log(`  контактов: ${Object.keys(contacts).length} (новых ${summary.contacts})`);

	console.log('Сделки…');
	const created = [];
	for (const [plannedWho, type, party, title, amount, students, priority, target, closeDays] of DEALS) {
		// Менеджер не может завести сделку на чужую организацию (бэкенд отвечает 404, как для несуществующей): если организацию
		// ведёт руководитель, сделку по ней заводит он. Организации руководителя — только МОУПН и УФИИ (`ownerOf` выше).
		const who = type === 'b2b' && plannedWho === 'kam' && ownerByShort[party] === 'head' ? 'head' : plannedWho;
		const found = await get(who, `/api/deals?q=${encodeURIComponent(title)}&limit=5`);
		if (found.items.some((d) => d.title === title)) continue;
		const org = type === 'b2b' ? orgsByShort[party] : null;
		const contact = type === 'b2b' ? Object.entries(contacts).find(([k]) => k.startsWith(`${party}:`))?.[1] : contacts[party];
		if (type === 'b2b' && !org) continue;
		const picks = products.slice(hash(title) % Math.max(1, products.length - 1)).slice(0, 1 + (Math.abs(hash(title)) % 2));
		const body = {
			title, deal_type: type, organization_id: org?.id ?? null, contact_id: contact?.id ?? null, amount, currency: 'RUB',
			students_planned: students, expected_close_date: dateFromNow(closeDays), priority, source: 'demo',
			products: picks.map((p, i) => ({ product_id: p.id, quantity: i === 0 ? Math.max(1, Math.round(students / 20)) : 1, price: p.base_price, discount_pct: i === 0 ? 10 : 0, total: null }))
		};
		let deal = await post(who, '/api/deals', body, idem());
		summary.deals += 1;
		deal = await walk(who, deal, graphs[type], target, lossReasons[Math.abs(hash(title)) % lossReasons.length]?.id);
		created.push({ who, deal, party });
		console.log(`  + ${deal.number} «${title}» → ${target}`);
	}

	console.log('Комментарии, задачи, участники…');
	for (const [index, { who, deal }] of created.entries()) {
		const first = await post(who, `/api/deals/${deal.id}/comments`, { body: COMMENTS[index % COMMENTS.length] });
		summary.comments += 1;
		if (index % 2 === 0) {
			await post(who, `/api/deals/${deal.id}/comments`, { body: COMMENTS[(index + 2) % COMMENTS.length], parent_id: first.id });
			summary.comments += 1;
		}
		if (index % 3 === 0) {
			await post(who, `/api/deals/${deal.id}/comments`, { body: 'Внутренняя заметка: скидку выше 15% не согласовываем без руководителя.', is_internal: true });
			summary.comments += 1;
		}
		if (who === 'kam' && index % 4 === 1) {
			await post('head', `/api/deals/${deal.id}/comments`, { body: 'Посмотрел материалы — давайте назначим встречу с ректором на следующей неделе.', mentions: [me.kam.id] });
			summary.comments += 1;
		}
		if (!deal.closed_at) {
			const assignee = who === 'kam' ? me.kam.id : me.head.id;
			const tasks = [
				{ title: 'Позвонить контактному лицу и уточнить состав групп', due: index % 3 === 0 ? -2 : 3, priority: 'high' },
				{ title: 'Подготовить презентацию программы', due: 7, priority: 'normal' }
			].slice(0, 1 + (index % 2));
			for (const t of tasks) {
				await post(who, '/api/tasks', { deal_id: deal.id, title: t.title, assignee_id: assignee, due_at: daysFromNow(t.due), priority: t.priority, description: index % 2 ? 'Материалы — в папке «КП» на диске.' : null });
				summary.tasks += 1;
			}
		}
		if (who === 'kam' && index % 5 === 0) {
			await post('kam', `/api/deals/${deal.id}/participants`, { user_id: me.head.id, role_in_deal: 'watcher' });
			summary.participants += 1;
		}
		if (who === 'head' && index % 2 === 1) {
			await post('head', `/api/deals/${deal.id}/participants`, { user_id: me.kam.id, role_in_deal: 'co_owner' });
			summary.participants += 1;
		}
	}

	console.log('Задачи…');
	await varyTasks();

	console.log('Готово:', JSON.stringify(summary));
}

main().catch((e) => {
	console.error('Сид прерван:', e.message);
	process.exitCode = 1;
});
