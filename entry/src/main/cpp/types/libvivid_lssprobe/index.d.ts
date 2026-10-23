/**
 * Diagnostic bridge to Nikon's `libLsSec-jni.so`.
 *
 * The device refuses to execute arbitrary files from the shell domain, so the
 * library is loaded inside the app sandbox instead. `probeLss` feeds it the
 * real captured session values and returns the library's own report, including
 * the shared-root index it resolves and the plaintext it decrypts.
 *
 * Remove once the credential decryption is wired and verified.
 */

/** Run the probe against the library at `libPath`; returns a text report. */
export function probeLss(libPath: string): string;
