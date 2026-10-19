<script>
	import { Button, InlineNotification, Typography } from '@lct-testkit/rt-ui';

	let { urls } = $props();
</script>

<div class="container container--narrow stack">
	<InlineNotification colorScheme="success" title="Заявка принята" subtitle="Куратор свяжется с вами по указанным контактам в ближайший рабочий день." />
	<Typography as="h1" variant="heading-h2" class="section-title">Спасибо за интерес к школе</Typography>
	<Typography variant="body-l" class="muted">Пока ждёте звонка, посмотрите остальные программы каталога.</Typography>
	<div><Button size="l" label="На главную" onclick={() => location.assign(urls.home)} /></div>
</div>
