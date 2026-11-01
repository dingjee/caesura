import Foundation

/// Morning time with sunrise computed using the NOAA solar equations
/// (replacing the meeussunmoon dependency). Polar day/night fallback: when the sun does
/// not cross the horizon, fall back to the default `morningHour` (6) so the pause always
/// has a finite end; the fallback is logged.
public enum UntilMorning {
    public static func msToSunrise(settings: SettingsStore, clock: Clock = SystemClock(), calendar: Calendar = .current) -> Int64 {
        let now = Date(timeIntervalSince1970: TimeInterval(clock.nowMillis) / 1000)
        var morningHour = 6.0
        var nextMorning: Date?

        if let stringValue = settings.get("morningHour")?.stringValue, stringValue == "sunrise" {
            let latitude = settings.getDouble("posLatitude")
            let longitude = settings.getDouble("posLongitude")
            if let sunrise = todaySunrise(beforeEndOf: now, latitude: latitude, longitude: longitude, calendar: calendar) {
                nextMorning = sunrise
                morningHour = Double(calendar.component(.hour, from: sunrise))
            } else {
                Log.warn("Caesura: sunrise unavailable (polar day/night or bad coordinates); falling back to 6:00")
                morningHour = 6
                nextMorning = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: now)
            }
        } else {
            morningHour = settings.get("morningHour")?.doubleValue ?? 6
            let hour = Int(min(max(morningHour, 0), 23))
            nextMorning = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now)
        }

        // Legacy: when the computed morning moment already lies in the past, aim at
        // tomorrow (covers fixed-hour, polar fallback, and past sunrises alike).
        if let morning = nextMorning, morning <= now {
            nextMorning = morning.addingTimeInterval(86400)
        }

        let millis = Int64((nextMorning ?? now).timeIntervalSince(now) * 1000)
        return max(0, millis)
    }

    /// Sunrise on the calendar day of `now` (may be in the past), like legacy
    /// `MeeusSunMoon.sunrise(dt, …)`; nil for polar day/night.
    static func todaySunrise(beforeEndOf now: Date, latitude: Double, longitude: Double, calendar: Calendar) -> Date? {
        let day = calendar.startOfDay(for: now)
        guard let dayOfYear = calendar.ordinality(of: .day, in: .year, for: day),
              let year = calendar.dateComponents([.year], from: day).year else { return nil }
        return SunriseCalculator.sunriseUTC(dayOfYear: dayOfYear, year: year,
                                            latitude: latitude, longitude: longitude,
                                            timeZone: calendar.timeZone)
    }

    /// Next sunrise strictly after `now`; nil for polar day/night on both candidate days.
    static func nextSunrise(after now: Date, latitude: Double, longitude: Double, calendar: Calendar) -> Date? {
        for dayOffset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)) else {
                continue
            }
            guard let dayOfYear = calendar.ordinality(of: .day, in: .year, for: day),
                  let year = calendar.dateComponents([.year], from: day).year else { continue }
            if let sunrise = SunriseCalculator.sunriseUTC(dayOfYear: dayOfYear, year: year,
                                                          latitude: latitude, longitude: longitude,
                                                          timeZone: calendar.timeZone),
               sunrise > now {
                return sunrise
            }
        }
        return nil
    }
}

/// NOAA sunrise calculation (GML "General Solar Position Calculations").
/// Input longitude is east-positive (GPS convention); NOAA uses west-positive, so it is
/// negated in the formula. Returns UTC instants.
enum SunriseCalculator {
    static func sunriseUTC(dayOfYear: Int, year: Int, latitude: Double, longitude: Double, timeZone: TimeZone) -> Date? {
        guard abs(latitude) <= 90 else { return nil }
        let gamma = 2.0 * .pi / 365.0 * (Double(dayOfYear) - 1 + 0.5)
        let eqTimeMinutes = 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
            - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
        let decl = (0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma)
            - 0.006758 * cos(2 * gamma) + 0.000907 * sin(2 * gamma)
            - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma))
        let latRad = latitude * .pi / 180
        let zenith = 90.833 * .pi / 180 // official sunrise
        let cosOmega = (cos(zenith) - sin(latRad) * sin(decl)) / (cos(latRad) * cos(decl))
        guard cosOmega >= -1, cosOmega <= 1 else { return nil } // polar day or night
        let omegaDegrees = acos(cosOmega) * 180 / .pi
        // NOAA calcSunriseSetUTC: timeUTC(minutes) = 720 - 4*(longitude + ha) - eqTime,
        // with longitude east-positive (GPS convention).
        let minutesUTC = 720 - 4 * (longitude + omegaDegrees) - eqTimeMinutes
        // Anchor the UTC minutes onto the UTC midnight of the UTC day containing local noon:
        // utcMidnight = localNoon + tzOffset - 12h  (localNoon = utcNoon - tzOffset).
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year
        components.month = 1
        components.day = dayOfYear
        components.hour = 12
        guard let localNoon = calendar.date(from: components) else { return nil }
        return localNoon + Double(timeZone.secondsFromGMT(for: localNoon)) - 43200 + minutesUTC * 60
    }
}
