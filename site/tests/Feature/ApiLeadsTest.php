<?php

namespace Tests\Feature;

use App\Models\Lead;
use Carbon\Carbon;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class ApiLeadsTest extends TestCase
{
    use RefreshDatabase;

    private const TOKEN = 'test-token-0123456789';

    protected function setUp(): void
    {
        parent::setUp();
        config(['site.api_token' => self::TOKEN]);
    }

    private function lead(string $name, string $updatedAt, ?string $id = null): Lead
    {
        $lead = new Lead([
            'name' => $name, 'phone' => '+7 900 555-00-00', 'email' => 'x@example.com',
            'course' => 'py-base', 'consent_at' => now(),
        ]);
        if ($id !== null) {
            $lead->id = $id;
        }
        $lead->created_at = Carbon::parse($updatedAt);
        $lead->updated_at = Carbon::parse($updatedAt);
        $lead->save();

        return $lead;
    }

    private function auth(): array
    {
        return ['Authorization' => 'Bearer '.self::TOKEN];
    }

    public function test_without_token_is_401(): void
    {
        $this->getJson('/api/v1/leads')->assertStatus(401)->assertJsonPath('error', 'unauthorized');
        $this->getJson('/api/v1/leads/'.\Illuminate\Support\Str::uuid()->toString())->assertStatus(401);
    }

    public function test_wrong_token_is_401(): void
    {
        $this->getJson('/api/v1/leads', ['Authorization' => 'Bearer wrong'])->assertStatus(401);
        $this->getJson('/api/v1/leads', ['Authorization' => 'Basic '.self::TOKEN])->assertStatus(401);
    }

    public function test_empty_server_token_closes_api(): void
    {
        config(['site.api_token' => '']);

        $this->getJson('/api/v1/leads', ['Authorization' => 'Bearer '])->assertStatus(401);
        $this->getJson('/api/v1/leads', $this->auth())->assertStatus(401);
    }

    public function test_response_shape_matches_crm_contract(): void
    {
        $this->lead('Мария Кузнецова', '2026-10-01 08:12:00.123456');

        $response = $this->getJson('/api/v1/leads', $this->auth())->assertOk();

        $response->assertJsonPath('next_cursor', null)->assertJsonCount(1, 'items');
        $item = $response->json('items.0');
        foreach (['lead_id', 'name', 'phone', 'email', 'product_interest', 'source_campaign', 'submitted_at', 'updated_at'] as $key) {
            $this->assertArrayHasKey($key, $item);
        }
        $this->assertSame('py-base', $item['product_interest']);
        $this->assertSame('2026-10-01T08:12:00.123456Z', $item['updated_at']);
        $this->assertTrue(\Illuminate\Support\Str::isUuid($item['lead_id']));
    }

    public function test_cursor_pagination_walks_all_pages_in_order_without_duplicates(): void
    {
        // Пять лидов, у трёх из них одинаковый updated_at: порядок внутри обеспечивает id.
        $this->lead('A', '2026-10-01 10:00:00.000001', '00000000-0000-4000-8000-000000000001');
        $this->lead('B', '2026-10-01 10:00:00.000002', '00000000-0000-4000-8000-000000000003');
        $this->lead('C', '2026-10-01 10:00:00.000002', '00000000-0000-4000-8000-000000000002');
        $this->lead('D', '2026-10-01 10:00:00.000002', '00000000-0000-4000-8000-000000000004');
        $this->lead('E', '2026-10-01 10:00:01.000000', '00000000-0000-4000-8000-000000000005');

        $names = [];
        $cursor = null;
        $pages = 0;
        do {
            $query = '?limit=2'.($cursor ? '&cursor='.$cursor : '');
            $json = $this->getJson('/api/v1/leads'.$query, $this->auth())->assertOk()->json();
            $names = array_merge($names, array_column($json['items'], 'name'));
            $cursor = $json['next_cursor'];
            $pages++;
        } while ($cursor !== null && $pages < 10);

        $this->assertSame(3, $pages);
        $this->assertSame(['A', 'C', 'B', 'D', 'E'], $names);
    }

    public function test_exact_page_boundary_has_no_trailing_cursor(): void
    {
        $this->lead('A', '2026-10-01 10:00:00');
        $this->lead('B', '2026-10-01 10:00:01');

        $this->getJson('/api/v1/leads?limit=2', $this->auth())
            ->assertOk()->assertJsonCount(2, 'items')->assertJsonPath('next_cursor', null);
    }

    public function test_updated_since_returns_only_newer_leads(): void
    {
        $this->lead('old', '2026-10-01 10:00:00.000000');
        $this->lead('edge', '2026-10-02 10:00:00.000000');
        $this->lead('new', '2026-10-03 10:00:00.000000');

        $names = fn (string $since) => array_column(
            $this->getJson('/api/v1/leads?updated_since='.urlencode($since), $this->auth())->assertOk()->json('items'),
            'name'
        );

        $this->assertSame(['new'], $names('2026-10-02T10:00:00.000000Z'));
        $this->assertSame(['edge', 'new'], $names('2026-10-01T10:00:00Z'));
        // Часовой пояс учитывается: 13:00+03:00 это 10:00 UTC.
        $this->assertSame(['new'], $names('2026-10-02T13:00:00+03:00'));
        $this->assertSame([], $names('2026-12-01T00:00:00Z'));
    }

    public function test_since_and_cursor_work_together_like_the_crm_does(): void
    {
        foreach (range(1, 5) as $i) {
            $this->lead("L$i", "2026-10-0$i 10:00:00");
        }

        $first = $this->getJson('/api/v1/leads?updated_since=2026-10-01T10:00:00Z&limit=2', $this->auth())->json();
        $this->assertSame(['L2', 'L3'], array_column($first['items'], 'name'));
        $second = $this->getJson('/api/v1/leads?updated_since=2026-10-01T10:00:00Z&limit=2&cursor='.$first['next_cursor'], $this->auth())->json();
        $this->assertSame(['L4', 'L5'], array_column($second['items'], 'name'));
        $this->assertNull($second['next_cursor']);
    }

    public function test_settle_window_hides_fresh_leads(): void
    {
        config(['site.api_settle_seconds' => 60]);
        $this->lead('settled', now()->subMinutes(5)->format('Y-m-d H:i:s.u'));
        $this->lead('fresh', now()->format('Y-m-d H:i:s.u'));

        $this->getJson('/api/v1/leads', $this->auth())->assertOk()->assertJsonCount(1, 'items')->assertJsonPath('items.0.name', 'settled');
    }

    public function test_limit_is_validated_and_capped_at_100(): void
    {
        foreach (['0', '101', 'abc', '-1'] as $limit) {
            $this->getJson('/api/v1/leads?limit='.$limit, $this->auth())->assertStatus(422)->assertJsonValidationErrors('limit');
        }
        $this->getJson('/api/v1/leads?limit=100', $this->auth())->assertOk();
    }

    public function test_default_limit_is_100(): void
    {
        for ($i = 0; $i < 101; $i++) {
            $this->lead("L$i", Carbon::parse('2026-10-01 10:00:00')->addSeconds($i)->format('Y-m-d H:i:s'));
        }

        $json = $this->getJson('/api/v1/leads', $this->auth())->assertOk()->json();
        $this->assertCount(100, $json['items']);
        $this->assertNotNull($json['next_cursor']);
    }

    public function test_bad_updated_since_and_cursor_are_422(): void
    {
        $this->getJson('/api/v1/leads?updated_since=вчера', $this->auth())->assertStatus(422)->assertJsonValidationErrors('updated_since');
        $this->getJson('/api/v1/leads?cursor=not-a-cursor', $this->auth())->assertStatus(422)->assertJsonValidationErrors('cursor');
    }

    public function test_show_returns_lead_or_404(): void
    {
        $lead = $this->lead('Один', '2026-10-01 10:00:00');

        $this->getJson('/api/v1/leads/'.$lead->id, $this->auth())->assertOk()->assertJsonPath('lead_id', $lead->id)->assertJsonPath('name', 'Один');
        $this->getJson('/api/v1/leads/'.\Illuminate\Support\Str::uuid()->toString(), $this->auth())->assertStatus(404);
        $this->getJson('/api/v1/leads/not-a-uuid', $this->auth())->assertStatus(404);
    }
}
