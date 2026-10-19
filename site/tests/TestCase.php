<?php

namespace Tests;

use Illuminate\Foundation\Testing\TestCase as BaseTestCase;

abstract class TestCase extends BaseTestCase
{
    protected function setUp(): void
    {
        parent::setUp();
        // Сборка Vite (public/build) в тестах не нужна: страницы проверяются по HTML-фолбэку.
        $this->withoutVite();
    }
}
