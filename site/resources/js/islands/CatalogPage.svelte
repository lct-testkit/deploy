<script>
	import { Badge, Button, Typography } from '@lct-testkit/rt-ui';
	import Hero from './Hero.svelte';
	import AccordionList from './AccordionList.svelte';
	import HowSteps from './HowSteps.svelte';

	let { courses, urls, how, faq } = $props();
	const go = (url) => () => location.assign(url);
</script>

<Hero eyebrow="Стань востребованным специалистом на рынке труда" title="Курсы ИТ школы РТК: старт и рост в IT"
	text="Программирование, анализ данных, кибербезопасность и DevOps. Преподают практики, задания — из реальных проектов. Выберите курс и оставьте заявку."
	ctaLabel="Выбрать курс" ctaHref="#courses" facts={[`${courses.length} курсов`, 'Онлайн и очно', 'Проверка заданий экспертами']} />

<section class="section" id="courses">
	<div class="container">
		<Typography as="h2" variant="heading-h2" class="section-title">Каталог курсов</Typography>
		<div class="cards">
			{#each courses as course (course.code)}
				<article class="course">
					<div class="course__tags">
						<Badge variant="secondary" colorScheme="neutral" size="s" label={course.duration} />
						<Badge variant="secondary" colorScheme="accent" size="s" label={course.level} />
					</div>
					<Typography as="h3" variant="heading-h4">{course.title}</Typography>
					<Typography variant="body-m" class="muted">{course.lead}</Typography>
					<div class="course__foot">
						<Typography variant="body-s" class="muted">{course.format}</Typography>
						<Button size="m" label="Подробнее" onclick={go(course.url)} />
					</div>
				</article>
			{/each}
		</div>
	</div>
</section>

<section class="section section--tint" id="how">
	<div class="container">
		<Typography as="h2" variant="heading-h2" class="section-title">Как проходит обучение</Typography>
		<HowSteps {how} />
	</div>
</section>

<section class="section" id="faq">
	<div class="container container--narrow">
		<Typography as="h2" variant="heading-h2" class="section-title">Ответы на вопросы</Typography>
		<AccordionList items={faq.map(([title, text]) => ({ title, text }))} />
		<div class="center cta-row"><Button size="l" label="Оставить заявку" onclick={go(urls.apply)} /></div>
	</div>
</section>
