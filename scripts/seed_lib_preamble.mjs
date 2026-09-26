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

