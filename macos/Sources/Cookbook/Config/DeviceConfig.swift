import Foundation

/// Per-mode device list and conversion settings. Built-in defaults; user edits go to UserDefaults.
struct DeviceConfig: Codable, Equatable {
    var defaultKey: String?
    var language: String?
    var fontSize: Int
    var pageCompression: Bool
    var fontSerif: String
    var fontSans: String
    var fontMono: String
    var devices: [DeviceInfo]

    static func builtIn(kind: String) -> DeviceConfig {
        let fonts = (
            serif: "Hiragino Mincho ProN",
            sans: "Hiragino Sans",
            mono: "Menlo"
        )
        if kind == "pdf" {
            return DeviceConfig(
                defaultKey: "kpw11",
                language: nil,
                fontSize: 120,
                pageCompression: false,
                fontSerif: fonts.serif, fontSans: fonts.sans, fontMono: fonts.mono,
                devices: [
                    DeviceInfo(key: "kpw11", label: "Kindle Paperwhite 11th",
                               width: 1236, height: 1648, supersample: 3, orientation: "landscape"),
                    DeviceInfo(key: "rp1", label: "Sony DPT-RP1",
                               width: 1650, height: 2200, supersample: 3, orientation: "portrait"),
                ]
            )
        }
        return DeviceConfig(
            defaultKey: "x3",
            language: nil,
            fontSize: 60,
            pageCompression: false,
            fontSerif: fonts.serif, fontSans: fonts.sans, fontMono: fonts.mono,
            devices: [
                DeviceInfo(key: "x3", label: "Xteink X3",
                           width: 528, height: 792, supersample: 3, orientation: "portrait"),
                DeviceInfo(key: "x4", label: "Xteink X4",
                           width: 480, height: 800, supersample: 3, orientation: "portrait"),
            ]
        )
    }
}

enum DeviceConfigStore {
    static func load(kind: String) -> DeviceConfig {
        if let data = UserDefaults.standard.data(forKey: key(kind)),
           let cfg = try? JSONDecoder().decode(DeviceConfig.self, from: data),
           (try? validate(cfg, kind: kind)) != nil {
            return cfg
        }
        return .builtIn(kind: kind)
    }

    static func save(_ config: DeviceConfig, kind: String) throws {
        try validate(config, kind: kind)
        let data = try JSONEncoder().encode(config)
        UserDefaults.standard.set(data, forKey: key(kind))
    }

    static func validate(_ config: DeviceConfig, kind: String) throws {
        if config.devices.isEmpty {
            throw AppError.message("At least one device is required.")
        }
        if let def = config.defaultKey, !config.devices.contains(where: { $0.key == def }) {
            throw AppError.message("default '\(def)' is not one of the defined devices.")
        }
        var seen = Set<String>()
        for dev in config.devices {
            if dev.key.isEmpty { throw AppError.message(L10n.t("errEmptyKey")) }
            if seen.contains(dev.key) { throw AppError.message(L10n.t("errDuplicateKey", ["key": dev.key])) }
            seen.insert(dev.key)
            if dev.width <= 0 || dev.height <= 0 {
                throw AppError.message("\(dev.key) width/height must be positive.")
            }
            if kind == "xtch" && dev.supersample <= 0 {
                throw AppError.message("\(dev.key) supersample must be a positive integer.")
            }
            if kind == "xtch" && dev.height % 8 != 0 {
                throw AppError.message("\(dev.key) height must be a multiple of 8.")
            }
            if dev.orientation != "portrait" && dev.orientation != "landscape" {
                throw AppError.message("\(dev.key) orientation must be portrait or landscape.")
            }
        }
        if config.fontSize <= 0 { throw AppError.message(L10n.t("errFontSize")) }
        if config.fontSerif.isEmpty || config.fontSans.isEmpty || config.fontMono.isEmpty {
            throw AppError.message(L10n.t("errFontsRequired"))
        }
    }

    private static func key(_ kind: String) -> String {
        "dev.cookbook.config.\(kind)"
    }
}
