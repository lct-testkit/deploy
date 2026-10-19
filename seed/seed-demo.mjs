// Демо-данные через API живого бэкенда (агент A). Идемпотентно: организации ищутся по ИНН, контакты — по фамилии
// в организации, сделки — по названию; повторный запуск ничего не дублирует, переходы делаются только для новых сделок.
//   node tools/seed-demo.mjs            (по умолчанию http://localhost:5273 → прокси на бэкенд)
//   APP_URL=http://localhost:8080 node tools/seed-demo.mjs
import { BASE, accessToken, ensureConsent, graphSteps } from './lib.mjs';
import { apiAs, attachPdf } from './f-lib.mjs';

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
	{ inn: inn10('772901234'), name: 'ООО «Цифровые кадры»', short: 'Цифровые кадры', type: 'company', region: 'Москва', city: 'Москва', students: null },
	// вузы руководителя без сделок: на них менеджер просит доступ (вкладка «Запросы доступа»)
	{ inn: inn10('720301234'), name: 'Тюменский государственный институт цифровых технологий', short: 'ТюмГИЦТ', type: 'university', region: 'Тюменская', city: 'Тюмень', students: 6200 },
	{ inn: inn10('550101234'), name: 'Омский колледж информационных технологий', short: 'ОмКИТ', type: 'college', region: 'Омская', city: 'Омск', students: 1500 }
];

// вузы, которые ведёт руководитель (менеджер заводит сделки по ним только после одобренного запроса доступа или через руководителя)
const HEAD_ORGS = new Set(['МОУПН', 'УФИИ', 'ТюмГИЦТ', 'ОмКИТ']);

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
	['Цифровые кадры', 'Фомин', 'Артём', 'Юрьевич', 'Генеральный директор', true],
	// вторые контакты — чтобы вкладка «Контакты» вуза не состояла из одной строки
	['СУТИ', 'Рогов', 'Алексей', 'Павлович', 'Начальник управления информатизации', false],
	['ППУ', 'Тихонова', 'Светлана', 'Игоревна', 'Заведующая учебной частью', false],
	['НИЦТ', 'Белов', 'Максим', 'Олегович', 'Директор центра карьеры', false],
	['УФИИ', 'Нургалиева', 'Динара', 'Маратовна', 'Заместитель декана по учебной работе', false],
	['КубГАТУ', 'Левченко', 'Татьяна', 'Андреевна', 'Начальник учебного отдела', false],
	['УАТУ', 'Исмагилов', 'Рустем', 'Фанилович', 'Руководитель центра цифровых компетенций', false],
	['МОУПН', 'Крылова', 'Наталья', 'Дмитриевна', 'Начальник отдела дополнительного образования', false],
	['СПбИЦЭ', 'Жуков', 'Станислав', 'Игоревич', 'Директор по партнёрствам', false],
	['КСУТ', 'Рязанцев', 'Олег', 'Валентинович', 'Проректор по цифровой трансформации', true],
	['ЧИПМ', 'Воронцов', 'Пётр', 'Алексеевич', 'Директор института', true],
	['РКСИ', 'Дьяченко', 'Алла', 'Сергеевна', 'Заместитель директора по учебной работе', false],
	['ВГКИТ', 'Мальцева', 'Ирина', 'Борисовна', 'Заведующая отделением информатики', false],
	['ТюмГИЦТ', 'Шевцов', 'Андрей', 'Леонидович', 'Проректор по образовательной деятельности', true],
	['ТюмГИЦТ', 'Ларионова', 'Юлия', 'Викторовна', 'Начальник отдела практики', false],
	['ОмКИТ', 'Бондаренко', 'Галина', 'Петровна', 'Директор колледжа', true]
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

// Сделки: [владелец, тип, организация/контакт, название, сумма, студентов, приоритет, цель, дней до закрытия].
// Цель B2B-сделки — номер шага из задания, а не код статуса: `{ step: 8 }`; `back: true` — дойти до шага и вернуться на шаг назад;
// `{ end: 'lost' | 'parked' | 'won', at: N }` — закрыть с шага N. Цель B2C — код статуса воронки B2C.
// Каждая третья сделка, которой нужно пройти шаг 5 («корректировка документов», необязательный), идёт через него, остальные пропускают.
const DEALS = [
	['kam', 'b2b', 'КГТУ', 'Программа «Разработка на Python» для 3 курса', '1250000', 120, 'high', { step: 8 }, 45],
	['kam', 'b2b', 'СУТИ', 'Курс по сетевым технологиям для магистратуры', '840000', 60, 'normal', { step: 4 }, 60],
	['kam', 'b2b', 'ППУ', 'Пилот «Основы Data Science»', '390000', 40, 'normal', { step: 2 }, 90],
	['kam', 'b2b', 'НИЦТ', 'Цифровая кафедра: DevOps-трек', '2100000', 150, 'critical', { step: 6 }, 30],
	['kam', 'b2b', 'УФИИ', 'Летняя ИТ-школа для абитуриентов', '560000', 200, 'normal', { step: 3 }, 75],
	['kam', 'b2b', 'КубГАТУ', 'Курс «Кибербезопасность» для агроинженеров', '720000', 80, 'high', { step: 11 }, 20],
	['kam', 'b2b', 'РКСИ', 'Программа переподготовки преподавателей', '310000', 25, 'low', { step: 1 }, 120],
	['kam', 'b2b', 'УАТУ', 'Трек «Промышленный интернет вещей»', '1650000', 90, 'high', { step: 7 }, 15],
	['kam', 'b2b', 'ЧИПМ', 'Курс «Машинное обучение» — 2025/26', '480000', 35, 'normal', { end: 'lost', at: 3 }, 40],
	['kam', 'b2b', 'ВГКИТ', 'Стажировочная программа для выпускников', '150000', 30, 'low', { end: 'parked', at: 4 }, 180],
	['kam', 'b2b', 'СПбИЦЭ', 'Обучение сотрудников университета работе с LMS', '290000', 50, 'normal', { step: 1 }, 100],
	['kam', 'b2b', 'МОУПН', 'Партнёрская программа «Цифровые кафедры 2026»', '3400000', 400, 'critical', { step: 10, back: true }, 10],
	['kam', 'b2b', 'КСУТ', 'Курс по мобильной разработке', '610000', 45, 'normal', { step: 5 }, 55],
	['kam', 'b2b', 'Цифровые кадры', 'Корпоративное обучение аналитиков данных', '990000', 20, 'high', { step: 3 }, 35],
	['kam', 'b2c', 'Смирнова', 'Frontend-разработчик с нуля — Смирнова Е. А.', '89000', 1, 'normal', 'consultation', 14],
	['kam', 'b2c', 'Волков', 'Data Science Pro — Волков П. Д.', '129000', 1, 'normal', 'won', 7],
	['kam', 'b2c', 'Егорова', 'Python для анализа данных — Егорова А. Р.', '59000', 1, 'low', 'contact_verification', 21],
	['head', 'b2b', 'МОУПН', 'Расширение программы на второй кампус', '1800000', 160, 'high', { step: 12 }, 25],
	['head', 'b2b', 'УФИИ', 'Хакатон-интенсив для студентов', '240000', 300, 'normal', { step: 14 }, 12],
	['head', 'b2b', 'КГТУ', 'Пролонгация программы 2024 года', '1100000', 110, 'normal', { end: 'won', at: 14 }, 5],
	// вторая волна: ранние статусы с короткими SLA (Истекает / Нарушен) и больше B2C
	['kam', 'b2b', 'СУТИ', 'Модуль «Облачные технологии» для бакалавриата', '430000', 70, 'high', { step: 1 }, 50],
	['kam', 'b2b', 'ППУ', 'Курс «Тестирование программного обеспечения»', '380000', 45, 'normal', { step: 2 }, 65],
	['kam', 'b2b', 'НИЦТ', 'Стажировки для студентов 4 курса', '270000', 60, 'normal', { step: 3 }, 40],
	['kam', 'b2b', 'КубГАТУ', 'Летняя школа по робототехнике', '520000', 90, 'low', { step: 1 }, 85],
	['kam', 'b2b', 'РКСИ', 'Сетевая академия: расширение программы', '340000', 30, 'normal', { step: 2 }, 70],
	['head', 'b2b', 'КГТУ', 'Кибербезопасность для преподавателей', '410000', 40, 'high', { step: 3 }, 30],
	['head', 'b2b', 'УФИИ', 'Цифровая кафедра: анализ данных', '1350000', 120, 'critical', { step: 2 }, 55],
	['kam', 'b2c', 'Назаров', 'DevOps с нуля — Назаров И. С.', '99000', 1, 'normal', 'lms_enrollment', 10],
	['kam', 'b2c', 'Кузьмина', 'Аналитик данных — Кузьмина Т. В.', '109000', 1, 'low', 'lost', 12],
	['kam', 'b2c', 'Тарасов', 'Java-разработчик — Тарасов А. М.', '119000', 1, 'high', 'payment_contract', 9],
	['head', 'b2c', 'Орлов', 'UX/UI-дизайн — Орлов Д. К.', '79000', 1, 'normal', 'won', 3],
	['kam', 'b2c', 'Беляева', 'Python-старт — Беляева М. С.', '45000', 1, 'normal', 'contact_verification', 18],
	['head', 'b2c', 'Гусев', 'Тестировщик ПО — Гусев К. О.', '69000', 1, 'low', 'training_completed', 6],
	// третья волна: короткие SLA на ранних статусах — сделки быстро уходят в «Истекает» и «Нарушен»
	['kam', 'b2b', 'КГТУ', 'Пилот по кибербезопасности для магистров', '260000', 35, 'high', { step: 1 }, 60],
	['kam', 'b2b', 'СУТИ', 'Курс «Сети 5G» для бакалавров', '310000', 40, 'normal', { step: 2 }, 70],
	['head', 'b2b', 'ППУ', 'Летняя практика для студентов ИТ-института', '180000', 60, 'normal', { step: 3 }, 45],
	['kam', 'b2b', 'УАТУ', 'Программа «Умное производство»', '890000', 75, 'critical', { step: 2 }, 50],
	['kam', 'b2b', 'ЧИПМ', 'Введение в анализ данных для преподавателей', '145000', 25, 'low', { step: 1 }, 90],
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
const summary = { orgs: 0, contacts: 0, deals: 0, advanced: 0, transitions: 0, comments: 0, tasks: 0, participants: 0, sla: 0 };

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
	await ensureTeamTree(team);
	return team;
}

/** Команды с регионами для картинки справки: «Отдел вузов» — Москва, «Отдел колледжей» — Ростовская область, «Региональный отдел» внутри «Отдела вузов» — Новосибирская область. */
async function ensureTeamTree(root) {
	const regions = (await get('kam', '/api/regions')).items;
	const regionId = (name) => regions.find((r) => r.name === name)?.id ?? null;
	const users = (await get('admin', '/api/admin/users?limit=100')).items;
	const headId = (name) => users.find((u) => u.full_name === name)?.id ?? null;
	const fresh = await get('admin', `/api/admin/teams/${root.id}`);
	if (!fresh.region_id && regionId('Москва')) {
		await call('admin', 'PATCH', `/api/admin/teams/${root.id}`, { region_id: regionId('Москва') }, ifMatch(fresh.version));
		console.log(`  + «${TEAM_NAME}»: регион Москва`);
	}
	const extra = [
		{ name: 'Отдел колледжей', region: 'Ростовская область', head: 'Дмитрий Волков', parent_id: null },
		{ name: 'Региональный отдел', region: 'Новосибирская область', head: 'Сергей Смирнов', parent_id: root.id }
	];
	const teams = (await get('admin', '/api/admin/teams?limit=100')).items;
	for (const t of extra) {
		if (teams.some((x) => x.name === t.name)) continue;
		const body = { name: t.name, parent_id: t.parent_id, region_id: regionId(t.region), head_id: headId(t.head) };
		try {
			await post('admin', '/api/admin/teams', body);
		} catch {
			await post('admin', '/api/admin/teams', { ...body, head_id: null });
		}
		console.log(`  + команда «${t.name}»`);
	}
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
// B2C — по кодам статусов; B2B — по номерам шагов задания 1–3 (коды воронки меняются между версиями набора).
const SLA_SHORT_HOURS = { contact_verification: 0.05, consultation: 1.5 };
const SLA_SHORT_B2B_STEPS = [0.05, 0.15, 1];

function wantedSla(graph) {
	const b2b = graph.workflow.deal_type === 'b2b';
	const order = graphSteps(graph);
	return order
		.map((s) => {
			const short = b2b ? SLA_SHORT_B2B_STEPS[order.indexOf(s)] : SLA_SHORT_HOURS[s.code];
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

// ---------------------------------------------------------------- лицензии вуз–вендор–ПО (F2)
// Вендоры — организации-компании, ПО — продукты вида «ПО»; лицензии на вузы из ORGS. Идемпотентно: вендор/ПО — по названию и коду, лицензия — по номеру договора.
const LICENSE_VENDORS = ['ООО «Астра Линукс»', 'АО «Лаборатория Касперского»', 'ООО «РЕД СОФТ»', 'Фирма «1С»', 'ООО «Новые облачные технологии»', 'ООО «Базальт СПО»'];
const LICENSE_SOFTWARE = [
	['AST-SE', 'Astra Linux Special Edition', 0],
	['KES-ENT', 'Kaspersky Endpoint Security для бизнеса', 1],
	['RED-OS', 'РЕД ОС Муром', 2],
	['1C-EDU', '1С:Предприятие 8. Версия для обучения', 3],
	['MYOFFICE-EDU', 'МойОфис Образование', 4],
	['ALT-EDU', 'Альт Образование', 5]
];
// [фрагмент названия вуза, вендор, ПО, договор, дата подписания|null, подписана да/нет/null, действует до|null, срок в годах|null, бессрочно, статус передачи, менеджер, ответственные, комментарий]
// Часть лицензий уже истекла, часть истекает в 2026, есть бессрочная и «срок в годах» без даты, одна не подписана.
const LICENSES = [
	['Красноярский', 0, 0, 'ЛД-2024/011', '2024-02-12', true, '2025-02-11', null, false, 'transferred', 'Орлов Игорь Павлович', 'Белова Т. С., проректор по ИТ', 'Лицензия закончилась, продление обсуждается'],
	['Красноярский', 1, 1, 'ЛД-2025/044', '2025-09-03', true, '2027-09-02', null, false, 'transferred', 'Орлов Игорь Павлович', 'Белова Т. С., проректор по ИТ', null],
	['Московский открытый', 0, 0, 'ЛД-2023/102', '2023-10-20', true, '2025-10-19', null, false, 'transferred', 'Смирнова Алла Викторовна', 'Громов Д. А., начальник ЦИТ', 'Нужно продление до начала семестра'],
	['Московский открытый', 2, 2, 'ЛД-2026/007', '2026-03-14', true, '2026-12-31', null, false, 'in_progress', 'Смирнова Алла Викторовна', 'Громов Д. А., начальник ЦИТ', 'Заканчивается в декабре, ждём заявку на продление'],
	['Санкт-Петербургский', 3, 3, 'ЛД-2025/019', '2025-05-22', true, '2028-05-21', null, false, 'transferred', 'Кузнецов Роман Андреевич', 'Тихонова Е. В., зав. кафедрой информатики', null],
	['Санкт-Петербургский', 4, 4, 'ЛД-2026/021', null, false, null, 3, false, 'not_started', 'Кузнецов Роман Андреевич', 'Тихонова Е. В., зав. кафедрой информатики', 'Договор на согласовании у юристов вуза'],
	['Воронежский', 5, 5, 'ЛД-2024/067', '2024-11-05', true, '2026-03-31', null, false, 'transferred', 'Фёдорова Мария Олеговна', 'Рябов К. Н., заместитель директора', 'Срок вышел весной, вуз не продлил'],
	['Челябинский', 1, 1, 'ЛД-2026/030', '2026-06-18', true, '2029-06-17', null, false, 'in_progress', 'Орлов Игорь Павлович', 'Мельников А. В., проректор', null],
	['Уфимский', 0, 0, 'ЛД-2022/005', '2022-04-01', true, null, null, true, 'transferred', 'Смирнова Алла Викторовна', 'Хабибуллин Р. Р., начальник управления ИТ', 'Бессрочная лицензия по рамочному договору'],
	['Ростовский', 2, 2, 'ЛД-2026/012', '2026-02-09', true, '2026-11-30', null, false, 'transferred', 'Фёдорова Мария Олеговна', 'Сидоренко Л. П., директор колледжа', 'Истекает в ноябре'],
	['Кубанский', 3, 3, 'ЛД-2025/088', '2025-12-02', true, '2027-12-01', null, false, 'declined', 'Кузнецов Роман Андреевич', 'Прохоров С. И., проректор по развитию', 'Вуз отказался от передачи, выбрал другое решение'],
	['Уральский', 4, 4, 'ЛД-2025/053', '2025-07-15', true, '2027-07-14', null, false, 'transferred', 'Орлов Игорь Павлович', 'Дьяконов В. М., зав. лабораторией', null],
	['Новосибирский', 5, 5, 'ЛД-2026/033', '2026-09-01', true, '2031-08-31', null, false, 'in_progress', 'Фёдорова Мария Олеговна', 'Иванова О. Н., директор ЦИТ', 'Пятилетний договор, идёт передача дистрибутивов'],
	['Пермский', 1, 1, 'ЛД-2024/090', '2024-09-10', true, '2025-09-09', null, false, 'transferred', 'Смирнова Алла Викторовна', 'Никифоров Е. Г., проректор', 'Истекла в прошлом году'],
	['Самарский', 0, 0, 'ЛД-2026/041', null, null, null, 2, false, 'not_started', 'Кузнецов Роман Андреевич', 'Лебедева Н. А., начальник отдела ИТ', null],
	['Казанский', 2, 2, 'ЛД-2025/071', '2025-10-27', true, '2026-10-26', null, false, 'transferred', 'Орлов Игорь Павлович', 'Шакиров Т. Ф., проректор по цифровизации', 'Закончится через неделю'],
	['Казанский', 3, 3, 'ЛД-2026/002', '2026-01-20', true, '2028-01-19', null, false, 'transferred', 'Орлов Игорь Павлович', 'Шакиров Т. Ф., проректор по цифровизации', null]
];

async function ensureLicenses(orgsByShort) {
	const vendorIds = [];
	for (const name of LICENSE_VENDORS) {
		// поиск идёт по подстроке названия: по куску без кавычек («ООО Астра Лину») вендор не находился и сид падал на повторном запуске (409)
		const found = await get('admin', `/api/organizations?org_type=company&q=${encodeURIComponent(name.match(/«(.+)»/)?.[1] ?? name)}&limit=20`);
		let org = found.items.find((o) => o.name === name);
		if (!org) org = await post('admin', '/api/organizations', { name, org_type: 'company', source: 'demo' }, idem());
		vendorIds.push(org.id);
	}
	const productIds = [];
	for (const [code, name, vendor] of LICENSE_SOFTWARE) {
		const found = await get('admin', `/api/products?kind=software&code=${code}&limit=5`);
		let product = found.items[0];
		if (!product) product = await post('admin', '/api/products', { code, name, kind: 'software', vendor_id: vendorIds[vendor], currency: 'RUB' }, idem());
		productIds.push(product.id);
	}
	const orgs = Object.values(orgsByShort);
	let created = 0;
	for (const [frag, vendor, product, contract, signedAt, signed, until, term, perpetual, status, manager, responsible, comment] of LICENSES) {
		const org = orgs.find((o) => o.name.includes(frag));
		if (!org) continue;
		const exists = await get('admin', `/api/organization-licenses?q=${encodeURIComponent(contract)}&limit=5`);
		if (exists.items.some((l) => l.contract_number === contract)) continue;
		await post(
			'admin',
			'/api/organization-licenses',
			{
				organization_id: org.id,
				vendor: LICENSE_VENDORS[vendor],
				vendor_id: vendorIds[vendor],
				product_name: LICENSE_SOFTWARE[product][1],
				product_id: productIds[product],
				contract_number: contract,
				license_signed_at: signedAt,
				is_signed: signed,
				license_valid_until: until,
				license_term_years: term,
				is_perpetual: perpetual,
				transfer_status: status,
				manager_full_name: manager,
				responsible_contacts: responsible,
				comment
			},
			idem()
		);
		created += 1;
	}
	return created;
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

/**
 * Маршрут B2B-сделки по цели из DEALS: номера шагов подряд (шаг 5 — только если `via5`), затем возврат на шаг назад или завершающий статус.
 * Шаг 5 необязателен: без него переход идёт 4 → 6 напрямую.
 */
export function routeFor(target, via5) {
	const at = target.at ?? target.step;
	const route = [];
	for (let n = 2; n <= at; n += 1) if (n !== 5 || via5 || at < 6) route.push(n);
	if (target.back && at > 1) route.push(at === 6 && !via5 ? 4 : at - 1);
	if (target.end) route.push(target.end);
	return route;
}

let b2bFlow = null; // воронка B2B: список шагов и все статусы (нужны walkB2b)

/** Условия перехода → поля, файлы и комментарий тела запроса; подпись выполнить нельзя — такой переход пропускается с понятной строкой. */
async function bodyFor(who, j, deal, t, status, lossReasonId) {
	const body = { to_status_id: status.id, fields: {}, attachments: [] };
	if (t.requires_comment) body.comment = status.type === 'lost' ? 'Вуз выбрал другого поставщика после сравнения КП.' : status.type === 'parked' ? 'Ждём решения учёного совета, вернёмся к сделке позже.' : `Переход: ${t.name}.`;
	if (status.type === 'lost') body.fields.loss_reason_id = lossReasonId;
	if (status.type === 'parked') body.fields['custom_fields.park_reason'] = 'Решение учёного совета отложено';
	if (t.satisfied) return body;
	let needSignature = false;
	for (const leaf of t.conditions ?? []) {
		if (leaf.satisfied) continue;
		const file = /^step_attachments\.(.+)$/.exec(leaf.field);
		if (file) {
			if (!body.attachments.length) body.attachments.push(await attachPdf(j, deal.id, file[1]));
		} else if (leaf.field === 'signature_status') needSignature = true;
		else if (leaf.field === 'loss_reason_id' || leaf.field === 'custom_fields.park_reason' || leaf.field === 'custom_fields.resume_at') continue;
		else if (leaf.field.startsWith('custom_fields.')) body.fields[leaf.field] = leaf.expected ?? 'Демо';
	}
	if (needSignature && !body.attachments.length) throw new Error('переход требует подписи: пропущен');
	return body;
}

async function walkB2b(who, deal, route, lossReasonId) {
	const j = await apiAs(who);
	let current = deal;
	for (const stop of route) {
		const status = typeof stop === 'number' ? b2bFlow.steps[stop - 1] : b2bFlow.all.find((x) => x.type === stop);
		const available = (await get(who, `/api/deals/${current.id}/available-transitions`)).items;
		const t = available.find((x) => x.to_status_id === status.id);
		if (!t || !t.role_allowed) {
			console.log(`    ! ${deal.number}: нет доступного перехода в «${status.name.slice(0, 40)}»${t ? ' (не по роли)' : ''}`);
			return current;
		}
		try {
			const body = await bodyFor(who, j, current, t, status, lossReasonId);
			const res = await post(who, `/api/deals/${current.id}/transition`, body, ifMatch(current.version));
			current = res.deal;
			summary.transitions += 1;
		} catch (e) {
			console.log(`    ! ${deal.number}: переход «${t.name.slice(0, 50)}» не выполнен (${e.message.slice(0, 140)})`);
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
				const title = TASK_TITLES[h % TASK_TITLES.length];
				const priority = ['normal', 'high', 'low'][h % 3];
				// «Подготовить презентацию программы» есть и среди типовых, и среди разных названий: без этой проверки такая задача перезаписывалась на каждом прогоне
				if (title === task.title && priority === task.priority) continue;
				await call(who, 'PATCH', `/api/tasks/${task.id}`, { title, priority });
				if (h % 5 === 0 && task.status === 'open') await post(who, `/api/tasks/${task.id}/complete`);
				renamed += 1;
			}
			if (!res.next_cursor) break;
			cursor = res.next_cursor;
		}
	}
	if (renamed) console.log(`  задач переименовано: ${renamed}`);
}

// ---------------------------------------------------------------- витрина: чтобы не было пустых списков (запросы доступа, согласования, ключи,
// подписи, отчёты, файлы, филиалы…). Каждый блок идемпотентен (ищет по стабильному названию/адресу) и не валит весь сид: ошибка блока — предупреждение.
const showcase = { requests: 0, approvals: 0, docs: 0, signed: 0, reports: 0, files: 0, branches: 0 };

/** Вызов, который не бросает: { status, body }. */
async function tryCall(who, method, path, body, headers = {}) {
	try {
		return { status: 200, body: await call(who, method, path, body, headers) };
	} catch (e) {
		return { status: e.status ?? 0, body: e.body ?? null, message: e.message };
	}
}

async function block(name, fn) {
	console.log(`${name}…`);
	try {
		await fn();
	} catch (e) {
		console.log(`  ! ${name}: ${e.message}`);
	}
}

// запросы доступа менеджера к вузам руководителя и администратора (УФИИ, ТюмГИЦТ, ОмКИТ ведёт руководитель, ЗАО «МФТИ-НТ» — администратор):
// ожидают решения, один отклонён, один одобрен на 30 дней. Чужие вузы по иерархии руководителю доступны, поэтому его запросы не заводим.
async function ensureAccessRequests(orgsByShort, adminOrgId) {
	const mine = (await get('kam', '/api/access-requests?box=mine&limit=100')).items;
	const ask = async (orgId, reason) => {
		const res = await tryCall('kam', 'POST', '/api/access-requests', { entity_type: 'organization', entity_id: orgId, reason }, idem());
		if (res.status >= 300) {
			console.log(`  ! запрос доступа: ${res.message}`);
			return null;
		}
		showcase.requests += 1;
		return res.body;
	};
	const plan = [
		[orgsByShort['УФИИ']?.id, 'Нужно уточнить контакты декана перед летней ИТ-школой, прошу доступ к карточке УФИИ.', null, 'head'],
		[adminOrgId, 'Вуз пришёл с сайта, хочу связаться с контактным лицом и завести сделку.', null, 'admin'],
		[orgsByShort['ТюмГИЦТ']?.id, 'Веду переговоры с проректором по программе «Цифровые кафедры», нужен доступ к карточке вуза и его контактам.', { decision: 'reject', comment: 'По этому вузу работает мой отдел, давайте сначала обсудим на планёрке.' }, 'head'],
		[orgsByShort['ОмКИТ']?.id, 'Колледж запросил КП на курс по сетям, прошу доступ к карточке, чтобы подготовить предложение.', { decision: 'approve', days: 30, comment: 'Доступ на 30 дней, КП подготовьте до конца месяца.' }, 'head']
	];
	for (const [orgId, reason, decision, decider] of plan) {
		if (!orgId) continue;
		let request = mine.find((r) => r.entity_id === orgId);
		if (!request) request = await ask(orgId, reason);
		if (request && decision && request.status === 'pending') await tryCall(decider, 'POST', `/api/access-requests/${request.id}/decision`, decision);
	}
}

// «Четыре глаза»: заявки на заведение администратора. Заявка открывается ответом об ошибке «нужно второе подтверждение»; пользователь не создаётся,
// пока инициатор не нажмёт «Выполнить» после подтверждения.
async function ensureApprovals() {
	const specs = [
		{ by: 'admin', name: 'Сидоров Иван Петрович', email: 'i.sidorov@rtk-school.example', decide: null },
		{ by: 'admin2', name: 'Кузнецова Ольга Николаевна', email: 'o.kuznetsova@rtk-school.example', decide: null },
		{ by: 'admin', name: 'Лебедев Артём Игоревич', email: 'a.lebedev@rtk-school.example', decide: { who: 'admin2', reason: 'Сначала нужна заявка от руководителя отдела, пришлите её и повторите.' } }
	];
	for (const spec of specs) {
		// без параметра `status` список отдаёт только ожидающие, поэтому решённые ищем по каждому статусу отдельно
		const list = async () => {
			const rows = [];
			for (const status of ['pending', 'approved', 'rejected', 'consumed', 'expired']) rows.push(...(await get(spec.by, `/api/admin/approvals?status=${status}&limit=100`)).items);
			return rows.filter((a) => a.payload?.email === spec.email);
		};
		let found = await list();
		if (!found.some((a) => a.status !== 'expired')) {
			await tryCall(spec.by, 'POST', '/api/admin/users', { full_name: spec.name, email: spec.email, role: 'ADMIN' }, idem());
			found = await list();
			if (found.some((a) => a.status === 'pending')) showcase.approvals += 1;
		}
		const pending = found.find((a) => a.status === 'pending');
		if (spec.decide && pending) await tryCall(spec.decide.who, 'POST', `/api/admin/approvals/${pending.id}/reject`, { reason: spec.decide.reason });
	}
}

async function ensureIntegrations() {
	const users = (await get('admin', '/api/admin/users?limit=100')).items;
	const integration = users.find((u) => u.role === 'INTEGRATION');
	const KEY_NAME = 'Сайт школы — приём заявок';
	const keys = await get('admin', '/api/admin/integrations/api-keys');
	if (integration && !keys.some((k) => k.name === KEY_NAME)) {
		await post('admin', '/api/admin/integrations/api-keys', { name: KEY_NAME, user_id: integration.id }, idem()); // ключ в ответе не сохраняем и не печатаем
		console.log(`  + ключ «${KEY_NAME}»`);
	}
	const SUB_NAME = 'Сайт школы — события CRM';
	const subs = await get('admin', '/api/admin/integrations/webhooks');
	let sub = subs.find((s) => s.name === SUB_NAME);
	if (!sub) {
		// в офлайн-контейнере BASE — внутренний адрес сети compose, а подписка нужна на публичный
		const url = `${process.env.SEED_PUBLIC_URL || BASE}/site/`;
		sub = await post('admin', '/api/admin/integrations/webhooks', { name: SUB_NAME, url, event_types: ['DOCUMENT_SIGNED', 'DEAL_CREATED'] }, idem());
		console.log(`  + подписка «${SUB_NAME}»`);
		await tryCall('admin', 'POST', `/api/admin/integrations/webhooks/${sub.id}/test`);
	}
}

async function ensureRetentionAndSettings() {
	const runs = await get('admin', '/api/admin/retention/runs?limit=5');
	if (!runs.items.length) {
		await post('admin', '/api/admin/retention/run', { dry_run: true });
		console.log('  + пробный прогон хранения (dry-run)');
	}
	// настройка из реально используемых: контакт для уведомления РКН (до этого в черновике стояло «не указано»)
	const settings = await get('admin', '/api/admin/system-settings');
	if (!settings.items.some((s) => s.key === 'pdn.rkn_contact')) {
		await call('admin', 'PUT', '/api/admin/system-settings/pdn.rkn_contact', {
			value: 'Ответственный за обработку персональных данных: Иванова Е. А., privacy@rtk-school.example, +7 (495) 000-00-00',
			description: 'Контакт оператора для уведомлений Роскомнадзора об инцидентах'
		});
		console.log('  + настройка pdn.rkn_contact');
	}
}

// Подписи: [кто создаёт, название сделки, название документа, подписанты (ключи me), действия [кто, sign|reject, причина]]
const SIGN_SPECS = [
	['head', 'Расширение программы на второй кампус', 'Согласование КП: второй кампус МОУПН', ['kam', 'admin'], [['kam', 'sign']]],
	['head', 'Хакатон-интенсив для студентов', 'Договор-оферта: хакатон-интенсив', ['kam'], []],
	['head', 'Пролонгация программы 2024 года', 'Согласование КП: пролонгация программы', ['kam'], [['kam', 'reject', 'Нужно пересчитать стоимость с учётом новой скидки.']]],
	['head', 'Кибербезопасность для преподавателей', 'Согласование КП: кибербезопасность', ['admin'], []],
	['kam', 'Курс «Кибербезопасность» для агроинженеров', 'Согласование скидки: КубГАТУ', ['admin'], [['admin', 'sign']]],
	['kam', 'Цифровая кафедра: DevOps-трек', 'Согласование КП: цифровая кафедра НИЦТ', ['head'], []]
];

async function ensureSignatures(me) {
	for (const [creator, dealTitle, title, signerKeys, actions] of SIGN_SPECS) {
		const found = await get(creator, `/api/deals?q=${encodeURIComponent(dealTitle)}&limit=5`);
		const deal = found.items.find((d) => d.title === dealTitle);
		if (!deal) continue;
		const docs = (await get(creator, `/api/signature-documents?entity_type=deal&entity_id=${deal.id}&limit=50`)).items;
		let doc = docs.find((d) => d.title === title);
		if (!doc) {
			const created = await tryCall(creator, 'POST', '/api/signature-documents', { doc_type: 'kp', title, entity_type: 'deal', entity_id: deal.id, template_code: 'kp_approval', signers: signerKeys.map((k) => ({ user_id: me[k].id })), signing_order: 'parallel' }, idem());
			if (created.status >= 300) {
				console.log(`  ! документ «${title}»: ${created.message}`);
				continue;
			}
			const sent = await tryCall(creator, 'POST', `/api/signature-documents/${created.body.id}/send`);
			if (sent.status >= 300) {
				console.log(`  ! отправка «${title}»: ${sent.message}`);
				continue;
			}
			doc = sent.body;
			showcase.docs += 1;
		} else if (doc.status === 'draft') {
			const sent = await tryCall(creator, 'POST', `/api/signature-documents/${doc.id}/send`);
			if (sent.status < 300) doc = sent.body;
		}
		for (const [who, action, reason] of actions) {
			const request = (doc.requests ?? []).find((r) => r.signer_user_id === me[who].id);
			if (!request || !['sent', 'viewed'].includes(request.status)) continue;
			await tryCall(who, 'POST', `/api/signature-requests/${request.id}/view`);
			if (action === 'reject') {
				await tryCall(who, 'POST', `/api/signature-requests/${request.id}/reject`, { reason });
				continue;
			}
			const challenge = await tryCall(who, 'POST', `/api/signature-requests/${request.id}/challenge`);
			if (!challenge.body?.debug_code) {
				console.log(`  ! подпись «${title}»: стенд не отдал демо-код (${challenge.message ?? 'без debug_code'})`);
				continue;
			}
			const signed = await tryCall(who, 'POST', `/api/signature-requests/${request.id}/sign`, { otp: challenge.body.debug_code });
			if (signed.status < 300) showcase.signed += 1;
			else console.log(`  ! подпись «${title}»: ${signed.message}`);
		}
	}
}

// отчёты: [кто, вид, формат]
const REPORT_SPECS = [
	['head', 'deal_funnel', 'xlsx'],
	['head', 'sla_compliance', 'xlsx'],
	['head', 'stuck_deals', 'pdf'],
	['head', 'monthly_dynamics', 'xlsx'],
	['kam', 'deal_register', 'xlsx'],
	['kam', 'stuck_deals', 'xlsx']
];

async function ensureReports() {
	const have = {};
	for (const [who, code, format] of REPORT_SPECS) {
		have[who] ??= (await get(who, '/api/reports?limit=100')).items;
		if (have[who].some((r) => r.template_code === code && r.format === format)) continue;
		const res = await tryCall(who, 'POST', '/api/reports', { template_code: code, format, params: {} }, idem());
		if (res.status >= 300) {
			console.log(`  ! отчёт ${code}: ${res.message}`);
			continue;
		}
		showcase.reports += 1;
	}
}

// филиалы и институты (вкладка «Филиалы»): [вуз, название, адрес, родитель]
const BRANCHES = [
	['КГТУ', 'Институт информационных технологий', 'г. Казань, ул. Университетская, д. 5', null],
	['КГТУ', 'Кафедра прикладной информатики', null, 'Институт информационных технологий'],
	['КГТУ', 'Альметьевский филиал', 'г. Альметьевск, ул. Ленина, д. 12', null],
	['МОУПН', 'Институт цифровой экономики', 'г. Москва, Ленинградский пр-т, д. 31', null],
	['МОУПН', 'Колледж при МОУПН', 'г. Москва, ул. Бауманская, д. 9', null],
	['МОУПН', 'Зеленоградский филиал', 'г. Москва, Зеленоград, корп. 1801', null],
	['УФИИ', 'Институт кибербезопасности', 'г. Екатеринбург, ул. Мира, д. 19', null],
	['УФИИ', 'Нижнетагильский филиал', 'г. Нижний Тагил, ул. Красноармейская, д. 59', null],
	['СУТИ', 'Факультет вычислительной техники', null, null],
	['УАТУ', 'Институт авиационных технологий', 'г. Уфа, ул. К. Маркса, д. 12', null],
	['УАТУ', 'Стерлитамакский филиал', 'г. Стерлитамак, пр-т Октября, д. 2', null],
	['КСУТ', 'Институт космических и информационных технологий', 'г. Красноярск, ул. Киренского, д. 26', null],
	['СПбИЦЭ', 'Высшая школа цифровых сервисов', 'г. Санкт-Петербург, наб. реки Мойки, д. 36', null],
	['КубГАТУ', 'Факультет прикладной информатики', 'г. Краснодар, ул. Калинина, д. 13', null],
	['ЧИПМ', 'Институт математического моделирования', 'г. Челябинск, пр-т Ленина, д. 76', null],
	['РКСИ', 'Отделение сетевых технологий', 'г. Ростов-на-Дону, ул. Пушкинская, д. 140', null],
	['НИЦТ', 'Лаборатория больших данных', 'г. Новосибирск, пр-т Академика Лаврентьева, д. 6', null],
	['ППУ', 'Институт непрерывного образования', null, null],
	['ВГКИТ', 'Отделение программирования', 'г. Воронеж, ул. Плехановская, д. 53', null],
	['Цифровые кадры', 'Офис в Санкт-Петербурге', 'г. Санкт-Петербург, Невский пр-т, д. 90', null]
];

async function ensureBranches(orgsByShort, ownerByShort) {
	const cache = {};
	for (const [short, name, address, parentName] of BRANCHES) {
		const org = orgsByShort[short];
		if (!org) continue;
		const who = ownerByShort[short] ?? 'kam';
		cache[short] ??= (await get(who, `/api/organizations/${org.id}/branches`)).items;
		if (cache[short].some((b) => b.name === name)) continue;
		const parent = parentName ? cache[short].find((b) => b.name === parentName) : null;
		const res = await tryCall(who, 'POST', `/api/organizations/${org.id}/branches`, { name, address, parent_id: parent?.id ?? null });
		if (res.status >= 300) {
			console.log(`  ! филиал «${name}»: ${res.message}`);
			continue;
		}
		cache[short].push(res.body);
		showcase.branches += 1;
	}
}

// файлы сделок и вузов: [кто, 'deal'|'organization', название сделки / короткое имя вуза, категория, имя файла]
const FILE_SPECS = [
	['kam', 'deal', 'Программа «Разработка на Python» для 3 курса', 'contract', 'Договор_Python_3курс.pdf'],
	['kam', 'deal', 'Программа «Разработка на Python» для 3 курса', 'presentation', 'Презентация_программы.pdf'],
	['kam', 'deal', 'Цифровая кафедра: DevOps-трек', 'presentation', 'КП_DevOps-трек.pdf'],
	['kam', 'deal', 'Цифровая кафедра: DevOps-трек', 'other', 'Список_групп.pdf'],
	['kam', 'deal', 'Курс «Кибербезопасность» для агроинженеров', 'contract', 'Договор_КубГАТУ.pdf'],
	['kam', 'deal', 'Трек «Промышленный интернет вещей»', 'presentation', 'Программа_IoT.pdf'],
	['kam', 'deal', 'Курс «Машинное обучение» — 2025/26', 'act', 'Акт_ML_2025.pdf'],
	['head', 'deal', 'Расширение программы на второй кампус', 'contract', 'Допсоглашение_кампус.pdf'],
	['head', 'deal', 'Расширение программы на второй кампус', 'presentation', 'Презентация_кампус.pdf'],
	['head', 'deal', 'Пролонгация программы 2024 года', 'act', 'Акт_пролонгация.pdf'],
	['head', 'deal', 'Хакатон-интенсив для студентов', 'other', 'Регламент_хакатона.pdf'],
	['kam', 'organization', 'КГТУ', 'contract', 'Рамочный_договор_КГТУ.pdf'],
	['kam', 'organization', 'СУТИ', 'other', 'Карточка_партнёра_СУТИ.pdf'],
	['kam', 'organization', 'ППУ', 'presentation', 'Презентация_для_ППУ.pdf'],
	['kam', 'organization', 'КСУТ', 'license', 'Лицензионное_соглашение_КСУТ.pdf'],
	['head', 'organization', 'МОУПН', 'contract', 'Рамочный_договор_МОУПН.pdf'],
	['head', 'organization', 'УФИИ', 'other', 'Соглашение_о_сотрудничестве_УФИИ.pdf'],
	['kam', 'organization', 'ЧИПМ', 'contract', 'Договор_о_сотрудничестве_ЧИПМ.pdf'],
	['kam', 'organization', 'РКСИ', 'presentation', 'Презентация_для_РКСИ.pdf'],
	['kam', 'organization', 'НИЦТ', 'other', 'Реквизиты_НИЦТ.pdf'],
	['kam', 'organization', 'СПбИЦЭ', 'contract', 'Рамочный_договор_СПбИЦЭ.pdf'],
	['kam', 'organization', 'ВГКИТ', 'other', 'Письмо_о_намерениях_ВГКИТ.pdf'],
	['kam', 'organization', 'КубГАТУ', 'contract', 'Договор_КубГАТУ_общий.pdf'],
	['kam', 'organization', 'УАТУ', 'presentation', 'Презентация_для_УАТУ.pdf'],
	['kam', 'organization', 'Цифровые кадры', 'contract', 'Договор_с_партнёром.pdf']
];

async function ensureFiles(orgsByShort) {
	const clients = {};
	for (const [who, kind, subject, category, name] of FILE_SPECS) {
		let entityId;
		if (kind === 'deal') {
			const found = await get(who, `/api/deals?q=${encodeURIComponent(subject)}&limit=5`);
			entityId = found.items.find((d) => d.title === subject)?.id;
		} else {
			entityId = orgsByShort[subject]?.id;
		}
		if (!entityId) continue;
		const list = (await get(who, `/api/attachments?entity_type=${kind}&entity_id=${entityId}&limit=50`)).items;
		if (list.some((a) => a.description === name || a.file?.original_filename === name)) continue;
		try {
			clients[who] ??= await apiAs(who);
			await attachPdf(clients[who], entityId, category, name, kind);
			showcase.files += 1;
		} catch (e) {
			console.log(`  ! файл «${name}»: ${e.message}`);
		}
	}
}

async function main() {
	console.log(`Сид демо-данных → ${BASE}`);
	// первым запросом каждого пользователя обязан быть GET /api/me: он создаёт локальную запись (JIT) и не требует согласия на ПДн
	for (const who of ['admin', 'admin2', 'head', 'kam', 'auditor']) await login(who);
	const me = { kam: await get('kam', '/api/me'), head: await get('head', '/api/me'), admin: await get('admin', '/api/me') };

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
	b2bFlow = { steps: graphSteps(graphs.b2b), all: graphs.b2b.statuses.filter((x) => !x.is_archived) };
	console.log(`  B2B: «${graphs.b2b.workflow.name}», шагов ${b2bFlow.steps.length}`);

	console.log('Организации…');
	const ownerOf = (org) => (HEAD_ORGS.has(org.short) ? 'head' : 'kam');
	const ownerByShort = Object.fromEntries(ORGS.map((org) => [org.short, ownerOf(org)]));
	const orgsByShort = await ensureOrganizations(regionsByName, ownerOf);
	console.log(`  организаций: ${Object.keys(orgsByShort).length} (новых ${summary.orgs})`);

	console.log('Контакты…');
	const contacts = await ensureContacts(orgsByShort, ownerByShort);
	console.log(`  контактов: ${Object.keys(contacts).length} (новых ${summary.contacts})`);

	console.log('Лицензии…');
	console.log(`  лицензий: ${LICENSES.length} (новых ${await ensureLicenses(orgsByShort)})`);

	console.log('Сделки…');
	const created = [];
	let needFive = 0; // сколько сделок уже должны были пройти шаг 5: каждая третья идёт через него
	for (const [plannedWho, type, party, title, amount, students, priority, target, closeDays] of DEALS) {
		// Менеджер не может завести сделку на чужую организацию (бэкенд отвечает 404, как для несуществующей): если организацию
		// ведёт руководитель, сделку по ней заводит он. Организации руководителя — только МОУПН и УФИИ (`ownerOf` выше).
		const who = type === 'b2b' && plannedWho === 'kam' && ownerByShort[party] === 'head' ? 'head' : plannedWho;
		const isB2b = type === 'b2b' && typeof target === 'object';
		const passesFive = isB2b && (target.at ?? target.step) >= 6;
		const via5 = passesFive && needFive++ % 3 === 0;
		const lossReasonId = lossReasons[Math.abs(hash(title)) % lossReasons.length]?.id;
		const found = await get(who, `/api/deals?q=${encodeURIComponent(title)}&limit=5`);
		const existing = found.items.find((d) => d.title === title);
		if (existing) {
			// сделка уже есть: если она остановилась на маршруте раньше цели (сид шёл по старой воронке), доводим до цели с того места;
			// историю не переписываем: сделка вне маршрута или уже у цели остаётся как есть
			if (isB2b) {
				const full = (await get(who, `/api/deals/${existing.id}`)).deal;
				const route = routeFor(target, via5);
				const here = b2bFlow.steps.findIndex((x) => x.id === full.status_id) + 1;
				const from = here === 1 ? -1 : here > 1 ? route.lastIndexOf(here) : -2;
				if (from > -2 && !full.closed_at && from < route.length - 1) {
					const moved = await walkB2b(who, full, route.slice(from + 1), lossReasonId);
					if (moved.status_id !== full.status_id) {
						summary.advanced += 1;
						console.log(`  ↑ ${full.number} «${title}» → ${JSON.stringify(target)}`);
					}
				}
			}
			continue;
		}
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
		deal = isB2b ? await walkB2b(who, deal, routeFor(target, via5), lossReasonId) : await walk(who, deal, graphs[type], target, lossReasonId);
		created.push({ who, deal, party });
		console.log(`  + ${deal.number} «${title}» → ${typeof target === 'string' ? target : JSON.stringify(target)}`);
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

	await block('Филиалы и институты', () => ensureBranches(orgsByShort, ownerByShort));
	await block('Файлы сделок и вузов', () => ensureFiles(orgsByShort));
	await block('Интеграции: ключ и подписка', ensureIntegrations);
	await block('Запросы доступа', async () => {
		const adminOrg = (await get('admin', '/api/organizations?q=%D0%9C%D0%A4%D0%A2%D0%98&limit=10')).items.find((o) => o.owner_id === me.admin.id);
		await ensureAccessRequests(orgsByShort, adminOrg?.id ?? null);
	});
	await block('Согласования «четыре глаза»', ensureApprovals);
	await block('Подписание', () => ensureSignatures(me));
	await block('Отчёты', ensureReports);
	await block('Хранение и системные настройки', ensureRetentionAndSettings);

	console.log('Готово:', JSON.stringify({ ...summary, ...showcase }));
}

main().catch((e) => {
	console.error('Сид прерван:', e.message);
	process.exitCode = 1;
});
