import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";

/**
 * The one way server code reaches Supabase (CLAUDE.md rule 1). Screens never
 * import this; they call the API layer in src/lib/api. It acts as the
 * logged-in person, so Row Level Security decides what comes back. The secret
 * key is deliberately not used.
 */
export async function createClient() {
  const cookieStore = await cookies();

  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
    {
      cookies: {
        getAll: () => cookieStore.getAll(),
        setAll: (cookiesToSet) => {
          try {
            cookiesToSet.forEach(({ name, value, options }) => cookieStore.set(name, value, options));
          } catch {
            // Pages cannot write cookies. src/proxy.ts keeps the login fresh instead.
          }
        },
      },
    },
  );
}
