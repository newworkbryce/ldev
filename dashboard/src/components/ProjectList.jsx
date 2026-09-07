import { ProjectCard } from './ProjectCard';
import './ProjectList.css';

export function ProjectList({ projects, onEdit, onRemove }) {
  return (
    <div className="project-list" role="list">
      {projects.map((project) => (
        <ProjectCard key={project.id} project={project} onEdit={onEdit} onRemove={onRemove} />
      ))}
    </div>
  );
}
