import { PlatformIcon } from './AddProjectModal';
import './ProjectCard.css';

function isHttps(urlString) {
  try {
    return new URL(urlString).protocol === 'https:';
  } catch {
    return false;
  }
}

export function ProjectCard({ project, onEdit, onRemove }) {
  const { id, name, url, port, platform, faviconUrl: storedFaviconUrl } = project;
  const portBadge = port ? `:${port}` : null;
  const ssl = isHttps(url);
  const faviconUrl = storedFaviconUrl && storedFaviconUrl.trim() ? storedFaviconUrl.trim() : null;
  const fallbackLetter = name ? name.trim().charAt(0).toUpperCase() : '?';

  return (
    <article className="project-card" role="listitem">
      <div className="project-card-favicon" aria-hidden>
        {faviconUrl && (
          <img
            src={faviconUrl}
            alt=""
            width={40}
            height={40}
            onError={(e) => {
              e.target.style.display = 'none';
              e.target.nextElementSibling?.classList.add('is-visible');
            }}
          />
        )}
        <span className={`project-card-favicon-fallback ${!faviconUrl ? 'is-visible' : ''}`}>{fallbackLetter}</span>
      </div>
      <h3 className="project-card-name">{name}</h3>
      <div className="project-card-badges">
        {ssl && (
          <span className="badge badge-ssl" title="HTTPS" aria-label="Secure (HTTPS)">
            <svg viewBox="0 0 24 24" fill="currentColor" width={12} height={12} aria-hidden>
              <path d="M18 8h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zm-6 9c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zm3.1-9H8.9V6c0-1.71 1.39-3.1 3.1-3.1 1.71 0 3.1 1.39 3.1 3.1v2z" />
            </svg>
          </span>
        )}
        {portBadge && <span className="badge badge-port">{portBadge}</span>}
        {platform && (
          <span className="badge badge-platform">
            <PlatformIcon platform={platform} className="badge-platform-icon" size={16} />
            {platform}
          </span>
        )}
      </div>
      <div className="project-card-url-wrap">
        <a
          className="project-card-url"
          href={url}
          target="_blank"
          rel="noopener noreferrer"
        >
          {url}
          <span className="project-card-url-arrow" aria-hidden>↗</span>
        </a>
      </div>
      <div className="project-card-actions">
        <button
          type="button"
          className="btn-icon btn-edit"
          onClick={() => onEdit(project)}
          aria-label={`Edit ${name}`}
        >
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
            <path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7" />
            <path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z" />
          </svg>
        </button>
        <button
          type="button"
          className="btn-icon btn-delete"
          onClick={() => onRemove(id)}
          aria-label={`Remove ${name}`}
        >
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
            <polyline points="3 6 5 6 21 6" />
            <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2" />
            <line x1="10" y1="11" x2="10" y2="17" />
            <line x1="14" y1="11" x2="14" y2="17" />
          </svg>
        </button>
      </div>
    </article>
  );
}
