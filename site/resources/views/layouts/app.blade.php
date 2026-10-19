<!doctype html>
<html lang="ru">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="color-scheme" content="light">
    <title>@yield('title', 'ИТ-Школа РТК')</title>
    <meta name="description" content="@yield('description', 'ИТ-Школа РТК: практические курсы по программированию, анализу данных, кибербезопасности и DevOps.')">
    <link rel="icon" href="{{ asset('favicon.svg') }}" type="image/svg+xml">
    <script src="{{ asset('js-flag.js') }}"></script>
    {{-- Дизайн-система rt-ui, тема и Svelte-острова (сборка Vite). --}}
    @vite(['resources/js/app.js'])
    {{-- Без JS стилей rt-ui нет: показывается простая вёрстка фолбэка. --}}
    <noscript><link rel="stylesheet" href="{{ asset('css/fallback.css') }}"></noscript>
</head>
<body class="Theme_root_rtk_default_light rt-base">
<header class="site-header">
    <x-island name="header" :data="['urls' => $urls, 'loginUrl' => config('site.login_url')]">
        <div class="header">
            <div class="container header__inner">
                <a class="brand" href="{{ route('home') }}">ИТ школа <b>РТК</b></a>
                <nav class="nav" aria-label="Основное меню">
                    <a href="{{ route('home') }}#courses">Курсы</a>
                    <a href="{{ route('home') }}#how">Как проходит обучение</a>
                    <a href="#contacts">Контакты</a>
                    <a class="btn btn--small" href="{{ route('apply') }}">Подать заявку</a>
                </nav>
            </div>
        </div>
    </x-island>
</header>

<main>
    @yield('content')
</main>

<footer class="site-footer" id="contacts">
    <x-island name="footer" :data="['contact' => config('site.contact'), 'urls' => $urls, 'year' => (int) date('Y')]">
        <div class="footer footer__inner container">
            <div>
                <div class="footer__title">Контакты</div>
                <p>
                    <a href="mailto:{{ config('site.contact.email') }}">{{ config('site.contact.email') }}</a><br>
                    {{ config('site.contact.phone') }}<br>
                    {{ config('site.contact.address') }}
                </p>
            </div>
            <div>
                <div class="footer__title">Документы</div>
                <p><a href="{{ route('policy') }}">Политика обработки персональных данных</a></p>
            </div>
            <div class="footer__note">© {{ date('Y') }} При поддержке Ростелеком ИТ школа</div>
        </div>
    </x-island>
</footer>
</body>
</html>
