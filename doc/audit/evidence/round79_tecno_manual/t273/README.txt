T273 manual device run of DemoCrlProvider (example/lib/demo_crl_provider.dart) on TECNO KJ7 (Android 14), 2026-11-13.
Temp copy of the example in /tmp (repo untouched) with its own package id com.roy.admobwrapper.t273run, uninstalled afterwards; throwaway signing key, keys DA/DB and a CRL revoking DA (deleted afterwards).
Changes in the COPY only: example public key replaced; `DemoCrlProvider(allowInsecureHttp: true)` at the call site; android:usesCleartextTraffic="true" in the copy's manifest.
Built with --dart-define=VIP_CRL_URL=http://<mac-lan-ip>:8768/crl.txt so the URL reached the provider through kDemoCrlUrl exactly as the README describes.
A one-file python http.server served only crl.txt on the Mac LAN address; stopped afterwards (no process, no listener). LAN IPs redacted in the saved server log.

Observed (provider_and_redeem_events.txt, http_server_access_log.txt, screenshots):
  - Pressing "Refresh revocation list (CRL)": the server saw a GET /crl.txt from the PHONE's address (the other line in the log is my own curl self-check) and the SDK logged
    "refreshRevocationList: applied 1 revoked kid(s)". The snackbar said "Revocation list refresh finished - see the log for the result" (s_demo_provider_snackbar.png).
  - Key DA (listed in the CRL): "kid DA is revoked" / VipRedeemStatus.invalid error=key revoked.
  - Key DB (not listed): "redeemSignedKey ok kid=DB +24h". The DB entry was removed afterwards.
  - Driven with doc/audit/tools/adb_smoke.sh (the typed keys come from files; this script's redact step was not needed because only filtered flutter lines were saved). No FATAL, no ANR.

NOT shown:
  - The provider's own "[example] ..." debug lines are not in the saved log: DemoCrlProvider only logs on the no-URL / refusal / non-200 branches, so a successful fetch logs nothing from the example itself.
    The successful fetch is evidenced by the server log + the SDK's "applied 1 revoked kid(s)".
  - The default HTTPS path of DemoCrlProvider against a real CA was not exercised (insecure HTTP was enabled in the copy); that path is covered by the loopback unit tests, not by this run.
  - One device, one run, LAN only.
