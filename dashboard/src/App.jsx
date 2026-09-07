import { useState, useEffect, useCallback } from 'react';
import { Header } from './components/Header';
import { ProjectList } from './components/ProjectList';
import { EmptyState } from './components/EmptyState';
import { AddProjectModal } from './components/AddProjectModal';
import { SuggestedProjectsModal } from './components/SuggestedProjectsModal';
import { fetchConfig, fetchProbedSuggestions, saveProject, updateProject, deleteProject, updateSettings } from './api';
import { SettingsModal } from './components/SettingsModal';
import './App.css';

export default function App() {
  const [projects, setProjects] = useState([]);
  const [sitesDir, setSitesDir] = useState('');
  const [localTld, setLocalTld] = useState('.ldev');
  const [loading, setLoading] = useState(true);
  const [redirectingTo, setRedirectingTo] = useState(null);
  const [error, setError] = useState('');
  const [modalOpen, setModalOpen] = useState(false);
  const [editingProject, setEditingProject] = useState(null);
  const [suggestionForModal, setSuggestionForModal] = useState(null);
  const [suggestions, setSuggestions] = useState([]);
  const [probePending, setProbePending] = useState(false);
  const [suggestedModalOpen, setSuggestedModalOpen] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);

  const loadConfig = useCallback(async () => {
    try {
      setError('');
      const config = await fetchConfig();
      setProjects(config.projects);
      setSitesDir(config.sitesDir);
      setLocalTld(config.localTld);
      setSuggestions(config.suggestions ?? []);
      const hostname = window.location.hostname;
      const match = config.projects.find((p) => {
        if (!p.autoRedirect) return false;
        try {
          return new URL(p.url).hostname === hostname;
        } catch {
          return false;
        }
      });
      if (match) setRedirectingTo(match.url);
    } catch (e) {
      setError(e.message);
      setProjects([]);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    loadConfig();
  }, [loadConfig]);

  useEffect(() => {
    if (redirectingTo) window.location.href = redirectingTo;
  }, [redirectingTo]);

  useEffect(() => {
    if (!suggestedModalOpen) return;
    let cancelled = false;
    setProbePending(true);
    (async () => {
      let list = suggestions;
      if (list.length === 0) {
        const config = await fetchConfig().catch(() => null);
        if (cancelled || !config) return;
        list = config.suggestions ?? [];
        if (!cancelled) setSuggestions(list);
      }
      if (cancelled || list.length === 0) {
        if (!cancelled) setProbePending(false);
        return;
      }
      try {
        const probed = await fetchProbedSuggestions();
        if (!cancelled) {
          setSuggestions(probed);
          setProbePending(false);
        }
      } catch {
        if (!cancelled) setProbePending(false);
      }
    })();
    return () => { cancelled = true; };
  }, [suggestedModalOpen]);

  const handleAddProject = () => {
    setError('');
    setEditingProject(null);
    setModalOpen(true);
  };

  const handleEditProject = (project) => {
    setError('');
    setEditingProject(project);
    setModalOpen(true);
  };

  const handleCloseModal = () => {
    setModalOpen(false);
    setEditingProject(null);
    setSuggestionForModal(null);
  };

  const handleAddSuggestion = (suggestion) => {
    setError('');
    setEditingProject(null);
    setSuggestionForModal(suggestion);
    setSuggestedModalOpen(false);
    setModalOpen(true);
  };

  const applyConfig = (config) => {
    setProjects(config.projects);
    setSitesDir(config.sitesDir);
    setLocalTld(config.localTld);
    if (config.suggestions !== undefined) setSuggestions(config.suggestions);
  };

  const handleSubmitProject = async (project, editingId) => {
    try {
      const payload = { ...project };
      if (suggestionForModal?.faviconUrl) {
        payload.faviconUrl = suggestionForModal.faviconUrl;
      }
      const config = editingId
        ? await updateProject(editingId, payload)
        : await saveProject(payload);
      applyConfig(config);
      setModalOpen(false);
      setEditingProject(null);
      setSuggestionForModal(null);
    } catch (e) {
      setError(e.message);
    }
  };

  const handleRemoveProject = async (id) => {
    try {
      const config = await deleteProject(id);
      applyConfig(config);
      setError('');
    } catch (e) {
      setError(e.message);
    }
  };

  const handleSaveSettings = async (nextSitesDir, nextLocalTld) => {
    try {
      const config = await updateSettings({ sitesDir: nextSitesDir, localTld: nextLocalTld });
      applyConfig(config);
      setSettingsOpen(false);
    } catch (e) {
      setError(e.message);
    }
  };

  const isEmpty = projects.length === 0 && !loading;

  if (redirectingTo) {
    return (
      <div className="redirecting-screen" aria-live="polite" aria-busy="true">
        <div className="redirecting-spinner" aria-hidden />
        <p className="redirecting-text">Redirecting…</p>
      </div>
    );
  }

  return (
    <div className="app">
      <Header
        onAddProject={handleAddProject}
        onOpenSettings={() => setSettingsOpen(true)}
        onOpenSuggested={() => setSuggestedModalOpen(true)}
      />
      <main className="main">
        {loading ? (
          <div className="loading" aria-live="polite">
            Loading…
          </div>
        ) : (
          <>
            {isEmpty ? (
              <EmptyState onAddProject={handleAddProject} />
            ) : (
              <ProjectList
                projects={projects}
                onEdit={handleEditProject}
                onRemove={handleRemoveProject}
              />
            )}
            <div className="error-banner" hidden={!error} role="alert">
              {error}
            </div>
          </>
        )}
      </main>
      <SuggestedProjectsModal
        isOpen={suggestedModalOpen}
        onClose={() => setSuggestedModalOpen(false)}
        suggestions={suggestions}
        probePending={probePending}
        onAdd={handleAddSuggestion}
      />
      <AddProjectModal
        isOpen={modalOpen}
        onClose={handleCloseModal}
        onSubmit={handleSubmitProject}
        editingProject={editingProject}
        suggestion={suggestionForModal}
      />
      <SettingsModal
        isOpen={settingsOpen}
        onClose={() => setSettingsOpen(false)}
        onSave={handleSaveSettings}
        sitesDir={sitesDir}
        localTld={localTld}
      />
    </div>
  );
}
