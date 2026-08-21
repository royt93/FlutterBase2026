# AppLovin's bundled IAB OMID lib ships consumer rules referencing Amazon's
# optional Privacy Pass attestation classes, which aren't on the classpath
# here (this app doesn't use Amazon Privacy Pass) — R8 only warns, doesn't
# need to keep code that never runs.
-dontwarn com.amazon.privacypass.**
