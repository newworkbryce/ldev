import { useEffect } from 'react';
import { PlatformIcon } from './AddProjectModal';
import './SuggestedProjects.css';
import './SuggestedProjectsModal.css';

export function SuggestedProjectsModal({ isOpen, onClose, suggestions, probePending, onAdd }) {
  const handleBackdropClick = (e) => {
    if (e.target === e.currentTarget) onClose();
  };

  useEffect(() => {
    if (!isOpen) return;
    const onKeyDown = (e) => {
      if (e.key === 'Escape') onClose();
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [isOpen, onClose]);

  if (!isOpen) return null;

  return (
    <div
      className="modal-overlay suggested-modal-overlay"
      role="dialog"
      aria-modal="true"
      aria-labelledby="suggested-modal-title"
      onClick={handleBackdropClick}
    >
      <div className="modal-backdrop" onClick={onClose} aria-hidden />
      <div className="modal-content suggested-modal-content" onClick={(e) => e.stopPropagation()}>
        <div className="modal-header">
          <h2 id="suggested-modal-title" className="modal-title">
            Suggested projects
          </h2>
          <button
            type="button"
            className="modal-close"
            onClick={onClose}
            aria-label="Close"
          >
            ×
          </button>
        </div>
        <div className="suggested-modal-body">
          {!suggestions || suggestions.length === 0 ? (
            <p className="suggested-modal-empty">No suggested projects. Check your Sites directory in Settings.</p>
          ) : (
            <div className="suggested-projects-grid" role="list">
              {suggestions.map((s) => (
                <article key={s.hostname} className="suggested-tile" role="listitem">
                  <h3 className="suggested-tile-name">{s.name}</h3>
                  <div className="suggested-tile-meta">
                    {s.ssl && (
                      <span className="badge badge-ssl" title="HTTPS" aria-label="Secure (HTTPS)">
                        <svg viewBox="0 0 24 24" fill="currentColor" width={12} height={12} aria-hidden>
                          <path d="M18 8h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zm-6 9c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zm3.1-9H8.9V6c0-1.71 1.39-3.1 3.1-3.1 1.71 0 3.1 1.39 3.1 3.1v2z" />
                        </svg>
                      </span>
                    )}
                    <span className="badge badge-platform">
                      <PlatformIcon platform={s.platform} className="suggested-tile-platform-icon" size={16} />
                      {s.platform}
                    </span>
                    {s.port && <span className="badge badge-port">:{s.port}</span>}
                    <span className="suggested-tile-protocol">{s.ssl ? 'HTTPS' : 'HTTP'}</span>
                  </div>
                  <a
                    className="suggested-tile-url"
                    href={s.url}
                    target="_blank"
                    rel="noopener noreferrer"
                  >
                    {s.url}
                    <span className="suggested-tile-url-arrow" aria-hidden>↗</span>
                  </a>
                  {(probePending || s.probeStatus != null) && (
                    <span
                      className={`suggested-tile-probe suggested-tile-probe--${s.probeStatus ?? 'checking'}`}
                      aria-label={
                        s.probeStatus === 'success'
                          ? 'URL responds'
                          : s.probeStatus === 'no-response'
                            ? 'No response from URL'
                            : 'Checking URL'
                      }
                    >
                      {s.probeStatus === 'success'
                        ? 'Responds'
                        : s.probeStatus === 'no-response'
                          ? 'No response'
                          : 'Checking…'}
                    </span>
                  )}
                  {s.devServerRequired && (
                    <span
                      className="suggested-tile-dev-server-notice"
                      title="Run dev server (e.g. npm run dev) for this URL to respond"
                    >
                      {s.platform === 'Node' || s.platform === 'Vite'
                        ? `Requires ${s.platform.toLowerCase()} dev server to be running`
                        : 'Requires dev server to be running'}
                    </span>
                  )}
                  <button
                    type="button"
                    className="suggested-tile-add"
                    onClick={() => onAdd(s)}
                    aria-label={`Add ${s.name}`}
                  >
                    Add
                  </button>
                </article>
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
