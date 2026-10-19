<?php

namespace Database\Seeders;

use Illuminate\Database\Seeder;

class DatabaseSeeder extends Seeder
{
    public function run(): void
    {
        if (config('site.seed_demo')) {
            $this->call(LeadSeeder::class);
        }
    }
}
