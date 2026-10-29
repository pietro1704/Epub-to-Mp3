# Piper configuration fixtures

JSON fixtures retain the complete parsed contents of the catalog's pinned Cadu
and Jeff configurations, serialized compactly for test readability. Both declare
one speaker and omit `speaker_id_map`. No model weights are included.

Source: `rhasspy/piper-voices`, revision
`c10ece1aade47bb51c153c893d14e5bf8e5b7117`, paths
`pt/pt_BR/{cadu,jeff}/medium/pt_BR-{cadu,jeff}-medium.onnx.json`.
Original downloaded configuration SHA-256:

- Cadu: `5fe03aa3d4901880554905b12075713cd552598c8a350455a1ec73f8b4e6be19`
- Jeff: `7bf8145b572b36806f5ce0f1d3322b6711975bc7d0473e8d36fced4a9ec0030d`

Catalog provenance and model license metadata remain in converter-core's model
catalog. Whitespace normalization changes fixture byte hashes but not JSON values.
