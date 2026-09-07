<?php
/**
 * Local Projects Dashboard – file-based API
 * Main config is stored in ~/Sites/local-projects-dashboard.json (or path set in data/config-path.json).
 * Config shape: { "sitesDir": "...", "localTld": ".ldev", "projects": [...] }
 */

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

$appDir = __DIR__;
$bootstrapFile = $appDir . '/data/config-path.json';

function getDefaultConfigPath(): string {
  $home = getenv('HOME') ?: ($_SERVER['HOME'] ?? '');
  if ($home === '') {
    return '';
  }
  return rtrim($home, '/') . '/Sites/local-projects-dashboard.json';
}

function readConfigPath(string $bootstrapFile): string {
  $default = getDefaultConfigPath();
  if (!is_file($bootstrapFile)) {
    $dir = dirname($bootstrapFile);
    if (!is_dir($dir)) {
      @mkdir($dir, 0755, true);
    }
    if ($default !== '' && is_dir($dir)) {
      @file_put_contents($bootstrapFile, json_encode(['configPath' => $default], JSON_PRETTY_PRINT));
    }
    return $default;
  }
  $raw = @file_get_contents($bootstrapFile);
  if ($raw === false || $raw === '') {
    return $default;
  }
  $decoded = json_decode($raw, true);
  $path = is_array($decoded) ? trim((string) ($decoded['configPath'] ?? '')) : '';
  return $path !== '' ? $path : $default;
}

function readConfig(string $path): array {
  if ($path === '' || !is_file($path)) {
    $home = getenv('HOME') ?: ($_SERVER['HOME'] ?? '');
    $sitesDir = $home !== '' ? rtrim($home, '/') . '/Sites' : '';
    return [
      'sitesDir' => $sitesDir,
      'localTld' => '.ldev',
      'projects' => [],
    ];
  }
  $raw = file_get_contents($path);
  if ($raw === false || $raw === '') {
    return ['sitesDir' => dirname($path), 'localTld' => '.ldev', 'projects' => []];
  }
  $decoded = json_decode($raw, true);
  if (!is_array($decoded)) {
    return ['sitesDir' => dirname($path), 'localTld' => '.ldev', 'projects' => []];
  }
  $home = getenv('HOME') ?: ($_SERVER['HOME'] ?? '');
  $defaultSites = $home !== '' ? rtrim($home, '/') . '/Sites' : '';
  return [
    'sitesDir' => trim((string) ($decoded['sitesDir'] ?? $defaultSites)),
    'localTld' => trim((string) ($decoded['localTld'] ?? '.ldev')) ?: '.ldev',
    'projects' => is_array($decoded['projects'] ?? null) ? $decoded['projects'] : [],
  ];
}

function writeConfig(string $path, array $config): bool {
  $dir = dirname($path);
  if (!is_dir($dir)) {
    if (!@mkdir($dir, 0755, true)) {
      return false;
    }
  }
  $json = json_encode([
    'sitesDir' => $config['sitesDir'],
    'localTld' => $config['localTld'],
    'projects' => $config['projects'],
  ], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
  return file_put_contents($path, $json) !== false;
}

function writeBootstrapConfigPath(string $bootstrapFile, string $configPath): void {
  $dir = dirname($bootstrapFile);
  if (!is_dir($dir)) {
    @mkdir($dir, 0755, true);
  }
  @file_put_contents($bootstrapFile, json_encode(['configPath' => $configPath], JSON_PRETTY_PRINT));
}

/**
 * Try to get WordPress home/site URL from wp-config.php (WP_HOME or WP_SITEURL).
 * Returns [ 'url' => string, 'hostname' => string, 'port' => string, 'ssl' => bool ] or null.
 */
function getWordPressUrlFromConfig(string $wpPath): ?array {
  $configFile = $wpPath . DIRECTORY_SEPARATOR . 'wp-config.php';
  if (!is_file($configFile)) {
    return null;
  }
  $raw = @file_get_contents($configFile);
  if ($raw === false) {
    return null;
  }
  $url = null;
  if (preg_match("/define\s*\(\s*['\"]WP_HOME['\"]\s*,\s*['\"]([^'\"]+)['\"]\s*\)/", $raw, $m)) {
    $url = trim($m[1]);
  }
  if (($url === null || $url === '') && preg_match("/define\s*\(\s*['\"]WP_SITEURL['\"]\s*,\s*['\"]([^'\"]+)['\"]\s*\)/", $raw, $m)) {
    $url = trim($m[1]);
  }
  if ($url === null || $url === '') {
    return null;
  }
  $parsed = parse_url($url);
  if (!is_array($parsed) || empty($parsed['host'])) {
    return null;
  }
  $hostname = $parsed['host'];
  $port = isset($parsed['port']) ? (string) $parsed['port'] : '';
  $scheme = isset($parsed['scheme']) ? strtolower($parsed['scheme']) : 'https';
  $ssl = ($scheme === 'https');
  $builtUrl = $scheme . '://' . $hostname . ($port !== '' ? ':' . $port : '');
  return [
    'url' => $builtUrl,
    'hostname' => $hostname,
    'port' => $port,
    'ssl' => $ssl,
  ];
}

/**
 * Build a valid hostname from a directory name and local TLD.
 * - If the directory already ends with the TLD (e.g. seasonal-drops.ldev), use it as-is to avoid double .ldev.
 * - Otherwise normalize for valid hostnames: lowercase, spaces to hyphens, strip invalid characters.
 */
function dirToHostname(string $entry, string $localTld): string {
  $tldLen = strlen($localTld);
  if ($tldLen > 0 && strcasecmp(substr($entry, -$tldLen), $localTld) === 0) {
    return $entry;
  }
  $normalized = strtolower($entry);
  $normalized = preg_replace('/\s+/', '-', $normalized);
  $normalized = preg_replace('/[^a-z0-9.-]+/', '-', $normalized);
  $normalized = trim(preg_replace('/-+/', '-', $normalized), '-');
  return $normalized !== '' ? $normalized . $localTld : $entry . $localTld;
}

/**
 * Scan sitesDir for subdirectories and detect platform / port / SSL.
 * For WordPress, tries to use WP_HOME/WP_SITEURL from wp-config.php when present.
 * Returns array of { name, hostname, url, platform, port, ssl } for each detected site.
 */
function detectSuggestions(string $sitesDir, string $localTld, array $existingProjects): array {
  $suggestions = [];
  if ($sitesDir === '' || !is_dir($sitesDir)) {
    return $suggestions;
  }
  $existingUrls = array_column($existingProjects, 'url');
  $existingHostnames = array_filter(array_map(function ($p) {
    $host = parse_url($p['url'] ?? '', PHP_URL_HOST);
    return is_string($host) ? $host : '';
  }, $existingProjects));

  $entries = @scandir($sitesDir);
  if ($entries === false) {
    return $suggestions;
  }

  foreach ($entries as $entry) {
    if ($entry === '.' || $entry === '..' || $entry[0] === '.') {
      continue;
    }
    $path = $sitesDir . DIRECTORY_SEPARATOR . $entry;
    if (!is_dir($path)) {
      continue;
    }

    $hostname = dirToHostname($entry, $localTld);
    $name = preg_replace('/[.-]/', ' ', $entry);
    $name = ucwords(strtolower($name));

    $platform = 'Other';
    $port = '';
    $ssl = false;

    if (is_dir($path . DIRECTORY_SEPARATOR . 'wp-content')) {
      $platform = 'WordPress';
      $wpUrl = getWordPressUrlFromConfig($path);
      if ($wpUrl !== null) {
        $url = $wpUrl['url'];
        $hostname = $wpUrl['hostname'];
        $port = $wpUrl['port'];
        $ssl = $wpUrl['ssl'];
      } else {
        $port = '8443';
        $ssl = true;
        $url = ($ssl ? 'https' : 'http') . '://' . $hostname . ($port !== '' ? ':' . $port : '');
      }
    } elseif (is_file($path . DIRECTORY_SEPARATOR . 'artisan')) {
      $platform = 'Other';
      $port = '8000';
      $ssl = false;
    } elseif (is_file($path . DIRECTORY_SEPARATOR . 'package.json')) {
      $pkg = @file_get_contents($path . DIRECTORY_SEPARATOR . 'package.json');
      if ($pkg !== false) {
        $json = json_decode($pkg, true);
        if (is_array($json)) {
          $deps = array_merge(
            $json['dependencies'] ?? [],
            $json['devDependencies'] ?? []
          );
          if (isset($deps['next'])) {
            $platform = 'Node';
            $port = '3000';
          } elseif (isset($deps['vite'])) {
            $platform = 'Vite';
            $port = '5173';
          } elseif (isset($deps['react']) || isset($deps['express'])) {
            $platform = 'Node';
            $port = '3000';
          }
        }
      }
      $ssl = false;
    }

    if ($platform !== 'WordPress') {
      $url = ($ssl ? 'https' : 'http') . '://' . $hostname . ($port !== '' ? ':' . $port : '');
    }

    if (in_array($url, $existingUrls, true)) {
      continue;
    }
    if (in_array($hostname, $existingHostnames, true)) {
      continue;
    }

    $devServerRequired = ($platform !== 'WordPress');
    $suggestions[] = [
      'name' => $name,
      'hostname' => $hostname,
      'url' => $url,
      'platform' => $platform,
      'port' => $port,
      'ssl' => $ssl,
      'devServerRequired' => $devServerRequired,
    ];
  }

  usort($suggestions, fn ($a, $b) => strcasecmp($a['name'], $b['name']));
  return $suggestions;
}

/**
 * Resolve the favicon URL for a given site URL. First parses the page source for <link rel="icon">,
 * then falls back to origin/favicon.ico. Returns absolute favicon URL or empty string.
 */
function resolveFaviconUrl(string $siteUrl, int $timeoutSeconds = 3): string {
  try {
    $parsed = parse_url($siteUrl);
    $scheme = ($parsed['scheme'] ?? 'https') . '://';
    $host = $parsed['host'] ?? '';
    $port = isset($parsed['port']) ? ':' . $parsed['port'] : '';
    if ($host === '') {
      return '';
    }
    $origin = $scheme . $host . $port;
  } catch (Throwable $e) {
    return '';
  }
  $opts = [
    'http' => [
      'timeout' => $timeoutSeconds,
      'ignore_errors' => true,
    ],
    'ssl' => [
      'verify_peer' => false,
      'verify_peer_name' => false,
    ],
  ];
  $opts['http']['method'] = 'GET';
  $ctx = stream_context_create($opts);
  $html = @file_get_contents($origin . '/', false, $ctx);
  if ($html !== false && preg_match('/<link[^>]+rel=(["\'])(?:shortcut )?icon\1[^>]+href=(["\'])([^"\']+)\2/i', $html, $m)) {
    $href = trim($m[3]);
    if (strpos($href, 'http') === 0) {
      return $href;
    }
    if (strpos($href, '//') === 0) {
      return (parse_url($origin, PHP_URL_SCHEME) ?? 'https') . ':' . $href;
    }
    if (strpos($href, '/') === 0) {
      return $origin . $href;
    }
    return rtrim($origin, '/') . '/' . $href;
  }
  $faviconIco = $origin . '/favicon.ico';
  $opts['http']['method'] = 'HEAD';
  $ctx = stream_context_create($opts);
  $headers = @get_headers($faviconIco, false, $ctx);
  if (is_array($headers) && count($headers) > 0) {
    $status = (int) preg_replace('/\D/', '', $headers[0]);
    if ($status >= 200 && $status < 400) {
      return $faviconIco;
    }
  }
  $opts['http']['method'] = 'GET';
  $ctx = stream_context_create($opts);
  $body = @file_get_contents($faviconIco, false, $ctx);
  if ($body !== false && strlen($body) > 0) {
    return $faviconIco;
  }
  return '';
}

/**
 * Probe a URL with a short timeout. Tries HEAD first, then GET (many dev servers only respond to GET).
 * Returns true if we get any HTTP response (including 4xx/5xx).
 */
function probeUrl(string $url, int $timeoutSeconds = 3): bool {
  $opts = [
    'http' => [
      'timeout' => $timeoutSeconds,
      'ignore_errors' => true,
    ],
    'ssl' => [
      'verify_peer' => false,
      'verify_peer_name' => false,
    ],
  ];
  $opts['http']['method'] = 'HEAD';
  $ctx = stream_context_create($opts);
  $headers = @get_headers($url, false, $ctx);
  if (is_array($headers) && count($headers) > 0) {
    return true;
  }
  $opts['http']['method'] = 'GET';
  $ctx = stream_context_create($opts);
  $body = @file_get_contents($url, false, $ctx);
  return $body !== false;
}

/**
 * For each suggestion, try the current URL; if it fails, try the alternate protocol (and port for WordPress).
 * Returns suggestions with url, ssl, port updated to the working combination.
 */
function probeSuggestions(array $suggestions): array {
  $out = [];
  foreach ($suggestions as $s) {
    $url = $s['url'];
    $hostname = $s['hostname'];
    $port = $s['port'] ?? '';
    $platform = $s['platform'] ?? 'Other';
    $ssl = $s['ssl'] ?? false;

    if (probeUrl($url)) {
      $faviconUrl = resolveFaviconUrl($url);
      $out[] = array_merge($s, ['probeStatus' => 'success', 'faviconUrl' => $faviconUrl]);
      continue;
    }

    $altSsl = !$ssl;
    $altPort = $port;
    if ($platform === 'WordPress') {
      $altPort = $ssl ? '8080' : '8443';
    }
    $altUrl = ($altSsl ? 'https' : 'http') . '://' . $hostname . ($altPort !== '' ? ':' . $altPort : '');

    if (probeUrl($altUrl)) {
      $faviconUrl = resolveFaviconUrl($altUrl);
      $out[] = [
        'name' => $s['name'],
        'hostname' => $hostname,
        'url' => $altUrl,
        'platform' => $platform,
        'port' => $altPort,
        'ssl' => $altSsl,
        'devServerRequired' => $s['devServerRequired'] ?? ($platform !== 'WordPress'),
        'probeStatus' => 'success',
        'faviconUrl' => $faviconUrl,
      ];
    } else {
      $out[] = array_merge($s, ['probeStatus' => 'no-response', 'faviconUrl' => '']);
    }
  }
  return $out;
}

function sendJson(array $data, int $status = 200): void {
  http_response_code($status);
  echo json_encode($data);
}

/**
 * For each project missing faviconUrl, resolve it from the project URL and persist if any were updated.
 */
function backfillProjectFavicons(string $configPath, array &$config): void {
  $updated = false;
  foreach ($config['projects'] as &$p) {
    $current = trim((string) ($p['faviconUrl'] ?? ''));
    if ($current !== '') {
      continue;
    }
    $url = trim((string) ($p['url'] ?? ''));
    if ($url === '') {
      continue;
    }
    $faviconUrl = resolveFaviconUrl($url);
    if ($faviconUrl !== '') {
      $p['faviconUrl'] = $faviconUrl;
      $updated = true;
    }
  }
  unset($p);
  if ($updated && $configPath !== '') {
    @writeConfig($configPath, $config);
  }
}

function configResponse(array $config): array {
  $suggestions = detectSuggestions(
    $config['sitesDir'],
    $config['localTld'],
    $config['projects']
  );
  return [
    'projects' => $config['projects'],
    'sitesDir' => $config['sitesDir'],
    'localTld' => $config['localTld'],
    'suggestions' => $suggestions,
  ];
}

function sendError(string $message, int $status = 400): void {
  sendJson(['error' => $message], $status);
}

$configPath = readConfigPath($bootstrapFile);
$config = readConfig($configPath);
if ($configPath === '' && $config['sitesDir'] !== '') {
  $configPath = rtrim($config['sitesDir'], '/') . '/local-projects-dashboard.json';
  writeBootstrapConfigPath($bootstrapFile, $configPath);
}

$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

switch ($method) {
  case 'GET':
    backfillProjectFavicons($configPath, $config);
    $response = configResponse($config);
    if (!empty($_GET['probe'])) {
      $response['suggestions'] = probeSuggestions($response['suggestions']);
    }
    sendJson($response);
    break;

  case 'POST':
    $body = file_get_contents('php://input');
    $input = json_decode($body, true);
    if (!is_array($input)) {
      sendError('Invalid JSON body');
      exit;
    }
    $name = trim((string) ($input['name'] ?? ''));
    $url = trim((string) ($input['url'] ?? ''));
    $port = trim((string) ($input['port'] ?? ''));
    $platform = trim((string) ($input['platform'] ?? ''));
    if ($name === '' || $url === '') {
      sendError('Name and URL are required');
      exit;
    }
    $autoRedirect = !empty($input['autoRedirect']);
    $faviconUrl = trim((string) ($input['faviconUrl'] ?? ''));
    if ($faviconUrl === '') {
      $faviconUrl = resolveFaviconUrl($url);
    }
    $config['projects'][] = [
      'id' => (string) (time() . '-' . bin2hex(random_bytes(4))),
      'name' => $name,
      'url' => $url,
      'port' => $port,
      'platform' => $platform,
      'autoRedirect' => $autoRedirect,
      'faviconUrl' => $faviconUrl,
    ];
    if (!writeConfig($configPath, $config)) {
      sendError('Could not save projects', 500);
      exit;
    }
    sendJson(configResponse($config));
    break;

  case 'PUT':
    $body = file_get_contents('php://input');
    $input = json_decode($body, true);
    if (!is_array($input)) {
      sendError('Invalid JSON body');
      exit;
    }
    if (array_key_exists('sitesDir', $input) || array_key_exists('localTld', $input)) {
      $config['sitesDir'] = trim((string) ($input['sitesDir'] ?? $config['sitesDir']));
      $config['localTld'] = trim((string) ($input['localTld'] ?? $config['localTld'])) ?: '.ldev';
      $newPath = rtrim($config['sitesDir'], '/') . '/local-projects-dashboard.json';
      if (!writeConfig($newPath, $config)) {
        sendError('Could not save settings', 500);
        exit;
      }
      if ($newPath !== $configPath) {
        writeBootstrapConfigPath($bootstrapFile, $newPath);
      }
      sendJson(configResponse($config));
      break;
    }
    $id = (string) ($input['id'] ?? '');
    if ($id === '') {
      sendError('Missing id');
      exit;
    }
    $name = trim((string) ($input['name'] ?? ''));
    $url = trim((string) ($input['url'] ?? ''));
    $port = trim((string) ($input['port'] ?? ''));
    $platform = trim((string) ($input['platform'] ?? ''));
    $autoRedirect = array_key_exists('autoRedirect', $input) ? !empty($input['autoRedirect']) : null;
    if ($name === '' || $url === '') {
      sendError('Name and URL are required');
      exit;
    }
    $faviconUrl = trim((string) ($input['faviconUrl'] ?? ''));
    if ($faviconUrl === '') {
      $faviconUrl = resolveFaviconUrl($url);
    }
    $found = false;
    foreach ($config['projects'] as &$p) {
      if (($p['id'] ?? '') === $id) {
        $p['name'] = $name;
        $p['url'] = $url;
        $p['port'] = $port;
        $p['platform'] = $platform;
        $p['faviconUrl'] = $faviconUrl;
        if ($autoRedirect !== null) {
          $p['autoRedirect'] = $autoRedirect;
        }
        $found = true;
        break;
      }
    }
    if (!$found) {
      sendError('Project not found', 404);
      exit;
    }
    if (!writeConfig($configPath, $config)) {
      sendError('Could not save projects', 500);
      exit;
    }
    sendJson(configResponse($config));
    break;

  case 'DELETE':
    $id = $_GET['id'] ?? '';
    if ($id === '') {
      sendError('Missing id');
      exit;
    }
    $before = count($config['projects']);
    $config['projects'] = array_values(array_filter($config['projects'], fn ($p) => ($p['id'] ?? '') !== $id));
    if (count($config['projects']) === $before) {
      sendError('Project not found', 404);
      exit;
    }
    if (!writeConfig($configPath, $config)) {
      sendError('Could not save projects', 500);
      exit;
    }
    sendJson(configResponse($config));
    break;

  default:
    sendError('Method not allowed', 405);
}
