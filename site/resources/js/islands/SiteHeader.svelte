<script>
	// Шапка как на edupro: меню-бургер слева, логотип по центру, «Войти» справа (оранжевая кнопка — акцент темы rtk_default).
	import { Button, Drawer, IconButton, TopMenu } from '@lct-testkit/rt-ui';
	import { Menu } from '@lct-testkit/rt-ui/icons';
	import Logo from './Logo.svelte';

	let { urls, loginUrl } = $props();
	let open = $state(false);
	const go = (url) => () => location.assign(url);
	const links = [
		['Курсы', `${urls.home}#courses`],
		['Как проходит обучение', `${urls.home}#how`],
		['Вопросы и ответы', `${urls.home}#faq`],
		['Подать заявку', urls.apply],
	];
</script>

{#snippet menuIcon()}<Menu />{/snippet}

<TopMenu class="site-topmenu">
	<div class="site-bar">
		<div class="site-bar__left">
			<IconButton variant="ghost" colorScheme="neutral" size="l" icon={menuIcon} aria-label="Открыть меню" onclick={() => (open = true)} />
		</div>
		<Logo href={urls.home} />
		<div class="site-bar__right"><Button size="m" label="Войти" onclick={go(loginUrl)} /></div>
	</div>
</TopMenu>

<Drawer position="left" dimension={300} isOpened={open} onClickOverlay={() => (open = false)} onClose={() => (open = false)}>
	<nav class="drawer-nav" aria-label="Меню сайта">
		{#each links as [label, url] (label)}
			<a class="drawer-nav__link" href={url} onclick={() => (open = false)}>{label}</a>
		{/each}
	</nav>
</Drawer>
