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
    logIn: "Log in",
    logOut: "Log out",
    loggedInAs: "Logged in as",
  },
  login: {
    title: "Log in",
    phoneLabel: "Your mobile number",
    countryCode: "+91",
    sendCode: "Send code",
    sending: "Sending…",
    codeSentTo: "Enter the code for",
    codeLabel: "6-digit code",
    logIn: "Log in",
    checking: "Checking…",
    changeNumber: "Change number",
    invalidPhone: "Enter a 10-digit mobile number.",
    invalidCode: "Enter the 6-digit code.",
    wrongCode: "That code is not right, or it has expired. Try again.",
    couldNotSend: "We could not send a code to this number. Try again.",
    tooManyRequests: "Too many tries. Wait a minute and try again.",
  },
} as const;
