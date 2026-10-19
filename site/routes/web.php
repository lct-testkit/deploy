<?php

use App\Http\Controllers\SiteController;
use Illuminate\Support\Facades\Route;

Route::get('/', [SiteController::class, 'home'])->name('home');
Route::get('/course/{slug}', [SiteController::class, 'course'])->name('course');
Route::get('/apply', [SiteController::class, 'apply'])->name('apply');
// Защита от спама: honeypot (см. SiteController::store) + лимит отправок с одного адреса.
Route::post('/apply', [SiteController::class, 'store'])
    ->middleware('throttle:5,1')
    ->name('apply.store');
Route::get('/thanks', [SiteController::class, 'thanks'])->name('thanks');
Route::get('/policy', [SiteController::class, 'policy'])->name('policy');
