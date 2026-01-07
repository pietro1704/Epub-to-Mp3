import { PropsWithChildren, ReactNode } from "react";
import clsx from "clsx";

interface PanelProps extends PropsWithChildren {
  title?: string;
  description?: string;
  footer?: ReactNode;
  className?: string;
}

export default function Panel({
  title,
  description,
  footer,
  className,
  children,
}: PanelProps): JSX.Element {
  return (
    <section className={clsx("panel", className)}>
      {title && <h2 className="panel__title">{title}</h2>}
      {description && <p className="panel__description">{description}</p>}
      <div className="panel__body">{children}</div>
      {footer && <footer className="panel__footer">{footer}</footer>}
    </section>
  );
}
