<script>
	// Главный экран на фиолетовом фоне с оранжевой диагональной формой. Фиолетовый даёт тема rtk_purple (accent), кнопка внутри —
	// в теме rtk_default (accent оранжевый): обе темы — стандартные классы ДС, токены не переопределяются.
	import { Badge, Button, Typography } from '@lct-testkit/rt-ui';

	let { eyebrow, title, text, ctaLabel, ctaHref, facts = [] } = $props();

	function jump() {
		const target = document.getElementById(ctaHref.replace(/^.*#/, ''));
		if (target) target.scrollIntoView({ behavior: 'smooth' });
		else location.hash = ctaHref;
	}
</script>

<section class="hero Theme_root_rtk_purple_light">
	<div class="hero__shape Theme_root_rtk_default_light" aria-hidden="true"></div>
	<div class="container hero__inner">
		<div class="hero__text">
			<Typography variant="body-l" class="hero__eyebrow">{eyebrow}</Typography>
			<Typography as="h1" variant="heading-h1" class="hero__title">{title}</Typography>
			<Typography variant="body-l" class="hero__lead">{text}</Typography>
			<div class="Theme_root_rtk_default_light hero__cta">
				<Button size="l" label={ctaLabel} onclick={jump} />
			</div>
		</div>
		<div class="hero__art" aria-hidden="true">
			<div class="codewin">
				<div class="codewin__bar"><i></i><i></i><i></i></div>
				<div class="codewin__body">
					{#each [60, 85, 40, 72, 55, 90, 35, 66] as w, i (i)}<span class="codewin__line" style={`width:${w}%`}></span>{/each}
				</div>
			</div>
			<div class="chips">
				{#each facts as f (f)}<Badge variant="primary" colorScheme="neutral" size="m" label={f} />{/each}
			</div>
		</div>
	</div>
</section>
