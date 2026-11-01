/**
 * Every word a user sees lives here (CLAUDE.md section 11). Screens read from
 * this file and never hold their own wording, so Marathi and other languages
 * can be added in one place.
 */
export const text = {
  app: {
    name: "ALEE",
    tagline: "Rates and trade records for the steel industry",
  },
  home: {
    comingSoon: "Login opens here soon.",
  },
} as const;
