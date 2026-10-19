@props(['name', 'data' => []])
{{-- Контейнер Svelte-острова: внутри — SSR-фолбэк (работает без JS), data-props — входные данные компонента. --}}
<div data-island="{{ $name }}" data-props="{{ json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_HEX_TAG) }}">{{ $slot }}</div>
