/*
 * Mail workspace mount point (task 04). The shell auto-discovers this file via
 * import.meta.glob and mounts it at /mail (and, detached, at /detach/mail).
 * See ../README.md for the mounting contract.
 */

import type { WorkspaceProps } from "../contract";
import { DraftWorkbench } from "./DraftWorkbench";

export default function MailWorkspace({ api, detached }: WorkspaceProps) {
  return <DraftWorkbench api={api} detached={detached} />;
}
