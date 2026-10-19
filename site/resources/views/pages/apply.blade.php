@extends('layouts.app')

@section('title', 'Заявка на обучение — ИТ-Школа РТК')

@section('content')
<x-island name="apply" :data="[
    'action' => route('apply.store'),
    'token' => csrf_token(),
    'courses' => $courses,
    'selected' => $selected,
    'old' => old(),
    'errors' => collect($errors->messages())->map(fn ($m) => $m[0])->all(),
    'urls' => $urls,
]">
<section class="section">
    <div class="container container--narrow">
        <h1 class="h1--page">Заявка на обучение</h1>
        <p class="section__lead">Оставьте контакты — куратор свяжется с вами в рабочее время и ответит на вопросы о программе.</p>

        @include('partials.apply-form')
    </div>
</section>
</x-island>
@endsection
