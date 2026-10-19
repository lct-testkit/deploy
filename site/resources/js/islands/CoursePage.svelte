<script>
	import { Badge, Typography } from '@lct-testkit/rt-ui';
	import Hero from './Hero.svelte';
	import AccordionList from './AccordionList.svelte';
	import HowSteps from './HowSteps.svelte';
	import ApplyForm from './ApplyForm.svelte';

	let { course, courses, urls, how, faq, form } = $props();
</script>

<Hero eyebrow="Стань востребованным специалистом на рынке труда" title={course.headline} text={course.intro}
	ctaLabel="Оставить заявку" ctaHref="#apply" facts={[course.duration, course.format, course.level]} />

<section class="section">
	<div class="container about">
		<div>
			<Typography as="h2" variant="heading-h2" class="section-title">О программе курса</Typography>
			{#each course.about as paragraph (paragraph)}<Typography variant="body-l" class="about__p">{paragraph}</Typography>{/each}
		</div>
		<dl class="facts">
			<div><dt>Объём</dt><dd>{course.duration}</dd></div>
			<div><dt>Формат</dt><dd>{course.format}</dd></div>
			<div><dt>Уровень</dt><dd>{course.level}</dd></div>
		</dl>
	</div>
</section>

<section class="section section--tint">
	<div class="container">
		<Typography as="h2" variant="heading-h2" class="section-title">Чему вы научитесь</Typography>
		<div class="skills">
			{#each course.skills as [title, text, tags] (title)}
				<article class="skill">
					<Typography as="h3" variant="heading-h5">{title}</Typography>
					<Typography variant="body-m" class="muted">{text}</Typography>
					<div class="skill__tags">
						{#each tags as tag (tag)}<Badge variant="secondary" colorScheme="accent" size="s" label={tag} />{/each}
					</div>
				</article>
			{/each}
		</div>
	</div>
</section>

<section class="section">
	<div class="container container--narrow">
		<Typography as="h2" variant="heading-h2" class="section-title">Программа обучения</Typography>
		<AccordionList items={course.program.map(([title, list], i) => ({ title: `Модуль ${i + 1}. ${title}`, list }))} />
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
	</div>
</section>

<section class="section section--tint" id="apply">
	<ApplyForm embedded {courses} {urls} action={form.action} token={form.token} selected={form.selected} old={form.old} errors={form.errors} />
</section>
