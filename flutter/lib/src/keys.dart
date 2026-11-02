// Ed25519 public keys the SDK trusts, by kid. Raw 32-byte keys, base64.
// Rotating: add the new kid here and ship an SDK release BEFORE the server
// starts signing with it. Mirrors packages/core/src/keys.ts.

const Map<String, String> mealioKeys = <String, String>{
  'k1': 'AYOlGPRNr9JDsN2aKQ/WAVe0P2pUNTCzVM0C0uiuAdQ=',
};
