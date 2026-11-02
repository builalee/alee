import { Field, inputStyle } from "@/components/ui";
import type { Client } from "@/lib/api/queries";
import { text } from "@/lib/text";

const types = ["distributor", "dealer", "builder", "retailer"] as const;

/** A customer's details, for adding one and for editing one. */
export function ClientFields({ client, districts }: {
  client?: Client;
  districts: { id: string; name: string; stateName: string }[];
}) {
  return (
    <>
      {client && <input type="hidden" name="id" value={client.id} />}
      <Field label={text.clients.name} htmlFor="name">
        <input id="name" name="name" required maxLength={100} defaultValue={client?.name ?? ""} className={inputStyle} />
      </Field>
      <Field label={text.clients.phone} htmlFor="phone">
        <input id="phone" name="phone" type="tel" inputMode="numeric" autoComplete="off"
          defaultValue={client?.phone?.slice(3) ?? ""} className={inputStyle} />
      </Field>
      <Field label={text.clients.area} htmlFor="regionId">
        <select id="regionId" name="regionId" defaultValue={client?.region_id ?? ""} className={inputStyle}>
          <option value="">{text.common.choose}</option>
          {districts.map((d) => <option key={d.id} value={d.id}>{text.common.districtOf(d.name, d.stateName)}</option>)}
        </select>
      </Field>
      <Field label={text.clients.type} htmlFor="type">
        <select id="type" name="type" defaultValue={client?.client_type ?? ""} className={inputStyle}>
          <option value="">{text.common.choose}</option>
          {types.map((t) => <option key={t} value={t}>{text.clients.types[t]}</option>)}
        </select>
      </Field>
      <Field label={text.clients.note} htmlFor="note">
        <textarea id="note" name="note" rows={3} maxLength={2000} defaultValue={client?.note ?? ""} className={inputStyle} />
      </Field>
      <p className="text-sm">{text.clients.noteHint}</p>
    </>
  );
}
