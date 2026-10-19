// Точка входа: подключает дизайн-систему rt-ui (стили, тема, шрифт) и монтирует Svelte-«острова» в контейнеры,
// которые Blade оставил с SSR-фолбэком (data-island="имя", data-props="JSON").
import '@lct-testkit/rt-ui/styles/rt-ui.min.css';
import '@lct-testkit/rt-ui/themes/rtk_default_light.min.css';
import '@lct-testkit/rt-ui/themes/rtk_purple_light.min.css';
import '../css/fonts.css';
import '../css/site.css';

import { mount } from 'svelte';
import SiteHeader from './islands/SiteHeader.svelte';
import SiteFooter from './islands/SiteFooter.svelte';
import CatalogPage from './islands/CatalogPage.svelte';
import CoursePage from './islands/CoursePage.svelte';
import ApplyForm from './islands/ApplyForm.svelte';
import ThanksPage from './islands/ThanksPage.svelte';

const islands = {
	header: SiteHeader,
	footer: SiteFooter,
	catalog: CatalogPage,
	course: CoursePage,
	apply: ApplyForm,
	thanks: ThanksPage,
};

for (const target of document.querySelectorAll('[data-island]')) {
	const component = islands[target.dataset.island];
	if (!component) continue;
	let props = {};
	try {
		props = JSON.parse(target.dataset.props || '{}');
	} catch {
		/* битые props — монтируем с пустыми, фолбэк останется на месте при ошибке ниже */
	}
	// Фолбэк убираем только перед самым монтированием и возвращаем, если компонент упал.
	const fallback = [...target.childNodes];
	try {
		target.replaceChildren();
		mount(component, { target, props });
	} catch (error) {
		console.error('island', target.dataset.island, error);
		target.replaceChildren(...fallback);
	}
	target.setAttribute('data-ready', '');
}
document.documentElement.classList.add('islands-ready');
