<script>
	// Логотип «ИТ школа РТК»: знак — фиолетовый «лист» с оранжевым загнутым уголком, перерисован по файлу владельца; надпись — шрифтом ДС.
	import { Typography } from '@lct-testkit/rt-ui';
	let { href, size = 40 } = $props();
</script>

<a class="logo" {href} aria-label="ИТ школа РТК — на главную">
	<svg width={size} height={size} viewBox="0 0 100 100" aria-hidden="true">
		<path fill="#7700ff" d="M0 100V28A28 28 0 0 1 28 0H100V44L43 100Z" />
		<path fill="#ff4f12" d="M43 100V68A24 24 0 0 1 67 44H100Z" />
	</svg>
	<Typography as="span" variant="heading-h4" strong class="logo__text">ИТ школа РТК</Typography>
</a>
