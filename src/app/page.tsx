import Link from "next/link";
import { redirect } from "next/navigation";
import { logOut } from "@/lib/api/auth";
import { getMe } from "@/lib/api/queries";
import { formatPhone } from "@/lib/phone";
import { text } from "@/lib/text";

const linkStyle = "rounded-lg bg-foreground px-8 py-3 text-center text-lg font-semibold text-background";

export default async function Home() {
  const me = await getMe();
  if (me && !me.account && !me.isAdmin) redirect("/signup");

  return (
    <main className="flex flex-1 flex-col items-center justify-center gap-3 px-4 py-16 text-center">
      <h1 className="text-5xl font-bold tracking-tight">{text.app.name}</h1>
      <p className="max-w-xs text-lg">{text.app.tagline}</p>
      {me ? (
        <>
          <p>{text.home.loggedInAs} {formatPhone(me.phone)}</p>
          {me.account && (
            <p>
              {text.nav.yourRole} {text.roles[me.role]}
              {me.pendingRole && ` (${text.roles[me.pendingRole]}: ${text.nav.rolePending})`}
            </p>
          )}
          <nav className="mt-3 flex w-full max-w-xs flex-col gap-3">
            {me.isAdmin && <Link href="/admin" className={linkStyle}>{text.nav.admin}</Link>}
            {me.account && <Link href="/seller" className={linkStyle}>{text.nav.sellerSetup}</Link>}
          </nav>
          <form action={logOut}>
            <button type="submit" className="px-4 py-3 underline">{text.home.logOut}</button>
          </form>
        </>
      ) : (
        <Link href="/login" className={`mt-3 ${linkStyle}`}>{text.home.logIn}</Link>
      )}
    </main>
  );
}
