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
        resourceURL(animal.rawValue)
    }

    /// sprites 폴더의 PNG 위치.
    static func resourceURL(_ name: String) -> URL? {
        if let u = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "sprites") { return u }
        // `swift run` 으로 번들 없이 실행할 때: 작업 폴더의 Resources 를 쓴다
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/sprites/\(name).png")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    /// 메뉴 막대용 그림들. 주어진 프레임들에서 그림이 있는 영역만 공통으로 잘라 내서
    /// 프레임이 바뀌어도 위치가 흔들리지 않게 하고, 막대 높이에 맞춰 크기를 정한다.
    func barImages(_ wanted: [Frame], maxHeight: CGFloat) -> [Frame: NSImage] {
        guard let crop = contentBounds(wanted) else { return [:] }
        // 논리 픽셀 1칸 = 1pt 가 가장 선명하다. 키가 큰 동물(토끼)만 막대 높이에 맞춰 줄인다.
        let scale = min(1, maxHeight / crop.height)
        let size = NSSize(width: (crop.width * scale).rounded(), height: (crop.height * scale).rounded())
        var out: [Frame: NSImage] = [:]
        for f in wanted {
            guard let cg = self[f].cropping(to: crop) else { continue }
            out[f] = NSImage(size: size, flipped: false) { rect in
                guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                ctx.interpolationQuality = .none
                ctx.draw(cg, in: rect)
                return true
            }
        }
        return out
    }

    /// 주어진 프레임들에서 그림이 있는 영역 (논리 px, 위에서부터 센 좌표).
    func contentBounds(_ wanted: [Frame]) -> CGRect? {
        let g = SpriteSheet.grid
        var minX = g, maxX = -1, minY = g, maxY = -1
        var pixels = [UInt8](repeating: 0, count: g * g * 4)
        for f in wanted {
            pixels.withUnsafeMutableBytes { buf in
                guard let ctx = CGContext(data: buf.baseAddress, width: g, height: g, bitsPerComponent: 8,
                                          bytesPerRow: g * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                ctx.clear(CGRect(x: 0, y: 0, width: g, height: g))
                ctx.draw(self[f], in: CGRect(x: 0, y: 0, width: g, height: g))
            }
            for y in 0..<g {
                for x in 0..<g where pixels[(y * g + x) * 4 + 3] > 0 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
