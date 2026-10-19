{{-- Фолбэк формы заявки без JS (обычный POST). С JS его заменяет остров ApplyForm.svelte. Нужны $courses и $selected. --}}
@if ($errors->any())
    <div class="alert alert--error" role="alert">
        <b>Заявка не отправлена.</b> Проверьте отмеченные поля.
    </div>
@endif

<form class="form" method="post" action="{{ route('apply.store') }}" novalidate>
    @csrf

    <div class="field @error('name') field--error @enderror">
        <label for="f-name">ФИО <span class="req" aria-hidden="true">*</span></label>
        <input id="f-name" name="name" type="text" value="{{ old('name') }}" autocomplete="name" required maxlength="128">
        @error('name') <p class="field__error">{{ $message }}</p> @enderror
    </div>

    <div class="field-row">
        <div class="field @error('phone') field--error @enderror">
            <label for="phone">Телефон <span class="req" aria-hidden="true">*</span></label>
            <input id="phone" name="phone" type="tel" value="{{ old('phone') }}" autocomplete="tel" placeholder="+7 900 123-45-67" required maxlength="32">
            @error('phone') <p class="field__error">{{ $message }}</p> @enderror
        </div>
        <div class="field @error('email') field--error @enderror">
            <label for="email">E-mail <span class="req" aria-hidden="true">*</span></label>
            <input id="email" name="email" type="email" value="{{ old('email') }}" autocomplete="email" required maxlength="254">
            @error('email') <p class="field__error">{{ $message }}</p> @enderror
        </div>
    </div>

    <div class="field @error('organization') field--error @enderror">
        <label for="organization">Вуз или организация</label>
        <input id="organization" name="organization" type="text" value="{{ old('organization') }}" autocomplete="organization" maxlength="255">
        @error('organization') <p class="field__error">{{ $message }}</p> @enderror
    </div>

    <div class="field @error('course') field--error @enderror">
        <label for="course">Курс <span class="req" aria-hidden="true">*</span></label>
        <select id="course" name="course" required>
            <option value="">Выберите курс</option>
            @foreach ($courses as $course)
                <option value="{{ $course['code'] }}" @selected(old('course', $selected) === $course['code'])>{{ $course['title'] }}</option>
            @endforeach
        </select>
        @error('course') <p class="field__error">{{ $message }}</p> @enderror
    </div>

    <div class="field @error('comment') field--error @enderror">
        <label for="comment">Комментарий</label>
        <textarea id="comment" name="comment" rows="4" maxlength="2000">{{ old('comment') }}</textarea>
        @error('comment') <p class="field__error">{{ $message }}</p> @enderror
    </div>

    {{-- Honeypot: скрыто стилями, для человека и скринридера поля нет. --}}
    <div class="hp" aria-hidden="true">
        <label for="website">Не заполняйте это поле</label>
        <input id="website" name="website" type="text" tabindex="-1" autocomplete="off">
    </div>

    <div class="field field--check @error('consent') field--error @enderror">
        <label class="check">
            <input type="checkbox" name="consent" value="1" @checked(old('consent')) required>
            <span>Я даю согласие на обработку моих персональных данных в соответствии с
                <a href="{{ route('policy') }}" target="_blank" rel="noopener">Политикой обработки персональных данных</a>. <span class="req" aria-hidden="true">*</span></span>
        </label>
        @error('consent') <p class="field__error">{{ $message }}</p> @enderror
    </div>

    <button class="btn" type="submit">Отправить заявку</button>
    <p class="form__hint"><span class="req" aria-hidden="true">*</span> — обязательные поля</p>
</form>
