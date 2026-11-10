import AppKit

/// 동물 한 종의 스프라이트 시트. 32x32 프레임이 가로로 나열돼 있다.
final class SpriteSheet {
    static let grid = 32
    /// 발 아래 비어 있는 줄 수(논리 px). 발이 바닥에 닿도록 창을 이만큼 내린다.
    static let footGap: CGFloat = 2

    let frames: [CGImage]

    init?(animal: Animal) {
        guard let url = SpriteSheet.url(for: animal),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let g = SpriteSheet.grid
        let cut = Frame.allCases.compactMap { sheet.cropping(to: CGRect(x: $0.rawValue * g, y: 0, width: g, height: g)) }
        guard cut.count == Frame.allCases.count else { return nil }
        frames = cut
    }

    subscript(_ f: Frame) -> CGImage { frames[f.rawValue] }

    private static func url(for animal: Animal) -> URL? {
        if let u = Bundle.main.url(forResource: animal.rawValue, withExtension: "png", subdirectory: "sprites") { return u }
        // `swift run` 으로 번들 없이 실행할 때: 작업 폴더의 Resources 를 쓴다
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/sprites/\(animal.rawValue).png")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    /// 도트가 뭉개지지 않게 최근접 보간으로 그린 NSImage (메뉴 막대·패널용).
    func image(_ f: Frame, points: CGFloat) -> NSImage {
        let cg = self[f]
        return NSImage(size: NSSize(width: points, height: points), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: rect)
            return true
        }
    }
}
