import Foundation

extension TrainCar {
    /// A deployment by id, else a workspace's latest one (cars are newest first).
    static func find(_ text: String, in cars: [TrainCar]) -> TrainCar? {
        cars.first { $0.id == text } ?? cars.first { $0.workspace.caseInsensitiveCompare(text) == .orderedSame }
    }
}

struct TrainCar: Identifiable, Hashable {
    let id: String
    let workspace: String
    let kind: String
    let app: String
    let version: String
    let branch: String
    let by: String
    let at: Date
    let duration: TimeInterval?
    let status: String
    let error: String
}
