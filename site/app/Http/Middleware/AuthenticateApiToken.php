<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * Bearer-аутентификация API выдачи заявок. Токен берётся из SITE_API_TOKEN; пустой токен не «открывает»
 * API, а закрывает его целиком. Сравнение — по хэшам через hash_equals (время не зависит от длины совпавшего
 * префикса и от длины токена).
 */
class AuthenticateApiToken
{
    public function handle(Request $request, Closure $next): Response
    {
        $expected = (string) config('site.api_token');
        $provided = (string) $request->bearerToken();

        if ($expected === '' || $provided === '' || ! hash_equals(hash('sha256', $expected), hash('sha256', $provided))) {
            return response()
                ->json(['error' => 'unauthorized', 'message' => 'Нужен корректный Bearer-токен.'], 401)
                ->header('WWW-Authenticate', 'Bearer');
        }

        return $next($request);
    }
}
