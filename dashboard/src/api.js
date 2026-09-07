/** Resolve api.php from the same origin/path as the current page (works when built and served from any path). */
function getApiUrl() {
  if (typeof window === 'undefined') return 'api.php';
  const pathDir = window.location.pathname.replace(/\/[^/]*$/, '') || '';
  return window.location.origin + pathDir + '/api.php';
}

async function apiFetch(url, init) {
  try {
    return await fetch(url, init);
  } catch {
    throw new Error(
      'Cannot reach api.php. For production run ./restart-homebrew-apache.sh. For dev run: npm run dev:all (or php -S 127.0.0.1:8080 in a separate terminal).'
    );
  }
}

export async function fetchConfig(options = {}) {
  const api = getApiUrl();
  const url = options.probe ? api + '?probe=1' : api;
  const res = await apiFetch(url);
  if (!res.ok) throw new Error('Failed to load config (api.php returned ' + res.status + ')');
  let data;
  try {
    data = await res.json();
  } catch {
    throw new Error('Invalid response from server. Is api.php running?');
  }
  return {
    projects: data.projects || [],
    sitesDir: data.sitesDir ?? '',
    localTld: data.localTld ?? '.ldev',
    suggestions: data.suggestions || [],
  };
}

/** Fetch config with probed suggestions (tries each URL to detect protocol). Use in background so it doesn't block the UI. */
export async function fetchProbedSuggestions() {
  const config = await fetchConfig({ probe: true });
  return config.suggestions;
}

export async function fetchProjects() {
  const config = await fetchConfig();
  return config.projects;
}

export async function saveProject(project) {
  const res = await apiFetch(getApiUrl(), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(project),
  });
  let data;
  try {
    data = await res.json();
  } catch {
    throw new Error(res.ok ? 'Invalid response' : 'Server error. Is api.php running?');
  }
  if (!res.ok) throw new Error(data.error || 'Failed to save');
  return { projects: data.projects || [], sitesDir: data.sitesDir ?? '', localTld: data.localTld ?? '.ldev', suggestions: data.suggestions || [] };
}

export async function updateProject(id, project) {
  const res = await apiFetch(getApiUrl(), {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id, ...project }),
  });
  let data;
  try {
    data = await res.json();
  } catch {
    throw new Error(res.ok ? 'Invalid response' : 'Server error. Is api.php running?');
  }
  if (!res.ok) throw new Error(data.error || 'Failed to update');
  return { projects: data.projects || [], sitesDir: data.sitesDir ?? '', localTld: data.localTld ?? '.ldev', suggestions: data.suggestions || [] };
}

export async function deleteProject(id) {
  const res = await apiFetch(getApiUrl() + '?id=' + encodeURIComponent(id), { method: 'DELETE' });
  let data;
  try {
    data = await res.json();
  } catch {
    throw new Error(res.ok ? 'Invalid response' : 'Server error. Is api.php running?');
  }
  if (!res.ok) throw new Error(data.error || 'Failed to delete');
  return { projects: data.projects || [], sitesDir: data.sitesDir ?? '', localTld: data.localTld ?? '.ldev', suggestions: data.suggestions || [] };
}

export async function updateSettings(settings) {
  const res = await apiFetch(getApiUrl(), {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(settings),
  });
  let data;
  try {
    data = await res.json();
  } catch {
    throw new Error(res.ok ? 'Invalid response' : 'Server error. Is api.php running?');
  }
  if (!res.ok) throw new Error(data.error || 'Failed to save settings');
  return { projects: data.projects || [], sitesDir: data.sitesDir ?? '', localTld: data.localTld ?? '.ldev', suggestions: data.suggestions || [] };
}
