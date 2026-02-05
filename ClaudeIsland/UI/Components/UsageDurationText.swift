import SwiftUI

enum UsageDurationText {
    /// Creates a colorized duration label like `1d 10h 50m` or (when <1h) `12m 34s`.
    ///
    /// - Note: We keep digits and unit letters separately so we can color just the unit suffix.
    static func make(
        seconds: Int,
        digitColor: Color = Color.white.opacity(0.32),
        dayUnitColor: Color = TerminalColors.amber.opacity(0.95),
        hourUnitColor: Color = TerminalColors.blue.opacity(0.85),
        minuteUnitColor: Color = TerminalColors.cyan.opacity(0.55),
        secondUnitColor: Color = Color.white.opacity(0.35)
    ) -> Text {
        let clamped = max(0, seconds)

        func part(_ value: String, unit: String, unitColor: Color) -> Text {
            Text(value).foregroundColor(digitColor)
                + Text(unit).foregroundColor(unitColor)
        }

        let spacer = Text(" ").foregroundColor(digitColor)

        if clamped < 60 {
            return Text("<1").foregroundColor(digitColor)
                + Text("m").foregroundColor(minuteUnitColor)
        }

        if clamped < 3_600 {
            let minutes = clamped / 60
            let seconds = clamped % 60
            return part("\(minutes)", unit: "m", unitColor: minuteUnitColor)
                + spacer
                + part(String(format: "%02d", seconds), unit: "s", unitColor: secondUnitColor)
        }

        var remaining = clamped
        let days = remaining / 86_400
        remaining %= 86_400
        let hours = remaining / 3_600
        remaining %= 3_600
        let minutes = remaining / 60

        if days > 0 {
            return part("\(days)", unit: "d", unitColor: dayUnitColor)
                + spacer
                + part("\(hours)", unit: "h", unitColor: hourUnitColor)
                + spacer
                + part("\(minutes)", unit: "m", unitColor: minuteUnitColor)
        }

        return part("\(hours)", unit: "h", unitColor: hourUnitColor)
            + spacer
            + part(String(format: "%02d", minutes), unit: "m", unitColor: minuteUnitColor)
    }
}

