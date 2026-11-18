import Foundation

enum TtsCatalogFixture {
    static let json = #"""
    {"schema_version":3,"providers":[
      {"provider":"provider-a","runtime":"runtime-a","targets":["macos"]}
    ],"entries":[
      {"identity":{"model_id":"model-a","provider":"provider-a","runtime":"runtime-a","model_revision":"sha-a"},
       "language_evidence":{"routing_tags":["pt"],"exact_tags":[]},
       "compatibility":{"platforms":["Macos"],"runtime_available":true},
       "distribution":{"artifacts":[{"name":"model.onnx","sha256":"checksum-a"}]}},
      {"identity":{"model_id":"model-b","provider":"provider-a","runtime":"runtime-a","model_revision":"sha-b"},
       "language_evidence":{"routing_tags":["en"],"exact_tags":[]},
       "compatibility":{"platforms":["Macos"],"runtime_available":true},
       "distribution":{"artifacts":[]}}
    ]}
    """#

    static var data: Data { Data(json.utf8) }
}
