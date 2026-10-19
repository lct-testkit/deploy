<script>
	// Форма заявки на rt-ui. Это обычная <form method="post">: поля rt-ui рендерят нативные <input name=…>, отправка —
	// обычный POST (без fetch), валидацию и ответ даёт сервер; ошибки и введённые значения возвращаются в props.
	// Без JS страница показывает Blade-версию той же формы.
	import { Button, Checkbox, InlineNotification, Input, Select, TextArea, Typography } from '@lct-testkit/rt-ui';

	let { action, token, courses, selected, old, errors, urls, embedded = false } = $props();

	let name = $state(old.name ?? '');
	let phone = $state(old.phone ?? '');
	let email = $state(old.email ?? '');
	let organization = $state(old.organization ?? '');
	let course = $state(old.course ?? selected ?? '');
	let comment = $state(old.comment ?? '');
	let consent = $state(Boolean(old.consent));

	const items = courses.map((c) => ({ key: c.code, value: c.title }));
	const hasErrors = $derived(Object.keys(errors).length > 0);
	const text = (e) => e.target.value;
</script>

<div class={["container container--narrow stack", embedded && "stack--embedded"]}>
	{#if embedded}
		<Typography as="h2" variant="heading-h2" class="section-title">Оставить заявку</Typography>
	{:else}
		<Typography as="h1" variant="heading-h2" class="section-title">Заявка на обучение</Typography>
	{/if}
	<Typography variant="body-l" class="muted">Оставьте контакты — куратор свяжется с вами в рабочее время и ответит на вопросы о программе.</Typography>

	{#if hasErrors}
		<InlineNotification colorScheme="error" title="Заявка не отправлена" subtitle="Проверьте отмеченные поля." role="alert" />
	{/if}

	<form class="form" method="post" {action} novalidate>
		<input type="hidden" name="_token" value={token} />

		<Input name="name" label="ФИО *" value={name} onChange={(e) => (name = text(e))} error={errors.name} autocomplete="name" maxlength={128} />
		<div class="field-row">
			<Input name="phone" type="tel" label="Телефон *" value={phone} onChange={(e) => (phone = text(e))} error={errors.phone} autocomplete="tel" placeholder="+7 900 123-45-67" maxlength={32} />
			<Input name="email" type="email" label="E-mail *" value={email} onChange={(e) => (email = text(e))} error={errors.email} autocomplete="email" maxlength={254} />
		</div>
		<Input name="organization" label="Вуз или организация" value={organization} onChange={(e) => (organization = text(e))} error={errors.organization} autocomplete="organization" maxlength={255} />

		<Select label="Курс *" {items} value={course} deselectEnabled={false} autocomplete={{ enabled: false }} error={errors.course} onChange={(key) => (course = String(key ?? ''))} />
		<input type="hidden" name="course" value={course} />

		<TextArea name="comment" label="Комментарий" value={comment} onChange={(e) => (comment = text(e))} error={errors.comment} maxlength={2000} />

		<!-- Honeypot: человеку не виден, бот заполняет — сервер молча отбрасывает заявку -->
		<div class="hp" aria-hidden="true"><input type="text" name="website" tabindex="-1" autocomplete="off" /></div>

		<div class="consent">
			<Checkbox name="consent" value="1" checked={consent} onChange={(v) => (consent = v)}
				label="Я даю согласие на обработку персональных данных *" />
			<Typography variant="body-s" class="muted">
				Подробнее — в <a href={urls.policy} target="_blank" rel="noopener">Политике обработки персональных данных</a>.
			</Typography>
			{#if errors.consent}<Typography variant="body-s" class="field-error">{errors.consent}</Typography>{/if}
		</div>

		<div class="form__submit">
			<Button type="submit" size="l" label="Отправить заявку" />
			<Typography variant="body-s" class="muted">* — обязательные поля</Typography>
		</div>
	</form>
</div>
