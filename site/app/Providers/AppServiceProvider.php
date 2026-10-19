<?php

namespace App\Providers;

use Illuminate\Support\Facades\View;
use Illuminate\Support\ServiceProvider;

class AppServiceProvider extends ServiceProvider
{
    /**
     * Register any application services.
     */
    public function register(): void
    {
        //
    }

    /**
     * Bootstrap any application services.
     */
    public function boot(): void
    {
        // Адреса страниц для Svelte-островов: route() учитывает префикс /site из X-Forwarded-Prefix.
        View::composer('*', fn ($view) => $view->with('urls', [
            'home' => route('home'),
            'apply' => route('apply'),
            'policy' => route('policy'),
        ]));
    }
}
