import Foundation

enum ReaderCustomColorCodec {
    typealias Colors = (background: (Double, Double, Double), foreground: (Double, Double, Double))

    static func decode(_ raw: String) -> Colors {
        let parts = raw
            .split(separator: ",")
            .compactMap { Double($0) }
        guard parts.count == 6 else {
            return ((1, 1, 1), (0, 0, 0))
        }
        return ((parts[0], parts[1], parts[2]),
                (parts[3], parts[4], parts[5]))
    }

    static func encode(_ colors: Colors) -> String {
        let components = [colors.background.0, colors.background.1, colors.background.2,
                 colors.foreground.0, colors.foreground.1, colors.foreground.2]
        return components.map { String(format: "%.4f", $0) }.joined(separator: ",")
    }
}
