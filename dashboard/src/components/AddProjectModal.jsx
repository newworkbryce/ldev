import { useState, useEffect, useRef } from 'react';
import { siWordpress, siNodedotjs, siVite } from 'simple-icons';
import './AddProjectModal.css';

/** Platforms used in Sites: WordPress, Node, Vite. Port depends on HTTP/HTTPS for WordPress. */
const PLATFORMS = [
  { value: 'WordPress', label: 'WordPress', portHttp: '8080', portHttps: '8443' },
  { value: 'Node', label: 'Node', port: '3000' },
  { value: 'Vite', label: 'Vite', port: '5173' },
  { value: 'Other', label: 'Other', port: '' },
];

function getDefaultPort(platform, protocol) {
  const p = PLATFORMS.find((x) => x.value === platform);
  if (!p) return '';
  if (p.portHttp !== undefined) return protocol === 'https' ? p.portHttps : p.portHttp;
  return p.port ?? '';
}

/** Official brand SVG paths (24×24 viewBox). Other = generic box icon. */
const ICON_PATHS = {
  WordPress: siWordpress.path,
  Node: siNodedotjs.path,
  Vite: siVite.path,
  Other: 'M3 3h8v8H3V3zm10 0h8v8h-8V3zM3 13h8v8H3v-8zm10 0h8v8h-8v-8z',
};

export function PlatformIcon({ platform, className = '', size = 28 }) {
  const path = ICON_PATHS[platform] ?? ICON_PATHS.Other;
  return (
    <span className={className} aria-hidden>
      <svg viewBox="0 0 24 24" fill="currentColor" width={size} height={size} xmlns="http://www.w3.org/2000/svg">
        <path d={path} />
      </svg>
    </span>
  );
}

export function AddProjectModal({ isOpen, onClose, onSubmit, editingProject, suggestion }) {
  const [name, setName] = useState('');
  const [url, setUrl] = useState('');
  const [port, setPort] = useState('');
  const [platform, setPlatform] = useState('');
  const [protocol, setProtocol] = useState('https');
  const [autoRedirect, setAutoRedirect] = useState(false);
  const firstInputRef = useRef(null);

  useEffect(() => {
    if (!isOpen) return;
    if (editingProject) {
      setName(editingProject.name ?? '');
      setUrl(editingProject.url ?? '');
      setPort(editingProject.port ?? '');
      setPlatform(editingProject.platform ?? '');
      setAutoRedirect(!!editingProject.autoRedirect);
      try {
        const u = new URL(editingProject.url ?? '');
        setProtocol(u.protocol === 'https:' ? 'https' : 'http');
      } catch {
        setProtocol('https');
      }
    } else if (suggestion) {
      setName(suggestion.name ?? '');
      setUrl(suggestion.url ?? '');
      setPort(suggestion.port ?? '');
      setPlatform(suggestion.platform ?? 'Other');
      setProtocol(suggestion.ssl ? 'https' : 'http');
      setAutoRedirect(true);
    } else {
      const hostname = window.location.hostname;
      const nameFromHost = hostname.split('.')[0].replace(/-/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());
      setName(nameFromHost);
      setUrl(window.location.origin);
      setPort('');
      setPlatform('');
      setAutoRedirect(true);
      setProtocol(window.location.protocol === 'https:' ? 'https' : 'http');
    }
    const t = requestAnimationFrame(() => {
      firstInputRef.current?.focus();
    });
    return () => cancelAnimationFrame(t);
  }, [isOpen, editingProject, suggestion]);

  const handleProtocolChange = (newProtocol) => {
    setProtocol(newProtocol);
    const newPort = platform ? getDefaultPort(platform, newProtocol) : '';
    setPort(newPort);
    setUrl((prev) => {
      try {
        const u = new URL(prev || window.location.origin);
        u.protocol = newProtocol + ':';
        if (newPort) u.port = newPort;
        else u.port = '';
        return u.origin;
      } catch {
        return prev;
      }
    });
  };

  const handlePlatformSelect = (value) => {
    setPlatform(value);
    const newPort = getDefaultPort(value, protocol);
    setPort(newPort);
    setUrl((prev) => {
      try {
        const u = new URL(prev || window.location.origin);
        u.protocol = protocol + ':';
        if (newPort) u.port = newPort;
        else u.port = '';
        return u.origin;
      } catch {
        return prev;
      }
    });
  };

  useEffect(() => {
    if (!isOpen) return;
    const onKeyDown = (e) => {
      if (e.key === 'Escape') onClose();
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [isOpen, onClose]);

  const handleSubmit = (e) => {
    e.preventDefault();
    const trimmedName = name.trim();
    const trimmedUrl = url.trim();
    if (!trimmedName || !trimmedUrl) return;
    onSubmit(
      {
        name: trimmedName,
        url: trimmedUrl,
        port: port.trim(),
        platform: platform.trim(),
        autoRedirect,
      },
      editingProject?.id
    );
    onClose();
  };

  const handleBackdropClick = (e) => {
    if (e.target === e.currentTarget) onClose();
  };

  if (!isOpen) return null;

  return (
    <div
      className="modal-overlay"
      role="dialog"
      aria-modal="true"
      aria-labelledby="modal-title"
      onClick={handleBackdropClick}
    >
      <div className="modal-backdrop" onClick={onClose} aria-hidden />
      <div className="modal-content" onClick={(e) => e.stopPropagation()}>
        <div className="modal-header">
          <h2 id="modal-title" className="modal-title">
            {editingProject ? 'Edit project' : 'Add project'}
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
          <div className="field field-platform">
            <label className="field-label">Platform</label>
            <div className="platform-tiles" role="group" aria-label="Select platform">
              {PLATFORMS.map((p) => {
                const portLabel = getDefaultPort(p.value, protocol);
                return (
                  <button
                    key={p.value}
                    type="button"
                    className={`platform-tile ${platform === p.value ? 'platform-tile--selected' : ''}`}
                    onClick={() => handlePlatformSelect(p.value)}
                    aria-pressed={platform === p.value}
                  >
                    <PlatformIcon platform={p.value} className="platform-tile-icon" />
                    <span className="platform-tile-label">{p.label}</span>
                    {portLabel ? <span className="platform-tile-port">:{portLabel}</span> : null}
                  </button>
                );
              })}
            </div>
          </div>
          <div className="field">
            <label htmlFor="projectName">Project name</label>
            <input
              ref={firstInputRef}
              type="text"
              id="projectName"
              value={name}
              onChange={(e) => setName(e.target.value)}
              required
              placeholder="e.g. Seasonal Drops"
              autoComplete="off"
            />
          </div>
          <div className="field field-ssl">
            <label className="field-label">SSL</label>
            <div className="protocol-toggle" role="group" aria-label="SSL">
              <button
                type="button"
                className={`protocol-btn ${protocol === 'http' ? 'protocol-btn--selected' : ''}`}
                onClick={() => handleProtocolChange('http')}
                aria-pressed={protocol === 'http'}
              >
                HTTP
              </button>
              <button
                type="button"
                className={`protocol-btn ${protocol === 'https' ? 'protocol-btn--selected' : ''}`}
                onClick={() => handleProtocolChange('https')}
                aria-pressed={protocol === 'https'}
              >
                HTTPS
              </button>
            </div>
          </div>
          <div className="field">
            <label htmlFor="projectUrl">Local URL</label>
            <input
              type="url"
              id="projectUrl"
              value={url}
              onChange={(e) => setUrl(e.target.value)}
              required
              placeholder="e.g. https://seasonal-drops.ldev:8443"
              autoComplete="off"
            />
          </div>
          <div className="field">
            <label htmlFor="projectPort">Port</label>
            <input
              type="text"
              id="projectPort"
              value={port}
              onChange={(e) => setPort(e.target.value)}
              placeholder="e.g. 8443"
              inputMode="numeric"
              pattern="[0-9]*"
              autoComplete="off"
            />
          </div>
          <div className="field field-checkbox">
            <label className="checkbox-label">
              <input
                type="checkbox"
                className="checkbox-input"
                checked={autoRedirect}
                onChange={(e) => setAutoRedirect(e.target.checked)}
                aria-label="Auto redirect when visiting this project’s domain"
              />
              <span className="checkbox-box" aria-hidden>
                <svg className="checkbox-check" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                  <polyline points="20 6 9 17 4 12" />
                </svg>
              </span>
              <span className="checkbox-text">Auto Redirect</span>
            </label>
            <span className="field-hint">When the dashboard is opened on this project’s domain, redirect to the project URL.</span>
          </div>
          <div className="modal-actions">
            <button type="button" className="btn btn-ghost" onClick={onClose}>
              Cancel
            </button>
            <button type="submit" className="btn btn-primary">
              Save project
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
