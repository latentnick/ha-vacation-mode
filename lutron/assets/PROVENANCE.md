# Static Caséta LAP bootstrap assets

These three PEM files are data, not executable code. They were extracted using
Python's AST literal parser (without importing/executing the source) from:

https://github.com/gurumitts/pylutron-caseta/blob/1c25f55bef14adf0bac81c2bba43ea4f7e6826b1/src/pylutron_caseta/assets.py

Upstream license: Apache-2.0, retained in LICENSE.pylutron-caseta.
No upstream protocol implementation is bundled or executed.

| File | Upstream constant | SHA-256 (file bytes) |
| --- | --- | --- |
| lap-ca.pem | LAP_CA_PEM | 27456ebeec4f66cd0870c1a8239b443c025bf23f8d14a0bd8288addd4e8f6d54 |
| lap-client.pem | LAP_CERT_PEM | 156b2712da2bc94c519dcce84c51e5adeb14acc23006a362858e9fa227408b75 |
| lap-client-key.pem | LAP_KEY_PEM | 3d859bfb1b3bc0135007a487acbf2d525b92eb39dfc88a816acb8d346a05bf54 |

The bootstrap key is a publicly distributed association credential, NOT the
user's private paired identity. It allows access to the pairing service; a
physical button press authorizes issuance of a new client certificate. Generated
user keys must remain private and must never be committed alongside these files.

Trust policy reference at the same pinned revision: `utils.py` creates a TLS
client context with certificate-chain verification, minimum TLS 1.2, an explicit
CA, and hostname checking disabled. `pairing.py` uses the LAP CA for Caséta pairing,
then verifies the returned credentials with a LEAP ping. This implementation
targets Caséta only; it does not add RA3 trust roots or insecure fallbacks.
