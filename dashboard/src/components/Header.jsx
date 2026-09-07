import { Logo } from './Logo';
import './Header.css';

export function Header({ onAddProject, onOpenSettings, onOpenSuggested }) {
  return (
    <header className="dashboard-header">
      <div className="dashboard-header-inner">
        <div className="dashboard-brand">
          <Logo className="dashboard-logo" size={44} />
          <div>
            <h1 className="dashboard-title">Local Projects</h1>
            <p className="dashboard-subtitle">Quick access to your development sites</p>
          </div>
        </div>
        <div className="dashboard-actions">
          <button
            type="button"
            className="btn btn-ghost btn-suggested"
            onClick={onOpenSuggested}
            aria-label="Suggested projects"
          >
            Suggested
          </button>
          <button
            type="button"
            className="btn-icon-only btn-settings"
            onClick={onOpenSettings}
            aria-label="Settings"
          >
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
              <path d="M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6Z" />
              <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" />
            </svg>
          </button>
          <button
            type="button"
            className="btn btn-primary btn-add"
            onClick={onAddProject}
            aria-label="Add project"
          >
            <span className="btn-icon" aria-hidden>+</span>
            Add project
          </button>
        </div>
      </div>
    </header>
  );
}
