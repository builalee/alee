import Link from "next/link";
import { currentLoginPhone, logOut } from "@/lib/api/auth";
import { formatPhone } from "@/lib/phone";
import { text } from "@/lib/text";

export default async function Home() {
  const phone = await currentLoginPhone();

  return (
    <main className="flex flex-1 flex-col items-center justify-center gap-3 px-4 py-16 text-center">
      <h1 className="text-5xl font-bold tracking-tight">{text.app.name}</h1>
      <p className="max-w-xs text-lg">{text.app.tagline}</p>
      {phone ? (
        <>
          <p>{text.home.loggedInAs} {formatPhone(phone)}</p>
          <form action={logOut}>
            <button type="submit" className="px-4 py-3 underline">{text.home.logOut}</button>
          </form>
        </>
      ) : (
        <Link href="/login" className="mt-3 rounded-lg bg-foreground px-8 py-3 text-lg font-semibold text-background">
          {text.home.logIn}
        </Link>
      )}
    </main>
  );
}
