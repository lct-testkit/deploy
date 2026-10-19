@extends('layouts.app')

@section('title', $course['headline'].' — ИТ-Школа РТК')
@section('description', $course['intro'])

@section('content')
<x-island name="course" :data="[
    'course' => $course,
    'courses' => $courses,
    'urls' => $urls,
    'how' => config('site.how'),
    'faq' => config('site.faq'),
    'form' => [
        'action' => route('apply.store'),
        'token' => csrf_token(),
        'selected' => $selected,
        'old' => old(),
        'errors' => collect($errors->messages())->map(fn ($m) => $m[0])->all(),
    ],
]">
<section class="section">
    <div class="container container--narrow">
        <h1 class="h1--page">{{ $course['headline'] }}</h1>
        <p class="section__lead">{{ $course['intro'] }}</p>

        <h2>О программе курса</h2>
        @foreach ($course['about'] as $paragraph)
            <p>{{ $paragraph }}</p>
        @endforeach

        <h2>Чему вы научитесь</h2>
        <ul>
            @foreach ($course['skills'] as [$title, $text])
                <li><b>{{ $title }}.</b> {{ $text }}</li>
            @endforeach
        </ul>

        <h2>Программа обучения</h2>
        <ol>
            @foreach ($course['program'] as [$title, $topics])
                <li><b>{{ $title }}:</b> {{ implode('; ', $topics) }}</li>
            @endforeach
        </ol>

        <h2 id="apply">Оставить заявку</h2>
        @include('partials.apply-form')
    </div>
</section>
</x-island>
@endsection
