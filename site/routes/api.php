<?php

use App\Http\Controllers\Api\LeadController;
use Illuminate\Support\Facades\Route;

// Префикс /api задаёт сам Laravel. Лимит на IP — в том числе против перебора токена.
Route::prefix('v1')->middleware(['throttle:120,1', 'api.token'])->group(function () {
    Route::get('leads', [LeadController::class, 'index']);
    Route::get('leads/{id}', [LeadController::class, 'show']);
});
