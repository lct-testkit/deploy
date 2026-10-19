<?php

namespace Database\Seeders;

use App\Models\Lead;
use Illuminate\Database\Seeder;

/**
 * Демо-заявки. Заводятся только в пустую таблицу (и только при SITE_SEED_DEMO=true), поэтому повторный запуск
 * контейнера ничего не дублирует и не воскрешает удалённое. Все данные вымышленные (номера из резервного
 * диапазона 555, почта на example.com).
 */
class LeadSeeder extends Seeder
{
    public function run(): void
    {
        if (Lead::query()->exists()) {
            return;
        }

        $base = now()->subDays(2);
        $leads = [
            ['Анна Сергеевна Орлова', '+7 900 555-01-01', 'orlova@example.com', 'МГТУ им. Баумана', 'py-base', 'Хочу сменить профессию, опыта в программировании нет.', 'yandex-direct-oct'],
            ['Игорь Петрович Назаров', '+7 900 555-02-02', 'nazarov@example.com', 'ООО «Вектор»', 'devops', 'Администрирую серверы, интересует автоматизация выкладки.', 'site'],
            ['Мария Андреевна Кузнецова', '+7 900 555-03-03', 'kuznetsova@example.com', 'НИУ ВШЭ', 'ds-pro', null, 'organic'],
            ['Дмитрий Олегович Волков', '+7 900 555-04-04', 'volkov@example.com', null, 'cyber', 'Нужна программа для группы из пяти сотрудников.', 'site'],
        ];

        foreach ($leads as $i => [$name, $phone, $email, $org, $course, $comment, $campaign]) {
            $at = $base->copy()->addHours($i * 7)->addMinutes($i * 13);
            $lead = new Lead([
                'name' => $name, 'phone' => $phone, 'email' => $email, 'organization' => $org,
                'course' => $course, 'comment' => $comment, 'source_campaign' => $campaign, 'consent_at' => $at,
            ]);
            $lead->created_at = $at;
            $lead->updated_at = $at;
            $lead->save();
        }
    }
}
