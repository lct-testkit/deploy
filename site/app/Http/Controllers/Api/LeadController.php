<?php

namespace App\Http\Controllers\Api;

use App\Http\Controllers\Controller;
use App\Models\Lead;
use Carbon\Carbon;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;
use Throwable;

/**
 * Контракт для CRM (backend: app/modules/integration/cms_client.py):
 *   GET /api/v1/leads?updated_since=&cursor=&limit=  ->  {"items": [...], "next_cursor": "..."|null}
 *   GET /api/v1/leads/{id}                           ->  лид
 *
 * Порядок выдачи — по возрастанию (updated_at, id). Курсор — непрозрачная строка с позицией последней
 * отданной записи; updated_since — строго «новее» этого момента. Персональные данные в логи не пишутся.
 */
class LeadController extends Controller
{
    public function index(Request $request): JsonResponse
    {
        $max = (int) config('site.api_max_limit');

        $validator = Validator::make($request->query(), [
            'limit' => ['nullable', 'integer', 'min:1', "max:$max"],
            'updated_since' => ['nullable', 'string', 'max:64'],
            'cursor' => ['nullable', 'string', 'max:256'],
        ], [
            'limit.max' => "limit не больше $max.",
        ]);

        $since = null;
        $position = null;
        $validator->after(function ($validator) use ($request, &$since, &$position) {
            if (filled($request->query('updated_since'))) {
                $since = $this->parseTime((string) $request->query('updated_since'));
                if ($since === null) {
                    $validator->errors()->add('updated_since', 'updated_since: ожидается дата-время ISO 8601.');
                }
            }
            if (filled($request->query('cursor'))) {
                $position = $this->decodeCursor((string) $request->query('cursor'));
                if ($position === null) {
                    $validator->errors()->add('cursor', 'cursor: некорректное значение.');
                }
            }
        });

        if ($validator->fails()) {
            return response()->json(['error' => 'validation_failed', 'errors' => $validator->errors()], 422);
        }

        $limit = (int) ($request->query('limit') ?: $max);

        $query = Lead::query()->orderBy('updated_at')->orderBy('id');
        $this->applySettleWindow($query);
        if ($since !== null) {
            $query->where('updated_at', '>', $since->format('Y-m-d H:i:s.u'));
        }
        if ($position !== null) {
            $query->whereRaw('(updated_at, id) > (?, ?)', [$position['updated_at'], $position['id']]);
        }

        $rows = $query->limit($limit + 1)->get();
        $hasMore = $rows->count() > $limit;
        $page = $rows->take($limit);

        $next = null;
        if ($hasMore) {
            $last = $page->last();
            $next = $this->encodeCursor($last);
        }

        return response()->json([
            'items' => $page->map(fn (Lead $lead) => $lead->toApi())->values(),
            'next_cursor' => $next,
        ]);
    }

    public function show(string $id): JsonResponse
    {
        if (! Str::isUuid($id)) {
            return $this->notFound();
        }

        $query = Lead::query()->whereKey($id);
        $this->applySettleWindow($query);
        $lead = $query->first();

        return $lead ? response()->json($lead->toApi()) : $this->notFound();
    }

    private function notFound(): JsonResponse
    {
        return response()->json(['error' => 'not_found', 'message' => 'Лид не найден.'], 404);
    }

    private function applySettleWindow($query): void
    {
        $settle = (int) config('site.api_settle_seconds');
        if ($settle > 0) {
            $query->where('updated_at', '<=', Carbon::now('UTC')->subSeconds($settle)->format('Y-m-d H:i:s.u'));
        }
    }

    private function parseTime(string $value): ?Carbon
    {
        try {
            return Carbon::parse($value)->utc();
        } catch (Throwable) {
            return null;
        }
    }

    private function encodeCursor(Lead $lead): string
    {
        $raw = $lead->updated_at->copy()->utc()->format('Y-m-d H:i:s.u').'|'.$lead->id;

        return rtrim(strtr(base64_encode($raw), '+/', '-_'), '=');
    }

    /** @return array{updated_at: string, id: string}|null */
    private function decodeCursor(string $cursor): ?array
    {
        $raw = base64_decode(strtr($cursor, '-_', '+/'), true);
        if ($raw === false || substr_count($raw, '|') !== 1) {
            return null;
        }
        [$time, $id] = explode('|', $raw);
        if (! preg_match('/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{6}$/', $time) || ! Str::isUuid($id)) {
            return null;
        }

        return ['updated_at' => $time, 'id' => $id];
    }
}
