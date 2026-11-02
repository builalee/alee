"use client";

import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import { logContact } from "@/lib/api/clients";
import { callLink, whatsappLink } from "@/lib/phone";
import { text } from "@/lib/text";

/**
 * One tap to call or WhatsApp a customer. The tap is logged; a call closes his
 * due and overdue follow-ups, and ALEE then asks for the next date (decision 11.1).
 */
export function ContactButtons({ clientId, phone }: { clientId: string; phone: string }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [error, setError] = useState<string | null>(null);

  const contact = (kind: "call" | "whatsapp") => {
    // Opened straight away, inside the tap, so the phone doesn't block it.
    if (kind === "call") window.location.href = callLink(phone);
    else window.open(whatsappLink(phone), "_blank", "noopener");
    start(async () => {
      const result = await logContact(clientId, kind);
      if ("error" in result) return setError(result.error);
      if (kind === "call") router.push(`/clients/${clientId}/next?closed=${result.closed}`);
      else router.refresh();
    });
  };

  return (
    <div className="flex flex-col gap-2">
      <div className="grid grid-cols-2 gap-2">
        <button type="button" disabled={pending} onClick={() => contact("call")}
          className="rounded-lg bg-foreground px-3 py-3 text-lg font-semibold text-background disabled:opacity-50">
          {text.clients.call}
        </button>
        <button type="button" disabled={pending} onClick={() => contact("whatsapp")}
          className="rounded-lg border border-current/40 px-3 py-3 text-lg font-semibold disabled:opacity-50">
          {text.clients.whatsapp}
        </button>
      </div>
      {error && <p role="alert" className="text-red-700 dark:text-red-400">{error}</p>}
    </div>
  );
}
