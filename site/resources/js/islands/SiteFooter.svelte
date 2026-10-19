<script>
	import { Typography } from '@lct-testkit/rt-ui';
	import Logo from './Logo.svelte';
	import CookieBanner from './CookieBanner.svelte';

	let { contact, urls, year } = $props();
</script>

<div class="site-footer__inner">
	<div class="site-footer__brand">
		<Logo href={urls.home} size={36} />
	</div>
	<div>
		<Typography variant="body-m" strong>Контакты</Typography>
		<Typography variant="body-m"><a href={`mailto:${contact.email}`}>{contact.email}</a></Typography>
		<Typography variant="body-m">{contact.phone}</Typography>
		<Typography variant="body-m">{contact.address}</Typography>
	</div>
	<div>
		<Typography variant="body-m" strong>Документы</Typography>
		<Typography variant="body-m"><a href={urls.policy}>Политика обработки персональных данных</a></Typography>
	</div>
	<Typography variant="body-s" class="site-footer__note">© {year} При поддержке Ростелеком ИТ школа</Typography>
</div>
<CookieBanner />
