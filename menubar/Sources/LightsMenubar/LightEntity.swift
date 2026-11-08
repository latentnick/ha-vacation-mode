import Foundation

struct LightEntity: Identifiable, Hashable {
    var id: String { entityId }
    let entityId: String
    let friendlyName: String
}
