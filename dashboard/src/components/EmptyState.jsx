import './EmptyState.css';

export function EmptyState({ onAddProject }) {
  return (
    <div className="empty-state" role="status">
      <div className="empty-state-icon" aria-hidden>
        <svg width="64" height="64" viewBox="0 0 64 64" fill="none" xmlns="http://www.w3.org/2000/svg">
          <rect x="8" y="12" width="48" height="40" rx="6" stroke="currentColor" strokeWidth="2" strokeDasharray="4 2" opacity="0.4" />
          <path d="M20 28h24M20 36h16M20 44h20" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" opacity="0.5" />
          <circle cx="48" cy="24" r="8" fill="var(--accent)" opacity="0.2" />
          <circle cx="48" cy="24" r="4" fill="var(--accent)" />
        </svg>
      </div>
      <h2 className="empty-state-title">No projects yet</h2>
      <p className="empty-state-text">Add your first project to get started.</p>
      <button type="button" className="btn btn-secondary btn-empty-add" onClick={onAddProject}>
        Add project
      </button>
    </div>
  );
}
