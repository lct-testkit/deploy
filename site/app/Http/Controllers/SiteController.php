<?php

namespace App\Http\Controllers;

use App\Http\Requests\ApplyRequest;
use App\Models\Lead;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\View\View;

class SiteController extends Controller
{
    public function home(Request $request): View
    {
        $this->rememberCampaign($request);

        return view('pages.home', ['courses' => $this->courses()]);
    }

    public function course(Request $request, string $slug): View
    {
        $this->rememberCampaign($request);

        $course = collect($this->courses())->firstWhere('slug', $slug);
        abort_if($course === null, 404);

        return view('pages.course', [
            'course' => $course,
            'courses' => $this->courses(),
            'selected' => $course['code'],
        ]);
    }

    public function apply(Request $request): View
    {
        $this->rememberCampaign($request);
        $courses = $this->courses();
        $selected = $request->query('course');
        if (! in_array($selected, array_column($courses, 'code'), true)) {
            $selected = null;
        }

        return view('pages.apply', ['courses' => $courses, 'selected' => $selected]);
    }

    public function store(ApplyRequest $request): RedirectResponse
    {
        // Honeypot: бот заполнил скрытое поле. Отвечаем так же, как на успех, но ничего не сохраняем.
        if (filled($request->input('website'))) {
            return redirect()->route('thanks');
        }

        // UTM-метка кампании приходит со ссылки на сайт и запоминается в сессии, поэтому в форме её нет.
        $campaign = $request->session()->get('utm_campaign');

        Lead::create([
            'name' => $request->validated('name'),
            'phone' => $request->validated('phone'),
            'email' => mb_strtolower($request->validated('email')),
            'organization' => $request->validated('organization'),
            'course' => $request->validated('course'),
            'comment' => $request->validated('comment'),
            'source_campaign' => is_string($campaign) && $campaign !== '' ? mb_substr($campaign, 0, 128) : 'site',
            'consent_at' => now(),
        ]);

        return redirect()->route('thanks');
    }

    public function thanks(): View
    {
        return view('pages.thanks');
    }

    public function policy(): View
    {
        return view('pages.policy');
    }

    /** Курсы из config/courses.php с адресом страницы курса. */
    private function courses(): array
    {
        return array_map(
            fn (array $course) => $course + ['url' => route('course', $course['slug'])],
            config('courses')
        );
    }

    private function rememberCampaign(Request $request): void
    {
        $campaign = $request->query('utm_campaign');
        if (is_string($campaign) && preg_match('/^[\w\-.]{1,128}$/', $campaign)) {
            $request->session()->put('utm_campaign', $campaign);
        }
    }
}
