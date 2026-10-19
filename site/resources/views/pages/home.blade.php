@extends('layouts.app')

@section('content')
<x-island name="catalog" :data="['courses' => $courses, 'urls' => $urls, 'how' => config('site.how'), 'faq' => config('site.faq')]">
<section class="section">
    <div class="container">
        <h1>ИТ-Школа РТК</h1>
        <p class="section__lead">Практические курсы по программированию, анализу данных, кибербезопасности и DevOps.</p>
        <div class="cards">
            @foreach ($courses as $course)
                <article class="card">
                    <h3>{{ $course['title'] }}</h3>
                    <p>{{ $course['lead'] }}</p>
                    <p class="card__format">{{ $course['duration'] }} · {{ $course['format'] }}</p>
                    <a class="btn btn--small" href="{{ $course['url'] }}">О курсе</a>
                </article>
            @endforeach
        </div>
    </div>
</section>
</x-island>
@endsection
