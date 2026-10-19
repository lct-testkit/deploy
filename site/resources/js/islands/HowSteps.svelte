<script>
	import { Badge, Typography } from '@lct-testkit/rt-ui';
	let { how } = $props();
</script>

<div class="how">
	{#each how as [title, text], i (title)}
		<div class="how__item">
			<Badge variant="primary" colorScheme="accent" size="m" label={String(i + 1)} />
			<Typography variant="body-l" strong>{title}</Typography>
			<Typography variant="body-m" class="muted">{text}</Typography>
		</div>
	{/each}
</div>
