<?php
// ==============================================================================
// CLP Helper - CloudPanel vhost helper (used by `clp site -vhost=...`, lib/site.sh)
// File: lib/clp_regen.php
//
// Runs as the clp user with CloudPanel's own PHP (the binary and php.ini named in
// /usr/bin/clpctlWrapper). All reads and writes of CloudPanel's database go through
// CloudPanel's own code, the same way the admin panel does them; root never writes db.sq3.
//
// Usage:
//   clp_regen.php check                 CloudPanel internals this helper needs are present
//   clp_regen.php export                JSON {"sites":[{domain,type,template}],"templates":{name:template}}
//   clp_regen.php set-template <domain> new site vhost template read from stdin
//   clp_regen.php regen <domain>        regenerate the nginx vhost from the site's template
//                                       (CloudPanel's updateNginxVhostWithRollback: writes the vhost,
//                                       runs nginx -t, reloads; restores the old vhost on failure)
//   clp_regen.php set-certificate <domain>
//                                       make the site's self-signed certificate (created with the site)
//                                       the active one, as installing it in the admin panel does:
//                                       CloudPanel no longer renews a Let's Encrypt certificate the site
//                                       stopped using (`clp site -ssl=off`). Prints "ok" or "unchanged".
//
// Exit status: 0 ok, 1 error (message on stderr), 2 usage / site not found,
//              3 the site has no self-signed certificate,
//              4 incompatible CloudPanel version (nothing was written)
// ==============================================================================

const CLP_APP_DIR = '/home/clp/htdocs/app/files';
const CLP_CERT_COMMAND = 'site:install:certificate';

function clp_fail(string $msg, int $code = 1): void
{
    fwrite(STDERR, $msg . PHP_EOL);
    exit($code);
}

function clp_incompatible(string $what): void
{
    clp_fail('incompatible CloudPanel version: ' . $what, 4);
}

$mode = $argv[1] ?? '';
$domain = $argv[2] ?? '';
if (!in_array($mode, ['check', 'export', 'set-template', 'regen', 'set-certificate'], true)) {
    clp_fail('usage: clp_regen.php check|export|set-template <domain>|regen <domain>|set-certificate <domain>', 2);
}
if (in_array($mode, ['set-template', 'regen', 'set-certificate'], true)
    && !preg_match('/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/', $domain)) {
    clp_fail('invalid domain', 2);
}

if (!is_file(CLP_APP_DIR . '/vendor/autoload.php')) {
    clp_incompatible('vendor/autoload.php not found');
}
require CLP_APP_DIR . '/vendor/autoload.php';

foreach (['App\\Kernel', 'App\\Console\\Application', 'App\\Entity\\Site', 'App\\Entity\\VhostTemplate',
          'App\\Site\\Updater', 'Symfony\\Component\\Dotenv\\Dotenv'] as $class) {
    if (!class_exists($class)) {
        clp_incompatible('class ' . $class);
    }
}
foreach ([['App\\Entity\\Site', 'getDomainName'], ['App\\Entity\\Site', 'getType'],
          ['App\\Entity\\Site', 'getVhostTemplate'], ['App\\Entity\\Site', 'setVhostTemplate'],
          ['App\\Entity\\VhostTemplate', 'getName'], ['App\\Entity\\VhostTemplate', 'getTemplate'],
          ['App\\Site\\Updater', 'updateNginxVhostWithRollback']] as [$class, $method]) {
    if (!method_exists($class, $method)) {
        clp_incompatible($class . '::' . $method);
    }
}

// Same environment as bin/clpctl: .env, then ~clp/.env.custom
$dotenv = new Symfony\Component\Dotenv\Dotenv();
$dotenv->bootEnv(CLP_APP_DIR . '/.env');
$home = getenv('HOME') ?: '/home/clp';
if (is_file($home . '/.env.custom')) {
    $dotenv->bootEnv($home . '/.env.custom');
}
$kernel = new App\Kernel($_SERVER['APP_ENV'] ?? 'prod', (bool) ($_SERVER['APP_DEBUG'] ?? false));
$console = new App\Console\Application($kernel);
try {
    $command = $console->find(CLP_CERT_COMMAND);
} catch (Throwable $e) {
    clp_incompatible('command ' . CLP_CERT_COMMAND);
}
foreach (['getSite', 'getSiteUpdater', 'getSiteEntity'] as $method) {
    if (!method_exists($command, $method)) {
        clp_incompatible(CLP_CERT_COMMAND . '::' . $method);
    }
}
$manager = null;
try {
    $prop = new ReflectionProperty($command, 'siteEntityManager');
    $prop->setAccessible(true);
    $manager = $prop->getValue($command);
} catch (Throwable $e) {
    clp_incompatible(CLP_CERT_COMMAND . '::$siteEntityManager');
}
if (!is_object($manager) || !method_exists($manager, 'updateEntity')) {
    clp_incompatible('siteEntityManager::updateEntity');
}

function clp_call(object $obj, string $method, ...$args)
{
    $m = new ReflectionMethod($obj, $method);
    $m->setAccessible(true);
    return $m->invoke($obj, ...$args);
}

if ($mode === 'check') {
    echo "ok\n";
    exit(0);
}

$doctrine = $kernel->getContainer()->get('doctrine');

if ($mode === 'export') {
    $out = ['sites' => [], 'templates' => (object) []];
    foreach ($doctrine->getRepository(App\Entity\Site::class)->findAll() as $site) {
        $out['sites'][] = ['domain' => $site->getDomainName(), 'type' => (string) $site->getType(),
                           'template' => (string) $site->getVhostTemplate()];
    }
    $templates = [];
    foreach ($doctrine->getRepository(App\Entity\VhostTemplate::class)->findAll() as $tpl) {
        $templates[$tpl->getName()] = (string) $tpl->getTemplate();
    }
    $out['templates'] = (object) $templates;
    echo json_encode($out, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE), "\n";
    exit(0);
}

$entity = clp_call($command, 'getSiteEntity', $domain);
if (!$entity) {
    clp_fail('site not found: ' . $domain, 2);
}

if ($mode === 'set-template') {
    $template = stream_get_contents(STDIN);
    if ($template === false || trim($template) === '') {
        clp_fail('empty template', 2);
    }
    $entity->setVhostTemplate($template);
    $manager->updateEntity($entity);
    echo "ok\n";
    exit(0);
}

if ($mode === 'set-certificate') {
    // 只有這個模式用到的 CloudPanel 程式，另外檢查（不相容時不影響 -vhost）
    foreach ([['App\\Entity\\Site', 'getCertificates'], ['App\\Entity\\Site', 'getCertificate'],
              ['App\\Entity\\Site', 'setCertificate'], ['App\\Entity\\Certificate', 'getType'],
              ['App\\Entity\\Certificate', 'getId'], ['App\\Entity\\Certificate', 'getDefaultCertificate'],
              ['App\\Site\\Updater', 'installCertificate']] as [$class, $method]) {
        if (!class_exists($class) || !method_exists($class, $method)) {
            clp_incompatible($class . '::' . $method);
        }
    }
    if (!defined('App\\Entity\\Certificate::TYPE_SELF_SIGNED')) {
        clp_incompatible('App\\Entity\\Certificate::TYPE_SELF_SIGNED');
    }
    $selfSigned = null;
    foreach ($entity->getCertificates() as $cert) {
        if ((string) $cert->getType() !== (string) App\Entity\Certificate::TYPE_SELF_SIGNED) {
            continue;
        }
        if ($selfSigned === null || ($cert->getDefaultCertificate() && !$selfSigned->getDefaultCertificate())) {
            $selfSigned = $cert;
        }
    }
    if ($selfSigned === null) {
        clp_fail('the site has no self-signed certificate', 3);
    }
    $current = $entity->getCertificate();
    if ($current && $current->getId() === $selfSigned->getId()) {
        echo "unchanged\n";
        exit(0);
    }
    try {
        $site = clp_call($command, 'getSite', $domain);
        $updater = clp_call($command, 'getSiteUpdater', $site);
        if (!$updater) {
            clp_fail('no updater for this site type', 2);
        }
        // 與 CloudPanel 續期憑證的順序相同：先寫入檔案並 reload，再更新資料庫
        $updater->installCertificate($selfSigned);
        $entity->setCertificate($selfSigned);
        $manager->updateEntity($entity);
    } catch (Throwable $e) {
        clp_fail('installing the self-signed certificate failed: ' . $e->getMessage());
    }
    echo "ok\n";
    exit(0);
}

// regen
try {
    $site = clp_call($command, 'getSite', $domain);
    $updater = clp_call($command, 'getSiteUpdater', $site);
} catch (Throwable $e) {
    clp_fail('cannot load site: ' . $e->getMessage());
}
if (!$updater) {
    clp_fail('no vhost updater for this site type', 2);
}
try {
    $updater->updateNginxVhostWithRollback();
} catch (Throwable $e) {
    clp_fail('vhost regeneration failed: ' . $e->getMessage());
}
echo "ok\n";
exit(0);
