import type { ReactNode } from "react";
import { motion } from "framer-motion";

type PageHeaderProps = {
  eyebrow?: string;
  title: string;
  description?: string;
  actions?: ReactNode;
};

export function PageHeader({ eyebrow, title, description, actions }: PageHeaderProps) {
  return (
    <motion.div
      animate={{ opacity: 1, y: 0 }}
      className="mb-6 flex flex-col gap-4 md:flex-row md:items-end md:justify-between"
      initial={{ opacity: 0, y: 10 }}
      transition={{ duration: 0.28 }}
    >
      <div className="max-w-3xl">
        {eyebrow ? <p className="mb-2 text-xs font-medium uppercase text-cyan-200/80">{eyebrow}</p> : null}
        <h1 className="text-2xl font-semibold text-white md:text-3xl">{title}</h1>
        {description ? <p className="mt-2 text-sm leading-6 text-slate-400 md:text-base">{description}</p> : null}
      </div>
      {actions ? <div className="flex flex-wrap gap-2">{actions}</div> : null}
    </motion.div>
  );
}
