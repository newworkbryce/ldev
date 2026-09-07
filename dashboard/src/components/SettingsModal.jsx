import { useState, useEffect } from 'react';
import './SettingsModal.css';

export function SettingsModal({ isOpen, onClose, onSave, sitesDir, localTld }) {
  const [dir, setDir] = useState(sitesDir);
  const [tld, setTld] = useState(localTld);

  useEffect(() => {
    if (isOpen) {
      setDir(sitesDir);
      setTld(localTld);
    }
  }, [isOpen, sitesDir, localTld]);

  const handleSubmit = (e) => {
    e.preventDefault();
    const trimmedDir = dir.trim();
    const trimmedTld = tld.trim();
    onSave(trimmedDir, trimmedTld || '.ldev');
  };

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
      className="modal-overlay settings-modal-overlay"
      role="dialog"
      aria-modal="true"
      aria-labelledby="settings-modal-title"
      onClick={handleBackdropClick}
    >
      <div className="modal-backdrop" onClick={onClose} aria-hidden />
      <div className="modal-content settings-modal-content" onClick={(e) => e.stopPropagation()}>
        <div className="modal-header">
          <h2 id="settings-modal-title" className="modal-title">
            Settings
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
        <form className="modal-form" onSubmit={handleSubmit}>
          <div className="field">
            <label htmlFor="sitesDir">Sites directory</label>
            <input
              type="text"
              id="sitesDir"
              value={dir}
              onChange={(e) => setDir(e.target.value)}
              placeholder="e.g. /Users/you/Sites"
              autoComplete="off"
            />
            <span className="field-hint">Config and project list are stored here (e.g. ~/Sites/local-projects-dashboard.json).</span>
          </div>
          <div className="field">
            <label htmlFor="localTld">Local TLD</label>
            <input
              type="text"
              id="localTld"
              value={tld}
              onChange={(e) => setTld(e.target.value)}
              placeholder=".ldev"
              autoComplete="off"
            />
            <span className="field-hint">Local domain suffix (e.g. .ldev for seasonal-drops.ldev).</span>
          </div>
          <div className="modal-actions">
            <button type="button" className="btn btn-ghost" onClick={onClose}>
              Cancel
            </button>
            <button type="submit" className="btn btn-primary">
              Save
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
