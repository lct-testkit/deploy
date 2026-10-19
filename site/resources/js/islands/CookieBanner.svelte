<script>
	import { onMount } from 'svelte';
	import { InlineNotification } from '@lct-testkit/rt-ui';

	let visible = $state(false);
	const KEY = 'site-cookie-ok';

	onMount(() => {
		try {
			visible = localStorage.getItem(KEY) !== '1';
		} catch {
			visible = true;
		}
	});

	function accept() {
		try {
			localStorage.setItem(KEY, '1');
		} catch {
			/* хранилище недоступно — баннер просто закроется до перезагрузки */
		}
		visible = false;
	}
</script>

{#if visible}
	<div class="cookie" role="region" aria-label="Уведомление о cookie">
		<InlineNotification colorScheme="info" title="Мы используем файлы cookie"
			subtitle="Они помогают улучшать сайт. Продолжая просмотр, вы соглашаетесь с их использованием."
			actionButtons={[{ label: 'Понятно', action: accept }]} />
	</div>
{/if}
