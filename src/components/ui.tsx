import Link from "next/link";
import type { ReactNode } from "react";
import { text } from "@/lib/text";

export const inputStyle = "w-full rounded-lg border border-current/30 bg-transparent px-3 py-3 text-lg";

export function Screen({ title, back, children }: { title: string; back?: string; children: ReactNode }) {
  return (
    <main className="mx-auto flex w-full max-w-md flex-1 flex-col gap-5 px-4 py-6">
      {back && <Link href={back} className="self-start py-3 underline">{text.common.back}</Link>}
      <h1 className="text-2xl font-bold">{title}</h1>
      {children}
    </main>
  );
}

export function Card({ children }: { children: ReactNode }) {
  return <section className="flex flex-col gap-3 rounded-xl border border-current/20 p-4">{children}</section>;
}

export function Field({ label, htmlFor, children }: { label: string; htmlFor: string; children: ReactNode }) {
  return (
    <div className="flex flex-col gap-1">
      <label htmlFor={htmlFor} className="font-medium">{label}</label>
      {children}
    </div>
  );
}

/** Districts always show their level and parent (CLAUDE.md section 7). */
export function DistrictSelect({ id, name, districts, value }: {
  id: string;
  name: string;
  districts: { id: string; name: string; stateName: string }[];
  value?: string;
}) {
  return (
    <select id={id} name={name} required defaultValue={value ?? ""} className={inputStyle}>
      <option value="" disabled>{text.common.choose}</option>
      {districts.map((d) => <option key={d.id} value={d.id}>{text.common.districtOf(d.name, d.stateName)}</option>)}
    </select>
  );
}
