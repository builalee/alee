"use client";

import { useState } from "react";
import { inputStyle } from "@/components/ui";
import { addAmounts, formatRupees, formatSignedRupees, readAmount } from "@/lib/money";
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
const buttonStyle = "rounded-lg border border-current/40 px-3 py-3 font-medium";

/**
 * Today's basic rate for each brand line, yesterday's filled in. "Move every
 * rate" asks first, then fills each box with yesterday's rate moved by one
 * amount; the boxes are what goes to the confirmation screen, so what he
 * checks is what is published. Once today's rates are published the boxes
 * are locked until he taps "Change today's rates".
 */
export function PublishForm({ lines, publishedToday }: { lines: Line[]; publishedToday: boolean }) {
  const open = lines.filter((l) => l.move_status !== "not_quoting");
  const [rates, setRates] = useState<Record<string, string>>(() =>
    Object.fromEntries(open.map((l) => [l.brand_id, l.move_status === "move" ? String(Number(l.last_base_rate)) : ""])));
  const [locked, setLocked] = useState(publishedToday);
  const [isMinus, setIsMinus] = useState(false);
  const [by, setBy] = useState("");
  const [asking, setAsking] = useState<string | null>(null);
  const [moved, setMoved] = useState<string | null>(null);
  const [moveError, setMoveError] = useState(false);
  const canMove = open.some((l) => l.move_status === "move");

  const askToMove = () => {
    const typed = readAmount(by);
    setMoved(null);
    if (typed === "empty" || typed === "invalid" || Number(typed) === 0) return setMoveError(true);
    setMoveError(false);
    setAsking(`${isMinus ? "-" : ""}${typed}`);
  };

  const moveAll = (amount: string) => {
    setRates((current) => ({
      ...current,
      ...Object.fromEntries(open.filter((l) => l.move_status === "move").map((l) => [
        l.brand_id, addAmounts(String(Number(l.last_base_rate)), amount) ?? current[l.brand_id],
      ])),
    }));
    setAsking(null);
    setMoved(amount);
  };

  if (locked) {
    return (
      <div className="flex flex-col gap-4">
        <p className="font-medium">{text.publish.publishedToday}</p>
        {lines.map((l) => (
          <section key={l.brand_id} className="flex flex-col gap-1 rounded-xl border border-current/20 p-4 opacity-80">
            <h2 className="font-semibold">{l.line_name}</h2>
            {l.move_status === "not_quoting" ? <p>{text.publish.notQuoting}</p> : (
              <p className="text-2xl font-semibold">
                {rates[l.brand_id] ? formatRupees(rates[l.brand_id]) : ""}{" "}
                <span className="text-base font-normal">{text.publish.per} {text.products[l.current_unit]}</span>
              </p>
            )}
          </section>
        ))}
        <button type="button" onClick={() => setLocked(false)} className={`w-full py-3 text-lg ${buttonStyle}`}>
          {text.publish.change}
        </button>
      </div>
    );
  }

  return (
    <form action="/seller/publish/confirm" method="get" className="flex flex-col gap-4">
      {canMove && (
        <section className="flex flex-col gap-2 rounded-xl border border-current/20 p-4">
          <label htmlFor="by" className="font-medium">{text.publish.moveAll}</label>
          <div className="flex gap-2">
            <button type="button" aria-label={text.rates.plus} aria-pressed={!isMinus} className={signStyle(!isMinus)} onClick={() => { setIsMinus(false); setAsking(null); }}>+</button>
            <button type="button" aria-label={text.rates.minus} aria-pressed={isMinus} className={signStyle(isMinus)} onClick={() => { setIsMinus(true); setAsking(null); }}>−</button>
            <input id="by" type="text" inputMode="decimal" className={`${inputStyle} min-w-0`} value={by}
              onChange={(e) => { setBy(e.target.value); setAsking(null); }} />
            <button type="button" onClick={askToMove} className={`shrink-0 ${buttonStyle}`}>{text.publish.apply}</button>
          </div>
          {moveError && <p role="alert" className="text-red-700 dark:text-red-400">{text.publish.moveNumber}</p>}
          {asking && (
            <div role="alertdialog" aria-labelledby="move-ask" className="flex flex-col gap-2 rounded-lg bg-current/5 p-3">
              <p id="move-ask" className="font-medium">{text.publish.moveAsk} {formatSignedRupees(asking)}?</p>
              <div className="grid grid-cols-2 gap-2">
                <button type="button" onClick={() => moveAll(asking)}
                  className="rounded-lg bg-foreground px-3 py-3 font-semibold text-background">{text.publish.moveYes}</button>
                <button type="button" onClick={() => setAsking(null)} className={buttonStyle}>{text.publish.moveCancel}</button>
              </div>
            </div>
          )}
          {moved && (
            <p role="status" className="font-medium text-green-700 dark:text-green-400">
              {text.publish.moved} {formatSignedRupees(moved)}. {text.publish.movedCheck}
            </p>
          )}
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
                onChange={(e) => { setRates({ ...rates, [l.brand_id]: e.target.value }); setMoved(null); }} />
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
