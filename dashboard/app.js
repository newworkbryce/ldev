(function () {
  const API = 'api.php';

  const projectsList = document.getElementById('projectsList');
  const emptyState = document.getElementById('emptyState');
  const errorMessage = document.getElementById('errorMessage');
  const addProjectBtn = document.getElementById('addProjectBtn');
  const emptyAddBtn = document.getElementById('emptyAddBtn');
  const projectModal = document.getElementById('projectModal');
  const projectForm = document.getElementById('projectForm');
  const modalClose = document.getElementById('modalClose');
  const modalCancel = document.getElementById('modalCancel');
  const modalBackdrop = document.getElementById('modalBackdrop');

  function showError(msg) {
    errorMessage.textContent = msg;
    errorMessage.hidden = false;
  }

  function clearError() {
    errorMessage.hidden = true;
  }

  async function fetchProjects() {
    const res = await fetch(API);
    if (!res.ok) throw new Error('Failed to load projects');
    const data = await res.json();
    return data.projects || [];
  }

  async function saveProject(project) {
    const res = await fetch(API, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(project),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || 'Failed to save');
    return data.projects;
  }

  async function deleteProject(id) {
    const res = await fetch(API + '?id=' + encodeURIComponent(id), { method: 'DELETE' });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || 'Failed to delete');
    return data.projects;
  }

  function renderProjects(projects) {
    clearError();
    projectsList.innerHTML = '';
    if (projects.length === 0) {
      emptyState.hidden = false;
      return;
    }
    emptyState.hidden = true;
    projects.forEach((p) => {
      const card = document.createElement('article');
      card.className = 'project-card';
      card.setAttribute('role', 'listitem');
      const portBadge = p.port
        ? `<span class="badge">:${p.port}</span>`
        : '';
      const platformBadge = p.platform
        ? `<span class="badge badge-platform">${escapeHtml(p.platform)}</span>`
        : '';
      card.innerHTML = `
        <h3 class="project-name">${escapeHtml(p.name)}</h3>
        <div class="badges">${portBadge}${platformBadge}</div>
        <div class="project-url-wrap">
          <a class="project-url" href="${escapeAttr(p.url)}" target="_blank" rel="noopener">${escapeHtml(p.url)}</a>
        </div>
        <div class="project-actions">
          <button type="button" class="btn-delete" data-id="${escapeAttr(p.id)}" aria-label="Remove project">Remove</button>
        </div>
      `;
      card.querySelector('.btn-delete').addEventListener('click', () => removeProject(p.id));
      projectsList.appendChild(card);
    });
  }

  function escapeHtml(s) {
    const div = document.createElement('div');
    div.textContent = s;
    return div.innerHTML;
  }

  function escapeAttr(s) {
    return escapeHtml(s).replace(/"/g, '&quot;');
  }

  async function loadAndRender() {
    try {
      const projects = await fetchProjects();
      renderProjects(projects);
    } catch (e) {
      showError(e.message);
      renderProjects([]);
    }
  }

  async function removeProject(id) {
    try {
      const projects = await deleteProject(id);
      renderProjects(projects);
    } catch (e) {
      showError(e.message);
    }
  }

  function openModal() {
    clearError();
    projectForm.reset();
    projectModal.showModal();
    // Focus first field for keyboard users
    const firstInput = document.getElementById('projectName');
    if (firstInput) firstInput.focus();
  }

  function closeModal() {
    projectModal.close();
  }

  projectForm.addEventListener('submit', async (e) => {
    e.preventDefault();
    const name = document.getElementById('projectName').value.trim();
    const url = document.getElementById('projectUrl').value.trim();
    const port = document.getElementById('projectPort').value.trim();
    const platform = document.getElementById('projectPlatform').value.trim();
    if (!name || !url) return;
    try {
      await saveProject({ name, url, port, platform });
      closeModal();
      loadAndRender();
    } catch (err) {
      showError(err.message);
    }
  });

  addProjectBtn.addEventListener('click', openModal);
  emptyAddBtn.addEventListener('click', openModal);
  modalClose.addEventListener('click', closeModal);
  modalCancel.addEventListener('click', closeModal);
  modalBackdrop.addEventListener('click', closeModal);
  projectModal.addEventListener('cancel', closeModal);

  loadAndRender();
})();
