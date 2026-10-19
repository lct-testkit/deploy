@extends('layouts.app')

@section('title', 'Заявка принята — ИТ-Школа РТК')

@section('content')
<x-island name="thanks" :data="['urls' => $urls]">
<section class="section">
    <div class="container container--narrow center">
        <div class="done" aria-hidden="true">✓</div>
        <h1 class="h1--page">Спасибо, заявка принята</h1>
        <p class="section__lead">Куратор свяжется с вами по указанным контактам в ближайший рабочий день.</p>
        <p><a class="btn" href="{{ route('home') }}">На главную</a></p>
    </div>
</section>
</x-island>
@endsection
