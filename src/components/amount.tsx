"use client";

import { useState } from "react";
import { inputStyle } from "@/components/ui";
import { text } from "@/lib/text";

const signStyle = (on: boolean) =>
  `w-12 shrink-0 rounded-lg border border-current/30 text-xl font-semibold ${on ? "bg-foreground text-background" : ""}`;

/**
 * One typed figure, with an optional + or −, and zero as a single tick
 * (CLAUDE.md section 9). The tick is never on by itself: a figure left empty
 * reaches the server empty, and is never turned into zero (decision 2.24).
 */
export function Amount({ name, placeholder, zeroLabel, saved, signed }: {
  name: string;
  placeholder: string;
  zeroLabel: string;
  saved?: string | null;
  signed?: boolean;
}) {
  const figure = saved ?? "";
  const savedAsZero = figure !== "" && Number(figure) === 0;
  const [isZero, setIsZero] = useState(savedAsZero);
  const [isMinus, setIsMinus] = useState(figure.startsWith("-"));
  const [amount, setAmount] = useState(savedAsZero ? "" : figure.replace("-", ""));
  const value = isZero ? "0" : amount && isMinus ? `-${amount}` : amount;

  return (
    <div className="flex flex-col gap-2">
      {!isZero && (
        <div className="flex gap-2">
          {signed && (
            <>
              <button type="button" data-change aria-pressed={!isMinus} aria-label={text.rates.plus}
                className={signStyle(!isMinus)} onClick={() => setIsMinus(false)}>+</button>
              <button type="button" data-change aria-pressed={isMinus} aria-label={text.rates.minus}
                className={signStyle(isMinus)} onClick={() => setIsMinus(true)}>−</button>
            </>
          )}
          <input id={name} type="text" inputMode="decimal" placeholder={placeholder} className={`${inputStyle} min-w-0`}
            value={amount} onChange={(e) => setAmount(e.target.value)} />
        </div>
      )}
      <label className="flex min-h-11 items-center gap-2">
        <input type="checkbox" className="size-5" checked={isZero} onChange={(e) => setIsZero(e.target.checked)} />
        {zeroLabel}
      </label>
      <input type="hidden" name={name} value={value} />
    </div>
  );
}

type District = { id: string; name: string; stateName: string };

/** Only the districts he sells in, added one at a time, so the list stays short. */
export function AreaDifferences({ districts, saved, placeholder }: {
  districts: District[];
  saved: Record<string, string>;
  placeholder: string;
}) {
  const [added, setAdded] = useState(() => districts.filter((d) => d.id in saved).map((d) => d.id));
  const rows = added.flatMap((id) => districts.filter((d) => d.id === id));
  const left = districts.filter((d) => !added.includes(d.id));

  return (
    <>
      {rows.length === 0 && <p className="text-sm">{text.rates.noDistricts}</p>}
      {rows.map((d) => (
        <div key={d.id} className="flex flex-col gap-2 border-t border-current/15 pt-3">
          <div className="flex items-center justify-between gap-3">
            <label htmlFor={`area_${d.id}`} className="font-medium">{text.common.districtOf(d.name, d.stateName)}</label>
            <button type="button" data-change className="shrink-0 rounded-lg border border-current/40 px-3 py-2 text-sm"
              onClick={() => setAdded(added.filter((id) => id !== d.id))}>{text.rates.removeDistrict}</button>
          </div>
          <Amount name={`area_${d.id}`} placeholder={placeholder} zeroLabel={text.rates.sameRate} saved={saved[d.id]} signed />
        </div>
      ))}
      {left.length > 0 && (
        <select aria-label={text.rates.addDistrict} value="" className={inputStyle}
          onChange={(e) => setAdded([...added, e.target.value])}>
          <option value="" disabled>{text.rates.addDistrict}</option>
          {left.map((d) => <option key={d.id} value={d.id}>{text.common.districtOf(d.name, d.stateName)}</option>)}
        </select>
      )}
    </>
  );
}
