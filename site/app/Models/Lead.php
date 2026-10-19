<?php

namespace App\Models;

use Carbon\CarbonInterface;
use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Model;

class Lead extends Model
{
    use HasUuids;

    /** Формат времени в API: всегда UTC и микросекунды — CRM сравнивает значения как строки. */
    public const API_TIME_FORMAT = 'Y-m-d\TH:i:s.u\Z';

    protected $fillable = [
        'name', 'phone', 'email', 'organization', 'course', 'comment', 'source_campaign', 'consent_at',
    ];

    protected function casts(): array
    {
        return [
            'consent_at' => 'datetime',
            'created_at' => 'datetime',
            'updated_at' => 'datetime',
        ];
    }

    protected $dateFormat = 'Y-m-d H:i:s.u';

    public static function formatApiTime(CarbonInterface $time): string
    {
        return $time->copy()->utc()->format(self::API_TIME_FORMAT);
    }

    /**
     * Лид в форме контракта CRM (повторяет мок mocks/cms): lead_id, name, phone, email, product_interest,
     * source_campaign, submitted_at, updated_at. organization/comment — необязательные добавки.
     *
     * @return array<string, mixed>
     */
    public function toApi(): array
    {
        return [
            'lead_id' => $this->id,
            'name' => $this->name,
            'phone' => $this->phone,
            'email' => $this->email,
            'product_interest' => $this->course,
            'source_campaign' => $this->source_campaign,
            'organization' => $this->organization,
            'comment' => $this->comment,
            'submitted_at' => self::formatApiTime($this->created_at),
            'updated_at' => self::formatApiTime($this->updated_at),
        ];
    }
}
