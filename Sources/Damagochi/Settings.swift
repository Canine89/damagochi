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

    /// 사용량 말풍선을 띄우는 주기(분). 0 이면 끔.
    static let bubbleIntervals = [0, 5, 10, 30, 60]

    @Published var bubbleMinutes: Int {
        didSet { UserDefaults.standard.set(bubbleMinutes, forKey: "bubbleMinutes") }
    }

    /// 동물마다 정해진 성격 (동물 이름 → 성격 이름). 처음 실행할 때 무작위로 뽑는다.
    @Published var personalities: [String: String] {
        didSet { UserDefaults.standard.set(personalities, forKey: "personalities") }
    }

    func personality(for animal: Animal) -> Personality.Kind {
        Personality.Kind(rawValue: personalities[animal.rawValue] ?? "") ?? .playful
    }

    func setPersonality(_ kind: Personality.Kind, for animal: Animal) {
        personalities[animal.rawValue] = kind.rawValue
    }

    /// 지금과 다른 성격을 무작위로 뽑는다.
    func rollPersonality(for animal: Animal) {
        let current = personality(for: animal)
        let others = Personality.Kind.allCases.filter { $0 != current }
        setPersonality(others.randomElement() ?? current, for: animal)
    }

    /// 울타리: 켜면 펫이 fenceMin...fenceMax (화면 x 좌표) 안에서만 움직인다.
    @Published var fenceEnabled: Bool {
        didSet { UserDefaults.standard.set(fenceEnabled, forKey: "fenceEnabled") }
    }

    var fenceMin: Double {
        didSet { UserDefaults.standard.set(fenceMin, forKey: "fenceMin") }
    }

    var fenceMax: Double {
        didSet { UserDefaults.standard.set(fenceMax, forKey: "fenceMax") }
    }

    private init() {
        let d = UserDefaults.standard
        var saved = d.dictionary(forKey: "personalities") as? [String: String] ?? [:]
        for a in Animal.allCases where Personality.Kind(rawValue: saved[a.rawValue] ?? "") == nil {
            saved[a.rawValue] = Personality.Kind.allCases.randomElement()!.rawValue
        }
        personalities = saved
        d.set(saved, forKey: "personalities")
        fenceEnabled = d.bool(forKey: "fenceEnabled")
        fenceMin = d.double(forKey: "fenceMin")
        fenceMax = d.double(forKey: "fenceMax")
        bubbleMinutes = d.object(forKey: "bubbleMinutes") == nil ? 10 : d.integer(forKey: "bubbleMinutes")
        animal = Animal(rawValue: d.string(forKey: "animal") ?? "") ?? .cat
        let s = d.integer(forKey: "size")
        size = Settings.sizes.contains(s) ? s : 96
    }
}
