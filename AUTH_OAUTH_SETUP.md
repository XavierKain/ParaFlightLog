# Sign in with Apple / Google / Facebook — setup

The app side is done (`AuthService.signIn(with:)` + `OAuthSignInButtons`, offered on
Settings › Account and in the inline sign-in form of the condition-report sheet).
**Nothing works until the three providers are enabled in the Appwrite console**, and
that needs credentials only you can create.

Until a provider is enabled, tapping its button opens an Appwrite error page; closing
it is reported to the app as a cancellation, so the UI just goes quiet. No crash, no
red line — but also no session.

Reference values:

| | |
|---|---|
| Appwrite project | `69524ce30037813a6abb` (region `fra`) |
| Redirect / callback URI | `https://fra.cloud.appwrite.io/v1/account/sessions/oauth2/callback/{provider}/69524ce30037813a6abb` |
| App bundle ID | `com.xavierkain.ParaFlightLog2` |
| Apple Team ID | `S96H22CQ8W` |

Replace `{provider}` with `apple`, `google` or `facebook` — each provider gets its own
redirect URI.

---

## 0. Register the app as an Apple platform (do this first)

The console currently lists two Apple platforms, both `com.xavierkain.ParaFlightLog`,
but the app ships as **`com.xavierkain.ParaFlightLog2`**. It has not caused trouble so
far, but it is one line of insurance:

> Appwrite console → Overview → **Add platform** → Apple → iOS
> Name `SoarX iOS`, Bundle ID `com.xavierkain.ParaFlightLog2`

## 1. Apple

Apple is the one App Review actually cares about: offering Google/Facebook login
without Sign in with Apple is a rejection under guideline 4.8.

**Apple Developer portal** (developer.apple.com → Certificates, Identifiers & Profiles):

1. **Identifiers → the App ID `com.xavierkain.ParaFlightLog2`** → enable the
   *Sign In with Apple* capability → Save.
2. **Identifiers → + → Services IDs**. Description `SoarX Sign In`, identifier
   `com.xavierkain.ParaFlightLog2.signin` (it must differ from the bundle ID).
   Enable *Sign In with Apple* → **Configure**:
   - Primary App ID: `com.xavierkain.ParaFlightLog2`
   - Domains and Subdomains: `fra.cloud.appwrite.io`
   - Return URLs: `https://fra.cloud.appwrite.io/v1/account/sessions/oauth2/callback/apple/69524ce30037813a6abb`
3. **Keys → +**. Name `SoarX Sign In Key`, tick *Sign in with Apple*, configure it
   against the primary App ID, register, **download the `.p8`** (one download only —
   keep it next to the ASC keys in `/home/xavier/xklip/secrets/`). Note the Key ID.

**Appwrite console** → Auth → Settings → OAuth2 Providers → **Apple**:

- App ID: `com.xavierkain.ParaFlightLog2.signin` (the *Services* ID, not the bundle ID)
- Secret: the console shows the exact fields it wants — the Key ID, the Team ID
  (`S96H22CQ8W`), the bundle ID and the contents of the `.p8`.

Note: this is Apple's **web** Sign in with Apple, hosted in an
`ASWebAuthenticationSession`, not the native black button. Appwrite has no endpoint
that trades an Apple ID token for a session, so a native button would mean writing an
Appwrite Function to do the token exchange. Worth doing before a public release if the
web sheet feels heavy; fine for the friends beta.

## 2. Google

**Google Cloud console** (console.cloud.google.com) → pick or create a project:

1. *APIs & Services → OAuth consent screen*: External, app name `SoarX`, support email,
   scopes `email` + `profile`. While it stays in *Testing*, only the test users you
   list can sign in — add your beta friends, or publish the app.
2. *APIs & Services → Credentials → Create credentials → OAuth client ID* →
   **Web application** (yes, *Web*, not iOS: the flow goes through Appwrite's server):
   - Authorized redirect URI:
     `https://fra.cloud.appwrite.io/v1/account/sessions/oauth2/callback/google/69524ce30037813a6abb`

**Appwrite console** → Auth → OAuth2 Providers → **Google**: paste the Client ID and
Client secret.

## 3. Facebook

**Meta for Developers** (developers.facebook.com/apps) → Create app → *Authenticate and
request data from users with Facebook Login* → Consumer:

1. Add the **Facebook Login** product.
2. Facebook Login → Settings → Valid OAuth Redirect URIs:
   `https://fra.cloud.appwrite.io/v1/account/sessions/oauth2/callback/facebook/69524ce30037813a6abb`
3. App settings → Basic: note the App ID and App secret.
4. The app must be **Live** (not Development) for anyone but its listed developers/testers
   to sign in. Going live needs a privacy-policy URL.

**Appwrite console** → Auth → OAuth2 Providers → **Facebook**: App ID + App secret.

Facebook can return a user **without an email** (the pilot can uncheck it). The app
handles this — Account then shows the Facebook name instead of an email — but that
pilot's account can never be matched by email to an existing one.

---

## How accounts link up

Appwrite attaches an OAuth session to an **existing account when the email matches**.
So a pilot who signed up with email + password and later taps "Continue with Google"
keeps the same `userId`, and therefore the same spots, reports, kudos and cloud backup.

Two ways this quietly makes a *second* account instead:

- Apple's **Hide My Email** mints a `@privaterelay.appleid.com` address. Different
  email → different account, with an empty logbook.
- Facebook without email permission (see above).

There is no in-app "link my accounts" flow, and Appwrite has no merge. If a beta tester
ends up with a split logbook, the way out is: sign in to the old account, Back Up Now,
sign in to the new one, Restore Backup.

## Test checklist

- [ ] Continue with Apple → account created → Settings › Account shows "Signed in with Apple"
- [ ] Continue with Google, then Facebook, same
- [ ] Close the web sheet halfway → back to the form, **no error message**
- [ ] Sign out, sign back in with the same provider → same `userId` (check in the
      Appwrite console, the user count must not grow)
- [ ] An account created with email + password, then "Continue with Google" on the same
      address → one user, not two
- [ ] Report conditions while signed out → the three buttons are in the sheet too, and
      signing in there lands straight on the report form
- [ ] Push still registers after an OAuth sign-in (`account.createPushTarget` runs from
      `PushService.onSignedIn()`)

## If the web sheet opens but never closes

The SDK builds its `ASWebAuthenticationSession` with an explicit
`callbackURLScheme` (`appwrite-callback-69524ce30037813a6abb`), which is enough to
intercept the redirect — so the app deliberately does **not** declare that scheme in
`CFBundleURLTypes`. It can't, cheaply: the iOS target has no `Info.plist` file at all
(`GENERATE_INFOPLIST_FILE = YES`, everything comes from `INFOPLIST_KEY_*` build
settings, and `CFBundleURLTypes` has no `INFOPLIST_KEY_` form).

If a first device test shows the provider page succeeding but the sheet hanging open,
that assumption is wrong and the fix is: create a real `ParaFlightLog/Info.plist`, point
`INFOPLIST_FILE` at it, and add

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array><string>appwrite-callback-69524ce30037813a6abb</string></array>
  </dict>
</array>
```

## Known gaps

- **Brand assets**: the buttons use SF Symbols (`apple.logo`, `g.circle.fill`,
  `f.circle.fill`). Google and Facebook both require their official logo and wording on
  sign-in buttons — swap in the real assets before a public App Store release.
- **Account deletion** is still missing, and it is required by App Store guideline
  5.1.1(v) for any app that creates accounts.
- No password reset, no email verification.
