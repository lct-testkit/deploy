<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('leads', function (Blueprint $table) {
            $table->uuid('id')->primary();
            $table->string('name', 128);
            $table->string('phone', 32);
            $table->string('email', 254);
            $table->string('organization', 255)->nullable();
            $table->string('course', 64);
            $table->text('comment')->nullable();
            $table->string('source_campaign', 128)->default('site');
            $table->timestamp('consent_at', 6);
            // Микросекунды: по (updated_at, id) CRM листает выдачу курсором, секундной точности для порядка мало.
            $table->timestamps(6);

            $table->index(['updated_at', 'id']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('leads');
    }
};
