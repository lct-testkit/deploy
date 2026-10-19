<script>
	// Список-аккордеон на компонентах ДС. items: [{ title, text?, list? }].
	import { Accordion, AccordionDetails, AccordionGroup, AccordionSummary, Typography } from '@lct-testkit/rt-ui';
	import { ChevronDown } from '@lct-testkit/rt-ui/icons';

	let { items, mode = 'single' } = $props();
</script>

<AccordionGroup selectionMode={mode} class="acc">
	{#each items as item, i (item.title)}
		<Accordion class="acc__item" isOpen={i === 0}>
			<AccordionSummary class="acc__summary" cursor="pointer">
				{#snippet children({ isOpen })}
					<Typography variant="body-l" strong class="acc__title">{item.title}</Typography>
					<span class={['acc__chevron', isOpen && 'acc__chevron--open']}><ChevronDown /></span>
				{/snippet}
			</AccordionSummary>
			<AccordionDetails class="acc__details">
				{#if item.text}<Typography variant="body-m" class="muted">{item.text}</Typography>{/if}
				{#if item.list}
					<ul class="acc__list">
						{#each item.list as li (li)}<li><Typography as="span" variant="body-m">{li}</Typography></li>{/each}
					</ul>
				{/if}
			</AccordionDetails>
		</Accordion>
	{/each}
</AccordionGroup>
