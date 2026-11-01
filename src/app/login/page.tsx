import { redirect } from "next/navigation";
import { currentLoginPhone } from "@/lib/api/auth";
import { text } from "@/lib/text";
import { LoginForm } from "./login-form";

export const metadata = { title: `${text.login.title} · ${text.app.name}` };

export default async function LoginPage() {
  if (await currentLoginPhone()) redirect("/");

  return (
    <main className="flex flex-1 flex-col items-center justify-center gap-6 px-4 py-16">
      <h1 className="text-5xl font-bold tracking-tight">{text.app.name}</h1>
      <LoginForm />
    </main>
  );
}
