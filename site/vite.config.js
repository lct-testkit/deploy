import { defineConfig } from 'vite';
import laravel from 'laravel-vite-plugin';
import { svelte } from '@sveltejs/vite-plugin-svelte';

export default defineConfig({
	// Относительный base: сайт живёт и на корне (:8080 внутри сети), и под префиксом /site за Caddy;
	// абсолютные /build/... во втором случае не нашлись бы. Сборка кладёт ассеты в public/build.
	base: './',
	plugins: [laravel({ input: ['resources/js/app.js'] }), svelte()],
	// rt-ui тянет чистые ESM/CJS-хелперы, которые Vite должен предсобрать для браузера (как во frontend CRM).
	optimizeDeps: {
		include: ['attr-accept', 'imask', 'card-validator', 'clsx', 'dayjs', 'virtua', '@popperjs/core'].map((d) => `@lct-testkit/rt-ui > ${d}`),
	},
});
