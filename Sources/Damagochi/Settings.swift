import Combine
import Foundation

enum Animal: String, CaseIterable, Identifiable {
    case cat, dog, rabbit, hamster, fox, panda, pig, chick

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cat: return "고양이"
        case .dog: return "강아지"
        case .rabbit: return "토끼"
        case .hamster: return "햄스터"
        case .fox: return "여우"
        case .panda: return "판다"
        case .pig: return "돼지"
        case .chick: return "병아리"
        }
    }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    /// 화면에 표시되는 펫 크기(pt). 32px 격자의 정수배라 도트가 선명하게 유지된다.
    static let sizes = [64, 96]

    @Published var animal: Animal {
        didSet { UserDefaults.standard.set(animal.rawValue, forKey: "animal") }
    }

    @Published var size: Int {
        didSet { UserDefaults.standard.set(size, forKey: "size") }
    }

    private init() {
        let d = UserDefaults.standard
        animal = Animal(rawValue: d.string(forKey: "animal") ?? "") ?? .cat
        let s = d.integer(forKey: "size")
        size = Settings.sizes.contains(s) ? s : 96
    }
}
