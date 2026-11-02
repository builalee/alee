"use client";

import { useState } from "react";
import { inputStyle } from "@/components/ui";
import { addAmounts } from "@/lib/money";
import { text } from "@/lib/text";

type Line = {
  brand_id: string;
  line_name: string;
  last_base_rate: string | null;
  current_unit: "tonne" | "kg";
  move_status: "move" | "needs_rate" | "unit_changed" | "not_quoting";
};

const signStyle = (on: boolean) =>
  `w-12 shrink-0 rounded-lg border border-current/30 text-xl font-semibold ${on ? "bg-foreground text-background" : ""}`;

/**
 * Today's basic rate for each brand line, yesterday's filled in. "Move every
 * rate" fills each box with yesterday's rate moved by one amount; the boxes
 * are what goes to the confirmation screen, so what he checks is what is
 * published.
 */
export function PublishForm({ lines }: { lines: Line[] }) {
  const open = lines.filter((l) => l.move_status !== "not_quoting");
  const [rates, setRates] = useState<Record<string, string>>(() =>
    Object.fromEntries(open.map((l) => [l.brand_id, l.move_status === "move" ? String(Number(l.last_base_rate)) : ""])));
  const [isMinus, setIsMinus] = useState(false);
  const [by, setBy] = useState("");
  const canMove = open.some((l) => l.move_status === "move");

  const moveAll = () => {
    const amount = `${isMinus ? "-" : ""}${by.trim()}`;
    setRates((current) => ({
      ...current,
      ...Object.fromEntries(open.filter((l) => l.move_status === "move").map((l) => [
        l.brand_id, addAmounts(String(Number(l.last_base_rate)), amount) ?? current[l.brand_id],
      ])),
    }));
  };

  return (
    <form action="/seller/publish/confirm" method="get" className="flex flex-col gap-4">
      {canMove && (
        <section className="flex flex-col gap-2 rounded-xl border border-current/20 p-4">
          <label htmlFor="by" className="font-medium">{text.publish.moveAll}</label>
          <div className="flex gap-2">
            <button type="button" aria-pressed={!isMinus} className={signStyle(!isMinus)} onClick={() => setIsMinus(false)}>+</button>
            <button type="button" aria-pressed={isMinus} className={signStyle(isMinus)} onClick={() => setIsMinus(true)}>−</button>
            <input id="by" type="text" inputMode="decimal" className={`${inputStyle} min-w-0`} value={by}
              onChange={(e) => setBy(e.target.value)} />
            <button type="button" onClick={moveAll} className="shrink-0 rounded-lg border border-current/40 px-3 font-medium">
              {text.publish.apply}
            </button>
          </div>
        </section>
      )}

      {lines.map((l) => (
        <section key={l.brand_id} className="flex flex-col gap-2 rounded-xl border border-current/20 p-4">
          <h2 className="font-semibold">{l.line_name}</h2>
          {l.move_status === "not_quoting" ? (
            <p>{text.publish.notQuoting}</p>
          ) : (
            <>
              {l.move_status === "needs_rate" && <p className="text-sm">{text.publish.needsRate}</p>}
              {l.move_status === "unit_changed" && <p className="text-sm">{text.publish.unitChanged}</p>}
              <label htmlFor={`rate_${l.brand_id}`} className="font-medium">
                {text.publish.basicRate}, {text.publish.per} {text.products[l.current_unit]}
              </label>
              <input id={`rate_${l.brand_id}`} name={`rate_${l.brand_id}`} type="text" inputMode="decimal" required
                className={`${inputStyle} text-2xl font-semibold`} value={rates[l.brand_id] ?? ""}
                onChange={(e) => setRates({ ...rates, [l.brand_id]: e.target.value })} />
            </>
          )}
        </section>
      ))}

      <button type="submit" className="w-full rounded-lg bg-foreground px-3 py-3 text-lg font-semibold text-background">
        {text.publish.next}
      </button>
    </form>
  );
}
