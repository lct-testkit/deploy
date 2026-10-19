<?php

namespace App\Console\Commands;

use Illuminate\Console\Command;
use PDO;

/**
 * Создаёт роль и базу сайта в PostgreSQL, если их ещё нет. Нужна, потому что init-скрипты postgres выполняются
 * только на пустом кластере, а в HA (Patroni) кластер живёт отдельно и уже существует. Вызывается из entrypoint,
 * когда заданы SITE_DB_ADMIN_USER/SITE_DB_ADMIN_PASSWORD (учётка с правом CREATEROLE/CREATEDB); идемпотентна.
 */
class BootstrapDatabase extends Command
{
    protected $signature = 'site:bootstrap-db';

    protected $description = 'Создать роль и базу сайта, если их нет (нужны учётные данные администратора PostgreSQL)';

    public function handle(): int
    {
        $admin = (string) config('site.db_admin.user');
        if ($admin === '') {
            $this->line('SITE_DB_ADMIN_USER не задан — создание БД пропущено.');

            return self::SUCCESS;
        }

        $cfg = config('database.connections.pgsql');
        $dsn = sprintf('pgsql:host=%s;port=%s;dbname=%s', $cfg['host'], $cfg['port'], config('site.db_admin.database'));
        $pdo = new PDO($dsn, $admin, (string) config('site.db_admin.password'), [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);

        $role = $cfg['username'];
        $db = $cfg['database'];
        $quote = fn (string $ident) => '"'.str_replace('"', '""', $ident).'"';

        $exists = $pdo->prepare('SELECT 1 FROM pg_roles WHERE rolname = ?');
        $exists->execute([$role]);
        $password = $pdo->quote((string) $cfg['password']);
        if ($exists->fetchColumn()) {
            $pdo->exec(sprintf('ALTER ROLE %s WITH LOGIN PASSWORD %s', $quote($role), $password));
        } else {
            $pdo->exec(sprintf('CREATE ROLE %s WITH LOGIN PASSWORD %s', $quote($role), $password));
            $this->line("роль {$role} создана");
        }

        $exists = $pdo->prepare('SELECT 1 FROM pg_database WHERE datname = ?');
        $exists->execute([$db]);
        if (! $exists->fetchColumn()) {
            $pdo->exec(sprintf('CREATE DATABASE %s OWNER %s', $quote($db), $quote($role)));
            $this->line("база {$db} создана");
        }

        $this->info('база сайта готова');

        return self::SUCCESS;
    }
}
