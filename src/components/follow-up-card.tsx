import Link from "next/link";
import { ActionForm } from "@/components/action-form";
import { ContactButtons } from "@/components/contact-buttons";
import { closeFollowUp } from "@/lib/api/clients";
import { formatDate, todayInIndia } from "@/lib/dates";
import { text } from "@/lib/text";

/** One waiting follow-up: when it's due, its note, one tap to call or WhatsApp, and Done. */
export function FollowUpCard({ followUp, clientName, phone, closedBefore }: {
  followUp: { id: string; client_id: string; due_on: string; note: string | null };
  clientName?: string;
  phone?: string | null;
  /** On the "next follow-up" screen: how many were closed already, so Done reads "Close this too". */
  closedBefore?: number;
}) {
  const today = todayInIndia();
  const overdue = followUp.due_on < today;
  return (
    <div className={`flex flex-col gap-2 rounded-lg border p-3 ${overdue ? "border-red-600 dark:border-red-400" : "border-current/20"}`}>
      {clientName && (
        <Link href={`/clients/${followUp.client_id}`} className="text-lg font-semibold underline">{clientName}</Link>
      )}
      <p className={overdue ? "font-semibold text-red-700 dark:text-red-400" : "font-medium"}>
        {overdue
          ? `${text.clients.overdue}: ${formatDate(followUp.due_on)}`
          : followUp.due_on === today ? text.clients.dueToday : `${text.clients.due}: ${formatDate(followUp.due_on)}`}
      </p>
      {followUp.note && <p>{followUp.note}</p>}
      {phone && <ContactButtons clientId={followUp.client_id} phone={phone} />}
      <ActionForm action={closeFollowUp} submit={closedBefore === undefined ? text.clients.done : text.clients.closeToo} secondary>
        <input type="hidden" name="followUpId" value={followUp.id} />
        <input type="hidden" name="clientId" value={followUp.client_id} />
        {closedBefore !== undefined && <input type="hidden" name="closedBefore" value={closedBefore} />}
      </ActionForm>
    </div>
  );
}
