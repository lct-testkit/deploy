<?php

namespace Tests\Feature;

use App\Models\Lead;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Log;
use Tests\TestCase;

class ApplyFormTest extends TestCase
{
    use RefreshDatabase;

    /** @return array<string, mixed> */
    private function valid(array $override = []): array
    {
        return array_merge([
            'name' => 'Анна Сергеевна Орлова',
            'phone' => '+7 900 555-01-01',
            'email' => 'Orlova@Example.com',
            'organization' => 'МГТУ им. Баумана',
            'course' => 'py-base',
            'comment' => 'Хочу на ближайший поток',
            'consent' => '1',
        ], $override);
    }

    public function test_pages_render(): void
    {
        $this->get('/')->assertOk()->assertSee('ИТ-Школа РТК')->assertSee('Python-разработчик');
        $this->get('/apply')->assertOk()->assertSee('name="consent"', false)->assertSee('/policy', false);
        $this->get('/policy')->assertOk()->assertSee('152-ФЗ');
        $this->get('/thanks')->assertOk();
    }

    public function test_form_carries_csrf_token(): void
    {
        $this->get('/apply')->assertOk()->assertSee('name="_token"', false);
    }

    public function test_csrf_is_enforced_outside_tests(): void
    {
        // В тестах проверка CSRF отключена фреймворком; включаем её обратно и шлём POST без токена.
        $this->app['env'] = 'production';
        $this->withMiddleware();
        $this->post('/apply', $this->valid())->assertStatus(419);
        $this->assertDatabaseCount('leads', 0);
    }

    public function test_valid_application_is_saved(): void
    {
        $this->post('/apply', $this->valid())->assertRedirect('/thanks');

        $this->assertDatabaseCount('leads', 1);
        $lead = Lead::first();
        $this->assertSame('Анна Сергеевна Орлова', $lead->name);
        $this->assertSame('orlova@example.com', $lead->email);
        $this->assertSame('py-base', $lead->course);
        $this->assertSame('site', $lead->source_campaign);
        $this->assertNotNull($lead->consent_at);
    }

    public function test_utm_campaign_is_remembered(): void
    {
        $this->get('/?utm_campaign=yandex-direct-oct')->assertOk();
        $this->post('/apply', $this->valid());

        $this->assertSame('yandex-direct-oct', Lead::first()->source_campaign);
    }

    public function test_consent_is_required(): void
    {
        $data = $this->valid();
        unset($data['consent']);

        $this->from('/apply')->post('/apply', $data)->assertRedirect('/apply#apply')->assertSessionHasErrors('consent');
        $this->assertDatabaseCount('leads', 0);
    }

    public function test_required_fields_and_formats(): void
    {
        // Здесь много отправок подряд — лимит (5/мин) проверяется отдельным тестом.
        $this->withoutMiddleware(\Illuminate\Routing\Middleware\ThrottleRequests::class);
        $this->post('/apply', [])->assertSessionHasErrors(['name', 'phone', 'email', 'course', 'consent']);
        $this->post('/apply', $this->valid(['phone' => 'abc']))->assertSessionHasErrors('phone');
        $this->post('/apply', $this->valid(['email' => 'не-почта']))->assertSessionHasErrors('email');
        $this->post('/apply', $this->valid(['course' => 'unknown']))->assertSessionHasErrors('course');
        $this->post('/apply', $this->valid(['name' => 'Аня']))->assertSessionHasErrors('name');
        $this->post('/apply', $this->valid(['name' => '<script>alert(1)</script>']))->assertSessionHasErrors('name');
        $this->post('/apply', $this->valid(['comment' => str_repeat('я', 2001)]))->assertSessionHasErrors('comment');
        $this->assertDatabaseCount('leads', 0);
    }

    public function test_error_messages_are_in_russian(): void
    {
        $this->from('/apply')->post('/apply', [])->assertRedirect('/apply#apply');
        $this->followingRedirects()->from('/apply')->post('/apply', [])->assertSee('Заполните поле «ФИО».', false);
    }

    public function test_honeypot_discards_bot_submissions_silently(): void
    {
        $this->post('/apply', $this->valid(['website' => 'http://spam.example']))->assertRedirect('/thanks');

        $this->assertDatabaseCount('leads', 0);
    }

    public function test_throttle_limits_submissions_per_ip(): void
    {
        for ($i = 0; $i < 5; $i++) {
            $this->post('/apply', $this->valid())->assertRedirect('/thanks');
        }
        $this->post('/apply', $this->valid())->assertStatus(429);
        $this->assertDatabaseCount('leads', 5);
    }

    public function test_personal_data_is_not_logged(): void
    {
        Log::spy();
        $this->post('/apply', $this->valid());
        $this->post('/apply', $this->valid(['phone' => 'bad']));

        Log::shouldNotHaveReceived('info');
        Log::shouldNotHaveReceived('warning');
    }

    // Три отдельных теста: тестовый клиент Laravel кэширует корневой URL приложения между запросами одного теста,
    // поэтому второй запрос с префиксом внутри одного теста превращался бы в /site/site (артефакт тестов, не приложения).
    private const PROXY = ['X-Forwarded-Prefix' => '/site', 'X-Forwarded-Proto' => 'https', 'X-Forwarded-Host' => 'crm.example.com'];

    public function test_apply_page_links_and_form_under_a_path_prefix(): void
    {
        $apply = $this->get('/apply', self::PROXY)->assertOk();
        $apply->assertSee('action="https://crm.example.com/site/apply"', false);
        $apply->assertSee('href="https://crm.example.com/site/policy"', false);
        $apply->assertSee('https://crm.example.com/site/css/fallback.css', false);
        // Адреса для Svelte-островов (JSON в data-props) тоже с префиксом.
        $apply->assertSee('&quot;apply&quot;:&quot;https://crm.example.com/site/apply&quot;', false);
    }

    public function test_home_links_under_a_path_prefix(): void
    {
        $this->get('/', self::PROXY)->assertSee('href="https://crm.example.com/site/course/python-developer"', false);
    }

    public function test_redirect_after_submit_keeps_the_prefix(): void
    {
        $this->post('/apply', $this->valid(), self::PROXY)->assertRedirect('https://crm.example.com/site/thanks');
    }

    public function test_apply_page_mounts_the_svelte_island_with_server_state(): void
    {
        $response = $this->get('/apply?course=devops')->assertOk();
        $response->assertSee('data-island="apply"', false);
        $response->assertSee('&quot;selected&quot;:&quot;devops&quot;', false);
    }

    public function test_course_pages_render_for_every_catalog_course_and_unknown_is_404(): void
    {
        foreach (config('courses') as $course) {
            $this->get('/course/'.$course['slug'])->assertOk()->assertSee($course['headline'])->assertSee('data-island="course"', false);
        }
        $this->get('/course/nope')->assertNotFound();
    }

    public function test_every_catalog_course_code_is_accepted_by_the_form(): void
    {
        $this->withoutMiddleware(\Illuminate\Routing\Middleware\ThrottleRequests::class);
        foreach (config('courses') as $course) {
            $this->post('/apply', $this->valid(['course' => $course['code']]))->assertRedirect('/thanks');
        }
        $this->assertDatabaseCount('leads', count(config('courses')));
    }
}
