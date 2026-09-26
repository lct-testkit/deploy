// Сгенерировано scripts/sync_seed.sh из frontend/tools/lib.mjs — руками не править.
// Выжимка для сидов: адрес API, демо-учётки, токен и согласие на обработку ПДн.
// Без playwright (в образе node его нет): скриншотные хелперы frontend сюда не входят.
import http from 'node:http';

// --- Отличия от frontend/tools/lib.mjs: скрипты работают ВНУТРИ сети compose ---------------------------------
// 1. Keycloak берёт issuer токенов из X-Forwarded-Host/Proto (KC_PROXY_HEADERS=xforwarded). Скрипты ходят на
//    http://caddy:8080, и без подмены iss = http://caddy:8080/..., а API отвечает «Токен выдан другим realm».
//    Caddy доверяет X-Forwarded-* из приватных сетей (trusted_proxies), поэтому представляемся публичным адресом
//    стенда (SEED_PUBLIC_URL = BASE_URL).
// 2. Presigned-ссылки S3 (загрузка реестра ЕГРЮЛ) API подписывает на публичный адрес S3_PUBLIC_ENDPOINT_URL, из
//    контейнера он недоступен (обращение к публичному адресу хоста режет файрвол). Такие запросы идут напрямую
//    в seaweedfs, а заголовок Host остаётся публичным: подпись SigV4 считается по нему. fetch (undici) менять
//    Host не позволяет, поэтому для S3 используется node:http.
const publicUrl = process.env.SEED_PUBLIC_URL;
const s3PublicUrl = process.env.SEED_S3_PUBLIC_URL;
const s3InternalUrl = process.env.SEED_S3_INTERNAL_URL;
if (publicUrl || (s3PublicUrl && s3InternalUrl)) {
	const nativeFetch = globalThis.fetch;
	const viaInternalS3 = (url, init) =>
		new Promise((resolve, reject) => {
			const target = new URL(url.pathname + url.search, s3InternalUrl);
			const headers = Object.fromEntries(new Headers(init.headers));
			const body = init.body == null ? null : Buffer.from(init.body);
			headers.host = url.host;
			if (body) headers['content-length'] = String(body.length);
			const req = http.request(target, { method: init.method ?? 'GET', headers }, (res) => {
				const chunks = [];
				res.on('data', (chunk) => chunks.push(chunk));
				res.on('end', () => {
					const empty = [101, 204, 205, 304].includes(res.statusCode);
					resolve(new Response(empty ? null : Buffer.concat(chunks), { status: res.statusCode }));
				});
			});
			req.on('error', reject);
			if (body) req.write(body);
			req.end();
		});
	globalThis.fetch = (input, init = {}) => {
		if (s3PublicUrl && s3InternalUrl && typeof input === 'string' && input.startsWith(s3PublicUrl)) {
			return viaInternalS3(new URL(input), init);
		}
		if (!publicUrl) return nativeFetch(input, init);
		const { protocol, host } = new URL(publicUrl);
		const headers = new Headers(init.headers);
		headers.set('X-Forwarded-Host', host);
		headers.set('X-Forwarded-Proto', protocol.replace(':', ''));
		return nativeFetch(input, { ...init, headers });
	};
}

export const BASE = process.env.APP_URL || 'http://localhost:5273';
export const ACCOUNTS = {
	kam: { username: 'kam.ivanov', password: 'Kam123456789!' },
	head: { username: 'head.petrov', password: 'Head12345678!' },
	admin: { username: 'admin.crm', password: 'Admin12345678!' },
	admin2: { username: 'admin.volkov', password: 'Volkov12345678!' },
	auditor: { username: 'auditor.smirnov', password: 'Audit12345678!' }
};

async function tokensFor(who) {
	const account = ACCOUNTS[who];
	if (!account) throw new Error(`unknown role "${who}" (kam|head|admin|admin2|auditor)`);
	const config = await (await fetch(`${BASE}/config.json`)).json();
	const kc = config.keycloak;
	const body = new URLSearchParams({
		grant_type: 'password',
		client_id: kc.clientId,
		client_secret: kc.clientSecret ?? '',
		scope: 'openid',
		username: account.username,
		password: account.password
	});
	// several pages of one role sign in at the same moment (tools/buttons.mjs): Keycloak now and then answers one of them 401 — try again
	let response;
	for (let attempt = 0; attempt < 5; attempt++) {
		response = await fetch(`${BASE}${kc.path}/realms/${kc.realm}/protocol/openid-connect/token`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
			body
		});
		if (response.ok) break;
		await new Promise((resolve) => setTimeout(resolve, 400 * (attempt + 1) + Math.random() * 400));
	}
	if (!response.ok) throw new Error(`login ${who}: HTTP ${response.status} ${await response.text()}`);
	const json = await response.json();
	const now = Date.now();
	return {
		access_token: json.access_token,
		refresh_token: json.refresh_token,
		access_expires_at: now + json.expires_in * 1000,
		refresh_expires_at: now + (json.refresh_expires_in ?? 1800) * 1000,
		username: account.username
	};
}

/** Access token for API calls from scripts (seeding, assertions). */
export async function accessToken(who) {
	return (await tokensFor(who)).access_token;
}

/** Accept the personal-data policy for a role through the API (so screenshots are not covered by the consent dialog). */
export async function ensureConsent(who, tokens) {
	const auth = { Authorization: `Bearer ${tokens.access_token}` };
	const me = await (await fetch(`${BASE}/api/me`, { headers: auth })).json();
	if (!me.consent_required) return;
	const policy = await (await fetch(`${BASE}/api/me/policy`, { headers: auth })).json();
	await fetch(`${BASE}/api/me/consent`, {
		method: 'POST',
		headers: { ...auth, 'Content-Type': 'application/json' },
		body: JSON.stringify({ policy_version: policy.version, policy_text_hash: policy.text_hash ?? 'a'.repeat(64) })
	});
}
